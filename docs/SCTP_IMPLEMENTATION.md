# SCTP 数据通道实现计划

**文档版本**: 1.0  
**创建日期**: 2025年11月  
**最后更新**: 2025年11月  
**项目分支**: `feature/webrtc-implementation`  
**当前状态**: 待开始

## 📋 概述

SCTP (Stream Control Transmission Protocol) 是 WebRTC 数据通道的传输协议。本阶段将实现 SCTP over DTLS，为 WebRTC 提供可靠的数据通道功能。

## 🛠️ 技术栈

- **语言**: Zig 0.14.0
- **基础**: DTLS（已实现）作为传输层
- **协议**: RFC 4960 (SCTP), RFC 8832 (WebRTC Data Channels)

## 📁 项目结构

```
webrtc/src/sctp/
├── root.zig          # 模块导出
├── association.zig   # SCTP 关联管理
├── chunk.zig         # SCTP 块格式
├── stream.zig        # SCTP 流管理
└── datachannel.zig   # WebRTC 数据通道封装
```

## 🚀 实现阶段

### 1. SCTP 块格式实现 (RFC 4960 Section 3)

#### 1.1 SCTP 公共头
- **字段**:
  - Source Port Number (16 bits)
  - Destination Port Number (16 bits)
  - Verification Tag (32 bits)
  - Checksum (32 bits)

#### 1.2 块格式
- **块类型**:
  - DATA (0): 数据块
  - INIT (1): 初始化块
  - INIT-ACK (2): 初始化确认
  - SACK (3): 选择确认
  - HEARTBEAT (4): 心跳
  - HEARTBEAT-ACK (5): 心跳确认
  - ABORT (6): 中止
  - SHUTDOWN (7): 关闭
  - SHUTDOWN-ACK (8): 关闭确认
  - ERROR (9): 错误
  - COOKIE-ECHO (10): Cookie 回显
  - COOKIE-ACK (11): Cookie 确认
  - ECNE (12): 显式拥塞通知回显
  - CWR (13): 拥塞窗口减少
  - SHUTDOWN-COMPLETE (14): 关闭完成

- **块公共头**:
  - Chunk Type (8 bits)
  - Chunk Flags (8 bits)
  - Chunk Length (16 bits)

- **文件**: `webrtc/src/sctp/chunk.zig`
- **状态**: ⏳ 待开始

### 2. SCTP 关联建立 (RFC 4960 Section 5)

#### 2.1 四路握手
1. **INIT**: 发送方发送初始化块
2. **INIT-ACK**: 接收方回应初始化确认（包含 State Cookie）
3. **COOKIE-ECHO**: 发送方回显 State Cookie
4. **COOKIE-ACK**: 接收方确认，关联建立完成

#### 2.2 关联参数
- 初始序列号 (Initial TSN)
- 接收窗口 (a_rwnd)
- 出站流数量 (OS)
- 入站流数量 (MIS)
- 初始标签 (Verification Tag)
- State Cookie 生成和验证

- **文件**: `webrtc/src/sctp/association.zig`
- **状态**: ⏳ 待开始

### 3. SCTP 流管理 (RFC 4960 Section 6)

#### 3.1 多流支持
- 流标识符 (Stream Identifier)
- 流序列号 (Stream Sequence Number)
- 有序传输 (Ordered)
- 无序传输 (Unordered)

#### 3.2 流控制
- 接收窗口管理
- 拥塞控制（简化实现）
- 重传机制

- **文件**: `webrtc/src/sctp/stream.zig`
- **状态**: ⏳ 待开始

### 4. 数据传输

#### 4.1 DATA 块处理
- 数据分片和重组
- 确认机制（SACK）
- 重传机制
- 流控制

#### 4.2 可靠传输
- TSN (Transmission Sequence Number) 管理
- 选择确认 (Selective Acknowledgment)
- 拥塞控制（简化实现）

- **文件**: 在 `association.zig` 和 `stream.zig` 中实现
- **状态**: ⏳ 待开始

### 5. WebRTC 数据通道封装 (RFC 8832)

#### 5.1 数据通道协议
- **消息类型**:
  - DATA_CHANNEL_OPEN (0x03)
  - DATA_CHANNEL_ACK (0x02)
  - DATA_CHANNEL_OPEN_MESSAGE (0x01)

- **数据通道参数**:
  - Channel Type (0: DATA_CHANNEL_RELIABLE, 1: DATA_CHANNEL_RELIABLE_UNORDERED, 2: DATA_CHANNEL_PARTIAL_RELIABLE_REXMIT, 3: DATA_CHANNEL_PARTIAL_RELIABLE_TIMED)
  - Priority (16 bits)
  - Reliability Parameter (32 bits)
  - Label (可变长度 UTF-8 字符串)
  - Protocol (可变长度 UTF-8 字符串)

#### 5.2 数据通道 API
- `createDataChannel(label, protocol)` - 创建数据通道
- `send(data)` - 发送数据
- `onMessage(callback)` - 接收消息回调
- `close()` - 关闭数据通道

- **文件**: `webrtc/src/sctp/datachannel.zig`
- **状态**: ⏳ 待开始

### 6. SCTP over DTLS

#### 6.1 DTLS 集成
- 使用已实现的 DTLS 记录层
- 将 SCTP 包封装在 DTLS 记录中
- 处理 DTLS 握手完成后的 SCTP 传输

#### 6.2 连接管理
- DTLS 连接建立后启动 SCTP 关联
- 处理 DTLS 连接断开和 SCTP 关闭
- 错误处理和重连机制

- **文件**: 在 `peer/connection.zig` 中集成
- **状态**: ⏳ 待开始

## 🧪 测试策略

- **单元测试**: 对每个 SCTP 块类型进行解析和构建测试
- **协议一致性**: 使用 Wireshark 验证 SCTP 包格式
- **集成测试**: 与 DTLS 集成，测试完整的数据通道流程
- **性能测试**: 评估数据通道的吞吐量和延迟

## 📊 进度跟踪

### 待完成任务
- [ ] 实现 SCTP 公共头和块格式解析/构建
- [ ] 实现 INIT/INIT-ACK/COOKIE-ECHO/COOKIE-ACK 握手
- [ ] 实现 DATA 块和 SACK 确认机制
- [ ] 实现多流支持和有序/无序传输
- [ ] 实现 WebRTC 数据通道协议封装
- [ ] 实现 SCTP over DTLS 集成

### 已完成任务
- 无

## 📚 参考文档

- RFC 4960: Stream Control Transmission Protocol
- RFC 8832: WebRTC Data Channels
- RFC 3758: Stream Control Transmission Protocol (SCTP) Partial Reliability Extension
- RFC 6525: Stream Control Transmission Protocol (SCTP) Stream Reconfiguration

