# SRTP 协议实现计划

## 📋 概述

SRTP (Secure Real-time Transport Protocol) 协议实现，用于 WebRTC 媒体流的安全传输。SRTP 在 RTP 协议基础上添加了加密、认证和重放保护功能。

## 🎯 目标

实现完整的 SRTP 协议，支持：
1. SRTP 上下文初始化（使用 DTLS 派生的密钥）
2. SRTP 包加密/解密（AES-128-GCM）
3. SRTCP 包加密/解密
4. 重放保护（Replay Protection）
5. 认证标签验证（HMAC-SHA1）

## 📚 参考文档

- RFC 3711 - The Secure Real-time Transport Protocol (SRTP)
- RFC 5763 - Framework for Establishing a Secure Real-time Transport Protocol (SRTP) Security Context Using Datagram Transport Layer Security (DTLS)
- RFC 5764 - DTLS Extension to Establish Keys for the Secure Real-time Transport Protocol (SRTP)
- RFC 6188 - The Use of AES-128 Encryption and AES-128 CM in Secure Real-time Transport Protocol (SRTP)

## 🏗️ 实现结构

### 文件结构

```
webrtc/src/srtp/
├── root.zig           # 模块导出
├── context.zig        # SRTP 上下文管理
├── transform.zig      # SRTP/SRTCP 包转换（加密/解密）
├── crypto.zig         # SRTP 加密算法
└── replay.zig         # 重放保护
```

### 核心组件

#### 1. SRTP 上下文 (context.zig)

```zig
pub const Context = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    
    // Master Key 和 Salt（从 DTLS 派生）
    master_key: [16]u8,      // 128-bit master key
    master_salt: [14]u8,     // 112-bit master salt
    
    // 派生的会话密钥
    session_key: [16]u8,     // AES-128 会话密钥
    session_salt: [14]u8,    // 会话 Salt
    
    // SSRC 和 Rollover Counter
    ssrc: u32,
    rollover_counter: u32,
    
    // 重放保护窗口
    replay_window: ReplayWindow,
    
    // 加密算法参数
    cipher: Cipher,
    
    pub fn init(
        allocator: std.mem.Allocator,
        master_key: [16]u8,
        master_salt: [14]u8,
        ssrc: u32,
    ) !*Self;
    
    pub fn deinit(self: *Self) void;
    
    // 从 Master Key/Salt 派生会话密钥
    pub fn deriveSessionKey(self: *Self, label: []const u8) !void;
};
```

**功能：**
- SRTP 上下文初始化
- Master Key/Salt 管理
- 会话密钥派生（使用 PRF）
- SSRC 和 Rollover Counter 管理

#### 2. SRTP 转换 (transform.zig)

```zig
pub const Transform = struct {
    const Self = @This();
    
    context: *Context,
    
    /// 加密 SRTP 包
    pub fn protect(self: *Self, rtp_packet: []const u8, allocator: std.mem.Allocator) ![]u8;
    
    /// 解密 SRTP 包
    pub fn unprotect(self: *Self, srtp_packet: []const u8, allocator: std.mem.Allocator) ![]u8;
    
    /// 加密 SRTCP 包
    pub fn protectRtcp(self: *Self, rtcp_packet: []const u8, allocator: std.mem.Allocator) ![]u8;
    
    /// 解密 SRTCP 包
    pub fn unprotectRtcp(self: *Self, srtcp_packet: []const u8, allocator: std.mem.Allocator) ![]u8;
};
```

**功能：**
- SRTP 包加密/解密
- SRTCP 包加密/解密
- 认证标签添加/验证
- 序列号处理

#### 3. SRTP 加密算法 (crypto.zig)

```zig
pub const Crypto = struct {
    /// AES-128-CM（Counter Mode）加密
    pub fn aes128CmEncrypt(
        key: [16]u8,
        iv: [16]u8,
        plaintext: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8;
    
    /// AES-128-CM 解密
    pub fn aes128CmDecrypt(
        key: [16]u8,
        iv: [16]u8,
        ciphertext: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8;
    
    /// HMAC-SHA1 认证标签生成
    pub fn hmacSha1(
        key: []const u8,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8;
    
    /// 生成加密 IV（Initialization Vector）
    pub fn generateIV(
        session_salt: [14]u8,
        ssrc: u32,
        index: u48,
    ) [16]u8;
};
```

**功能：**
- AES-128-CM（Counter Mode）加密/解密
- HMAC-SHA1 认证标签生成/验证
- IV 生成（基于 SSRC、索引和 Salt）

#### 4. 重放保护 (replay.zig)

```zig
pub const ReplayWindow = struct {
    const Self = @This();
    
    bitmap: u64 = 0,           // 64-bit 滑动窗口位图
    last_sequence: u16 = 0,    // 最后接收的序列号
    
    /// 检查序列号是否重放
    pub fn check(self: *Self, sequence: u16) bool;
    
    /// 更新重放窗口
    pub fn update(self: *Self, sequence: u16) void;
};
```

**功能：**
- 滑动窗口重放检测
- 序列号验证

## 🔧 实现步骤

### 步骤 1: SRTP 上下文实现

1. **上下文结构定义**
   - Master Key/Salt 存储
   - SSRC 和 Rollover Counter 管理

2. **会话密钥派生**
   - 使用 PRF（Pseudo-Random Function）
   - 基于 Master Key、Master Salt 和标签
   - 派生 AES-128 密钥和 HMAC 密钥

3. **上下文初始化**
   - 从 DTLS Key Derivation 获取 Master Key/Salt
   - 初始化加密参数

### 步骤 2: SRTP 包加密/解密

1. **SRTP 包格式**
   ```
   SRTP 包 = RTP 头 + 加密载荷 + 认证标签（可选的 MKI）
   ```

2. **加密流程**
   - 提取 RTP 头信息（SSRC、序列号、时间戳）
   - 计算 IV（使用 SSRC、索引、Salt）
   - 使用 AES-128-CM 加密载荷
   - 生成认证标签（HMAC-SHA1）
   - 组装 SRTP 包

3. **解密流程**
   - 解析 SRTP 包
   - 验证认证标签
   - 计算 IV
   - 使用 AES-128-CM 解密载荷
   - 验证重放保护
   - 返回 RTP 包

### 步骤 3: SRTCP 包加密/解密

1. **SRTCP 包格式**
   ```
   SRTCP 包 = RTCP 头 + 加密载荷 + 认证标签 + 索引（32-bit）
   ```

2. **加密/解密流程**
   - 类似 SRTP，但使用 SRTCP 密钥派生
   - 索引字段处理
   - RTCP 包的认证

### 步骤 4: 重放保护

1. **滑动窗口实现**
   - 64-bit 位图
   - 序列号验证逻辑
   - Rollover Counter 处理

2. **序列号检查**
   - 计算完整的序列号（考虑 Rollover Counter）
   - 检查是否在窗口内
   - 更新窗口

## 🧪 测试计划

### 单元测试

1. **上下文测试**
   - 上下文初始化
   - 会话密钥派生
   - Master Key/Salt 存储

2. **加密/解密测试**
   - SRTP 包加密/解密往返
   - SRTCP 包加密/解密往返
   - 认证标签验证
   - 错误的认证标签检测

3. **重放保护测试**
   - 重放检测
   - 滑动窗口更新
   - Rollover Counter 处理

### 集成测试

1. **DTLS-SRTP 集成**
   - 使用 DTLS 派生的密钥初始化 SRTP
   - 端到端加密/解密流程

2. **与 RTP 集成**
   - SRTP 保护的 RTP 包传输
   - 接收和解密验证

## 📝 注意事项

1. **密钥派生**
   - 使用 RFC 3711 规定的 PRF
   - Master Key/Salt 从 DTLS Key Derivation 获取
   - 客户端和服务器使用不同的密钥

2. **索引计算**
   - SRTP 索引 = (Rollover Counter << 16) | Sequence Number
   - 用于 IV 生成和密钥派生

3. **性能考虑**
   - 加密/解密性能
   - 内存分配优化
   - 零拷贝技术（如果可能）

4. **安全性**
   - 正确的 IV 生成
   - 认证标签验证严格性
   - 重放保护的及时性

## 🔗 相关模块依赖

- `webrtc/src/dtls/key_derivation` - DTLS-SRTP 密钥派生
- `std.crypto` - AES-128-CM、HMAC-SHA1
- `webrtc/src/rtp` - RTP 包格式（后续实现）

## 📊 实现进度

- [ ] SRTP 上下文实现
- [ ] 会话密钥派生
- [ ] SRTP 包加密/解密
- [ ] SRTCP 包加密/解密
- [ ] 重放保护
- [ ] 单元测试
- [ ] 集成测试

