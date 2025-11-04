# WebRTC 示例应用

本目录包含 WebRTC 实现的示例应用，用于演示和测试功能。

## 示例列表

### 1. 信令服务器 (`signaling_server.zig`)

WebRTC 信令服务器，基于 WebSocket 实现，用于转发 offer/answer/ICE candidate 消息。

**运行方式：**
```bash
cd webrtc
zig build run-signaling
```

服务器将在 `ws://127.0.0.1:8080` 启动。

### 2. 信令客户端 (`signaling_client.zig`)

WebRTC 信令客户端，通过信令服务器连接两个 PeerConnection。

**运行方式：**

终端 1（启动信令服务器）：
```bash
cd webrtc
zig build run-signaling
```

终端 2（启动 Alice）：
```bash
cd webrtc
zig build run-client -- alice test-room
```

终端 3（启动 Bob）：
```bash
cd webrtc
zig build run-client -- bob test-room
```

**功能：**
- Alice 创建 offer 并发送给 Bob
- Bob 接收 offer，创建 answer 并发送给 Alice
- 双方交换 ICE candidates
- 建立 ICE 连接
- 建立 DTLS 握手
- 创建数据通道并发送测试消息

### 3. 数据通道 Echo 示例 (`datachannel_echo.zig`)

演示两个 PeerConnection 之间的数据通道双向通信（不通过信令服务器）。

**运行方式：**
```bash
cd webrtc
zig build run-echo
```

**功能：**
- 创建两个 PeerConnection（Alice 和 Bob）
- 建立 ICE 连接
- 完成 DTLS 握手
- 创建数据通道
- Alice 发送消息，Bob 回显

### 4. 数据通道基础示例 (`datachannel_example.zig`)

数据通道的基础使用示例（模拟环境）。

**运行方式：**
```bash
cd webrtc
zig build run-datachannel
```

### 5. UDP 测试 (`udp_test.zig`)

测试 UDP socket 的基本发送和接收功能。

**运行方式：**
```bash
cd webrtc
zig build run-udp-test
```

## 使用说明

### 完整示例流程（信令服务器 + 两个客户端）

1. **启动信令服务器**：
   ```bash
   zig build run-signaling
   ```

2. **在第一个终端启动 Alice**：
   ```bash
   zig build run-client -- alice test-room
   ```

3. **在第二个终端启动 Bob**：
   ```bash
   zig build run-client -- bob test-room
   ```

4. **观察连接建立过程**：
   - Alice 创建 offer 并发送
   - Bob 接收 offer，创建 answer 并发送
   - 双方交换 ICE candidates
   - 建立 ICE 连接
   - 完成 DTLS 握手
   - 创建数据通道
   - Alice 发送测试消息

## 注意事项

1. **SCTP Verification Tags**：当前示例中，SCTP Verification Tags 的设置是简化实现。在实际应用中，应该从 SCTP 握手过程中获取。

2. **TCP 客户端连接**：已实现 TCP 客户端连接功能（`nets.Tcp.connect`），支持异步连接。

3. **信令消息格式**：使用 JSON 格式，包含以下类型：
   - `join`: 加入房间
   - `offer`: SDP offer
   - `answer`: SDP answer
   - `ice-candidate`: ICE candidate
   - `leave`: 离开房间
   - `error`: 错误消息

4. **房间管理**：信令服务器支持多房间，每个房间可以有多个用户。

## 故障排除

### 连接被拒绝

如果客户端显示 "ConnectionRefused"，请确保信令服务器已启动。

### 端口被占用

如果端口 8080 被占用，可以修改 `signaling_server.zig` 中的端口号。

### 数据通道未建立

检查：
1. ICE 连接是否成功建立
2. DTLS 握手是否完成
3. SCTP Verification Tags 是否正确设置（当前示例中已简化）
