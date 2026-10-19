# Tests

Three requirements, one directory each. `tests/run.sh` checks all of them in about 12 seconds, offline:
it never touches the screen, the pointer, the focus or the running agent.

| # | Directory | Requirement | How it is checked |
|---|---|---|---|
| 1 | `1-external/` | The external display is never affected | Only the built-in display is a target by default (`Display.isTarget`). A browser blacks out protected video whenever any capture runs anywhere, so while any browser (Chrome, Edge…; not Spotify) has a CDM process alive (protected video open: playing, paused or buffering) every capture is stopped (`ProtectedPlayback.isBrowserCDM`, `Session.captureAllowed`). Sessions are created only for target displays, and every refresh puts a window that drifted off its display back (`2-animation/structure.py`). On the real screen, `1-external/watch.swift` records every 0.1 s whether a Matte window is on the external display (read-only, safe while the computer is in use). |
| 2 | `2-animation/` | The built-in display's system animations stay exactly as they are and never drop a frame | No capture while the system zooms into or out of full screen or slides Spaces: every capture passes one gate, `Session.captureAllowed` (unit-tested state by state). `structure.py` checks the source: every capture start sits behind that gate, nothing writes a system setting or animation, Space calls stay in the approved places, window levels stay main menu + 1 (band) and normal + 1 (bars). `zoom-cases.txt`: the system's zoom out and in, frame by frame (1/30 s) over a dark desktop, must add no bar at any point, and a letterboxed video's bars must not change while it zooms out. |
| 3 | `3-color/` | On the built-in display every area the system paints black becomes the fill, in every case | Offline rendering of the real `BandView` / `BarsView`: menu bar hidden, menu bar shown (titles kept, black background replaced), menu bar gone, no capture (transition, DRM), encoded and player black in the bars, subtitles kept, band and bars the same fill. Bar detection against `bars/expected.txt` (16 cases, synthetic samples from `tools/bars-regression/synth.py`); static app screens (`--still`) never get bars. |

## When to run

1. **After every change to `src/`**: `tests/run.sh`. A change is done only when it is all green.
2. **Before every push**: the git hooks run it again on commit and on push and refuse anything that isn't green
   (`tests/install-hooks.sh` once per clone links `tests/hook.sh` as `pre-commit` and `pre-push`; the push hook
   also refuses uncommitted changes in `src/`, `tests/`, `tools/`, so the pushed code is the tested code).
3. **An intended change to bar detection**: `tests/run.sh --bless-bars` rewrites `3-color/bars/expected.txt`;
   review its diff and say why each line changed in the commit message.
4. **A new requirement or a bug no check caught**: add the check first and confirm it fails on the broken
   code, then fix. Every check here was confirmed that way (9 deliberate bugs, all caught: an external display
   targeted, Spotify's CDM counted, DRM ignored, capture during the zoom, an ungated capture start, a system
   setting written, the screen blend dropped, a static dark UI given bars, bars adopted from the zoom animation).

## Not covered offline

What only the real screen shows (frame pacing during the system zoom, the menu bar mirror's 1-2 frame lag, live
DRM behaviour) is checked live, and only while nobody is using the computer: the pointer, the focus and the
keyboard are shared by every display.
