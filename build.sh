#!/bin/bash
# Build Matte.app into ~/Applications and (re)load the LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Matte.app"
LABEL="io.github.matte-fill"
mkdir -p "$APP/Contents/MacOS" build
swiftc -O -o build/matte-fill src/main.swift -framework Cocoa -framework ScreenCaptureKit -F /System/Library/PrivateFrameworks -framework SkyLight
cp build/matte-fill "$APP/Contents/MacOS/matte-fill"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Matte</string>
  <key>CFBundleExecutable</key><string>matte-fill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Samples the screen at low resolution to tint the notch band to match the current app.</string>
</dict></plist>
PL
codesign --force --sign - --identifier "$LABEL" -r="designated => identifier \"$LABEL\"" "$APP"
[ "${1:-}" = "--no-launchd" ] && exit 0
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
sed "s#__BIN__#$APP/Contents/MacOS/matte-fill#" launchd/agent.plist.template > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 1; done
echo "loaded $LABEL"

# Install the IINA plugin (takes effect on next IINA launch).
IINA_PLUGINS="$HOME/Library/Application Support/com.colliderli.iina/plugins"
if [ -d "$HOME/Library/Application Support/com.colliderli.iina" ]; then
  mkdir -p "$IINA_PLUGINS"
  rm -rf "$IINA_PLUGINS/matte-fill.iinaplugin"
  cp -R iina-plugin/matte-fill.iinaplugin "$IINA_PLUGINS/"
  defaults write com.colliderli.iina iinaEnablePluginSystem -bool true   # IINA 1.3 ships the plugin system disabled
  defaults write com.colliderli.iina "PluginEnabled.$LABEL" -bool true
  echo "installed IINA plugin (restart IINA to load)"
fi
