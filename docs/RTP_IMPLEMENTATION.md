# RTP/RTCP 实现计划

**文档版本**: 1.0  
**创建日期**: 2025年11月  
**项目分支**: `feature/webrtc-implementation`  
**当前状态**: 开始实现

## 📋 概述

RTP（Real-time Transport Protocol）和 RTCP（RTP Control Protocol）是 WebRTC 媒体传输的核心协议。本阶段将实现 RTP/RTCP 包的解析、构建和管理。

## 🎯 实现目标

### RTP 协议实现（RFC 3550）

#### 1. RTP 包头解析和构建

**基本 RTP 头字段**：
- Version (2 bits): RTP 版本，固定为 2
- Padding (1 bit): 填充标志
- Extension (1 bit): 扩展头标志
- CC (4 bits): CSRC 计数
- Marker (1 bit): 标记位（用于视频关键帧）
- Payload Type (7 bits): 载荷类型（0-127）
- Sequence Number (16 bits): 序列号
- Timestamp (32 bits): 时间戳
- SSRC (32 bits): 同步源标识符
- CSRC List (0-15 * 32 bits): 贡献源列表

**扩展头**：
- Profile-Specific Extension Header ID (16 bits)
- Extension Length (16 bits)
- Extension Data (variable)

**实现文件**: `webrtc/src/rtp/packet.zig`

**核心功能**:
- `parse(allocator, data: []const u8) !Packet` - 解析 RTP 包
- `encode(self: *Packet, allocator) ![]u8` - 编码 RTP 包
- `deinit(self: *Packet)` - 释放资源

#### 2. SSRC 管理

**功能**:
- SSRC 冲突检测和处理
- SSRC 生成（32 位随机数）
- SSRC 到媒体的映射

**实现文件**: `webrtc/src/rtp/ssrc.zig`

**核心功能**:
- `generateSsrc() u32` - 生成新的 SSRC
- `SsrcManager` 结构 - 管理多个 SSRC

#### 3. 序列号处理

**功能**:
- 序列号递增（16 位回绕处理）
- 乱序检测
- 丢包统计

**实现**: 在 `Packet` 结构中处理

#### 4. 时间戳处理

**功能**:
- 时间戳生成（基于采样率）
- 时间戳计算（90kHz 用于视频，采样率用于音频）
- RTP 时间到 NTP 时间转换

**实现**: 在 `Packet` 结构中处理

#### 5. Payload Type 映射

**标准 Payload Types**:
- 0: PCMU (G.711 μ-law)
- 8: PCMA (G.711 A-law)
- 96-127: 动态载荷类型（通过 SDP 协商）

**实现**: 在 `Packet` 结构中定义常量

### RTCP 协议实现（RFC 3550）

#### 1. RTCP 包格式

**RTCP 包类型**:
- SR (Sender Report) - 发送端报告
- RR (Receiver Report) - 接收端报告
- SDES (Source Description) - 源描述
- BYE (Goodbye) - 离开通知
- APP (Application-defined) - 应用定义

**RTCP 包通用头**:
- Version (2 bits): RTCP 版本，固定为 2
- Padding (1 bit): 填充标志
- RC (5 bits): Reception Report Count
- PT (8 bits): Packet Type
- Length (16 bits): 包长度（以 32 位字为单位）

#### 2. SR (Sender Report) 包

**字段**:
- SSRC of Sender (32 bits)
- NTP Timestamp (64 bits): NTP 时间戳
- RTP Timestamp (32 bits): RTP 时间戳
- Sender's Packet Count (32 bits): 发送包计数
- Sender's Octet Count (32 bits): 发送字节计数
- Reception Report Blocks (variable): 接收报告块列表

**实现**: `webrtc/src/rtp/rtcp.zig` 中的 `SenderReport` 结构

#### 3. RR (Receiver Report) 包

**字段**:
- SSRC of Receiver (32 bits)
- Reception Report Blocks (variable): 接收报告块列表

**实现**: `webrtc/src/rtp/rtcp.zig` 中的 `ReceiverReport` 结构

#### 4. 接收报告块 (Reception Report Block)

**字段**:
- SSRC (32 bits): 接收报告的 SSRC
- Fraction Lost (8 bits): 丢失比例（0-255，表示百分比）
- Cumulative Packets Lost (24 bits): 累计丢包数
- Extended Highest Sequence Number (32 bits): 扩展最高序列号
- Interarrival Jitter (32 bits): 到达间隔抖动
- Last SR Timestamp (32 bits): 最后一个 SR 的时间戳
- Delay Since Last SR (32 bits): 距离最后一个 SR 的延迟

**实现**: `webrtc/src/rtp/rtcp.zig` 中的 `ReceptionReport` 结构

#### 5. SDES (Source Description) 包

**SDES 项类型**:
- CNAME: 规范名（必填）
- NAME: 用户名
- EMAIL: 电子邮件
- PHONE: 电话号码
- LOC: 位置
- TOOL: 工具名
- NOTE: 注释
- PRIV: 私有扩展

**实现**: `webrtc/src/rtp/rtcp.zig` 中的 `SourceDescription` 结构

#### 6. BYE 包

**字段**:
- SSRC/CSRC List (variable): 离开的源列表
- Reason for Leaving (optional): 可选原因字符串

**实现**: `webrtc/src/rtp/rtcp.zig` 中的 `Bye` 结构

### 统计信息收集

**统计项**:
- 发送/接收包计数
- 发送/接收字节计数
- 丢包统计
- 延迟和抖动
- 往返时间 (RTT)

**实现**: `webrtc/src/rtp/stats.zig`

## 📁 文件结构

```
webrtc/src/rtp/
├── root.zig           # 模块导出
├── packet.zig         # RTP 包解析和构建
├── ssrc.zig           # SSRC 管理
├── rtcp.zig           # RTCP 包处理
└── stats.zig          # 统计信息收集
```

## 🧪 测试计划

### 单元测试

1. **RTP 包测试** (`packet_test.zig`):
   - RTP 包解析（基本头、扩展头、CSRC）
   - RTP 包编码
   - 序列号递增和回绕
   - 时间戳处理

2. **SSRC 管理测试** (`ssrc_test.zig`):
   - SSRC 生成
   - SSRC 冲突检测

3. **RTCP 包测试** (`rtcp_test.zig`):
   - SR 包解析和构建
   - RR 包解析和构建
   - SDES 包解析和构建
   - BYE 包解析和构建
   - RTCP 复合包处理

4. **统计信息测试** (`stats_test.zig`):
   - 发送/接收统计
   - 丢包统计
   - 延迟和抖动计算

## 🔧 实现细节

### RTP 包结构

```zig
pub const Packet = struct {
    allocator: std.mem.Allocator,
    
    // RTP 头字段
    version: u2 = 2,
    padding: bool = false,
    extension: bool = false,
    csrc_count: u4 = 0,
    marker: bool = false,
    payload_type: u7,
    sequence_number: u16,
    timestamp: u32,
    ssrc: u32,
    csrc_list: []u32 = undefined,  // 动态分配
    
    // 扩展头
    extension_profile: ?u16 = null,
    extension_data: []u8 = undefined,  // 动态分配
    
    // 载荷
    payload: []u8,
};
```

### RTCP 包结构

```zig
pub const RtcpPacket = union(enum) {
    sender_report: SenderReport,
    receiver_report: ReceiverReport,
    source_description: SourceDescription,
    bye: Bye,
    app: App,
};
```

## 📝 实现步骤

1. **第一步**: 实现 RTP 包解析和构建
   - 基本头字段解析
   - 扩展头支持
   - CSRC 列表处理

2. **第二步**: 实现 SSRC 管理
   - SSRC 生成函数
   - SSRC 管理器结构

3. **第三步**: 实现 RTCP 包解析
   - RTCP 复合包处理
   - SR/RR/SDES/BYE 包解析

4. **第四步**: 实现 RTCP 包构建
   - SR/RR/SDES/BYE 包构建
   - 复合包构建

5. **第五步**: 实现统计信息收集
   - 发送端统计
   - 接收端统计
   - RTT 计算

6. **第六步**: 编写单元测试
   - 所有模块的完整测试覆盖

## 🔗 参考文档

- RFC 3550: RTP: A Transport Protocol for Real-Time Applications
- RFC 3551: RTP Profile for Audio and Video Conferences with Minimal Control
- RFC 3711: The Secure Real-time Transport Protocol (SRTP)

## ⚠️ 注意事项

1. **字节序**: RTP/RTCP 使用大端序（网络字节序）
2. **对齐**: RTCP 包必须是 32 位对齐的
3. **复合包**: RTCP 包通常是复合包，包含多个 RTCP 包
4. **带宽限制**: RTCP 带宽应控制在 RTP 带宽的 5%
5. **序列号回绕**: 16 位序列号会回绕，需要正确处理

