#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Codex 模型切换器.app"
INSTALL_APP="${INSTALL_APP:-$HOME/Applications/Codex 模型切换器.app}"
LEGACY_APP="$HOME/Applications/Codex Model Switcher.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/Assets/AppIcon.png"
ICON_PREPARE="$ROOT/Tools/PrepareAppIcon.swift"
ICON_WORK="$BUILD_DIR/icon"
ICONSET="$ICON_WORK/AppIcon.iconset"

osascript -e 'tell application id "local.codex.model-switcher" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "com.openai.codex.switcher" to quit' >/dev/null 2>&1 || true
pkill -x CodexModelSwitcher >/dev/null 2>&1 || true

rm -rf "$BUILD_DIR" "$INSTALL_APP" "$LEGACY_APP"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET" "$(dirname "$INSTALL_APP")"

swift "$ICON_PREPARE" "$ICON_SOURCE" "$ICON_WORK/AppIcon.png"

sips -z 16 16 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_WORK/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

swiftc \
  -O \
  -parse-as-library \
  "$ROOT/Sources/CodexModelSwitcher.swift" \
  -o "$MACOS/CodexModelSwitcher" \
  -framework SwiftUI \
  -framework AppKit

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
if [ -f "$ROOT/provider-safe-guard.mjs" ]; then
    cp "$ROOT/provider-safe-guard.mjs" "$RESOURCES/"
fi
chmod +x "$MACOS/CodexModelSwitcher"
codesign --force --sign - "$APP" >/dev/null

cp -R "$APP" "$INSTALL_APP"
codesign --verify --deep --strict "$INSTALL_APP"
rm -rf "$APP"

echo "$INSTALL_APP"
