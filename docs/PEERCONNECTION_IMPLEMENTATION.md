# RTCPeerConnection 实现计划

## 概述

RTCPeerConnection 是 WebRTC 的核心 API，用于建立对等连接并管理媒体传输。它将整合所有已实现的底层组件：
- ICE Agent（连接建立）✅
- DTLS（安全传输）✅
- SRTP（媒体加密）✅
- RTP/RTCP（媒体传输）✅
- SCTP（数据通道）✅

**文档版本**: 2.1  
**创建日期**: 2025年11月  
**最后更新**: 2025年11月5日  
**项目分支**: `feature/webrtc-implementation`  
**当前状态**: ✅ 核心功能已完成，API 已优化以符合浏览器行为

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

#### createOffer(options?: RTCOfferOptions)
- 生成 SDP offer
- 包含本地支持的编解码器、ICE candidates
- **自动创建 UDP socket 并收集 candidates**（如果还未收集）
- 支持 RTCOfferOptions 参数（符合浏览器 API）
- 返回 RTCSessionDescription

#### createAnswer(options?: RTCAnswerOptions)
- 响应远程 offer，生成 SDP answer
- 协商编解码器和传输参数
- **自动创建 UDP socket 并收集 candidates**（如果还未收集）
- 支持 RTCAnswerOptions 参数（符合浏览器 API）
- 返回 RTCSessionDescription

#### setLocalDescription(description: RTCSessionDescription)
- 设置本地 SDP 描述
- **自动创建 UDP socket 并收集 candidates**（符合浏览器行为）
- 如果 UDP socket 已存在但还未收集 candidates，也会尝试收集
- 启动 DTLS 握手（如果收到 remote description）

#### setRemoteDescription(description: RTCSessionDescription)
- 设置远程 SDP 描述
- **自动解析 SDP 中的 candidates**
- **只有在有 candidate pairs 时才启动 connectivity checks**（避免过早失败）
- 自动处理 UDP socket 创建和关联（如果还未创建）

#### addTrack(track, stream)
- 添加媒体轨道（音频/视频）
- 创建 RTCRtpSender
- 建立发送路径

#### addIceCandidate(candidate: RTCIceCandidate | RTCIceCandidateInit)
- 添加远程 ICE candidate（支持 RTCIceCandidate 对象或 RTCIceCandidateInit 结构）
- 更新候选对列表
- **自动生成 candidate pairs 并开始 connectivity checks**（如果条件满足）
- 如果本地和远程描述都已设置，且已有 candidate pairs，会自动开始 connectivity checks

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
- [x] 定义 RTCPeerConnection 结构
- [x] 定义状态枚举
- [x] 实现初始化函数

### 步骤 2: 信令状态机
- [x] 实现 SignalingState 管理
- [x] 实现 setLocalDescription/setRemoteDescription
- [x] 实现 createOffer/createAnswer

### 步骤 3: ICE 集成
- [x] 集成 ICE Agent
- [x] 处理 candidate 收集事件
- [x] 处理连接状态变化

### 步骤 4: DTLS 集成
- [x] 集成 DTLS Context
- [x] 处理 DTLS 握手流程（客户端/服务器端）
- [x] 处理 DTLS 记录层

### 步骤 5: SRTP 集成
- [x] 从 DTLS 派生 SRTP 密钥
- [x] 创建发送方和接收方 SRTP Transform
- [x] 集成到 RTP 包处理流程

### 步骤 6: RTP/RTCP 集成
- [x] 集成 RTP 包发送/接收
- [x] 集成 RTCP 统计和反馈
- [x] 处理 SSRC 管理

### 步骤 7: 媒体轨道管理
- [x] 实现 addTrack/removeTrack
- [x] 创建 RTCRtpSender
- [x] 创建 RTCRtpReceiver
- [x] 建立媒体发送/接收路径

### 步骤 8: 数据通道集成
- [x] 集成 SCTP Association
- [x] 实现 createDataChannel
- [x] 实现数据通道列表管理
- [x] 实现 Stream ID 自动分配
- [x] 实现数据通道网络传输（通过 DTLS 发送 SCTP 数据包）
- [x] 实现数据通道接收流程（从 DTLS 接收并解析 SCTP 包）
  - [x] `recvSctpData()` - 从 DTLS 接收数据
  - [x] `handleSctpPacket()` - 解析 SCTP 包并验证
  - [x] `handleDataChunk()` - 路由到 DataChannel 并触发 onmessage 事件
  - [x] 示例程序已验证功能可用
- [x] 处理数据通道事件
- [ ] 自动创建 DataChannel（收到新 Stream ID 时）🔄 待完善
- [ ] 处理其他 SCTP Chunk 类型（SACK、HEARTBEAT 等）🔄 待完善

### 步骤 9: 事件系统
- [x] 实现事件回调（onicecandidate, onconnectionstatechange 等）
- [x] 实现事件分发机制
- [x] 自动触发 DTLS 握手和 SRTP 设置

### 步骤 10: 单元测试
- [x] 测试基础状态机
- [x] 测试 offer/answer 流程
- [x] 测试 ICE 集成
- [x] 测试端到端连接建立
- [x] 测试数据通道创建和管理
- [x] 测试 RTP/RTCP 集成
- [x] 测试事件系统

**测试结果**: 216/216 测试通过

### 步骤 11: API 优化（2025-11-05）
- [x] 自动化 ICE candidates 收集
  - [x] setupUdpSocketInternal 自动收集 candidates
  - [x] createOffer/createAnswer 时自动创建 socket 并收集 candidates
  - [x] setLocalDescription 时自动收集 candidates（如果还未收集）
- [x] 优化 setRemoteDescription
  - [x] 只有在有 candidate pairs 时才启动 connectivity checks
  - [x] 自动处理 UDP socket 创建和关联
- [x] 改进 addIceCandidate
  - [x] 添加 candidate 后自动生成 pairs 并开始 connectivity checks（如果条件满足）
- [x] 添加浏览器标准类型别名
  - [x] RTCSessionDescription, RTCIceCandidate, RTCOfferOptions, RTCAnswerOptions, RTCIceCandidateInit
- [x] 更新 Configuration 支持 certificates 和 credential_type
- [x] 修复所有编译错误
- [x] **所有示例程序已验证通过**

**API 改进详情**: 所有 API 调用已优化以符合浏览器行为，无需手动调用 gatherHostCandidates 等方法

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

## API 使用示例

### 基本流程（浏览器行为）

```zig
// 1. 创建 PeerConnection
const config = Configuration{};
var pc = try PeerConnection.init(allocator, schedule, config);
defer pc.deinit();

// 2. 创建 offer（自动收集 candidates）
const offer = try pc.createOffer(allocator, null);
try pc.setLocalDescription(offer); // 自动创建 UDP socket 并收集 candidates

// 3. 发送 offer 到对端（通过信令服务器）
// ... 信令交换 ...

// 4. 接收 answer
try pc.setRemoteDescription(answer); // 自动解析 candidates，等待 pairs 后再开始连接检查

// 5. 接收 ICE candidates（通过信令服务器）
// addIceCandidate 会自动生成 pairs 并开始 connectivity checks（如果条件满足）
try pc.addIceCandidate(candidate);

// 6. 创建数据通道
const channel = try pc.createDataChannel("test-channel", null);
```

### 可选：手动指定 UDP 地址（仅用于测试）

```zig
// 如果需要指定特定端口（测试场景）
const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 10000);
_ = try pc.setupUdpSocket(bind_addr); // setupUdpSocketInternal 会自动收集 candidates

// 然后正常创建 offer
const offer = try pc.createOffer(allocator, null);
try pc.setLocalDescription(offer); // candidates 已自动收集
```

## 注意事项

1. **异步操作**: 所有网络操作都需要在协程环境中执行
2. **状态同步**: 确保状态变化线程安全
3. **资源管理**: 正确释放所有分配的资源
4. **错误处理**: 提供清晰的错误信息
5. **事件顺序**: 确保事件按正确顺序触发
6. **浏览器行为**: API 已优化以符合浏览器行为，无需手动调用内部方法
   - 无需手动调用 `gatherHostCandidates()`
   - 无需手动调用 `generateCandidatePairs()`
   - 无需手动创建 UDP socket（除非测试需要指定地址）

