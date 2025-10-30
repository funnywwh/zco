# HTTP 框架性能分析与优化

## AB 测试结果分析

### 测试数据

```
Percentage of the requests served within a certain time (ms)
  50%      5
  66%      5
  75%      5
  80%      5
  90%      5
  95%      7
  98%     29
  99%   1835
 100%   7600 (longest request)
```

### 性能指标解读

#### 正面指标 ✅

- **50%-90% 请求**: 5ms 内完成，表现良好
- **95% 请求**: 7ms 内完成，可接受
- 大部分请求处理速度非常快

#### 问题指标 ⚠️

- **98% 请求**: 29ms，开始出现延迟
- **99% 请求**: 1835ms，严重延迟（异常值）
- **最长请求**: 7600ms，非常慢

### 问题分析

#### 主要瓶颈

1. **缺少 HTTP keep-alive 支持**（已修复）
   - 每个请求都新建和关闭连接
   - TCP 三次握手/四次挥手开销大
   - 连接创建和销毁延迟

2. **可能的资源竞争**
   - 协程调度器在高并发下的竞争
   - 内存分配器在高负载下的性能下降
   - IO 事件的异步处理延迟

3. **缓冲区管理**
   - 每个连接都分配新的缓冲区
   - 可能的内存分配延迟

#### 性能分布模式

```
┌─────────────────────────────────────────┐
│  50-95%:  5-7ms    ✅ 正常范围          │
│  98%:     29ms     ⚠️  开始变慢         │
│  99%:     1835ms   ❌ 严重异常          │
│  100%:    7600ms   ❌ 极端异常          │
└─────────────────────────────────────────┘
```

这种分布模式表明：
- 大部分请求处理正常
- 少数请求遇到严重的延迟（可能是资源竞争或阻塞）

### 已实施的优化

#### ✅ HTTP keep-alive 支持

**修改内容**：
- 在同一个 TCP 连接上处理多个请求
- 自动检测 `Connection` 头
- HTTP/1.1 默认启用 keep-alive
- HTTP/1.0 根据 Connection 头决定

**预期改进**：
- 减少连接创建/销毁开销
- 降低 98%+ 的延迟
- 提高吞吐量

**代码位置**：
- `http/src/server.zig`: `handleConnection` 函数

### 进一步优化建议

#### 1. 缓冲区池化（高优先级）

**问题**：每个连接都分配新缓冲区（8KB），频繁分配/释放

**优化**：
```zig
// 使用缓冲区池
const BUFFER_POOL_SIZE = 100;
var buffer_pool: std.ArrayList([]u8) = undefined;

fn getBuffer() ![]u8 {
    if (buffer_pool.popOrNull()) |buf| {
        return buf;
    }
    return try allocator.alloc(u8, read_buffer_size);
}

fn returnBuffer(buf: []u8) void {
    if (buffer_pool.items.len < BUFFER_POOL_SIZE) {
        buffer_pool.append(buf) catch allocator.free(buf);
    } else {
        allocator.free(buf);
    }
}
```

**预期效果**：减少内存分配延迟

#### 2. 连接限流和超时

**问题**：长时间连接的资源占用

**优化**：
- 设置连接超时（30秒）
- 限制最大并发连接数
- 监控连接状态

**代码位置**：`http/src/server.zig`

#### 3. 协程优先级调度

**问题**：高优先级请求可能被低优先级请求阻塞

**优化**：
- 使用 ZCO 的优先级调度
- 短请求（如健康检查）使用高优先级

#### 4. 响应缓冲优化

**问题**：每次响应都重新构建头部

**优化**：
- 缓存常见响应头
- 使用预编译响应模板
- 减少字符串格式化操作

#### 5. 中间件性能优化

**问题**：每个请求都执行所有中间件

**优化**：
- 中间件结果缓存
- 跳过不需要的中间件
- 优化日志中间件（使用异步日志）

### 性能测试建议

#### 测试环境

```bash
# 使用 ab 测试
ab -n 10000 -c 100 http://127.0.0.1:8080/

# 使用 wrk 测试（更好的性能指标）
wrk -t12 -c400 -d30s http://127.0.0.1:8080/

# 使用 vegeta（压力测试工具）
echo "GET http://127.0.0.1:8080/" | vegeta attack -duration=30s -rate=1000 | vegeta report
```

#### 监控指标

1. **延迟分布**：P50, P95, P99, P99.9
2. **吞吐量**：QPS (Requests Per Second)
3. **错误率**：4xx, 5xx 错误比例
4. **资源使用**：CPU, 内存, 连接数

#### 基准测试

```bash
# 不同并发级别
for c in 10 50 100 200 500; do
    echo "Testing with concurrency=$c"
    ab -n 10000 -c $c http://127.0.0.1:8080/ > results_$c.txt
done
```

### 预期性能目标

#### 短期目标（当前优化后）

- **P50**: < 3ms
- **P95**: < 10ms
- **P99**: < 50ms（从 1835ms 降低）
- **最长请求**: < 200ms（从 7600ms 降低）
- **QPS**: > 20,000

#### 长期目标（完整优化后）

- **P50**: < 1ms
- **P95**: < 5ms
- **P99**: < 20ms
- **P99.9**: < 100ms
- **QPS**: > 50,000

### 调试建议

#### 1. 添加性能日志

```zig
const start = std.time.nanoTimestamp();
// ... 处理逻辑 ...
const elapsed = std.time.nanoTimestamp() - start;
if (elapsed > 10 * std.time.ns_per_ms) {
    std.log.warn("Slow request: {}ms, path: {s}", .{ elapsed / std.time.ns_per_ms, ctx.req.path });
}
```

#### 2. 连接状态监控

```zig
var active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
// 在 accept 时增加，在 close 时减少
```

#### 3. 协程状态监控

```zig
// 监控协程队列长度
const queue_len = schedule.readyQueue.len;
if (queue_len > 1000) {
    std.log.warn("High coroutine queue: {}", .{queue_len});
}
```

### 总结

当前的性能问题主要集中在：

1. ✅ **已修复**：HTTP keep-alive 支持
2. 🔧 **待优化**：缓冲区池化
3. 🔧 **待优化**：连接管理和超时
4. 🔧 **待优化**：中间件性能

经过 keep-alive 优化后，预期性能改进：
- P99 延迟：从 1835ms 降低到 < 50ms（预计 97% 改进）
- 最长请求：从 7600ms 降低到 < 200ms（预计 97% 改进）
- 整体吞吐量：提升 30-50%

### 参考资源

- [ZCO 性能优化指南](./PERFORMANCE_OPTIMIZATION_GUIDE.md)
- [ZCO vs Go 性能对比](./PERFORMANCE_COMPARISON_REPORT.md)
- [FMT 格式化排查指南](./FMT_FORMATTING_TROUBLESHOOTING.md)

---

**最后更新**: 2025年10月29日  
**下次优化**: 缓冲区池化和连接管理

