#!/usr/bin/env bash
# Codex Model Switcher - Launch Script
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=3000

echo "========================================================================"
echo "                   Codex Model Switcher Dashboard"
echo "========================================================================"

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
  echo "错误: 未找到 Node.js，请先安装 Node.js (https://nodejs.org)。"
  exit 1
fi

# Install dependencies if node_modules doesn't exist
if [ ! -d "$PROJECT_DIR/node_modules" ]; then
  echo "正在安装依赖 (Express)..."
  cd "$PROJECT_DIR"
  npm install
fi

# Function to stop server on exit
cleanup() {
  echo ""
  echo "正在关闭 Codex Model Switcher 后端服务..."
  kill $SERVER_PID 2>/dev/null || true
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Start Node server
echo "正在启动后端服务..."
cd "$PROJECT_DIR"
node server.js &
SERVER_PID=$!

# Wait a moment for server to bind
sleep 1.5

# Open browser dashboard
URL="http://localhost:$PORT"
echo "正在自动打开浏览器控制面板: $URL"
if [[ "$OSTYPE" == "darwin"* ]]; then
  open "$URL"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  if command -v xdg-open &> /dev/null; then
    xdg-open "$URL"
  else
    echo "请手动在浏览器中打开: $URL"
  fi
else
  # Windows git bash / cmd
  start "$URL" || echo "请手动在浏览器中打开: $URL"
fi

echo "提示: 保持此窗口开启，在浏览器中操作切换。按 [Ctrl + C] 可退出并停止服务。"
echo "------------------------------------------------------------------------"

# Keep script running and wait for server
wait $SERVER_PID
