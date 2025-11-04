#!/bin/bash
# WebRTC 信令测试脚本
# 测试完整的 WebRTC 连接流程：信令交换 → ICE 连接 → DTLS 握手 → 数据通道通信

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

LOG_DIR="/tmp/webrtc_test_$$"
mkdir -p "$LOG_DIR"

# 清理函数
cleanup() {
    echo ""
    echo "清理进程..."
    pkill -f "zig build run-signaling" 2>/dev/null || true
    pkill -f "signaling_client" 2>/dev/null || true
    sleep 1
}

# 注册清理函数
trap cleanup EXIT INT TERM

echo "=== WebRTC 信令和数据通道测试 ==="
echo "日志目录: $LOG_DIR"
echo ""

# 清理之前的进程和端口占用
echo "清理之前的进程..."
pkill -9 -f "zig build run-signaling" 2>/dev/null || true
pkill -9 -f "signaling_server" 2>/dev/null || true
pkill -9 -f "signaling_client" 2>/dev/null || true
sleep 2

# 检查端口是否被占用
if lsof -ti:8080 >/dev/null 2>&1; then
    echo "⚠️  端口 8080 被占用，尝试释放..."
    lsof -ti:8080 | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# 启动信令服务器
echo "[1/4] 启动信令服务器..."
zig build run-signaling > "$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

# 检查服务器是否启动
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ 错误: 信令服务器启动失败"
    cat "$LOG_DIR/server.log"
    exit 1
fi

echo "✅ 信令服务器已启动 (PID: $SERVER_PID)"
echo ""

# 启动 Alice
echo "[2/4] 启动 Alice 客户端..."
zig build run-client -- alice test-room > "$LOG_DIR/alice.log" 2>&1 &
ALICE_PID=$!
sleep 3

# 启动 Bob
echo "[3/4] 启动 Bob 客户端..."
zig build run-client -- bob test-room > "$LOG_DIR/bob.log" 2>&1 &
BOB_PID=$!
sleep 3

echo "✅ 客户端已启动"
echo ""

# 等待连接建立和通信
echo "[4/4] 等待连接建立和数据通道通信..."
echo "    (等待最多 30 秒...)"
for i in {1..30}; do
    sleep 1
    # 检查是否所有进程还在运行
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "⚠️  信令服务器已退出"
        break
    fi
    if ! kill -0 $ALICE_PID 2>/dev/null && ! kill -0 $BOB_PID 2>/dev/null; then
        echo "   客户端已完成，检查结果..."
        break
    fi
done

echo ""
echo "=== 测试结果分析 ==="
echo ""

# 分析日志
echo "📊 信令服务器日志 (最后 20 行):"
echo "----------------------------------------"
tail -20 "$LOG_DIR/server.log" 2>/dev/null || echo "(无日志)"
echo ""

echo "📊 Alice 日志 (最后 40 行，包含关键信息):"
echo "----------------------------------------"
tail -40 "$LOG_DIR/alice.log" 2>/dev/null | grep -E "(info|error|warn|ICE|DTLS|握手|连接|消息|数据通道)" || tail -40 "$LOG_DIR/alice.log" 2>/dev/null || echo "(无日志)"
echo ""

echo "📊 Bob 日志 (最后 40 行，包含关键信息):"
echo "----------------------------------------"
tail -40 "$LOG_DIR/bob.log" 2>/dev/null | grep -E "(info|error|warn|ICE|DTLS|握手|连接|消息|数据通道)" || tail -40 "$LOG_DIR/bob.log" 2>/dev/null || echo "(无日志)"
echo ""

# 检查关键步骤
echo "🔍 关键步骤检查:"
echo "----------------------------------------"

# 检查信令交换
if grep -q "已发送 offer" "$LOG_DIR/alice.log" 2>/dev/null; then
    echo "✅ Alice 发送了 offer"
else
    echo "❌ Alice 未发送 offer"
fi

if grep -q "已发送 answer" "$LOG_DIR/bob.log" 2>/dev/null; then
    echo "✅ Bob 发送了 answer"
else
    echo "❌ Bob 未发送 answer"
fi

# 检查 ICE 连接
if grep -q "ICE 连接状态.*connected\|completed" "$LOG_DIR/alice.log" 2>/dev/null; then
    echo "✅ ICE 连接可能已建立 (Alice)"
else
    echo "⚠️  ICE 连接状态未知 (Alice)"
fi

if grep -q "ICE 连接状态.*connected\|completed" "$LOG_DIR/bob.log" 2>/dev/null; then
    echo "✅ ICE 连接可能已建立 (Bob)"
else
    echo "⚠️  ICE 连接状态未知 (Bob)"
fi

# 检查 DTLS 握手
if grep -q "DTLS 握手已完成\|handshake_complete" "$LOG_DIR/alice.log" 2>/dev/null; then
    echo "✅ DTLS 握手可能已完成 (Alice)"
else
    echo "⚠️  DTLS 握手状态未知 (Alice)"
fi

if grep -q "DTLS 握手已完成\|handshake_complete" "$LOG_DIR/bob.log" 2>/dev/null; then
    echo "✅ DTLS 握手可能已完成 (Bob)"
else
    echo "⚠️  DTLS 握手状态未知 (Bob)"
fi

# 检查数据通道
if grep -q "已创建数据通道\|数据通道已打开" "$LOG_DIR/alice.log" 2>/dev/null; then
    echo "✅ 数据通道已创建/打开 (Alice)"
else
    echo "⚠️  数据通道状态未知 (Alice)"
fi

# 检查消息发送
if grep -q "已发送测试消息\|收到消息" "$LOG_DIR/alice.log" 2>/dev/null; then
    echo "✅ 数据通道消息可能已发送/接收 (Alice)"
else
    echo "⚠️  数据通道消息状态未知 (Alice)"
fi

echo ""
echo "📁 完整日志文件:"
echo "   服务器: $LOG_DIR/server.log"
echo "   Alice:  $LOG_DIR/alice.log"
echo "   Bob:    $LOG_DIR/bob.log"
echo ""
echo "测试完成"

