# ZCO 示例程序

这个目录包含了 ZCO 协程库的各种示例和演示程序。

## 示例程序列表

### 1. demo_visible_preemption.zig
- **功能**: 演示时间片抢占调度效果
- **运行**: `zig build demo`
- **说明**: 创建两个CPU密集型协程，展示抢占调度如何让它们交替执行

### 2. test_preemption.zig
- **功能**: 基础抢占功能测试
- **运行**: `zig build run`
- **说明**: 测试时间片抢占的基本功能，包括协程创建、调度和抢占

## 构建和运行

### 运行抢占演示
```bash
zig build demo
```

### 运行基础测试
```bash
zig build run
```

### 运行所有测试
```bash
zig build test
```

## 时间片设置

可以通过修改 `src/schedule.zig` 中的 `startTimer` 函数来调整时间片长度：

- **1ms**: 极高频抢占，适合测试极限性能
- **10ms**: 高频抢占，适合实际应用
- **50ms**: 中频抢占，平衡性能和公平性
- **1小时**: 几乎无抢占，适合性能基准测试

## 性能测试

使用 ApacheBench 进行 HTTP 服务器性能测试：

```bash
# 启动 nets 服务器
cd ../nets && ./zig-out/bin/nets &

# 运行压力测试
ab -n 100000 -c 1000 http://localhost:8080/
```

## 注意事项

- 确保系统有足够的文件描述符限制
- 高并发测试可能需要调整系统参数
- 1ms 时间片下系统负载较高，建议在测试环境中使用
