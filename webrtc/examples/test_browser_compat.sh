#!/bin/bash

# WebRTC DataChannel 浏览器兼容性测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "WebRTC DataChannel 浏览器兼容性测试"
echo "=========================================="
echo ""

# 检查 Zig 是否安装
if ! command -v zig &> /dev/null; then
    echo "错误: 未找到 zig 命令，请先安装 Zig"
    exit 1
fi

echo "1. 构建浏览器兼容性测试服务器..."
# 切换到 webrtc 目录运行构建
cd ..
zig build run-browser-compat-server &
SERVER_PID=$!
cd examples

# 等待服务器启动
sleep 2

echo ""
echo "=========================================="
echo "测试说明:"
echo "=========================================="
echo ""
echo "1. 测试服务器已启动，监听在 ws://127.0.0.1:8080"
echo "2. 打开浏览器，访问: file://$SCRIPT_DIR/browser_test.html"
echo "   或者使用 HTTP 服务器:"
echo "   python3 -m http.server 8000"
echo "   然后访问: http://localhost:8000/browser_test.html"
echo ""
echo "3. 在浏览器中:"
echo "   - 点击 '连接到服务器' 按钮"
echo "   - 等待连接建立（状态显示 '连接: connected'）"
echo "   - 点击 '运行所有测试' 按钮运行自动化测试"
echo "   - 或手动发送消息测试"
echo ""
echo "4. 测试验证项:"
echo "   ✓ DataChannel 打开"
echo "   ✓ 发送消息"
echo "   ✓ 接收消息（Echo）"
echo "   ✓ 大数据包传输（64KB）"
echo "   ✓ 多消息传输"
echo "   ✓ 状态转换"
echo ""
echo "5. 查看日志:"
echo "   - 浏览器控制台（F12）"
echo "   - 服务器终端输出"
echo ""
echo "按 Ctrl+C 停止服务器"
echo ""

# 捕获退出信号
trap "kill $SERVER_PID 2>/dev/null; exit" INT TERM

# 等待服务器进程
wait $SERVER_PID

