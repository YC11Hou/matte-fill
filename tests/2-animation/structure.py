"""Source checks for requirements 1 and 2 on src/main.swift: no system setting or animation is ever
changed, every capture starts only behind the one gate (Session.captureAllowed via calm()), windows sit
at their fixed levels, sessions exist only for target displays. Exits non-zero on any violation."""
import re
import sys

src = open(sys.argv[1]).read().split("\n")
fails = 0


def check(ok, what):
    global fails
    print(("  ok   " if ok else "  FAIL ") + what)
    fails += 0 if ok else 1


def code(line):
    return line.split("//")[0]


def owner(i):
    """(class, func) enclosing line i."""
    cls = fn = None
    for j in range(i, -1, -1):
        m = re.match(r"\s*(?:@objc\s+)?(?:(?:private|static|override)\s+)*func\s+(\w+)", src[j])
        if fn is None and m:
            fn = m.group(1)
        m = re.match(r"(?:final\s+)?class\s+(\w+)", src[j])
        if m:
            cls = m.group(1)
            break
    return cls, fn


def sites(pattern):
    """Call sites (declarations of private APIs excluded)."""
    return [(i, owner(i)) for i, l in enumerate(src) if re.search(pattern, code(l)) and "@_silgen_name" not in l]


def body(cls, fn):
    """Source of func fn inside class cls."""
    for i, l in enumerate(src):
        if re.match(r"\s*(?:@objc\s+)?(?:(?:private|static|override)\s+)*func\s+" + fn + r"\b", l) and owner(i) == (cls, fn):
            depth, out = 0, []
            for k in range(i, len(src)):
                out.append(src[k])
                depth += code(src[k]).count("{") - code(src[k]).count("}")
                if depth == 0 and "{" in "".join(out):
                    return "\n".join(out)
    return ""


print("source rules")
forbidden = [
    (r"defaults\s+(write|delete)", "writes system preferences"),
    (r"killall", "kills a system process (Dock, SystemUIServer)"),
    (r"com\.apple\.dock|workspaces-swoosh|expose-animation|NSAutomaticWindowAnimationsEnabled", "touches system animation settings"),
    (r"reduceMotion|ReduceMotion", "touches Reduce Motion"),
    (r"CGSManagedDisplaySetCurrentSpace|SLSManagedDisplaySetCurrentSpace|CGSSetWindowTransform|SLSSetWindowTransform", "drives Spaces or system windows"),
]
for pat, why in forbidden:
    hits = [i + 1 for i, l in enumerate(src) if re.search(pat, code(l))]
    check(not hits, f"never {why}" + (f" (lines {hits})" if hits else ""))

# Space membership calls stay where the approved design puts them (CLAUDE.md 4.7.1): our two windows only.
for name, allowed in [("SLSAddWindowsToSpaces\\(", {("Session", "adopt"), ("Session", "pin")}),
                      ("SLSRemoveWindowsFromSpaces\\(", {("Session", "sweep")})]:
    where = {o for _, o in sites(name)}
    check(where <= allowed, f"{name[:-2]} only in {sorted(f for _, f in allowed)} (found {sorted(f for _, f in where)})")

print("capture gate")
gate = {
    r"\.startCapture\b": {("Sampler", "prepare"), ("Sampler", "start"), ("Sampler", "setMirror"),
                          ("MenuBarWatcher", "prepare"), ("MenuBarWatcher", "start")},
    r"sampler\??\.start\(\)": {("Session", "startSampling")},
    r"menuBar\??\.start\(\)": {("Session", "paceMenuBar")},
    r"sampler\??\.setMirror\(true\)": {("Session", "startSampling"), ("Session", "applyBars")},
}
for pat, allowed in gate.items():
    where = {o for _, o in sites(pat)}
    check(where <= allowed, f"{pat} only in {sorted(f for _, f in allowed)} (found {sorted(f for _, f in where)})")
for fn in ["startSampling", "paceMenuBar", "applyBars"]:
    check("calm(" in body("Session", fn), f"Session.{fn} passes the gate calm() before starting capture")
calm = body("Session", "calm")
check("Session.captureAllowed(" in calm and "protectedMode" in calm and "exiting" in calm,
      "calm() is Session.captureAllowed fed with protected playback and exit state")
# The Sampler/MenuBarWatcher stream starts above only run when their own start() was called.
for cls in ["Sampler", "MenuBarWatcher"]:
    check("if self.running" in body(cls, "prepare"), f"{cls}.prepare starts capture only if start() was already called")

print("menu bar")
amb = body("Session", "applyMenuBar")
check("Session.menuBarYield(" in amb, "applyMenuBar decides through Session.menuBarYield (unit-tested)")
check("protectedMode else { return }" not in amb, "applyMenuBar still runs in protected mode: the band must yield there too")
pmb = body("Session", "paceMenuBar")
check(pmb.count("calm(") >= 1 and pmb.count("calm(") == pmb.count("calm(now, strip: true)"),
      "every gate check in paceMenuBar is the strip gate: the menu bar is watched once the Space has switched, without waiting for the window")
check("Display.fullScreenOwner(" in body("Session", "watchForExit"), "the full-screen app is taken from the window filling the display, after the Space switch")

print("windows and displays")
panels = body("Session", "makePanels")
check("makePanel(level: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)" in panels, "notch band window: main menu + 1")
check("makePanel(level: Int(CGWindowLevelForKey(.normalWindow)) + 1)" in panels, "bars window: normal + 1")
made = sites(r"\bSession\(cfg:")
check(all(o[0] == "Controller" for _, o in made) and made, "sessions are created only by the Controller")
ctl = "\n".join(src[i] for i, o in enumerate(src) if o and owner(i)[0] == "Controller")
check("Display.targetScreens(" in ctl, "the Controller builds sessions from Display.targetScreens only")
check("p.frame != screen.frame" in body("Session", "refresh"), "every refresh puts a window that drifted off its display back")

print("structure: all passed" if fails == 0 else f"structure: {fails} FAILED")
sys.exit(1 if fails else 0)
