# P99 延迟问题修复指南

## 问题描述

使用 `ab` (ApacheBench) 测试时，P99 延迟仍然很高（1835ms），即使已经实现了 HTTP keep-alive 支持。

## 关键问题：ab 默认不使用 keep-alive

**重要**：`ab` 默认使用 HTTP/1.0，且**默认不启用 keep-alive**！

### 解决方案

使用 `ab` 时必须加上 `-k` 参数来启用 HTTP keep-alive：

```bash
# ❌ 错误：没有启用 keep-alive（每个请求都新建连接）
ab -n 10000 -c 100 http://127.0.0.1:8080/
# 结果：P99=2675ms, RPS=6430/sec（性能差）

# ✅ 正确：启用 keep-alive（在同一个连接上发送多个请求）
ab -k -n 10000 -c 100 http://127.0.0.1:8080/
# 结果：P99=32ms, RPS=110750/sec（性能好 17.2x）
```

### 性能对比

详见 **[HTTP_KEEPALIVE_COMPARISON.md](./HTTP_KEEPALIVE_COMPARISON.md)**

## 其他可能的问题

### 1. 读取逻辑过于复杂

当前的读取逻辑在每次请求时都要：
- 多次检查 `header_end`
- 多次调用 `indexOf`
- 在循环内解析 Content-Length

**优化建议**：
- 先尝试一次性读取（大多数GET请求都是小请求）
- 只在必要时才进入分片处理流程
- 简化 Content-Length 解析逻辑

### 2. 请求解析开销

每次请求都要创建新的 `Context`，这涉及内存分配。可以考虑：
- 重用 `Context`（但需要小心清理）
- 使用对象池
- 优化内存分配模式

### 3. 协程调度延迟

在极高并发下（如1000并发），协程调度器可能成为瓶颈：
- 检查协程队列长度
- 考虑使用工作协程池（类似 `nets/src/main.zig` 的实现）
- 优化时间片调度

## 测试步骤

### 1. 使用正确的 ab 参数

```bash
# 启动服务器
cd /home/winger/zigwk/zco/http
zig build run &

# 等待服务器启动
sleep 1

# 使用 -k 参数启用 keep-alive 进行测试
ab -k -n 10000 -c 100 http://127.0.0.1:8080/

# 对比测试（不使用 keep-alive）
ab -n 10000 -c 100 http://127.0.0.1:8080/
```

### 2. 检查 Connection 头

```bash
# 使用 curl 验证 keep-alive 是否生效
curl -v http://127.0.0.1:8080/ 2>&1 | grep -i connection

# 应该看到：
# < Connection: keep-alive
```

### 3. 使用 wrk 进行对比测试

`wrk` 默认支持 keep-alive，可以作为对比：

```bash
wrk -t12 -c400 -d30s http://127.0.0.1:8080/
```

## 预期结果

使用 `-k` 参数后，预期改进：

```
50%      5ms   ✅
66%      5ms   ✅
75%      5ms   ✅
80%      5ms   ✅
90%      5ms   ✅
95%      7ms   ✅
98%     15-30ms  ⚠️ (比之前好很多)
99%     50-100ms ⚠️ (比1835ms好很多)
100%    < 200ms   ⚠️ (比7600ms好很多)
```

## 如果问题仍然存在

如果使用 `-k` 后问题仍然存在，需要进一步诊断：

### 1. 添加性能日志

在 `server.zig` 中添加时间戳记录：

```zig
const start_time = std.time.nanoTimestamp();
// ... 处理请求 ...
const end_time = std.time.nanoTimestamp();
const latency_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
if (latency_ms > 100) {
    std.log.warn("Slow request: {d:.2}ms", .{latency_ms});
}
```

### 2. 检查协程调度

- 检查协程队列是否堆积
- 检查是否有协程长时间阻塞
- 检查时间片调度是否正常

### 3. 使用 perf 分析

```bash
perf record -g ./zig-out/bin/http
perf report
```

## 总结

**最可能的原因**：没有使用 `ab -k` 启用 keep-alive，导致每个请求都要建立新连接。

**立即行动**：
1. 使用 `ab -k` 重新测试
2. 验证 Connection 头是否正确返回
3. 如果问题仍然存在，添加性能日志进一步诊断

