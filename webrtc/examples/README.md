# WebRTC 示例应用

## 数据通道示例

`datachannel_example.zig` 演示了如何使用 WebRTC 数据通道进行双向消息传输。

### 功能特性

- 创建 PeerConnection
- 创建数据通道
- 设置事件回调（onopen, onclose, onmessage, onerror）
- 发送消息
- 接收消息（模拟）

### 运行示例

```bash
cd webrtc
zig build run-datachannel
```

### 使用说明

1. **创建 PeerConnection**
   ```zig
   const config = PeerConnection.Configuration{};
   var pc = try PeerConnection.init(allocator, &schedule, config);
   ```

2. **创建数据通道**
   ```zig
   const channel = try pc.createDataChannel("test-channel", null);
   ```

3. **设置事件回调**
   ```zig
   channel.setOnOpen(callback);
   channel.setOnClose(callback);
   channel.setOnMessage(callback);
   channel.setOnError(callback);
   ```

4. **发送消息**
   ```zig
   channel.send("Hello, WebRTC!") catch |err| {
       // 处理错误
   };
   ```

5. **接收消息**
   ```zig
   // 在实际应用中，应该持续监听
   pc.recvSctpData() catch |err| {
       // 处理错误
   };
   ```

### 注意事项

- 当前示例是演示版本，需要完整的连接建立（ICE、DTLS 握手）才能实际传输数据
- 在实际应用中，需要两个 PeerConnection 实例（客户端和服务器端）进行通信
- 需要信令服务器来交换 SDP 和 ICE candidates

### 完整流程

1. 创建 PeerConnection（双方）
2. 创建数据通道
3. 生成 SDP offer/answer
4. 交换 SDP（通过信令服务器）
5. 交换 ICE candidates（通过信令服务器）
6. ICE 连接建立
7. DTLS 握手完成
8. SCTP 关联建立
9. 数据通道可以发送/接收消息

