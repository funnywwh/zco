# ICE Agent 实现计划

## 📋 概述

ICE Agent 是 WebRTC ICE 协议的核心组件，负责候选地址收集、连接性检查和连接建立。

## 🎯 目标

实现完整的 ICE Agent，支持：
1. Candidate 收集（Host/ServerReflexive/Relay）
2. Candidate Pair 生成和优先级排序
3. Connectivity Checks（STUN Binding Request/Response）
4. ICE 状态机管理（NEW → CHECKING → CONNECTED/FAILED）

## 📁 文件结构

- `webrtc/src/ice/agent.zig` - ICE Agent 主实现

## 🏗️ 数据结构设计

### ICE Agent 结构

```zig
pub const IceAgent = struct {
    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    
    // Candidate 集合
    local_candidates: std.ArrayList(*Candidate),
    remote_candidates: std.ArrayList(*Candidate),
    
    // Candidate Pair
    candidate_pairs: std.ArrayList(CandidatePair),
    
    // 状态
    state: State,
    
    // STUN 配置
    stun_servers: std.ArrayList(StunServer),
    
    // 检查状态
    check_list: std.ArrayList(Check),
    
    // 选中的对
    selected_pair: ?CandidatePair,
    
    // 组件 ID（RTP 通常为 1，RTCP 为 2）
    component_id: u32,
};
```

### ICE 状态枚举

```zig
pub const State = enum {
    new,        // 初始状态
    gathering,  // 收集 Candidate
    checking,   // 进行 Connectivity Checks
    connected,  // 找到可用连接
    completed,  // 所有检查完成
    failed,     // 连接失败
    closed,     // 已关闭
};
```

### Candidate Pair

```zig
pub const CandidatePair = struct {
    local: *Candidate,
    remote: *Candidate,
    priority: u64,
    state: PairState,
    
    const PairState = enum {
        waiting,    // 等待检查
        in_progress, // 正在检查
        succeeded,  // 检查成功
        failed,     // 检查失败
        frozen,     // 被冻结（等待触发）
    };
};
```

### STUN Server

```zig
pub const StunServer = struct {
    address: std.net.Address,
    username: ?[]const u8,
    password: ?[]const u8,
};
```

### Check

```zig
pub const Check = struct {
    pair: CandidatePair,
    stun_transaction_id: [12]u8,
    state: CheckState,
    retry_count: u32,
    timeout_timer: ?*Timer,
    
    const CheckState = enum {
        pending,    // 待发送
        sent,       // 已发送
        received,   // 已收到响应
        timed_out,  // 超时
    };
};
```

## 🚀 核心功能实现

### 1. Candidate 收集

#### Host Candidate 收集
- 遍历本地网络接口
- 为每个接口创建 Host Candidate
- 使用 UDP socket 绑定到本地地址

#### Server Reflexive Candidate 收集
- 向 STUN 服务器发送 Binding Request
- 从响应中获取 XOR-MAPPED-ADDRESS
- 创建 Server Reflexive Candidate

#### Relay Candidate 收集（如果配置了 TURN）
- 向 TURN 服务器请求 Allocation
- 获取 Relay 地址
- 创建 Relay Candidate

### 2. Candidate Pair 生成

根据 RFC 8445 规则：
- 每个本地 Candidate 与每个远程 Candidate 配对
- 计算 Pair 优先级：`priority = (2^32) * MIN(G,d) + (2^1) * MAX(G,d) + (G>d?1:0)`
  - G: 本地 Candidate 优先级
  - d: 远程 Candidate 优先级

### 3. Connectivity Checks

#### Check 发送流程
1. 从 Check List 中选择优先级最高的 Frozen Pair
2. 解冻该 Pair（状态改为 Waiting）
3. 发送 STUN Binding Request
4. 等待响应或超时

#### STUN Binding Request 处理
- 使用已实现的 STUN 协议
- 包含 USERNAME、REALM、NONCE（如果使用认证）
- 包含 MESSAGE-INTEGRITY

#### STUN Binding Response 处理
- 验证 MESSAGE-INTEGRITY
- 提取 XOR-MAPPED-ADDRESS
- 标记 Pair 为 Succeeded

### 4. ICE 状态机

```
NEW
  ↓ (start gathering)
GATHERING
  ↓ (candidates collected)
CHECKING
  ↓ (valid pair found)
CONNECTED
  ↓ (all checks done)
COMPLETED
```

或

```
CHECKING
  ↓ (all checks failed)
FAILED
```

### 5. 事件处理

- `onCandidate` - Candidate 收集完成回调
- `onCandidatePair` - Pair 状态变化回调
- `onStateChange` - ICE 状态变化回调
- `onSelectedPair` - 选中可用 Pair 回调

## 📝 API 设计

### 初始化

```zig
pub fn init(
    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    component_id: u32,
) !*IceAgent
```

### Candidate 收集

```zig
// 开始收集 Host Candidates
pub fn gatherHostCandidates(self: *IceAgent) !void

// 添加 STUN 服务器并收集 Server Reflexive Candidates
pub fn addStunServer(
    self: *IceAgent,
    address: std.net.Address,
    username: ?[]const u8,
    password: ?[]const u8,
) !void

// 收集 Server Reflexive Candidates
pub fn gatherServerReflexiveCandidates(self: *IceAgent) !void
```

### 远程 Candidate 处理

```zig
// 添加远程 Candidate
pub fn addRemoteCandidate(self: *IceAgent, candidate: *Candidate) !void

// 开始 Connectivity Checks
pub fn startConnectivityChecks(self: *IceAgent) !void
```

### 状态查询

```zig
// 获取当前状态
pub fn getState(self: *const IceAgent) State

// 获取选中的 Pair
pub fn getSelectedPair(self: *const IceAgent) ?CandidatePair

// 获取所有本地 Candidates
pub fn getLocalCandidates(self: *const IceAgent) []const *Candidate
```

## 🧪 测试策略

### 单元测试

1. **Candidate 收集测试**
   - Host Candidate 收集
   - Server Reflexive Candidate 收集（需要 STUN 服务器模拟）

2. **Pair 生成测试**
   - Pair 优先级计算正确性
   - Pair 状态管理

3. **Connectivity Checks 测试**
   - Check 发送和响应处理
   - 超时处理
   - 重试机制

4. **状态机测试**
   - 状态转换正确性
   - 错误场景处理

### 集成测试

1. **端到端连接测试**
   - 两个 ICE Agent 之间的连接建立
   - NAT 穿透测试

2. **性能测试**
   - 大量 Candidate 的处理性能
   - Check 并发处理能力

## 📚 参考文档

- RFC 8445 - Interactive Connectivity Establishment (ICE)
- RFC 5389 - Session Traversal Utilities for NAT (STUN)
- RFC 5766 - Traversal Using Relays around NAT (TURN)

## 🔧 实现注意事项

1. **协程使用**
   - Candidate 收集在独立协程中执行
   - 每个 Connectivity Check 使用独立协程
   - 使用 ZCO 调度器管理异步操作

2. **内存管理**
   - 所有 Candidate 和 Pair 使用 allocator 分配
   - 确保正确释放资源（使用 defer）

3. **错误处理**
   - 网络错误使用重试机制
   - STUN 请求失败不应导致整个 Agent 失败

4. **性能优化**
   - Candidate Pair 按优先级排序（使用堆或有序列表）
   - 限制并发 Check 数量（避免过载）
   - 使用定时器管理超时

## ⏱️ 预计实现时间

- **基础实现**: 2-3 周
- **完整测试**: 1 周
- **总计**: 3-4 周

## 🎯 下一步行动

1. 创建 `webrtc/src/ice/agent.zig` 文件
2. 实现基础数据结构
3. 实现 Host Candidate 收集
4. 实现 Candidate Pair 生成
5. 实现 Connectivity Checks
6. 实现状态机
7. 编写单元测试

