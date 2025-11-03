# SRTP Transform 加解密逻辑说明

## 核心原则

**protect() 和 unprotect() 不能使用同一个 transform/上下文**

在真实场景中：
- **发送方**：使用独立的 SRTP 上下文和 Transform，调用 `protect()` 加密
- **接收方**：使用独立的 SRTP 上下文和 Transform，调用 `unprotect()` 解密
- 两者各自维护自己的序列号状态，但初始状态必须一致（通常都是 0）

## protect() 加密流程

### 输入
- RTP 包：`[RTP 头 12 字节] [载荷]`

### 流程步骤

1. **提取序列号**
   - 从 RTP 头字节 2-3（大端序）读取序列号

2. **更新发送方的序列号状态**
   - 调用 `ctx.updateSequence(sequence_number)`
   - 这会更新 `ctx.sequence_number` 和可能的 `ctx.rollover_counter`
   - **注意**：这会修改上下文状态，影响后续包的 IV 生成

3. **生成 IV**
   - 调用 `ctx.generateIV()`
   - IV = f(session_salt, ssrc, index)
   - index = (rollover_counter << 16) | sequence_number

4. **加密载荷**
   - 使用 AES-128-CTR 模式
   - Key = session_key
   - IV = 步骤 3 生成的 IV
   - 输出：加密后的载荷

5. **构建认证数据**
   - `auth_data = RTP 头 + 加密载荷`
   - **注意**：认证数据不包含认证标签本身

6. **生成认证标签**
   - 使用 HMAC-SHA1
   - Key = auth_key
   - Data = auth_data（步骤 5）
   - 输出：10 字节认证标签

7. **构建 SRTP 包**
   - `SRTP 包 = RTP 头 + 加密载荷 + 认证标签`

### 输出
- SRTP 包：`[RTP 头 12 字节] [加密载荷] [认证标签 10 字节]`

## unprotect() 解密流程

### 输入
- SRTP 包：`[RTP 头 12 字节] [加密载荷] [认证标签 10 字节]`

### 流程步骤

1. **解析 SRTP 包**
   - 提取 RTP 头（前 12 字节）
   - 提取加密载荷（中间部分）
   - 提取认证标签（后 10 字节）

2. **提取序列号**
   - 从 RTP 头字节 2-3（大端序）读取序列号

3. **保存当前状态**
   - 保存 `sequence_number`、`rollover_counter`、`replay_window` 状态
   - **目的**：如果认证或重放检查失败，需要恢复状态

4. **更新接收方的序列号状态**
   - 调用 `ctx.updateSequence(sequence_number)`
   - **关键**：接收方需要使用与发送方 protect() 时相同的序列号状态
   - 只要两者的初始序列号状态相同，就会生成相同的 IV
   - 示例：
     - 发送方初始：seq=0, roc=0 → protect(seq=0) → updateSequence(0) → IV
     - 接收方初始：seq=0, roc=0 → unprotect(seq=0) → updateSequence(0) → 相同的 IV

5. **生成 IV**
   - 调用 `ctx.generateIV()`
   - **必须与 protect() 时生成的 IV 相同**

6. **检查重放保护**
   - 调用 `replay_window.checkReplay(sequence_number)`
   - 如果检测到重放，恢复状态并返回 `error.ReplayDetected`
   - **注意**：`checkReplay` 内部会更新重放窗口，如果后续认证失败需要恢复

7. **构建认证数据**
   - `auth_data = RTP 头 + 加密载荷`
   - **必须与 protect() 步骤 5 的 auth_data 相同**

8. **验证认证标签**
   - 使用 `verifyHmacSha1(auth_key, auth_data, auth_tag)`
   - 如果验证失败，恢复状态并返回 `error.AuthenticationFailed`

9. **解密载荷**
   - 使用 AES-128-CTR 模式（与加密相同）
   - Key = session_key
   - IV = 步骤 5 生成的 IV（必须与加密时相同）
   - 输入：加密载荷
   - 输出：解密后的载荷

10. **构建 RTP 包**
    - `RTP 包 = RTP 头 + 解密载荷`

### 输出
- RTP 包：`[RTP 头 12 字节] [载荷]`

## 关键要点

### 1. IV 生成的一致性
- protect() 和 unprotect() 必须生成相同的 IV 才能正确解密
- IV 依赖于序列号状态（sequence_number 和 rollover_counter）
- 因此，发送方和接收方的初始序列号状态必须一致

### 2. 状态管理
- protect() 会修改发送方的序列号状态（用于后续包）
- unprotect() 会修改接收方的序列号状态（用于后续包）
- 如果认证或重放检查失败，需要恢复状态，避免影响后续包的处理

### 3. 认证数据的一致性
- protect() 和 unprotect() 构建的认证数据必须完全相同
- `auth_data = RTP 头 + 加密载荷`
- RTP 头在 protect() 和 unprotect() 时是相同的
- 加密载荷在 protect() 和 unprotect() 时也是相同的（SRTP 包中直接提取）

### 4. 认证与解密的顺序
- 先验证认证标签，再解密
- 这样可以防止无效数据被处理
- 如果认证失败，不会进行解密（节省资源）

### 5. 重放保护
- 重放检查在认证之前进行
- 如果检测到重放，不进行认证和解密
- 重放窗口状态在检查后更新，但如果认证失败需要恢复

## 测试注意事项

在测试中，需要：
1. 创建两个独立的 Context（发送方和接收方）
2. 确保两者的初始序列号状态相同（都是 0）
3. 使用不同的 Transform 实例（一个用于 protect，一个用于 unprotect）

```zig
// 发送方上下文
var sender_ctx = try Context.init(allocator, master_key, master_salt, ssrc);
defer sender_ctx.deinit();
sender_ctx.replay_window.reset();

// 接收方上下文（初始状态与发送方相同）
var receiver_ctx = try Context.init(allocator, master_key, master_salt, ssrc);
defer receiver_ctx.deinit();
receiver_ctx.replay_window.reset();

var sender_transform = Transform.init(sender_ctx);
var receiver_transform = Transform.init(receiver_ctx);

// 使用不同的 transform
const srtp_packet = try sender_transform.protect(rtp_packet, allocator);
const recovered = try receiver_transform.unprotect(srtp_packet, allocator);
```

