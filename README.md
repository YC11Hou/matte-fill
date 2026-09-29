# Matte

> Fill the black areas of full screen with a color that suits the picture.

On a MacBook, when any app goes full screen, the pure‑black regions the system or the player would otherwise draw — outside the app's own content — are replaced with a muted, low‑saturation color derived from what's on screen. Two kinds of region are handled:

1. the black strip beside the camera housing (the notch band), and
2. the letterbox / pillarbox bars of a video — both the ones the player draws and the ones baked into the video file.

By default this only applies to the MacBook's built‑in display; external displays are left untouched. A switch can extend it to every display. The name comes from film (the black borders around a frame) and from framing (the mat around a picture). The original motivation was a corner‑damaged panel that leaked light against a pure‑black background.

## Principles

- **Replace at the source, don't cover‑and‑cut.** Where a black region has a real color setting behind it, that setting is changed directly. In IINA this is mpv's `background`; overlays, the OSD and subtitles already draw on top of it, so nothing ever needs to be cut out and no black shows through.
- **Correct on the first frame.** Entering full screen, both the color and the geometry are prepared ahead of time — no black‑then‑color, no fade.
- **Plug and play.** No system file is modified and no process is injected; quitting the agent restores the system exactly.

## Components

| Part | Role |
|---|---|
| `src/main.swift` → `~/Applications/Matte.app` | A background agent (`LSUIElement`, no Dock icon, never takes focus). It (1) detects full screen per display; (2) samples the display at low resolution with ScreenCaptureKit and derives a color in OKLab; (3) covers the notch band with a colored strip; (4) analyzes screenshots the IINA plugin drops, to measure bars baked into a video; (5) for non‑IINA apps, colors detected letterbox bars with an overlay; (6) writes each display's color to `~/Library/Caches/matte-fill/state.json`. |
| `iina-plugin/matte-fill.iinaplugin` | Source‑level handling inside IINA. Sets mpv's `background` to Matte's color, and pushes bars baked into the video out of view in full screen using mpv's video geometry (`video-margin-ratio-*` + `video-zoom` + `video-pan-*`) — no video filter, no change to hardware decoding. |
| `launchd/agent.plist.template` | LaunchAgent `io.github.matte-fill`: starts at login, relaunches on crash. |
| `build.sh` | Compile → sign → reload the LaunchAgent → install the IINA plugin. |

## Instant Space switch — remove the transition seam and delay

When entering a native full‑screen Space, macOS slides the two Spaces past each other, and the black seam the compositor shows between them during that slide is drawn by WindowServer, where our windows can't reach. Turning off Dock's slide animation makes the switch an instant cut, so the seam and the delay are gone:

```bash
matte-fill --instant on    # instant full-screen switching (original value saved)
matte-fill --instant off   # restore
```

This toggles Dock's `workspaces-swoosh-animation-off` user preference — **no process is injected** — and is **fully reversible**: the original value is saved on enable and restored whenever the agent stops (normal quit, crash, or uninstall), with a marker file so the next launch reconciles after a crash. Enabling and restoring each relaunch Dock (windows and full‑screen sessions are preserved). Note this is a global Dock setting: Space switching on external displays becomes instant too; there is no per‑display equivalent.

## How it works

### Full‑screen detection

Per display: the display's current Space is a native full‑screen Space (`CGSCopyManagedDisplaySpaces` type 4), or a window covering the whole display (so IINA's "traditional full screen" is caught too). As soon as a full‑screen Space appears — the moment the zoom starts — the notch band is shown.

### Color

- A weighted OKLab mean of the picture inside the bars: rows near the top count 3×, the hue is the chroma‑weighted mean so vivid areas set the mood without dominating, and pure‑black pixels are excluded.
- Mapped to OKLCH: lightness `L = 0.26 + 0.45 × mean brightness`, clamped to `0.34–0.56`; chroma capped at `0.05`. A near‑neutral picture falls back to a warm graphite.
- The color is eased with an exponential curve (time constant 1.2 s). On entry it snaps to the first sample; in IINA it starts from the color of the most recently analyzed frame.

### IINA — bars baked into the video

1. The plugin takes an mpv screenshot (video only, no subtitles) after 0.2 / 1.5 / 4 / 8 / 15 s of playback, then one per 30 s of position, at most 40 per file. Each is written to the plugin's data folder.
2. The agent analyzes each screenshot — the per‑side bar fractions and a fill color — and writes the verdict back beside it.
3. Only frames whose picture spans one axis edge to edge count; a logo or a lone lit object on black is ignored. Each side takes the minimum over informative frames, so a dark scene can only shrink the bars. Symmetric bars apply after one informative frame; an asymmetric result needs three.
4. In full screen, margins frame the content, zoom fills it, pan centers it. IINA keeps mpv's `keepaspect` off while windowed (which disables this geometry) and turns it on synchronously as full screen starts, so the geometry is prepared while windowed and lands on the first full‑screen frame. The formula is validated offline against mpv 0.35's `video/out/aspect.c`.

### The full‑screen Space backdrop

A full‑screen Space is black wherever no app window reaches. The moment a Space is created, Matte's colored plate and the notch band become members of it (via `SLSAddWindowsToSpaces`), one level below normal windows, so the compositor draws the Space with Matte's color from its first frame, the slide‑in included. The plate never joins a desktop Space, so it can't tint the desktop or its widgets, and it's removed when the last full‑screen Space goes.

### Other apps — overlay (fallback)

Apps with no source hook get a colored overlay over the detected letterbox. Only that app's own window is sampled, so system HUDs don't trigger a cutout. On entry, without cached geometry, the whole screen is colored at once and the video region is carved out on the first sampled frame, turning a black‑then‑color jump into a color‑to‑video reveal.

## Configuration

`~/.config/matte-fill/config.json` — every field is optional and takes effect within a second:

```json
{ "displays": "builtin", "instantSpaceSwitch": false, "fallbackColor": "#3A3733", "adaptive": true,
  "coverBars": true, "minLightness": 0.34, "maxLightness": 0.56, "maxChroma": 0.05,
  "smoothingSeconds": 1.2, "sampleFPS": 10 }
```

`displays` is `builtin` (the MacBook's own display only) or `all` (every display). It can also be set with `matte-fill --displays builtin|all`.

## Install / update / uninstall

```bash
./build.sh     # compile, sign, install the LaunchAgent, install the IINA plugin (restart IINA to load it)
# First run: System Settings → Privacy & Security → Screen & System Audio Recording → enable Matte
~/Applications/Matte.app/Contents/MacOS/matte-fill --status
launchctl bootout gui/$(id -u)/io.github.matte-fill && rm ~/Library/LaunchAgents/io.github.matte-fill.plist
```

`build.sh` enables IINA's plugin system (`iinaEnablePluginSystem`, off by default) and this plugin.

## Debugging

| What | Where |
|---|---|
| Agent: show / hide, first‑frame color, config reload | `/tmp/matte-fill.log` |
| IINA plugin: targeted display, background, bars, geometry, errors | `~/Library/Application Support/com.colliderli.iina/plugins/.data/io.github.matte-fill/status.json` (once a second) |
| Color from a screenshot (overlay path) | `matte-fill --analyze shot.png` |
| Screenshot analysis (IINA path) | `matte-fill --analyze-shot frame.jpg` |
| On‑screen geometry | `matte-fill --preview` |

## Known limits

- Only active in full screen; ordinary windows are left as they are.
- Non‑IINA apps use the overlay fallback: bars baked into a video (part of the picture) can't be told apart from outside and remain, and there's a brief detection delay when a video's geometry is first seen.
- IINA's own black window background shows for the ~0.35 s of its full‑screen animation (IINA draws it; the plugin can't change it).
- The black seam of the native Space‑switch slide is drawn by WindowServer and can't be reached without touching a system process; use `--instant on` to make the switch instant instead.
