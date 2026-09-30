// Fills the area around the picture inside mpv itself. `background` takes the agent's color on the
// displays Matte targets; bars baked into the video are pushed out of view with VO geometry
// (margins + zoom + pan), which never touches the filter chain or the hardware decoder. This is the
// window's steady state, not a full-screen reaction: IINA freezes mpv rendering for the whole
// full-screen animation and stretches the last windowed frame, so that frame must already be matted.
// IINA keeps mpv's keepaspect off while windowed (which disables the geometry); we turn it on.
// Bars are measured from async screenshots that the matte-fill agent analyzes, and remembered per file.
const { core, event, mpv, file, utils } = iina;

const STATE = "~/Library/Caches/matte-fill/state.json";
const DATA = "@data/";
const GEOM = ["video-margin-ratio-left", "video-margin-ratio-right", "video-margin-ratio-top",
              "video-margin-ratio-bottom", "video-zoom", "video-pan-x", "video-pan-y"];
const MAX_SHOTS = 40;

// mpv's own values for what we override, captured on first use (mpv may not be up at load time).
let orig = null;
function captureOrig() {
  orig = { background: mpv.getString("background") || "#000000" };
  GEOM.forEach((p) => { orig[p] = mpv.getNumber(p) || 0; });
}
let appliedBg = null, appliedGeom = null, ownKeepaspect = false, lastError = null;

let stCache = null, stAt = 0;
function readState() {
  const now = Date.now();
  if (now - stAt < 200) return stCache;
  stAt = now;
  try { stCache = file.exists(STATE) ? JSON.parse(file.read(STATE)) : null; } catch (e) { stCache = null; }
  return stCache;
}

// The agent's entry for the display this window is on, or null when Matte doesn't target it.
function targetScreen(st) {
  const cur = (core.window.screens || []).find((s) => s.current);
  if (!cur || !st || !st.screens) return null;
  const a = cur.frame;
  return st.screens.find((s) => Math.abs(s.x - a.x) < 1 && Math.abs(s.y - a.y) < 1 &&
                                Math.abs(s.w - a.width) < 1 && Math.abs(s.h - a.height) < 1) || null;
}

// MARK: bar detection (per file: screenshots after 0.2/1.5/4/8/15 s of actual playback, so a resumed
// film is measured right away, plus one per 30 s of playback position)

let media = null;
function hash(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

const EARLY_MS = [200, 1500, 4000, 8000, 15000];

function shotTick() {
  const url = core.status.url;
  if (!url) { media = null; return; }
  const now = Date.now();
  if (!media || media.url !== url) {
    media = { url, key: hash(url), n: 0, played: 0, early: 0, bins: {}, pending: {}, results: [], bars: null, color: null, at: now };
    try {   // a file seen before starts fully matted, before its first frame
      const saved = `${DATA}bars-${media.key}.json`;
      if (file.exists(saved)) Object.assign(media, JSON.parse(file.read(saved)));
    } catch (e) {}
    aggregate();
  }
  const dt = now - media.at;
  media.at = now;
  collect();
  const vp = mpv.getNative("video-out-params");
  if (!vp || !vp.dw || core.status.paused || media.n >= MAX_SHOTS) return;
  media.played += dt;
  const pos = mpv.getNumber("time-pos");
  const bin = pos >= 0 ? Math.floor(pos / 30) : -1;
  let take = false;
  if (media.early < EARLY_MS.length && media.played >= EARLY_MS[media.early]) { media.early++; take = true; }
  else if (media.early > 0 && bin >= 0 && !media.bins[bin]) take = true;
  if (!take) return;
  if (bin >= 0) media.bins[bin] = true;
  const name = `shot-${media.key}-${media.n++}`;
  const path = utils.resolvePath(`${DATA}${name}.jpg`);
  if (!path) return;
  mpv.command("no-osd", ["async", "screenshot-to-file", path, "video"]);   // encoded on an mpv worker thread
  media.pending[name] = now;
}

// Picks up the agent's analyses and remembers them for the file.
function collect() {
  let changed = false;
  for (const name of Object.keys(media.pending)) {
    const res = `${DATA}${name}.json`;
    if (!file.exists(res)) {
      if (Date.now() - media.pending[name] > 15000) delete media.pending[name];
      continue;
    }
    delete media.pending[name];
    let r = null;
    try { r = JSON.parse(file.read(res)); } catch (e) {}
    file.delete(res);
    if (!r) continue;
    if (r.info) media.results.push({ top: r.top, bottom: r.bottom, left: r.left, right: r.right, info: true });
    if (r.color) media.color = r.color;
    changed = true;
  }
  if (!changed) return;
  aggregate();
  file.write(`${DATA}bars-${media.key}.json`, JSON.stringify({ results: media.results.slice(-MAX_SHOTS), color: media.color }));
}

// Bars are the per-side minimum over informative frames, so a dark scene can only ever shrink them.
function aggregate() {
  const inf = media.results.filter((r) => r.info);
  if (inf.length < 1) { media.bars = null; return; }
  const side = (k) => { const v = Math.min(...inf.map((r) => r[k])); return v >= 0.005 ? v : 0; };
  const b = { t: side("top"), b: side("bottom"), l: side("left"), r: side("right") };
  // Real bars are nearly always symmetric; a lopsided result is more likely a dark scene edge,
  // so it needs a third frame to back it up.
  const lopsided = Math.abs(b.t - b.b) > 0.01 || Math.abs(b.l - b.r) > 0.01;
  media.bars = b.t + b.b + b.l + b.r > 0 && (!lopsided || inf.length >= 3) ? b : null;
}

// MARK: geometry

let lastDims = null, dimsSince = 0;
function geometry(scr) {
  const vp = mpv.getNative("video-out-params"), od = mpv.getNative("osd-dimensions");
  const bars = media && media.bars;
  if (!bars || !vp || !vp.dw || !vp.dh || !od || !od.w || !od.h || (vp.rotate || 0) % 180) return null;
  // Windowed: fit the window exactly. Full screen: until the window has kept its size for 300 ms,
  // assume native full screen (below the camera housing); then the real window is authoritative.
  const now = Date.now(), dims = `${od.w}x${od.h}`;
  if (dims !== lastDims) { lastDims = dims; dimsSince = now; }
  const cur = od.w / od.h;
  const fin = !fsNow || now - dimsSince >= 300 ? cur : scr.w / (scr.h - (scr.top || 0));
  const { t, b, l, r } = bars;
  const fx = 1 - l - r, fy = 1 - t - b, ca = (vp.dw / vp.dh) * fx / fy;
  // Clipping top/bottom bars needs area aspect >= content aspect, side bars the reverse; the window
  // aspect animates between the last reading and the final value, so size for the safe extreme.
  const we = t + b >= l + r ? Math.min(cur, fin) : Math.max(cur, fin);
  const my = Math.max(0, (1 - we / ca) / 2), mx = Math.max(0, (1 - ca / we) / 2);
  const areaPx = Math.min(od.w * (1 - 2 * mx), od.h * (1 - 2 * my));
  const zoom = Math.log2(fx > fy ? 1 / fy : 1 / fx) + Math.log2(1 + 6 / areaPx);   // ~3 px overscan hides rounding
  return { "video-margin-ratio-left": mx, "video-margin-ratio-right": mx,
           "video-margin-ratio-top": my, "video-margin-ratio-bottom": my,
           "video-zoom": zoom, "video-pan-x": -(l - r) / 2, "video-pan-y": -(t - b) / 2 };
}

function setGeometry(g) {
  const want = g || orig;
  const key = GEOM.map((p) => want[p].toFixed(5)).join(",");
  if (key === appliedGeom) return;
  GEOM.forEach((p) => mpv.set(p, want[p]));
  appliedGeom = key;
}

// MARK: main loop

// Small color helpers so the letterbox background can ease from black to the target color.
function hexRGB(h) { h = h.replace("#", ""); return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]; }
function rgbHex(r, g, b) { const f = (x) => Math.max(0, Math.min(255, Math.round(x))).toString(16).padStart(2, "0"); return "#" + f(r) + f(g) + f(b); }
function mix(a, b, t) { const A = hexRGB(a), B = hexRGB(b); return rgbHex(A[0] + (B[0] - A[0]) * t, A[1] + (B[1] - A[1]) * t, A[2] + (B[2] - A[2]) * t); }

const ZOOM_MS = 450;   // IINA freezes mpv for roughly this long during the full-screen zoom
let fsNow = false, fsPrev = false, fsEdge = 0, lastReport = 0, lastKey = "";
function update() {
  if (!orig) captureOrig();
  const now = Date.now();
  const st = readState();
  const scr = core.window.loaded ? targetScreen(st) : null;
  fsNow = !!(core.window.loaded && core.window.fullscreen);
  if (fsNow && !fsPrev) fsEdge = now;   // full-screen rising edge
  fsPrev = fsNow;
  // The letterbox is black during the zoom (mpv frozen, the window hasn't covered the bars yet). Only
  // after the zoom (~ZOOM_MS) is mpv rendering the bars again -- start the dark->light fade there so it
  // is actually seen, over `fade` seconds, instead of a pop.
  const target = !scr ? orig.background : (scr.active || !media || !media.color ? scr.color : media.color);
  let bg = target;
  if (scr && fsNow && target) {
    const fade = (st && st.fade > 0) ? st.fade * 1000 : 0;
    const el = now - fsEdge - ZOOM_MS;
    if (fade <= 0 || el >= fade) bg = target;
    else if (el < 0) bg = "#000000";                       // still zooming (frozen; invisible)
    else { const p = el / fade; bg = mix("#000000", target, p * p * (3 - 2 * p)); }   // smoothstep
  }
  if (bg && bg !== appliedBg) { mpv.set("background", bg); appliedBg = bg; }
  const g = scr ? geometry(scr) : null;
  setGeometry(g);
  // IINA sets keepaspect=no on load and whenever it leaves full screen; while matting, keep it on.
  if (g && !fsNow && (!ownKeepaspect || !mpv.getFlag("keepaspect"))) { mpv.set("keepaspect", true); ownKeepaspect = true; }
  else if (!g && ownKeepaspect && !fsNow) { mpv.set("keepaspect", false); ownKeepaspect = false; }

  // Written at once when full screen flips (the agent shows the notch band from it) and every second.
  const cur = (core.window.screens || []).find((x) => x.current);
  const key = `${fsNow}|${!!scr}`;
  if (now - lastReport >= 1000 || key !== lastKey) {
    lastReport = now; lastKey = key;
    file.write(`${DATA}status.json`, JSON.stringify({
      t: now, targeted: !!scr, fullscreen: fsNow, screen: cur ? cur.frame : null, background: appliedBg,
      geometry: g, error: lastError, bars: media && media.bars, shots: media ? media.n : 0,
      analyzed: media ? media.results.length : 0,
    }));
  }
}

function guarded(fn) {
  return () => { try { fn(); } catch (e) { lastError = `${new Date().toISOString()} ${e}`; } };
}

event.on("iina.window-loaded", guarded(update));
event.on("iina.window-screen.changed", guarded(update));
setInterval(guarded(shotTick), 250);
setInterval(guarded(update), 30);
