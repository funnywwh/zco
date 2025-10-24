#!/bin/bash

# 快速性能测试脚本
# 对比 ZCO 和 Go 的 HTTP 服务器性能

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Quick ZCO vs Go Performance Test ===${NC}"

# 检查依赖
if ! command -v zig &> /dev/null; then
    echo -e "${RED}Error: zig not found${NC}"
    exit 1
fi

if ! command -v go &> /dev/null; then
    echo -e "${RED}Error: go not found${NC}"
    exit 1
fi

if ! command -v ab &> /dev/null; then
    echo -e "${RED}Error: ApacheBench (ab) not found${NC}"
    exit 1
fi

# 构建服务器
echo -e "${YELLOW}Building servers...${NC}"

    # 构建 ZCO 服务器
    echo "Building ZCO server..."
    cd ../nets
    zig build -Doptimize=ReleaseFast
    cp zig-out/bin/nets ../benchmarks/zig_server/zig_server
    cd ../benchmarks

# 构建 Go 服务器
echo "Building Go server..."
cd go_server
go build -o go_server main.go
cd ..

echo -e "${GREEN}Servers built successfully${NC}"

# 测试函数
test_server() {
    local server_type=$1
    local port=$2
    local requests=$3
    local concurrency=$4
    
    echo -e "${YELLOW}Testing $server_type server: $requests requests, $concurrency concurrent${NC}"
    
    # 启动服务器
    if [ "$server_type" = "ZCO" ]; then
        cd zig_server
        ./zig_server &
        local server_pid=$!
        cd ..
    else
        cd go_server
        ./go_server &
        local server_pid=$!
        cd ..
    fi
    
    # 等待服务器启动
    sleep 3
    
    # 运行测试
    local result=$(ab -n "$requests" -c "$concurrency" "http://localhost:$port/" 2>&1)
    
    # 提取关键指标
    local rps=$(echo "$result" | grep "Requests per second" | awk '{print $4}')
    local avg_time=$(echo "$result" | grep "Time per request.*mean)" | awk '{print $4}')
    local failed=$(echo "$result" | grep "Failed requests" | awk '{print $3}')
    
    echo -e "${GREEN}$server_type Results:${NC}"
    echo "  RPS: $rps"
    echo "  Avg Time: $avg_time ms"
    echo "  Failed: $failed"
    echo
    
    # 停止服务器
    kill $server_pid 2>/dev/null || true
    sleep 1
}

# 运行测试
echo -e "${BLUE}=== Testing ZCO Server ===${NC}"
test_server "ZCO" 8080 10000 100

echo -e "${BLUE}=== Testing Go Server ===${NC}"
test_server "Go" 8081 10000 100

echo -e "${GREEN}=== Quick test completed ===${NC}"
