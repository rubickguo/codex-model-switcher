#!/usr/bin/env bash
# Codex Model Switcher - App Build Script
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Codex Model Switcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
LAUNCHER_SRC="$PROJECT_DIR/launcher.applescript"

echo "========================================================================"
echo "          正在构建 self-contained macOS 应用程序 (.app)..."
echo "========================================================================"

# Write AppleScript source code
cat << 'APPLESCRIPT' > "$LAUNCHER_SRC"
set appPath to POSIX path of (path to me)
if appPath ends with "/" then
  set resourcePath to appPath & "Contents/Resources"
else
  set resourcePath to appPath & "/Contents/Resources"
end if

-- Start any existing instances of our server running on port 18788
try
  do shell script "lsof -t -i :18788 | xargs kill -9"
end try

-- Launch Electron directly using the bundled binary via open
try
  set electronApp to resourcePath & "/node_modules/electron/dist/Electron.app"
  set mainJs to resourcePath & "/main.js"
  
  -- Open the Electron app bundle passing the script path as args
  do shell script "open -a " & quoted form of electronApp & " --args " & quoted form of mainJs
on error err
  display dialog "启动失败: " & err buttons {"好"} default button "好" with title "Codex Model Switcher"
end try
APPLESCRIPT

# Compile the AppleScript source into an .app bundle
echo "正在编译 AppleScript..."
rm -rf "$APP_BUNDLE"
osacompile -o "$APP_BUNDLE" "$LAUNCHER_SRC"

# Copy project files into App Resources folder
echo "正在将项目文件打包进 App 内部..."
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$RESOURCES_DIR/public"
mkdir -p "$RESOURCES_DIR/scripts"

cp "$PROJECT_DIR/main.js" "$PROJECT_DIR/package.json" "$RESOURCES_DIR/"
cp -R "$PROJECT_DIR/node_modules" "$RESOURCES_DIR/"
cp -R "$PROJECT_DIR/public/" "$RESOURCES_DIR/public/"
if [ -f "$PROJECT_DIR/scripts/provider-safe-guard.mjs" ]; then
    cp "$PROJECT_DIR/scripts/provider-safe-guard.mjs" "$RESOURCES_DIR/scripts/"
fi

# Clean up temp applescript file
rm -f "$LAUNCHER_SRC"

echo "========================================================================"
echo "构建成功! 应用程序已生成在:"
echo "👉 $APP_BUNDLE"
echo "您可以直接双击运行，或将其拖动到 /Applications 目录使用。"
echo "========================================================================"
