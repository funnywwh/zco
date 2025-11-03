# RTCPeerConnection 实现计划

## 概述

RTCPeerConnection 是 WebRTC 的核心 API，用于建立对等连接并管理媒体传输。它将整合所有已实现的底层组件：
- ICE Agent（连接建立）
- DTLS（安全传输）
- SRTP（媒体加密）
- RTP/RTCP（媒体传输）
- SCTP（数据通道）

## 架构设计

```
RTCPeerConnection
├── ICE Agent（连接建立和候选收集）
├── DTLS Context（安全握手）
├── SRTP Context（媒体加密上下文）
├── RTP/RTCP Handler（媒体包处理）
├── SCTP Association（数据通道）
└── Signaling State Machine（信令状态机）
```

## 核心功能

### 1. 状态管理

- **信令状态** (SignalingState): stable, have-local-offer, have-remote-offer, have-local-pranswer, have-remote-pranswer, closed
- **ICE 连接状态** (IceConnectionState): new, checking, connected, completed, failed, disconnected, closed
- **ICE 收集状态** (IceGatheringState): new, gathering, complete
- **连接状态** (ConnectionState): new, connecting, connected, disconnected, failed, closed

### 2. 核心方法

#### createOffer()
- 生成 SDP offer
- 包含本地支持的编解码器、ICE candidates
- 设置本地描述

#### createAnswer()
- 响应远程 offer，生成 SDP answer
- 协商编解码器和传输参数

#### setLocalDescription()
- 设置本地 SDP 描述
- 触发 ICE candidate 收集
- 启动 DTLS 握手（如果收到 remote description）

#### setRemoteDescription()
- 设置远程 SDP 描述
- 解析远程 ICE candidates
- 启动连接检查

#### addTrack()
- 添加媒体轨道（音频/视频）
- 创建 RTCRtpSender
- 建立发送路径

#### addIceCandidate()
- 添加远程 ICE candidate
- 更新候选对列表
- 触发连接检查

### 3. 内部组件整合

#### ICE Agent 集成
```zig
ice_agent: *ice.Agent,
// 处理 candidate 收集和连接检查
```

#### DTLS 集成
```zig
dtls_context: ?*dtls.Context,
// 处理 DTLS 握手和记录层
```

#### SRTP 集成
```zig
srtp_sender: ?*srtp.Transform,    // 发送方 SRTP
srtp_receiver: ?*srtp.Transform, // 接收方 SRTP
// 处理媒体加密/解密
```

#### RTP/RTCP 集成
```zig
rtp_sender: ?*rtp.PacketHandler,
rtcp_handler: ?*rtcp.Handler,
// 处理 RTP 包发送和接收
```

#### SCTP 集成
```zig
sctp_association: ?*sctp.Association,
// 处理数据通道
```

## 实现步骤

### 步骤 1: 基础结构定义
- [ ] 定义 RTCPeerConnection 结构
- [ ] 定义状态枚举
- [ ] 实现初始化函数

### 步骤 2: 信令状态机
- [ ] 实现 SignalingState 管理
- [ ] 实现 setLocalDescription/setRemoteDescription
- [ ] 实现 createOffer/createAnswer

### 步骤 3: ICE 集成
- [ ] 集成 ICE Agent
- [ ] 处理 candidate 收集事件
- [ ] 处理连接状态变化

### 步骤 4: DTLS 集成
- [ ] 集成 DTLS Context
- [ ] 处理 DTLS 握手流程
- [ ] 处理 DTLS 记录层

### 步骤 5: SRTP 集成
- [ ] 从 DTLS 派生 SRTP 密钥
- [ ] 创建发送方和接收方 SRTP Transform
- [ ] 集成到 RTP 包处理流程

### 步骤 6: RTP/RTCP 集成
- [ ] 集成 RTP 包发送/接收
- [ ] 集成 RTCP 统计和反馈
- [ ] 处理 SSRC 管理

### 步骤 7: 媒体轨道管理
- [ ] 实现 addTrack/removeTrack
- [ ] 创建 RTCRtpSender
- [ ] 建立媒体发送路径

### 步骤 8: 数据通道集成
- [ ] 集成 SCTP Association
- [ ] 实现 createDataChannel
- [ ] 处理数据通道事件

### 步骤 9: 事件系统
- [ ] 实现事件回调（onicecandidate, onconnectionstatechange 等）
- [ ] 实现事件分发机制

### 步骤 10: 单元测试
- [ ] 测试基础状态机
- [ ] 测试 offer/answer 流程
- [ ] 测试 ICE 集成
- [ ] 测试端到端连接建立

## 文件结构

```
webrtc/src/peer/
├── connection.zig      # RTCPeerConnection 主实现
├── transceiver.zig     # RTCRtpTransceiver
├── sender.zig          # RTCRtpSender
├── receiver.zig         # RTCRtpReceiver
├── session.zig         # 会话状态管理
└── root.zig            # 模块导出
```

## 参考规范

- [W3C WebRTC 1.0 Specification](https://www.w3.org/TR/webrtc/)
- [RFC 8825: WebRTC Overview](https://datatracker.ietf.org/doc/html/rfc8825)
- [RFC 8829: JavaScript Session Establishment Protocol](https://datatracker.ietf.org/doc/html/rfc8829)

## 注意事项

1. **异步操作**: 所有网络操作都需要在协程环境中执行
2. **状态同步**: 确保状态变化线程安全
3. **资源管理**: 正确释放所有分配的资源
4. **错误处理**: 提供清晰的错误信息
5. **事件顺序**: 确保事件按正确顺序触发

