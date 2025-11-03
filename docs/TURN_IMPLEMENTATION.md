# TURN 协议实现计划

## 📋 概述

TURN (Traversal Using Relays around NAT) 协议实现，用于在复杂 NAT 环境下提供中继候选地址，完成 WebRTC ICE 协议的 NAT 穿透支持。

## 🎯 目标

实现完整的 TURN 客户端，支持：
1. Allocation（中继地址分配）
2. Permission（权限管理）
3. Channel（通道绑定）
4. Data Indication/Send（数据传输）

## 📚 参考文档

- RFC 5766 - Traversal Using Relays around NAT (TURN)
- RFC 5389 - Session Traversal Utilities for NAT (STUN) - TURN 基于 STUN

## 🏗️ 数据结构设计

### TURN 客户端结构

```zig
pub const Turn = struct {
    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    udp: ?*nets.Udp = null,
    
    // TURN 服务器地址
    server_address: std.net.Address,
    username: []const u8,
    password: []const u8,
    
    // Allocation 信息
    allocation: ?Allocation = null,
    
    // 状态
    state: State,
};

pub const State = enum {
    idle,           // 空闲
    allocating,     // 正在分配
    allocated,      // 已分配
    refreshing,     // 正在刷新
    error,          // 错误
};
```

### Allocation 结构

```zig
pub const Allocation = struct {
    relay_address: std.net.Address,      // 中继地址
    relayed_address: std.net.Address,    // 实际中继的地址
    lifetime: u32,                       // 生存时间（秒）
    reservation_token: ?[]const u8 = null, // 预留令牌
};
```

### TURN 消息方法扩展

TURN 扩展了 STUN 的方法类型：
- `Allocate` (0x003) - 分配请求
- `Refresh` (0x004) - 刷新请求
- `Send` (0x006) - 发送指示
- `Data` (0x007) - 数据指示
- `CreatePermission` (0x008) - 创建权限
- `ChannelBind` (0x009) - 通道绑定

### TURN 属性

```zig
pub const AttributeType = enum(u16) {
    // 继承 STUN 属性
    mapped_address = 0x0001,
    username = 0x0006,
    message_integrity = 0x0008,
    // ...
    
    // TURN 特定属性
    channel_number = 0x000C,          // Channel 编号
    lifetime = 0x000D,                // 生存时间
    xor_peer_address = 0x0012,        // XOR 对等地址
    data = 0x0013,                     // 数据
    xor_relayed_address = 0x0016,     // XOR 中继地址
    requested_transport = 0x0019,     // 请求的传输协议
    even_port = 0x0018,               // 偶数端口
    requested_address_family = 0x0017, // 请求的地址族
    dont_fragment = 0x001A,           // 不分片
    reservation_token = 0x0022,       // 预留令牌
};
```

## 🚀 核心功能实现

### 1. Allocation（分配）

```zig
pub fn allocate(self: *Turn) !Allocation {
    // 1. 发送 Allocate 请求
    // 2. 包含 REQUESTED-TRANSPORT (UDP = 17)
    // 3. 处理响应，提取 XOR-RELAYED-ADDRESS
    // 4. 保存 lifetime
}
```

### 2. CreatePermission（创建权限）

```zig
pub fn createPermission(self: *Turn, peer_address: std.net.Address) !void {
    // 1. 发送 CreatePermission 请求
    // 2. 包含 XOR-PEER-ADDRESS
    // 3. 等待成功响应
}
```

### 3. Send（发送数据）

```zig
pub fn send(self: *Turn, data: []const u8, peer_address: std.net.Address) !void {
    // 1. 构建 Send 指示（Indication）
    // 2. 包含 XOR-PEER-ADDRESS 和 DATA
    // 3. 发送到 TURN 服务器
}
```

### 4. 接收 Data Indication

```zig
pub fn recv(self: *Turn, buffer: []u8) !struct { data: []u8, peer: std.net.Address } {
    // 1. 接收 Data Indication
    // 2. 解析 XOR-PEER-ADDRESS 和 DATA
    // 3. 返回数据和对等地址
}
```

### 5. ChannelData（通道数据，可选优化）

```zig
pub fn sendChannelData(self: *Turn, channel_number: u16, data: []const u8) !void {
    // ChannelData 不是 STUN 消息，是单独的格式
    // 格式：0x4000 | channel_number (2 bytes) + length (2 bytes) + data
}
```

## 🔧 实现细节

### TURN 基于 STUN

TURN 是 STUN 的扩展，所以：
1. 复用 STUN 的消息格式和属性编码/解析
2. 扩展消息方法类型
3. 添加 TURN 特定属性

### 认证

TURN 使用与 STUN 相同的认证机制：
- 长期凭证：username:realm:password → MD5 → HMAC-SHA1 key
- MESSAGE-INTEGRITY 属性验证

### 状态管理

- `idle` → `allocating` → `allocated`
- `allocated` → `refreshing` → `allocated`
- 任何状态 → `error`

## 📝 API 设计

```zig
pub fn init(
    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    server_address: std.net.Address,
    username: []const u8,
    password: []const u8,
) !*Turn

pub fn deinit(self: *Self) void

pub fn allocate(self: *Self) !Allocation

pub fn refresh(self: *Self, lifetime: ?u32) !void

pub fn createPermission(self: *Self, peer_address: std.net.Address) !void

pub fn send(self: *Self, data: []const u8, peer_address: std.net.Address) !void

pub fn recv(self: *Self, buffer: []u8) !struct { data: []u8, peer: std.net.Address }
```

## 🧪 测试策略

### 单元测试
1. Allocation 请求/响应
2. Permission 创建
3. Send/Data 指示处理
4. ChannelData 消息（如果实现）

### 集成测试
1. 与真实 TURN 服务器交互
2. 通过 TURN 中继进行端到端通信
3. 与 ICE Agent 集成测试

## ⏱️ 预计实现时间

- **基础实现**: 1-2 周
- **完整测试**: 3-5 天
- **总计**: 2-3 周

## 🎯 下一步行动

1. 创建 `webrtc/src/ice/turn.zig` 文件
2. 扩展 STUN 消息方法类型
3. 实现 TURN 特定属性
4. 实现 Allocation 流程
5. 实现 Permission 和 Send/Data
6. 集成到 ICE Agent
7. 编写单元测试

