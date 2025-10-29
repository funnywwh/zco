# HTTP 框架改进计划

## 当前状态

✅ **已实现**：
- HTTP keep-alive 支持
- 基本的请求/响应处理
- 中间件系统
- 路由系统
- JWT、文件上传、静态文件等服务

## 待改进项

### 高优先级 🔴

#### 1. 请求分片和粘包处理

**问题**：
- 当前实现假设一次 `read()` 读取完整的 HTTP 请求
- 在 keep-alive 模式下，可能遇到：
  - **粘包**：多个请求在同一个 TCP 数据包中
  - **分包**：一个请求分成多个 TCP 数据包

**改进方案**：
```zig
// 需要实现请求边界检测
fn readCompleteRequest(client: *nets.Tcp, buffer: []u8) !usize {
    var total_read: usize = 0;
    var header_end: ?usize = null;
    
    while (true) {
        const n = try client.read(buffer[total_read..]);
        total_read += n;
        
        // 查找 "\r\n\r\n" 确定头部结束
        if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n")) |pos| {
            header_end = pos + 4;
            
            // 检查是否有 Content-Length
            // 如果有，继续读取直到达到指定长度
            // 如果没有，头部结束就是请求结束（GET请求）
            break;
        }
        
        if (total_read >= buffer.len) {
            return error.BufferTooSmall;
        }
    }
    
    return total_read;
}
```

**影响**：修复后可以正确处理分片和粘包，提高稳定性

#### 2. Content-Length 完整读取

**问题**：
- 当前如果请求体较大，可能一次读取不完整
- 需要根据 Content-Length 继续读取

**改进方案**：
- 解析 HTTP 头部后，检查 Content-Length
- 如果指定了长度，继续读取直到达到指定长度
- 如果没有 Content-Length，检查是否是 chunked 编码

### 中优先级 🟡

#### 3. 连接超时和限流

**问题**：
- 长时间空闲的连接占用资源
- 没有最大连接数限制
- 可能导致资源耗尽

**改进方案**：
```zig
// 添加连接超时
const KEEP_ALIVE_TIMEOUT = 30 * std.time.ns_per_s; // 30秒
var last_request_time: std.time.Instant = undefined;

// 在每次请求后更新
last_request_time = try std.time.Instant.now();

// 在读取前检查
const elapsed = (try std.time.Instant.now()).since(last_request_time);
if (elapsed > KEEP_ALIVE_TIMEOUT) {
    // 超时，关闭连接
    break;
}

// 最大连接数限制
const MAX_CONNECTIONS = 10000;
var active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
```

#### 4. 缓冲区池化

**问题**：
- 每个连接都分配新的 8KB 缓冲区
- 频繁分配/释放导致延迟

**改进方案**：
- 使用缓冲区池复用缓冲区
- 减少内存分配开销

### 低优先级 🟢

#### 5. HTTP/1.1 Chunked 编码支持

**问题**：
- 当前不支持 Transfer-Encoding: chunked
- 对大数据传输不友好

#### 6. HTTP/2 支持

**问题**：
- 仅支持 HTTP/1.1
- HTTP/2 可以提供更好的性能

#### 7. 请求压缩（gzip/deflate）

**问题**：
- 响应没有压缩
- 对文本内容（HTML、JSON）可以显著减少传输量

## 性能优化路线图

### Phase 1: 基础稳定性（当前阶段）
- [x] HTTP keep-alive
- [ ] 请求分片处理
- [ ] Content-Length 完整读取

### Phase 2: 资源管理
- [ ] 连接超时
- [ ] 连接数限制
- [ ] 缓冲区池化

### Phase 3: 高级特性
- [ ] Chunked 编码
- [ ] 响应压缩
- [ ] HTTP/2 支持

## 测试建议

### 1. Keep-Alive 测试

```bash
# 测试 keep-alive 是否生效
curl -v http://127.0.0.1:8080/ 2>&1 | grep -i connection

# 应该看到：Connection: keep-alive
```

### 2. 多请求测试

```bash
# 创建包含多个请求的文件
cat > requests.txt <<EOF
GET / HTTP/1.1
Host: 127.0.0.1:8080

GET / HTTP/1.1
Host: 127.0.0.1:8080

EOF

# 通过 netcat 发送
cat requests.txt | nc 127.0.0.1 8080
```

### 3. 压力测试

```bash
# 使用 wrk 测试 keep-alive
wrk -t12 -c400 -d30s http://127.0.0.1:8080/

# 使用 vegeta
echo "GET http://127.0.0.1:8080/" | vegeta attack -duration=30s -rate=1000 | vegeta report
```

## 参考实现

参考 `nets/src/main.zig` 中的优化实现：
- 使用协程池处理连接
- 缓冲区复用
- 快速路径优化
- 零拷贝优化

---

**最后更新**: 2025年10月29日

