#!/bin/bash
# WebRTC 信令测试脚本

set -e

echo "=== WebRTC 信令测试 ==="
echo ""

# 清理之前的进程
pkill -f "zig build run-signaling" 2>/dev/null || true
pkill -f "signaling_client" 2>/dev/null || true
sleep 1

# 启动信令服务器
echo "启动信令服务器..."
cd "$(dirname "$0")/.."
zig build run-signaling > /tmp/signaling_server.log 2>&1 &
SERVER_PID=$!
sleep 2

# 检查服务器是否启动
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "错误: 信令服务器启动失败"
    cat /tmp/signaling_server.log
    exit 1
fi

echo "信令服务器已启动 (PID: $SERVER_PID)"
echo ""

# 启动 Alice
echo "启动 Alice..."
zig build run-client -- alice test-room > /tmp/alice.log 2>&1 &
ALICE_PID=$!
sleep 2

# 启动 Bob
echo "启动 Bob..."
zig build run-client -- bob test-room > /tmp/bob.log 2>&1 &
BOB_PID=$!
sleep 5

# 等待进程结束或超时
echo "等待连接建立..."
sleep 10

# 显示日志
echo ""
echo "=== 信令服务器日志 ==="
cat /tmp/signaling_server.log | tail -20 || true

echo ""
echo "=== Alice 日志 ==="
cat /tmp/alice.log | tail -30 || true

echo ""
echo "=== Bob 日志 ==="
cat /tmp/bob.log | tail -30 || true

# 清理
echo ""
echo "清理进程..."
kill $ALICE_PID $BOB_PID $SERVER_PID 2>/dev/null || true
wait $ALICE_PID $BOB_PID $SERVER_PID 2>/dev/null || true

echo ""
echo "测试完成"

