# WebSocket服务器模块

基于ZCO协程库实现的完整WebSocket服务器，支持RFC 6455标准协议。

## 功能特性

- ✅ WebSocket握手（HTTP升级）
- ✅ 文本消息收发
- ✅ 二进制消息收发
- ✅ Ping/Pong保活机制
- ✅ 分片消息支持
- ✅ 关闭握手
- ✅ 多连接并发处理
- ✅ 基于协程的异步IO

## 构建

```bash
cd websocket
zig build
```

## 运行服务器

```bash
zig build run
```

服务器将在 `ws://127.0.0.1:8080` 启动。

## 使用示例

### 基本用法

```zig
const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const websocket = @import("websocket");

pub fn main() !void {
    // ... 初始化代码 ...

    // 创建TCP服务器
    const server = try nets.Tcp.init(schedule);
    defer {
        server.close();
        server.deinit();
    }

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try server.bind(address);
    try server.listen(128);

    // 接受连接
    const client = try server.accept();
    defer {
        client.close();
        client.deinit();
    }

    // 创建WebSocket连接
    var ws = try websocket.WebSocket.fromTcp(client);
    defer ws.deinit();

    // 执行握手
    try ws.handshake();

    // 发送文本消息
    try ws.sendText("Hello, WebSocket!");

    // 读取消息
    var buffer: [4096]u8 = undefined;
    const frame = try ws.readMessage(buffer[0..]);
    
    // 处理消息
    switch (frame.opcode) {
        .TEXT => {
            std.log.info("Received: {s}", .{frame.payload});
            ws.allocator.free(frame.payload);
        },
        .BINARY => {
            std.log.info("Received binary: {} bytes", .{frame.payload.len});
            ws.allocator.free(frame.payload);
        },
        else => {},
    }

    // 关闭连接
    try ws.close(1000, "Normal closure");
}
```

## API文档

### WebSocket结构体

#### `fromTcp(tcp: *nets.Tcp) !*WebSocket`

从TCP连接创建WebSocket实例。

#### `deinit() void`

清理WebSocket资源。

#### `handshake() !void`

执行WebSocket握手，将HTTP连接升级为WebSocket连接。

#### `sendText(data: []const u8) !void`

发送文本消息。

#### `sendBinary(data: []const u8) !void`

发送二进制消息。

#### `readMessage(buffer: []u8) !FrameType`

读取完整消息（自动处理分片）。返回的`FrameType.payload`需要使用`ws.allocator.free()`释放。

#### `sendPing(data: ?[]const u8) !void`

发送PING帧（可选携带数据）。

#### `sendPong(data: []const u8) !void`

发送PONG帧（响应PING）。

#### `close(code: ?u16, reason: ?[]const u8) !void`

关闭WebSocket连接。`code`为可选的关闭码（默认1000），`reason`为可选的关闭原因。

### FrameType结构体

```zig
pub const FrameType = struct {
    opcode: Opcode,      // 帧操作码
    payload: []u8,       // 载荷数据（需要手动释放）
    fin: bool,           // 是否是最后一帧
};
```

### Opcode枚举

```zig
pub const Opcode = enum(u4) {
    CONTINUATION = 0x0,  // 分片继续
    TEXT = 0x1,          // 文本帧
    BINARY = 0x2,        // 二进制帧
    CLOSE = 0x8,         // 关闭帧
    PING = 0x9,          // Ping帧
    PONG = 0xA,          // Pong帧
};
```

## 测试

使用Node.js测试客户端：

```bash
cd test
npm install
node client_test.js
```

测试套件包括：
- WebSocket握手测试
- 文本消息收发测试
- 二进制消息收发测试
- Ping/Pong机制测试
- 分片消息测试
- 关闭握手测试
- 多连接并发测试

## 注意事项

1. `readMessage()`返回的payload数据需要手动使用`ws.allocator.free()`释放
2. 所有网络操作必须在协程环境中进行
3. 确保在使用前调用`handshake()`完成握手
4. 大消息会自动分片，`readMessage()`会自动重组分片

## 协议支持

本实现支持RFC 6455 WebSocket协议的核心功能：
- ✅ 基础帧格式
- ✅ 掩码处理
- ✅ 分片消息
- ✅ 控制帧（PING/PONG/CLOSE）
- ✅ 握手（Sec-WebSocket-Accept生成）
- ❌ 扩展协议（permessage-deflate等，暂不支持）
- ❌ 子协议协商（暂不支持，但可扩展）

## 性能

- 基于协程的异步IO，支持高并发
- 零拷贝帧处理（分片除外）
- 自动处理ping/pong，保持连接活跃

## 示例程序

运行示例echo服务器：

```bash
zig build run
```

服务器会将收到的所有消息echo回客户端。
