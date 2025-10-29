# HTTP 服务器协程池优化

## 概述

HTTP 服务器现在支持**协程池模式**，参考 `nets` 模块的实现，使用固定数量的工作协程处理连接，而不是为每个连接创建新协程。这可以显著减少协程创建开销，提高高并发场景下的性能。

## 架构对比

### 原始模式（Direct Mode）

```zig
// 为每个连接创建新协程
while (true) {
    const client = tcp.accept() catch continue;
    _ = try schedule.go(handleConnection, .{ self, client });
}
```

**特点**：
- ✅ 简单直接
- ✅ 每个连接独立协程
- ❌ 高并发下协程创建开销大
- ❌ 可能导致协程数量爆炸

### 协程池模式（Pool Mode）

```zig
// 创建固定数量的工作协程
for (0..worker_pool_size) |_| {
    _ = try schedule.go(worker, .{ self, client_chan });
}

// accept 循环将连接发送到 channel
while (true) {
    const client = tcp.accept() catch continue;
    try client_chan.send(client);
}
```

**特点**：
- ✅ 固定数量的工作协程（减少创建开销）
- ✅ 使用 channel 分发连接（负载均衡）
- ✅ 连接数限制保护
- ✅ 更好的资源控制

## 配置选项

### 默认配置

```zig
var server = http.Server.init(allocator, schedule);

// 默认配置：
// - worker_pool_size: 100
// - channel_buffer: 1000
// - max_connections: 10000
// - use_pool: true
```

### 自定义配置

```zig
var server = http.Server.init(allocator, schedule);

// 设置协程池大小
server.setWorkerPoolSize(200);  // 200 个工作协程

// 设置 channel 缓冲大小
server.setChannelBuffer(2000);  // 2000 个连接的缓冲

// 设置最大连接数
server.setMaxConnections(5000); // 最多 5000 个并发连接

// 禁用协程池（使用原始模式）
server.setUsePool(false);
```

### 完整示例

```zig
const std = @import("std");
const zco = @import("zco");
const http = @import("http");

pub fn main() !void {
    _ = try zco.loop(struct {
        fn run() !void {
            const allocator = try zco.getSchedule().allocator;
            const schedule = try zco.getSchedule();

            var server = http.Server.init(allocator, schedule);
            defer server.deinit();

            // 配置协程池
            server.setWorkerPoolSize(200);
            server.setChannelBuffer(2000);
            server.setMaxConnections(10000);
            server.setUsePool(true); // 启用协程池（默认已启用）

            // 添加路由
            try server.get("/", handleRoot);

            // 启动服务器
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            try server.listen(address);
        }
    }.run, .{});
}
```

## 性能优势

### 协程池模式的优势

1. **减少协程创建开销**
   - 固定数量的工作协程，无需频繁创建/销毁
   - 降低内存分配和调度开销

2. **更好的负载均衡**
   - Channel 自动分发连接到空闲工作协程
   - 避免某些协程过载，其他协程空闲

3. **资源控制**
   - 连接数限制保护服务器
   - 防止协程数量爆炸

4. **高并发性能**
   - 在极高并发下（1000+）性能更稳定
   - 减少协程调度器的压力

### 性能对比（预期）

| 场景 | Direct Mode | Pool Mode |
|------|-------------|-----------|
| 低并发 (< 100) | 相似 | 相似 |
| 中并发 (100-1000) | 良好 | 更好 |
| 高并发 (1000+) | 可能退化 | 稳定 |

## 实现细节

### 工作协程

```zig
// 工作协程循环
fn worker(server: *Server, chan: *TcpChan) !void {
    while (true) {
        // 从 channel 接收连接
        var client = chan.recv() catch break;

        // 检查连接数限制
        if (server.connection_count.load() >= server.max_connections) {
            client.close();
            client.deinit();
            continue;
        }

        // 处理连接（支持 keep-alive）
        handleConnection(server, client) catch |e| {
            // 错误处理
        };
    }
}
```

### Accept 循环

```zig
// 服务器协程：accept 并分发
fn acceptLoop(tcp: *nets.Tcp, chan: *TcpChan) !void {
    while (true) {
        var client = tcp.accept() catch continue;
        chan.send(client) catch {
            // channel 满了，关闭连接
            client.close();
            client.deinit();
        };
    }
}
```

## 配置建议

### 小规模应用（< 100 并发）

```zig
server.setWorkerPoolSize(50);
server.setChannelBuffer(500);
server.setMaxConnections(1000);
```

### 中等规模应用（100-1000 并发）

```zig
server.setWorkerPoolSize(100);  // 默认值
server.setChannelBuffer(1000);  // 默认值
server.setMaxConnections(10000); // 默认值
```

### 大规模应用（1000+ 并发）

```zig
server.setWorkerPoolSize(200);
server.setChannelBuffer(2000);
server.setMaxConnections(50000);
```

### 极高并发（10,000+ 并发）

```zig
server.setWorkerPoolSize(500);
server.setChannelBuffer(5000);
server.setMaxConnections(100000);
```

## 监控和调优

### 连接数监控

服务器使用原子计数器跟踪当前连接数：

```zig
// 在代码中可以访问
const current_connections = server.connection_count.load(.monotonic);
```

### 日志输出

启用协程池模式后，启动时会输出配置信息：

```
HTTP server listening on 127.0.0.1:8080 (pool mode)
Worker pool size: 100, Channel buffer: 1000, Max connections: 10000
```

### 调优建议

1. **Worker Pool Size**
   - 太大：浪费内存，调度开销增加
   - 太小：连接处理延迟增加
   - 建议：根据 CPU 核心数和并发需求设置（通常 50-500）

2. **Channel Buffer**
   - 太大：占用内存
   - 太小：accept 可能阻塞
   - 建议：设置为 worker_pool_size 的 2-10 倍

3. **Max Connections**
   - 根据服务器资源设置
   - 考虑文件描述符限制（`ulimit -n`）

## 迁移指南

### 从 Direct Mode 迁移到 Pool Mode

1. **默认已启用**，无需修改代码
2. 如需禁用，调用 `server.setUsePool(false)`
3. 根据并发需求调整配置参数

### 性能测试

对比测试两种模式：

```bash
# 使用协程池模式（默认）
ab -k -n 50000 -c 1000 http://127.0.0.1:8080/

# 禁用协程池
# 在代码中设置：server.setUsePool(false);
ab -k -n 50000 -c 1000 http://127.0.0.1:8080/
```

## 注意事项

1. **协程池模式必须启用 keep-alive**
   - 工作协程会处理多个请求（keep-alive）
   - 不使用 keep-alive 时，模式切换不会带来太大收益

2. **Channel 阻塞**
   - 如果 channel 满了，新的连接会被拒绝
   - 可以通过增大 `channel_buffer` 或 `worker_pool_size` 解决

3. **错误处理**
   - 工作协程中的错误不会导致服务器崩溃
   - 单个连接的错误不影响其他连接

## 总结

协程池模式是 HTTP 服务器的一个重要优化，特别适合高并发场景。通过固定数量的工作协程和 channel 分发机制，可以在保持性能的同时，更好地控制资源使用。

**建议**：对于大多数应用，使用默认配置即可。只有在极高并发或特殊需求时，才需要调整参数。

