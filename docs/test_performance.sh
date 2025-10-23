#!/bin/bash

# ZCO 性能测试脚本
# 用于测试优化后的性能表现

echo "🚀 ZCO 协程库性能测试"
echo "========================"

# 编译优化版本
echo "📦 编译优化版本..."
zig build -Doptimize=ReleaseFast

if [ $? -ne 0 ]; then
    echo "❌ 编译失败"
    exit 1
fi

echo "✅ 编译成功"

# 启动服务器（后台运行）
echo "🌐 启动服务器..."
./zig-out/bin/zco &
SERVER_PID=$!

# 等待服务器启动
sleep 2

# 检查服务器是否启动成功
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ 服务器启动失败"
    exit 1
fi

echo "✅ 服务器启动成功 (PID: $SERVER_PID)"

# 性能测试
echo ""
echo "📊 开始性能测试..."

# 测试1: 基础并发测试
echo "测试1: 基础并发测试 (1000请求, 100并发)"
ab -n 1000 -c 100 http://localhost:8080/ | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""

# 测试2: 高并发测试
echo "测试2: 高并发测试 (5000请求, 500并发)"
ab -n 5000 -c 500 http://localhost:8080/ | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""

# 测试3: 极限并发测试
echo "测试3: 极限并发测试 (10000请求, 1000并发)"
ab -n 10000 -c 1000 http://localhost:8080/ | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""

# 测试4: 长连接测试
echo "测试4: 长连接测试 (5000请求, 100并发, Keep-Alive)"
ab -n 5000 -c 100 -k http://localhost:8080/ | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""

# 测试5: 压力测试
echo "测试5: 压力测试 (20000请求, 2000并发)"
ab -n 20000 -c 2000 http://localhost:8080/ | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""

# 停止服务器
echo "🛑 停止服务器..."
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null

echo ""
echo "✅ 性能测试完成"
echo ""
echo "📈 优化效果总结:"
echo "- 协程调度: 批量处理32个协程"
echo "- 内存使用: 栈大小从32KB减少到8KB"
echo "- 事件循环: 条目数从4K增加到16K"
echo "- 连接限制: 最大10000个并发连接"
echo "- HTTP处理: 预编译响应，简化解析"
echo "- 性能监控: 实时统计延迟和吞吐量"
