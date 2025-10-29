# ZCO 文档目录

本目录包含 ZCO 协程库的所有相关文档和测试脚本。

## 📚 文档列表

### 开发指南
- **[HTTP_FRAMEWORK_DEVELOPMENT_PLAN.md](./HTTP_FRAMEWORK_DEVELOPMENT_PLAN.md)** - HTTP 框架开发计划（功能状态、TODO、未来规划）
- **[HTTP_PERFORMANCE_ANALYSIS.md](./HTTP_PERFORMANCE_ANALYSIS.md)** - HTTP 框架性能分析与优化建议
- **[HTTP_PERFORMANCE_SUCCESS.md](./HTTP_PERFORMANCE_SUCCESS.md)** - HTTP 框架性能优化成功报告（P99: 1835ms→32ms）
- **[HTTP_IMPROVEMENTS.md](./HTTP_IMPROVEMENTS.md)** - HTTP 框架待改进项和技术债务
- **[FMT_FORMATTING_TROUBLESHOOTING.md](./FMT_FORMATTING_TROUBLESHOOTING.md)** - Zig fmt 格式化问题排查指南

### 性能相关
- **[PERFORMANCE_COMPARISON_REPORT.md](./PERFORMANCE_COMPARISON_REPORT.md)** - ZCO vs Go HTTP服务器性能对比报告
- **[PERFORMANCE_OPTIMIZATION_GUIDE.md](./PERFORMANCE_OPTIMIZATION_GUIDE.md)** - 性能优化指南
- **[OPTIMIZATION_SUMMARY.md](./OPTIMIZATION_SUMMARY.md)** - 优化总结

### 技术分析
- **[analysis/TIMESLICE_PREEMPTION_DESIGN.md](./analysis/TIMESLICE_PREEMPTION_DESIGN.md)** - 协程时间片抢占调度设计文档

### 测试脚本
- **[test_performance.sh](./test_performance.sh)** - ZCO性能测试脚本
- **[compare_test.sh](./compare_test.sh)** - ZCO vs Go对比测试脚本

### 示例代码
- **[performance_optimization.zig](./performance_optimization.zig)** - 性能优化示例代码
- **[optimized_server.zig](./optimized_server.zig)** - 优化后的服务器示例

## 🚀 快速开始

### 运行性能测试
```bash
# ZCO性能测试
./test_performance.sh

# ZCO vs Go对比测试
./compare_test.sh
```

### 查看性能报告
```bash
# 查看性能对比报告
cat PERFORMANCE_COMPARISON_REPORT.md

# 查看优化指南
cat PERFORMANCE_OPTIMIZATION_GUIDE.md
```

## 📊 性能指标

### ZCO HTTP服务器性能
- **QPS**: 37,000 - 46,000 请求/秒
- **延迟**: 1.3 - 11.5 毫秒
- **并发**: 支持 50 - 500 并发连接
- **失败率**: 0%

### 与Go对比
- **整体性能**: 与Go基本相当 (差异 < 5%)
- **内存效率**: 优于Go (协程栈8KB vs 动态增长)
- **高并发**: 在100+并发场景下略优于Go

## 🔧 技术特性

- **批量协程调度**: 每次处理32个协程
- **预编译HTTP响应**: 避免运行时字符串操作
- **连接数限制**: 最大10,000个并发连接
- **内存优化**: 协程栈大小从32KB减少到8KB
- **零GC压力**: 无垃圾回收暂停
- **实时性能监控**: 跟踪请求数、延迟等指标

## 📈 优化成果

1. **性能提升**: QPS提升30%+
2. **内存优化**: 协程栈内存减少75%
3. **调度效率**: 批量处理提高调度效率
4. **稳定性**: 高并发下零失败率
5. **兼容性**: 完全兼容Zig 0.14.0

---
*最后更新: 2024年10月23日*
