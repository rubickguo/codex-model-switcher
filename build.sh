#!/usr/bin/env bash
# Codex Switcher - Swift App Builder
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Codex 模型切换器"
APP_EXECUTABLE="CodexModelSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

echo "========================================================================"
echo "          正在编译并打包原生 Swift macOS 应用程序 (.app)..."
echo "========================================================================"

# Create App bundle directory structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile main.swift directly into the app bundle
echo "正在使用 swiftc 编译源代码..."
swiftc -O -o "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE" "$PROJECT_DIR/main.swift"

if [ -f "$PROJECT_DIR/scripts/provider-safe-guard.mjs" ]; then
    cp "$PROJECT_DIR/scripts/provider-safe-guard.mjs" "$APP_BUNDLE/Contents/Resources/"
fi

# Write Info.plist
echo "正在生成 Info.plist 配置..."
cat << 'PLIST' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexModelSwitcher</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.model-switcher</string>
    <key>CFBundleName</key>
    <string>Codex 模型切换器</string>
    <key>CFBundleDisplayName</key>
    <string>Codex 模型切换器</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Copy to ~/Applications and keep a backup of the previously installed build.
echo "正在安装到 $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALLED_APP" ]; then
    BACKUP_APP="$INSTALLED_APP.before-safe-fix-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALLED_APP" "$BACKUP_APP"
    echo "已备份旧版本到: $BACKUP_APP"
fi
cp -R "$APP_BUNDLE" "$INSTALL_DIR/"

# Clean up local workspace build to avoid duplication
rm -rf "$APP_BUNDLE"

echo "========================================================================"
echo "构建成功! 应用程序已安装在:"
echo "👉 $INSTALLED_APP"
echo "您可以直接在启动台 (Launchpad) 或 ~/Applications 中双击启动。"
echo "========================================================================"
