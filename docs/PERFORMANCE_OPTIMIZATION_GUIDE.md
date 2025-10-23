# ZCO 高并发性能优化指南

## 🚨 问题分析

### 当前性能瓶颈

1. **协程调度效率低**
   - 每次只处理一个协程
   - 优先级队列的线性查找 O(n)
   - 大量协程在就绪队列中等待

2. **HTTP处理复杂**
   - 复杂的字符串解析
   - 大量的内存分配
   - 重复的字符串比较

3. **内存管理问题**
   - 频繁的内存分配/释放
   - 没有对象池复用
   - 协程栈大小固定但可能过大

## ⚡ 优化方案

### 1. 调度器优化

#### 问题代码
```zig
// 当前实现 - 每次只处理一个协程
inline fn checkNextCo(self: *Schedule) !void {
    const count = self.readyQueue.count();
    if (count > 0) {
        const nextCo = self.readyQueue.remove();  // 只处理一个
        try cozig.Resume(nextCo);
    }
}
```

#### 优化方案
```zig
// 批量处理协程
inline fn checkNextCo(self: *Schedule) !void {
    const count = @min(self.readyQueue.count(), BATCH_SIZE);
    if (count == 0) return;
    
    // 批量处理多个协程
    for (0..count) |i| {
        const co = self.readyQueue.items[i];
        try co.Resume();
    }
    
    // 移除已处理的协程
    for (0..count) |_| {
        _ = self.readyQueue.orderedRemove(0);
    }
}
```

### 2. 数据结构优化

#### 使用更高效的数据结构
```zig
// 替换优先级队列为简单数组
readyQueue: std.ArrayList(*zco.Co),
sleepQueue: std.ArrayList(*zco.Co),

// 使用HashMap快速查找协程
coMap: std.HashMap(usize, *zco.Co, std.hash_map.default_hash_fn(usize), std.hash_map.default_eql_fn(usize)),
```

### 3. HTTP处理优化

#### 预编译响应
```zig
// 预编译HTTP响应，避免运行时字符串操作
const HTTP_200_KEEPALIVE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhelloworld";
const HTTP_200_CLOSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld";
```

#### 简化请求处理
```zig
fn handleRequestFast(buffer: []const u8, client: *nets.Tcp) !bool {
    // 快速检查请求类型
    if (buffer.len < 3) return false;
    
    // 检查是否是GET请求
    if (!std.mem.eql(u8, buffer[0..3], "GET")) {
        return false;
    }
    
    // 快速检查Connection头
    const isKeepAlive = std.mem.indexOf(u8, buffer, "Connection: keep-alive") != null;
    
    if (isKeepAlive) {
        _ = try client.write(HTTP_200_KEEPALIVE);
        return true;
    } else {
        _ = try client.write(HTTP_200_CLOSE);
        return false;
    }
}
```

### 4. 内存管理优化

#### 协程池
```zig
pub const CoroutinePool = struct {
    pool: std.ArrayList(*zco.Co),
    available: std.ArrayList(*zco.Co),
    
    pub fn getCo(self: *Self) ?*zco.Co {
        return self.available.popOrNull();
    }
    
    pub fn returnCo(self: *Self, co: *zco.Co) void {
        self.available.append(co) catch {};
    }
};
```

#### 内存池
```zig
pub const MemoryPool = struct {
    blocks: std.ArrayList([]u8),
    freeBlocks: std.ArrayList([]u8),
    
    pub fn getBlock(self: *Self) ?[]u8 {
        return self.freeBlocks.popOrNull();
    }
    
    pub fn returnBlock(self: *Self, block: []u8) void {
        self.freeBlocks.append(block) catch {};
    }
};
```

### 5. 配置优化

#### 调整协程栈大小
```zig
// 根据实际需求调整栈大小
pub const DEFAULT_ZCO_STACK_SZIE = 1024 * 8;  // 8KB instead of 32KB
```

#### 调整事件循环参数
```zig
// 增加事件循环条目数
schedule.xLoop = try xev.Loop.init(.{
    .entries = 1024 * 16,  // 16K entries instead of 4K
});
```

## 🔧 具体实施步骤

### 步骤1：优化调度器
1. 修改 `schedule.zig` 中的 `checkNextCo` 函数
2. 实现批量处理逻辑
3. 添加连接数限制

### 步骤2：简化HTTP处理
1. 预编译HTTP响应
2. 简化请求解析逻辑
3. 减少字符串操作

### 步骤3：优化内存管理
1. 实现协程池
2. 实现内存池
3. 减少动态分配

### 步骤4：调整配置参数
1. 减小协程栈大小
2. 增加事件循环条目数
3. 调整批处理大小

## 📊 性能测试

### 测试命令
```bash
# 测试并发性能
ab -n 10000 -c 100 http://localhost:8080/

# 测试高并发
ab -n 50000 -c 1000 http://localhost:8080/

# 测试长连接
ab -n 10000 -c 100 -k http://localhost:8080/
```

### 预期改进
- **响应时间**：从毫秒级降低到微秒级
- **并发能力**：从1000提升到10000+
- **内存使用**：减少50%以上
- **CPU使用率**：降低30%以上

## 🚀 高级优化

### 1. 无锁数据结构
```zig
// 使用无锁队列
const LockFreeQueue = struct {
    head: std.atomic.Value(*Node),
    tail: std.atomic.Value(*Node),
    // ...
};
```

### 2. CPU亲和性
```zig
// 绑定协程到特定CPU核心
pub fn setCpuAffinity(co: *zco.Co, cpu: usize) void {
    // 设置CPU亲和性
}
```

### 3. 零拷贝优化
```zig
// 使用sendfile等零拷贝技术
pub fn sendFile(fd: i32, file: std.fs.File) !void {
    // 零拷贝文件传输
}
```

## 📈 监控和调试

### 性能监控
```zig
pub const PerfMonitor = struct {
    requestCount: std.atomic.Value(u64),
    totalLatency: std.atomic.Value(u64),
    maxLatency: std.atomic.Value(u64),
    
    pub fn recordRequest(self: *Self, latencyNs: u64) void {
        // 记录性能指标
    }
};
```

### 调试工具
```bash
# 使用perf分析性能
perf record -g ./zco_server
perf report

# 使用strace跟踪系统调用
strace -c ./zco_server
```

## 🎯 总结

通过以上优化，ZCO协程库在高并发场景下的性能将得到显著提升：

1. **调度效率**：批量处理协程，减少调度开销
2. **内存效率**：对象池和内存池，减少分配开销
3. **处理效率**：简化HTTP处理，减少CPU开销
4. **配置优化**：调整参数，平衡性能和资源使用

这些优化将帮助您解决高并发时响应延时大的问题，提升系统的整体性能。
