# DTLS 协议实现计划

## 📋 概述

DTLS (Datagram Transport Layer Security) 协议实现，用于 WebRTC 的安全传输层。DTLS 是 TLS 的 UDP 版本，提供数据报传输的安全保护。

## 🎯 目标

实现完整的 DTLS 1.2/1.3 协议，支持：
1. DTLS 记录层（RFC 6347）
2. DTLS 握手协议
3. 证书处理和验证
4. DTLS-SRTP 密钥派生

## 📚 参考文档

- RFC 6347 - Datagram Transport Layer Security Version 1.2
- RFC 8446 - The Transport Layer Security (TLS) Protocol Version 1.3
- RFC 5705 - Keying Material Exporters for Transport Layer Security (TLS)
- RFC 5763 - Framework for Establishing a Secure Real-time Transport Protocol (SRTP) Security Context Using Datagram Transport Layer Security (DTLS)

## 🏗️ 实现结构

### 文件结构

```
webrtc/src/dtls/
├── root.zig           # 模块导出
├── record.zig         # DTLS 记录层
├── handshake.zig      # DTLS 握手协议
├── context.zig        # DTLS 上下文管理
├── crypto.zig         # DTLS 加密/解密
└── key_derivation.zig # DTLS-SRTP 密钥派生
```

### 核心组件

#### 1. DTLS 记录层 (record.zig)

```zig
pub const Record = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    udp: ?*nets.Udp = null,
    
    // 记录层状态
    epoch: u16,
    sequence_number: u48,
    read_epoch: u16,
    write_epoch: u16,
    
    // 加密状态
    read_cipher: ?Cipher,
    write_cipher: ?Cipher,
    
    pub const ContentType = enum(u8) {
        change_cipher_spec = 20,
        alert = 21,
        handshake = 22,
        application_data = 23,
    };
    
    pub const ProtocolVersion = enum(u16) {
        dtls_1_0 = 0xfeff,
        dtls_1_2 = 0xfefd,
        dtls_1_3 = 0xfe03,
    };
    
    pub const RecordHeader = struct {
        content_type: ContentType,
        version: ProtocolVersion,
        epoch: u16,
        sequence_number: u48,
        length: u16,
    };
};
```

**功能：**
- DTLS 记录封装和解析
- 分片处理（处理 MTU 限制）
- 重放保护（基于序列号）
- 记录层加密/解密

#### 2. DTLS 握手协议 (handshake.zig)

```zig
pub const Handshake = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    record: *Record,
    
    // 握手状态
    state: HandshakeState,
    flight: Flight,
    
    // 握手参数
    client_random: [32]u8,
    server_random: [32]u8,
    master_secret: [48]u8,
    
    pub const HandshakeState = enum {
        initial,
        client_hello_sent,
        server_hello_received,
        server_certificate_received,
        server_key_exchange_received,
        server_hello_done_received,
        client_key_exchange_sent,
        change_cipher_spec_sent,
        finished_sent,
        handshake_complete,
    };
    
    pub const HandshakeType = enum(u8) {
        hello_request = 0,
        client_hello = 1,
        server_hello = 2,
        hello_verify_request = 3,
        certificate = 11,
        server_key_exchange = 12,
        certificate_request = 13,
        server_hello_done = 14,
        certificate_verify = 15,
        client_key_exchange = 16,
        finished = 20,
    };
};
```

**功能：**
- ClientHello/ServerHello
- Certificate 交换
- KeyExchange (ECDHE)
- CertificateVerify
- Finished 验证
- 握手消息重传机制

#### 3. DTLS 上下文 (context.zig)

```zig
pub const Context = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    record: Record,
    handshake: Handshake,
    
    // 连接信息
    remote_address: ?std.net.Address,
    local_address: ?std.net.Address,
    
    // 证书
    certificate: ?Certificate,
    private_key: ?PrivateKey,
    
    // 状态
    is_connected: bool,
    is_client: bool,
    
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule, is_client: bool) !*Self;
    pub fn deinit(self: *Self) void;
    
    pub fn connect(self: *Self, address: std.net.Address) !void;
    pub fn accept(self: *Self) !void;
    
    pub fn send(self: *Self, data: []const u8) !usize;
    pub fn recv(self: *Self, buffer: []u8) !usize;
};
```

#### 4. DTLS-SRTP 密钥派生 (key_derivation.zig)

```zig
pub const KeyDerivation = struct {
    pub fn deriveSrtpKeys(
        master_secret: [48]u8,
        client_random: [32]u8,
        server_random: [32]u8,
        is_client: bool,
    ) !struct {
        client_master_key: [16]u8,
        server_master_key: [16]u8,
        client_master_salt: [14]u8,
        server_master_salt: [14]u8,
    };
};
```

## 🔧 实现步骤

### 步骤 1: DTLS 记录层实现

1. **记录头结构**
   - 定义 RecordHeader 结构
   - 实现记录编码/解码

2. **分片处理**
   - 处理大于 MTU 的消息
   - 实现分片重组

3. **重放保护**
   - 序列号管理
   - 滑动窗口检测

4. **加密集成**
   - AES-GCM 加密/解密
   - MAC 计算和验证

### 步骤 2: DTLS 握手实现

1. **握手消息**
   - ClientHello 构建
   - ServerHello 解析
   - 证书交换

2. **密钥交换**
   - ECDHE 实现
   - Master Secret 计算

3. **握手状态机**
   - 状态转换
   - 错误处理

4. **重传机制**
   - 握手消息重传
   - 超时处理

### 步骤 3: 证书处理

1. **证书生成**
   - 自签名证书生成
   - 证书序列化

2. **证书验证**
   - 证书链验证
   - 指纹计算

### 步骤 4: DTLS-SRTP 密钥派生

1. **密钥导出函数**
   - PRF (Pseudo-Random Function)
   - 密钥派生标签

2. **Master Key/Salt 导出**
   - Client/Server 密钥分离
   - 长度计算

## 🧪 测试计划

### 单元测试

1. **记录层测试**
   - 记录编码/解码
   - 分片处理
   - 重放保护

2. **握手测试**
   - ClientHello 构建
   - ServerHello 解析
   - 状态转换

3. **密钥派生测试**
   - DTLS-SRTP 密钥导出
   - 密钥值验证

### 集成测试

1. **端到端握手**
   - 完整握手流程
   - 证书交换

2. **数据加密传输**
   - 应用数据加密
   - 解密验证

## 📝 注意事项

1. **DTLS vs TLS 区别**
   - UDP 传输，需要处理丢包和乱序
   - 握手消息可能需要重传
   - 记录层需要显式序列号

2. **性能考虑**
   - 加密/解密性能
   - 内存分配优化
   - 缓存管理

3. **安全性**
   - 随机数生成质量
   - 密钥管理
   - 证书验证严格性

## 🔗 相关模块依赖

- `std.crypto` - 加密算法
- `nets` - UDP 网络层
- `zco` - 协程调度
- `webrtc/src/utils` - 工具函数（指纹计算等）

