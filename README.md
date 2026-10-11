# Matte

**Matte fills the black areas of full screen with a color that suits the picture.** On a MacBook, when a video or an app goes full screen, the letterbox and pillarbox bars — and the camera-housing band beside the notch — are drawn pure black, and the frame ends up floating in a void. Matte replaces that black with a muted, low-saturation color sampled from the picture itself, so the surround feels like part of the image. It works at the source (mpv's `background` inside IINA, a colored overlay elsewhere), changes no system files and injects no process, and reverts completely when you quit. The original spark was a corner-damaged panel that leaked light against pure black.

## 1. The effect

The bar color is sampled from the picture, so it adapts to every scene — green fields, warm fur, cool mist:

![Without Matte (black bars) versus with Matte (bars colored to match), across six film scenes](docs/comparison-v5.jpg)

<sub>Frames from the open movies Big Buck Bunny and Sintel, (c) Blender Foundation, licensed CC BY 3.0.</sub>

## 2. See it in motion

[![Entering and leaving full screen, without and with Matte](docs/matte-demo-sintel.gif)](docs/matte-demo-sintel.mp4)

Entering full screen, the notch band takes the color at once and the bars ease from black to the matched color; leaving, they ease back to black and slide away with the system's own animation, which Matte never alters. Player UI — titles, controls, subtitles — stays exactly as it is: only the black underneath is replaced. Full-quality clips: [the comparison above](docs/matte-demo-sintel.mp4) and [a real-world run on YouTube](docs/matte-demo-youtube.mp4), with the title and controls coming and going over the bars.

<sub>Sintel trailer, (c) Blender Foundation, licensed CC BY 3.0. The only black left is about a tenth of a second in the notch band as macOS slides into a new full-screen Space: the system's slide doesn't draw other apps' windows.</sub>

## 3. Install

Requirements: a MacBook running macOS 14 or later, and (optional) [IINA](https://iina.io) for source-level video handling.

```bash
git clone https://github.com/YC11Hou/matte-fill.git
cd matte-fill
./build.sh
```

`build.sh` compiles the agent to `~/Applications/Matte.app`, installs a LaunchAgent that starts it at login, and installs the IINA plugin. On first run, grant screen recording:

> System Settings → Privacy & Security → Screen & System Audio Recording → enable **Matte**

Then it runs automatically. One optional control:

```bash
# which displays it works on (default: the built-in display only)
~/Applications/Matte.app/Contents/MacOS/matte-fill --displays builtin|all
```

Settings live in `~/.config/matte-fill/config.json` (every field optional, applied within a second); `fadeSeconds` (default 2.5) controls how slowly the color eases in. Matte never changes macOS's own animations. To uninstall:

```bash
launchctl bootout gui/$(id -u)/io.github.matte-fill
rm -r ~/Library/LaunchAgents/io.github.matte-fill.plist ~/Applications/Matte.app
```
