# ZCO - 高性能协程库 v0.5.0

ZCO 是一个用 Zig 编写的高性能协程库，提供类似 Go 语言的协程功能，但在性能、控制和实时性方面具有显著优势。经过完整的性能测试验证，ZCO 在协程密集型应用中展现出卓越的性能和稳定性。

## 🆕 v0.5.0 更新内容

### 🌐 HTTP 框架与示例稳定性增强
- 默认启用 HTTP 流式解析器（Streaming Parser），在高并发和大报文下更稳健
- 调整示例服务器默认并发参数：`worker_pool_size=512`、`channel_buffer=8192`、`max_connections=10000`
- 提供 `scripts/http_bench.sh` 脚本：一键构建、启动、停止与 ab/wrk 压测

### 📈 基准结果（本地参考，400 并发）
- ab -k: RPS≈10207，P99≈46ms，Failed=0
- ab    : RPS≈10144，P99≈47ms，Failed=0
- wrk 30s: RPS≈9935，Avg≈39.8ms

> 详细输出见 `benchmarks/results/`，最新汇总见 `benchmarks/results/benchmark_report_latest.md`。

### 🔧 使用提示
- 压测前建议：`ulimit -n 1048576`，以及 `sudo sysctl -w net.core.somaxconn=65535`
- 启动示例 HTTP 服务器与压测：
```bash
./scripts/http_bench.sh start
./scripts/http_bench.sh ab   # 默认 ab -k -n 200000 -c 400
./scripts/http_bench.sh wrk  # 默认 wrk -t12 -c400 -d30s
./scripts/http_bench.sh stop
```

## 🆕 v0.4.2 更新内容

### 🌐 WebSocket 服务器模块
- **完整协议支持**: 实现 RFC 6455 WebSocket 标准协议
- **核心功能**: 握手、文本/二进制消息、ping/pong、分片消息、关闭握手
- **性能优化**: 动态内存管理，支持大消息分片处理
- **协议合规**: UTF-8 验证和完整的协议合规性检查
- **测试验证**: 提供完整的 Node.js 测试套件，所有测试通过

### 🔧 WebSocket 特性
- 基于协程的异步 IO，支持高并发连接
- 自动处理 ping/pong 保活机制
- 支持分片消息的自动重组
- 完整的内存管理和错误处理

## 🆕 v0.4.1 更新内容

### 🚀 环形缓冲区+优先级位图调度器
- **O(1) 优先级查找**: 使用32位位图实现常数时间查找最高优先级协程
- **多优先级支持**: 支持0-31共32个优先级级别的独立队列
- **内存优化**: 环形缓冲区避免频繁内存分配，提高性能
- **架构升级**: 调度器架构的重大升级，提升调度效率

### ⚡ 性能优化
- **查找最高优先级**: O(log n) → O(1)
- **入队/出队操作**: O(1)
- **可配置缓冲区**: 默认 2048 大小的环形缓冲区

### 📚 文档整理
- 完整的技术文档: `docs/RING_BUFFER_PRIORITY_REPORT.md`
- 优化的文档结构: 所有文档统一整理到 `docs/` 目录

### 🔧 新 API
```zig
// 带优先级的协程创建
schedule.goWithPriority(highPriorityTask, .{}, 15);

// 队列统计
schedule.readyQueue.getHighestPriority();
schedule.readyQueue.getPriorityCount(10);
```

## 🆕 v0.4.0 更新内容

### 完整性能优化
- **内存池**: 减少堆分配开销
- **协程池**: 重用协程对象，降低创建/销毁成本
- **连接池**: 复用TCP连接，提升网络性能
- **批量处理**: 智能批量调度，提高吞吐量
- **SIMD优化**: 向量化字符串比较，加速HTTP解析
- **分支预测**: 优化关键路径的条件分支
- **内存对齐**: 优化数据结构内存布局

### 性能提升
- **RPS提升**: 46,500 → 55,000+ (提升 18%)
- **P99延迟**: 显著降低，更稳定的响应时间
- **零失败率**: 所有测试场景保持零失败

## 特性

### 🚀 高性能
- **低开销**: 协程创建 ~1-2μs，上下文切换 ~100-200ns
- **小运行时**: 最小化运行时，只包含必要的调度和上下文切换代码，~50KB
- **批量处理**: 批量处理协程，提高调度效率
- **性能验证**: 与 Go 性能对比测试显示接近的性能表现

### ⚡ 强制时间片抢占
- **防止饿死**: 强制中断 CPU 密集型协程，确保公平调度
- **10ms 时间片**: 平衡性能和公平性的时间片设置
- **信号处理器**: 基于 Linux 信号的高效抢占机制

### 🎯 精确控制
- **栈大小控制**: 精确控制每个协程的栈大小（64KB Debug / 16KB Release）
- **自定义调度**: 完全控制调度策略，支持优先级调度
- **内存管理**: 支持自定义内存分配器，避免 GC 暂停

### 🔧 系统编程友好
- **编译时错误检查**: 使用 Zig 的错误处理机制，编译时检查
- **底层控制**: 提供更底层的控制，适合系统编程和嵌入式开发
- **跨平台**: 支持 Linux，可扩展到 Windows/macOS

### 🧪 完整测试验证
- **性能对比**: 提供与 Go 的完整性能对比测试套件
- **压力测试**: 支持高并发压力测试，验证稳定性
- **自动化测试**: 一键运行快速测试和完整测试套件
- **详细报告**: 生成详细的性能测试报告和分析

## 快速开始

### 安装依赖

确保系统已安装 Zig 0.14.0 和 libxev：

```bash
# Ubuntu/Debian
sudo apt install zig libxev-dev

# 或者从源码编译 libxev
git clone https://github.com/mitchellh/libxev.git
cd libxev && make && sudo make install
```

### 构建项目

```bash
# 克隆项目
git clone <repository-url>
cd zco

# 构建库和示例
zig build

# 构建并运行示例
zig build run
```

### 基本使用

```zig
const std = @import("std");
const zco = @import("zco");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建调度器
    const schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建协程
    _ = try schedule.go(struct {
        fn run() !void {
            std.log.info("Hello from coroutine 1!", .{});
            try zco.Sleep(1000); // 休眠 1ms
            std.log.info("Coroutine 1 finished!", .{});
        }
    }.run, .{});

    _ = try schedule.go(struct {
        fn run() !void {
            std.log.info("Hello from coroutine 2!", .{});
            try zco.Sleep(1000); // 休眠 1ms
            std.log.info("Coroutine 2 finished!", .{});
        }
    }.run, .{});

    // 运行调度器
    try schedule.loop();
}
```

## 示例程序

### 1. 基础示例 (`src/main.zig`)
- **功能**: 演示基本协程创建和调度
- **运行**: `zig build run`
- **说明**: 创建多个协程，展示时间片抢占调度效果

### 2. 网络服务器 (`nets/`)
- **功能**: 基于 ZCO 的高性能 TCP 服务器基础模块
- **运行**: `cd nets && zig build run`
- **说明**: 提供 TCP 连接管理，展示 ZCO 在网络编程中的优势

### 3. HTTP 框架 (`http/`)
- **功能**: 完整的 HTTP 框架，支持路由、中间件、JWT、文件上传等
- **运行**: `cd http && zig build run`
- **说明**: 提供完整的 Web 开发功能，包含路由系统、中间件链、JWT认证、静态文件服务、模板引擎等

### 4. WebSocket 服务器 (`websocket/`)
- **功能**: 完整的 WebSocket 服务器实现
- **运行**: `cd websocket && zig build run`
- **测试**: `cd websocket/test && npm install && node client_test.js`
- **说明**: 支持 RFC 6455 标准协议，包含完整的测试套件

### 5. 性能对比测试 (`benchmarks/`)
- **功能**: ZCO 与 Go 的性能对比测试套件
- **运行**: `cd benchmarks && ./quick_test.sh`
- **说明**: 提供完整的性能测试和对比分析

## 性能测试

### 协程性能测试

```bash
# 运行基础性能测试
zig build run

# 查看性能统计
# 输出包括：总切换次数、抢占次数、抢占率等
```

### 网络服务器压力测试

```bash
# 启动服务器
cd nets && zig build run -Doptimize=ReleaseFast &

# 运行压力测试
ab -n 100000 -c 1000 http://localhost:8080/

# 极限压力测试
ab -n 1000000 -c 5000 http://localhost:8080/
```

### ZCO vs Go 性能对比测试

我们提供了完整的性能对比测试套件，对比 ZCO 和 Go 协程库的性能：

```bash
# 快速性能测试
cd benchmarks
./quick_test.sh

# 完整性能测试（多个测试用例）
./run_benchmark.sh
```

#### 测试结果示例

**完整性能测试结果（v0.3.1 with 协程池）**:

| 测试用例 | 服务器 | RPS | 平均响应时间 | 失败请求 |
|----------|--------|-----|-------------|----------|
| 1,000/10 | ZCO | 46,500 | 0.215 ms | 0 |
| 1,000/10 | Go | 45,000 | 0.222 ms | 0 |
| 10,000/100 | ZCO | 55,064 | 1.816 ms | 0 |
| 10,000/100 | Go | 57,931 | 1.726 ms | 0 |
| 50,000/500 | ZCO | 52,028 | 9.610 ms | 0 |
| 50,000/500 | Go | 53,238 | 9.392 ms | 0 |
| 100,000/1000 | ZCO | 49,044 | 20.390 ms | 0 |
| 100,000/1000 | Go | 55,756 | 17.935 ms | 0 |

**性能分析**:
- **性能大幅提升**: 使用协程池后，ZCO 性能提升 87-112%，现在与 Go 性能非常接近
- **低并发优势**: 在 1,000/10 场景下，ZCO RPS 超过 Go 3%
- **高并发稳定**: ZCO 在高并发场景下性能稳定，仍然保持零失败率
- **协程池优势**: 固定协程池避免了频繁创建/销毁协程的开销，显著提升性能
- **channel 缓冲**: 带缓冲的 channel 平滑处理连接峰值，提升吞吐量
- **性能接近**: ZCO 与 Go 的 RPS 差距缩小到 5-13%，在某些场景下甚至超越
- **零失败率**: 所有测试场景下 ZCO 都保持零失败率，展现优秀的稳定性

#### 详细性能测试

完整测试包括多个测试用例：
- 1,000 请求，10 并发
- 10,000 请求，100 并发  
- 50,000 请求，500 并发（已验证）
- 100,000 请求，1,000 并发（极限测试）

测试结果将保存到 `benchmarks/results/` 目录，包含详细的性能报告。

## 配置选项

### 时间片设置

可以通过修改 `src/schedule.zig` 中的 `startTimer` 函数来调整时间片长度：

- **1ms**: 极高频抢占，适合测试极限性能
- **10ms**: 高频抢占，适合实际应用（默认）
- **50ms**: 中频抢占，平衡性能和公平性
- **1小时**: 几乎无抢占，适合性能基准测试

### 栈大小配置

在 `src/config.zig` 中配置协程栈大小：

- **Debug 模式**: 64KB（默认）
- **Release 模式**: 16KB（默认）
- **自定义**: 通过 `root.DEFAULT_ZCO_STACK_SZIE` 设置

## 架构设计

### 核心组件

1. **Schedule**: 协程调度器，管理协程生命周期和调度
2. **Co**: 协程对象，包含上下文、栈和状态信息
3. **信号处理器**: 实现时间片抢占的核心机制
4. **事件循环**: 基于 libxev 的异步 I/O 处理

### 调度机制

- **协作式调度**: 协程主动让出 CPU（通过 `Suspend()` 或 `Sleep()`）
- **抢占式调度**: 定时器信号强制中断长时间运行的协程
- **批量处理**: 每次处理多个协程，提高调度效率

## 与 Go 的对比

| 特性 | ZCO | Go |
|------|-----|-----|
| 协程创建开销 | ~1-2μs | ~2-5μs |
| 上下文切换开销 | ~100-200ns | ~500ns-1μs |
| 运行时大小 | ~50KB | ~2-5MB |
| 栈大小控制 | 精确控制 | 动态增长 |
| 调度控制 | 完全可控 | 运行时决定 |
| 抢占机制 | 强制抢占 | 协作式 |
| 错误处理 | 编译时检查 | 运行时检查 |
| 内存管理 | 自定义分配器 | GC 管理 |
| 性能测试 | 完整测试套件 | 内置基准测试 |
| 高并发稳定性 | 1000+ 并发无失败 | 优秀 |
| 系统编程 | 原生支持 | 需要 CGO |

## 系统要求

- **操作系统**: Linux (主要支持)
- **Zig 版本**: 0.14.0+
- **依赖**: libxev
- **架构**: x86_64

## 开发状态

### 已完成功能
- [x] 时间片抢占调度机制
- [x] 协程状态管理和上下文切换
- [x] 信号屏蔽保护共享数据
- [x] 性能统计和监控
- [x] 批量协程处理优化
- [x] 网络服务器集成
- [x] HTTP 框架模块（路由、中间件、JWT、文件上传、模板引擎）
- [x] WebSocket 服务器模块（v0.4.2）
- [x] 高并发压力测试验证
- [x] 与 Go 的性能对比测试
- [x] 完整的性能测试套件
- [x] 详细的文档和使用指南

### 待改进功能
- [x] 优先级感知抢占（已实现环形缓冲区+优先级位图调度器）
- [x] WebSocket 服务器支持（已实现）
- [x] HTTP 框架支持（已实现）
- [ ] 自适应时间片调整
- [ ] 跨平台支持（Windows/macOS）
- [ ] 更详细的性能监控
- [x] 协程池管理（已实现）
- [ ] WebSocket 客户端支持
- [ ] 更多网络协议支持（HTTP/2, gRPC 等）

## 贡献指南

1. Fork 项目
2. 创建功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add some amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 打开 Pull Request

## 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 致谢

- [libxev](https://github.com/mitchellh/libxev) - 高性能异步 I/O 库
- [Zig](https://ziglang.org/) - 系统编程语言
- Go 语言协程设计 - 提供了设计灵感

---

**注意**: 这是一个积极开发中的项目。核心功能已经稳定并通过了完整的性能测试验证，但 API 可能会在后续版本中发生变化。建议在充分测试后再用于生产环境。