#!/bin/bash

# 性能测试脚本
# 对比 ZCO 和 Go 的 HTTP 服务器性能

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 测试配置
ZIG_SERVER_PORT=8080
GO_SERVER_PORT=8081
RESULTS_DIR="results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# 测试参数
TEST_CASES=(
    "1000:10"      # 1000 requests, 10 concurrent
    "10000:100"    # 10000 requests, 100 concurrent
    "50000:500"    # 50000 requests, 500 concurrent
    "100000:1000"  # 100000 requests, 1000 concurrent
)

echo -e "${BLUE}=== ZCO vs Go HTTP Server Performance Benchmark ===${NC}"
echo "Timestamp: $TIMESTAMP"
echo "Results will be saved to: $RESULTS_DIR/"
echo

# 创建结果目录
mkdir -p "$RESULTS_DIR"

# 检查依赖
check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"
    
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
    
    echo -e "${GREEN}All dependencies found${NC}"
}

# 构建服务器
build_servers() {
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
}

# 启动服务器
start_server() {
    local server_type=$1
    local port=$2
    local pid_file=$3
    
    if [ "$server_type" = "zig" ]; then
        cd zig_server
        ./zig_server &
        echo $! > "../$pid_file"
        cd ..
    else
        cd go_server
        ./go_server &
        echo $! > "../$pid_file"
        cd ..
    fi
    
    # 等待服务器启动
    echo "Waiting for $server_type server to start..."
    sleep 3
    
    # 检查服务器是否启动成功
    if curl -s "http://localhost:$port/" > /dev/null 2>&1; then
        echo -e "${GREEN}$server_type server started successfully on port $port${NC}"
    else
        echo -e "${RED}$server_type server failed to start${NC}"
        return 1
    fi
}

# 停止服务器
stop_server() {
    local pid_file=$1
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "Server stopped (PID: $pid)"
        fi
        rm -f "$pid_file"
    fi
}

# 运行性能测试
run_benchmark() {
    local server_type=$1
    local port=$2
    local requests=$3
    local concurrency=$4
    local output_file=$5
    
    echo -e "${YELLOW}Testing $server_type server: $requests requests, $concurrency concurrent${NC}"
    
    ab -n "$requests" -c "$concurrency" "http://localhost:$port/" > "$output_file" 2>&1
    
    # 提取关键指标
    local rps=$(grep "Requests per second" "$output_file" | awk '{print $4}')
    local avg_time=$(grep "Time per request.*mean)" "$output_file" | awk '{print $4}')
    local failed_requests=$(grep "Failed requests" "$output_file" | awk '{print $3}')
    
    echo -e "${GREEN}$server_type Results:${NC}"
    echo "  RPS: $rps"
    echo "  Avg Time: $avg_time ms"
    echo "  Failed: $failed_requests"
    echo
}

# 生成对比报告
generate_report() {
    local report_file="$RESULTS_DIR/benchmark_report_$TIMESTAMP.md"
    
    echo -e "${YELLOW}Generating benchmark report...${NC}"
    
    cat > "$report_file" << EOF
# ZCO vs Go HTTP Server Performance Benchmark

**Test Date:** $(date)
**Test Environment:** $(uname -a)

## Test Configuration

- **ZCO Server Port:** $ZIG_SERVER_PORT
- **Go Server Port:** $GO_SERVER_PORT
- **Test Tool:** ApacheBench (ab)

## Results Summary

| Test Case | Server | Requests | Concurrency | RPS | Avg Time (ms) | Failed Requests |
|-----------|--------|----------|-------------|-----|---------------|-----------------|
EOF

    # 处理每个测试用例的结果
    for test_case in "${TEST_CASES[@]}"; do
        IFS=':' read -r requests concurrency <<< "$test_case"
        
        # ZCO 结果
        local zig_file="$RESULTS_DIR/zig_${requests}_${concurrency}.txt"
        if [ -f "$zig_file" ]; then
            local zig_rps=$(grep "Requests per second" "$zig_file" | awk '{print $4}')
            local zig_avg=$(grep "Time per request.*mean)" "$zig_file" | awk '{print $4}')
            local zig_failed=$(grep "Failed requests" "$zig_file" | awk '{print $3}')
            
            echo "| $requests/$concurrency | ZCO | $requests | $concurrency | $zig_rps | $zig_avg | $zig_failed |" >> "$report_file"
        fi
        
        # Go 结果
        local go_file="$RESULTS_DIR/go_${requests}_${concurrency}.txt"
        if [ -f "$go_file" ]; then
            local go_rps=$(grep "Requests per second" "$go_file" | awk '{print $4}')
            local go_avg=$(grep "Time per request.*mean)" "$go_file" | awk '{print $4}')
            local go_failed=$(grep "Failed requests" "$go_file" | awk '{print $3}')
            
            echo "| $requests/$concurrency | Go | $requests | $concurrency | $go_rps | $go_avg | $go_failed |" >> "$report_file"
        fi
    done
    
    cat >> "$report_file" << EOF

## Detailed Results

EOF

    # 添加详细结果
    for test_case in "${TEST_CASES[@]}"; do
        IFS=':' read -r requests concurrency <<< "$test_case"
        echo "### Test Case: $requests requests, $concurrency concurrent" >> "$report_file"
        echo "" >> "$report_file"
        
        # ZCO 详细结果
        local zig_file="$RESULTS_DIR/zig_${requests}_${concurrency}.txt"
        if [ -f "$zig_file" ]; then
            echo "#### ZCO Server" >> "$report_file"
            echo '```' >> "$report_file"
            cat "$zig_file" >> "$report_file"
            echo '```' >> "$report_file"
            echo "" >> "$report_file"
        fi
        
        # Go 详细结果
        local go_file="$RESULTS_DIR/go_${requests}_${concurrency}.txt"
        if [ -f "$go_file" ]; then
            echo "#### Go Server" >> "$report_file"
            echo '```' >> "$report_file"
            cat "$go_file" >> "$report_file"
            echo '```' >> "$report_file"
            echo "" >> "$report_file"
        fi
    done
    
    echo -e "${GREEN}Benchmark report generated: $report_file${NC}"
}

# 主函数
main() {
    check_dependencies
    build_servers
    
    # 测试 ZCO 服务器
    echo -e "${BLUE}=== Testing ZCO Server ===${NC}"
    start_server "zig" $ZIG_SERVER_PORT "zig_server.pid"
    
    for test_case in "${TEST_CASES[@]}"; do
        IFS=':' read -r requests concurrency <<< "$test_case"
        local output_file="$RESULTS_DIR/zig_${requests}_${concurrency}.txt"
        run_benchmark "ZCO" $ZIG_SERVER_PORT "$requests" "$concurrency" "$output_file"
    done
    
    stop_server "zig_server.pid"
    
    # 等待端口释放
    sleep 2
    
    # 测试 Go 服务器
    echo -e "${BLUE}=== Testing Go Server ===${NC}"
    start_server "go" $GO_SERVER_PORT "go_server.pid"
    
    for test_case in "${TEST_CASES[@]}"; do
        IFS=':' read -r requests concurrency <<< "$test_case"
        local output_file="$RESULTS_DIR/go_${requests}_${concurrency}.txt"
        run_benchmark "Go" $GO_SERVER_PORT "$requests" "$concurrency" "$output_file"
    done
    
    stop_server "go_server.pid"
    
    # 生成报告
    generate_report
    
    echo -e "${GREEN}=== Benchmark completed ===${NC}"
    echo "Results saved in: $RESULTS_DIR/"
}

# 清理函数
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    stop_server "zig_server.pid"
    stop_server "go_server.pid"
}

# 设置清理陷阱
trap cleanup EXIT

# 运行主函数
main "$@"