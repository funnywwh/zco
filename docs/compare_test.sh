#!/bin/bash

echo "🚀 ZCO vs Go HTTP Server 性能对比测试"
echo "=========================================="

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 测试配置
TESTS=(
    "1000:50:ZCO-低并发"
    "5000:100:ZCO-中并发" 
    "10000:200:ZCO-高并发"
    "20000:500:ZCO-超高并发"
    "1000:50:Go-低并发"
    "5000:100:Go-中并发"
    "10000:200:Go-高并发"
    "20000:500:Go-超高并发"
)

# 启动ZCO服务器
echo -e "${BLUE}启动ZCO服务器...${NC}"
cd /home/winger/zigwk/zco/nets
./zig-out/bin/nets &
ZCO_PID=$!
sleep 3

# 启动Go服务器
echo -e "${BLUE}启动Go服务器...${NC}"
cd /home/winger/zigwk/zco
go run go_server.go &
GO_PID=$!
sleep 3

# 检查服务器是否启动成功
echo -e "${YELLOW}检查服务器状态...${NC}"
if curl -s http://localhost:8080/ > /dev/null; then
    echo -e "${GREEN}✅ ZCO服务器运行正常${NC}"
else
    echo -e "${RED}❌ ZCO服务器启动失败${NC}"
    kill $ZCO_PID 2>/dev/null
    kill $GO_PID 2>/dev/null
    exit 1
fi

if curl -s http://localhost:8081/ > /dev/null; then
    echo -e "${GREEN}✅ Go服务器运行正常${NC}"
else
    echo -e "${RED}❌ Go服务器启动失败${NC}"
    kill $ZCO_PID 2>/dev/null
    kill $GO_PID 2>/dev/null
    exit 1
fi

echo ""
echo -e "${YELLOW}开始性能测试...${NC}"
echo ""

# 测试结果存储
declare -A results

# 执行测试
for test in "${TESTS[@]}"; do
    IFS=':' read -r requests concurrency name <<< "$test"
    
    echo -e "${BLUE}测试: $name (${requests}请求, ${concurrency}并发)${NC}"
    
    if [[ $name == Go-* ]]; then
        port=8081
        server_name="Go"
    else
        port=8080
        server_name="ZCO"
    fi
    
    # 执行ab测试
    result=$(ab -n $requests -c $concurrency http://localhost:$port/ 2>/dev/null | grep -E "(Requests per second|Time per request|Failed requests|Complete requests)")
    
    # 提取关键指标
    qps=$(echo "$result" | grep "Requests per second" | awk '{print $4}')
    time_per_request=$(echo "$result" | grep "Time per request.*mean)" | awk '{print $4}')
    failed_requests=$(echo "$result" | grep "Failed requests" | awk '{print $3}')
    complete_requests=$(echo "$result" | grep "Complete requests" | awk '{print $3}')
    
    # 存储结果
    results["${name}_qps"]=$qps
    results["${name}_time"]=$time_per_request
    results["${name}_failed"]=$failed_requests
    results["${name}_complete"]=$complete_requests
    
    echo -e "  QPS: ${GREEN}$qps${NC}"
    echo -e "  平均延迟: ${GREEN}${time_per_request}ms${NC}"
    echo -e "  完成请求: ${GREEN}$complete_requests${NC}"
    echo -e "  失败请求: ${GREEN}$failed_requests${NC}"
    echo ""
    
    # 等待一下再进行下一个测试
    sleep 2
done

# 生成对比报告
echo "=========================================="
echo -e "${YELLOW}📊 性能对比报告${NC}"
echo "=========================================="

echo ""
echo -e "${BLUE}QPS对比 (请求/秒):${NC}"
printf "%-20s %-15s %-15s %-15s\n" "测试场景" "ZCO" "Go" "ZCO优势"
printf "%-20s %-15s %-15s %-15s\n" "--------------------" "---------------" "---------------" "---------------"

for scenario in "低并发" "中并发" "高并发" "超高并发"; do
    zco_qps=${results["ZCO-${scenario}_qps"]}
    go_qps=${results["Go-${scenario}_qps"]}
    
    if [[ -n "$zco_qps" && -n "$go_qps" ]]; then
        advantage=$(echo "scale=2; $zco_qps / $go_qps" | bc 2>/dev/null || echo "N/A")
        printf "%-20s %-15s %-15s %-15s\n" "$scenario" "$zco_qps" "$go_qps" "${advantage}x"
    fi
done

echo ""
echo -e "${BLUE}延迟对比 (毫秒):${NC}"
printf "%-20s %-15s %-15s %-15s\n" "测试场景" "ZCO" "Go" "Go优势"
printf "%-20s %-15s %-15s %-15s\n" "--------------------" "---------------" "---------------" "---------------"

for scenario in "低并发" "中并发" "高并发" "超高并发"; do
    zco_time=${results["ZCO-${scenario}_time"]}
    go_time=${results["Go-${scenario}_time"]}
    
    if [[ -n "$zco_time" && -n "$go_time" ]]; then
        advantage=$(echo "scale=2; $go_time / $zco_time" | bc 2>/dev/null || echo "N/A")
        printf "%-20s %-15s %-15s %-15s\n" "$scenario" "$zco_time" "$go_time" "${advantage}x"
    fi
done

echo ""
echo -e "${BLUE}失败率对比:${NC}"
printf "%-20s %-15s %-15s\n" "测试场景" "ZCO" "Go"
printf "%-20s %-15s %-15s\n" "--------------------" "---------------" "---------------"

for scenario in "低并发" "中并发" "高并发" "超高并发"; do
    zco_failed=${results["ZCO-${scenario}_failed"]}
    go_failed=${results["Go-${scenario}_failed"]}
    printf "%-20s %-15s %-15s\n" "$scenario" "$zco_failed" "$go_failed"
done

# 清理服务器进程
echo ""
echo -e "${YELLOW}清理服务器进程...${NC}"
kill $ZCO_PID 2>/dev/null
kill $GO_PID 2>/dev/null
sleep 2

echo ""
echo -e "${GREEN}✅ 性能对比测试完成！${NC}"
