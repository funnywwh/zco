# WebRTC 完整实现计划

**文档版本**: 1.0  
**创建日期**: 2025年1月  
**项目分支**: `feature/webrtc-implementation`  
**当前状态**: 规划阶段

## 📋 项目概述

在 ZCO 协程库基础上，从零实现完整的 WebRTC 协议栈，支持音视频通话功能。项目将遵循 Zig 0.14.0 规范和 ZCO 项目的协程编程模式。

## 🛠️ 技术栈

- **基础**: ZCO 协程调度器 + libxev 异步 IO
- **网络**: 基于现有的 `nets` 模块扩展 UDP 支持
- **信令**: 基于现有的 `websocket` 模块实现信令服务器
- **加密**: 使用 `std.crypto` 实现 DTLS、SRTP
- **协议**: 从零实现所有 WebRTC 相关协议

## 📁 项目结构

```
webrtc/
├── build.zig
├── build.zig.zon
├── README.md
└── src/
    ├── root.zig              # 模块导出
    ├── main.zig              # 示例程序
    ├── signaling/            # 信令层
    │   ├── server.zig        # WebSocket 信令服务器
    │   ├── sdp.zig           # SDP 解析和生成
    │   └── message.zig       # 信令消息处理
    ├── ice/                  # ICE 协议
    │   ├── agent.zig         # ICE Agent
    │   ├── candidate.zig     # ICE Candidate
    │   ├── stun.zig          # STUN 协议实现
    │   └── turn.zig          # TURN 协议实现
    ├── dtls/                 # DTLS 协议
    │   ├── context.zig       # DTLS 上下文
    │   ├── handshake.zig     # DTLS 握手
    │   ├── record.zig        # DTLS 记录层
    │   └── crypto.zig        # DTLS 加密/解密
    ├── srtp/                 # SRTP 协议
    │   ├── context.zig       # SRTP 上下文
    │   ├── transform.zig     # SRTP 转换
    │   └── crypto.zig        # SRTP 加密/解密
    ├── rtp/                  # RTP/RTCP 协议
    │   ├── packet.zig        # RTP 包解析
    │   ├── rtcp.zig          # RTCP 包处理
    │   └── ssrc.zig          # SSRC 管理
    ├── sctp/                 # SCTP 协议（数据通道）
    │   ├── association.zig  # SCTP 关联
    │   ├── chunk.zig         # SCTP 块
    │   └── stream.zig        # SCTP 流
    ├── media/                # 媒体处理
    │   ├── codec.zig         # 编解码器接口
    │   ├── audio.zig         # 音频处理
    │   ├── video.zig         # 视频处理
    │   └── track.zig         # 媒体轨道
    ├── peer/                 # PeerConnection
    │   ├── connection.zig    # RTCPeerConnection
    │   ├── transceiver.zig   # RTCRtpTransceiver
    │   └── session.zig       # 会话管理
    └── utils/                # 工具函数
        ├── fingerprint.zig   # DTLS 指纹计算
        ├── crypto_utils.zig  # 加密工具
        └── random.zig        # 随机数生成
```

## 🚀 实现阶段

### 阶段 1: 基础网络和信令层 (1-2周)

#### 1. UDP 支持扩展
- 在 `nets` 模块中添加 UDP socket 支持
- 实现异步 UDP 读写（基于 libxev）
- **文件**: `nets/src/udp.zig`
- **状态**: ⏳ 待开始

#### 2. 信令服务器实现
- 基于现有 `websocket` 模块
- 实现信令消息路由（offer/answer/ICE candidate）
- 实现房间管理和用户配对
- **文件**: `webrtc/src/signaling/server.zig`, `message.zig`
- **状态**: ⏳ 待开始

#### 3. SDP 协议实现
- SDP 解析器（RFC 4566）
- SDP 生成器
- 媒体描述处理（音频/视频）
- ICE candidate 嵌入
- **文件**: `webrtc/src/signaling/sdp.zig`
- **状态**: ⏳ 待开始

### 阶段 2: ICE 和 NAT 穿透 (2-3周)

#### 4. STUN 协议实现
- STUN 消息格式（RFC 5389）
- STUN Binding Request/Response
- 属性解析（MAPPED-ADDRESS, XOR-MAPPED-ADDRESS）
- 消息完整性检查（MESSAGE-INTEGRITY）
- **文件**: `webrtc/src/ice/stun.zig`
- **状态**: ⏳ 待开始

#### 5. ICE Agent 实现
- ICE Candidate 收集
- Host/ServerReflexive/Relay candidates
- Candidate 优先级计算
- Connectivity Checks（检查对）
- ICE 状态机（NEW/CHECKING/CONNECTED/FAILED）
- **文件**: `webrtc/src/ice/agent.zig`, `candidate.zig`
- **状态**: ⏳ 待开始

#### 6. TURN 协议实现（可选，但建议实现）
- TURN 客户端实现（RFC 5766）
- Allocation 请求/响应
- Permission 和 Channel 机制
- Data Indication 处理
- **文件**: `webrtc/src/ice/turn.zig`
- **状态**: ⏳ 待开始

### 阶段 3: DTLS 握手和安全 (3-4周)

#### 7. DTLS 协议实现
- DTLS 记录层（RFC 6347）
- DTLS 握手协议
- 证书处理（自签名证书生成/验证）
- Cipher Suite 支持（至少 AES-128-GCM）
- DTLS-SRTP Key Derivation
- **文件**: `webrtc/src/dtls/` 目录下所有文件
- **状态**: ⏳ 待开始

#### 8. 加密工具
- AES-GCM 加密/解密
- HMAC-SHA256 用于消息认证
- ECDHE 密钥交换（P-256）
- **文件**: `webrtc/src/utils/crypto_utils.zig`
- 使用 `std.crypto` 的标准实现
- **状态**: ⏳ 待开始

### 阶段 4: SRTP 媒体加密 (2-3周)

#### 9. SRTP 协议实现
- SRTP 上下文初始化
- Master Key 和 Salt 派生
- SRTP 包加密/解密
- SRTCP 包加密/解密
- Replay Protection
- **文件**: `webrtc/src/srtp/` 目录下所有文件
- **状态**: ⏳ 待开始

### 阶段 5: RTP/RTCP 媒体传输 (2-3周)

#### 10. RTP 协议实现
- RTP 包头解析和构建
- SSRC 管理
- 序列号处理
- 时间戳处理
- Payload 类型映射
- **文件**: `webrtc/src/rtp/packet.zig`, `ssrc.zig`
- **状态**: ⏳ 待开始

#### 11. RTCP 协议实现
- RTCP 包解析（SR, RR, SDES, BYE）
- 发送端报告（SR）
- 接收端报告（RR）
- 带宽和统计信息收集
- **文件**: `webrtc/src/rtp/rtcp.zig`
- **状态**: ⏳ 待开始

### 阶段 6: SCTP 数据通道 (3-4周)

#### 12. SCTP 协议实现（over DTLS）
- SCTP 关联建立
- SCTP 块格式（DATA, INIT, INIT-ACK, etc.）
- 流控制
- 有序/无序传输
- 数据通道封装（RFC 8832）
- **文件**: `webrtc/src/sctp/` 目录下所有文件
- **状态**: ⏳ 待开始

### 阶段 7: 媒体处理 (4-5周)

#### 13. 媒体编解码器
- 音频编解码器接口
- Opus 编码器/解码器（RFC 6716）
- G.711 (PCMU/PCMA) 支持
- 视频编解码器接口
- VP8/VP9 解码器基础实现
- H.264 基础解码器（可选）
- **文件**: `webrtc/src/media/codec.zig`, `audio.zig`, `video.zig`
- **状态**: ⏳ 待开始

#### 14. 媒体轨道管理
- MediaStreamTrack 抽象
- 音频轨道处理
- 视频轨道处理
- **文件**: `webrtc/src/media/track.zig`
- **状态**: ⏳ 待开始

### 阶段 8: PeerConnection 整合 (2-3周)

#### 15. RTCPeerConnection 实现
- PeerConnection 状态机
- createOffer/createAnswer
- setLocalDescription/setRemoteDescription
- addTrack/removeTrack
- addIceCandidate
- **文件**: `webrtc/src/peer/connection.zig`
- **状态**: ⏳ 待开始

#### 16. Transceiver 和会话管理
- RTCRtpTransceiver 实现
- 发送/接收路径整合
- 会话状态管理
- **文件**: `webrtc/src/peer/transceiver.zig`, `session.zig`
- **状态**: ⏳ 待开始

### 阶段 9: 测试和示例 (持续进行)

#### 17. 测试套件
- 单元测试（每个模块）
- 集成测试（端到端）
- 浏览器兼容性测试
- **状态**: ⏳ 待开始

#### 18. 示例应用
- 简单的点对点音视频通话示例
- 信令服务器示例
- 数据通道示例
- **状态**: ⏳ 待开始

## 🔧 技术要点

### 内存管理
- 所有资源使用 ZCO 调度器的 allocator
- 大量使用 `defer` 确保资源释放
- 避免在协程切换时持有大块内存

### 协程使用
- ICE candidate 收集在独立协程中
- DTLS 握手在独立协程中
- 每个媒体流使用独立协程
- 数据通道使用独立协程

### 性能优化
- RTP/SRTP 包处理使用零拷贝技术
- 使用环形缓冲区处理媒体流
- 协程池管理 DTLS 连接
- 缓存常用加密操作结果

### 错误处理
- 所有协议错误使用 Zig error 类型
- 提供详细的错误信息
- 网络错误自动重试机制

## 📚 关键文件引用

### 现有模块复用
- `nets/tcp.zig` - TCP 连接（信令）
- `websocket/` - WebSocket 协议（信令传输）
- `zco.Schedule` - 协程调度器
- `io/` - 异步 IO 基础

### 标准库使用
- `std.crypto` - 加密算法（AES, HMAC, ECDH）
- `std.net` - 网络地址处理
- `std.hash` - 哈希计算
- `std.base64` - Base64 编码/解码

## ⚠️ 预期挑战

1. **DTLS 实现复杂性** - DTLS 握手状态机复杂，需要仔细实现
2. **SCTP over DTLS** - SCTP 协议本身复杂，在 DTLS 上实现更复杂
3. **媒体编解码** - 编解码器实现工作量巨大，可能需要简化版本
4. **浏览器兼容性** - 需要确保生成的 SDP 和 ICE candidates 符合浏览器期望
5. **性能优化** - 实时媒体流对性能要求极高

## 📖 文档要求

- 每个模块提供中文 API 文档
- 复杂的协议实现提供英文行内注释
- README 包含使用示例
- 提供架构设计文档

## 🧪 测试策略

- 每个协议层独立单元测试
- 使用 Wireshark 验证协议包格式
- 与浏览器 WebRTC API 集成测试
- 性能基准测试

## 📊 进度跟踪

### 待完成任务
- [ ] 在 nets 模块中实现 UDP socket 支持（异步读写）
- [ ] 实现 WebSocket 信令服务器，支持 offer/answer/ICE candidate 消息路由
- [ ] 实现 SDP 协议解析器和生成器（RFC 4566）
- [ ] 实现 STUN 协议（RFC 5389），支持 Binding Request/Response
- [ ] 实现 ICE Agent，支持 candidate 收集、优先级计算、connectivity checks
- [ ] 实现 TURN 客户端协议（RFC 5766），支持 relay candidates
- [ ] 实现 DTLS 记录层，支持包的封装和分片
- [ ] 实现 DTLS 握手协议，包括证书处理和密钥交换
- [ ] 实现 DTLS-SRTP 密钥派生机制
- [ ] 实现 SRTP 上下文和加密/解密
- [ ] 实现 RTP 包解析和构建，包括 SSRC 管理和序列号处理
- [ ] 实现 RTCP 协议，支持 SR/RR/SDES/BYE 包
- [ ] 实现 SCTP 关联建立和块处理
- [ ] 实现 SCTP 数据通道封装（RFC 8832）
- [ ] 实现音频编解码器接口和 Opus 编解码器
- [ ] 实现视频编解码器接口和 VP8 基础解码器
- [ ] 实现 MediaStreamTrack 抽象和音频/视频轨道管理
- [ ] 实现 RTCPeerConnection，整合所有组件
- [ ] 实现 RTCRtpTransceiver 和会话管理
- [ ] 创建完整的音视频通话示例应用

### 已完成任务
_暂无_

## 📝 更新日志

- **2025-01-XX**: 创建初始计划文档

---

**注意**: 这是一个长期项目，预计需要 20-30 周的开发时间。建议分阶段实施，每个阶段完成后进行充分测试和验证。

