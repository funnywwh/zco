# WebRTC DataChannel 浏览器兼容性测试

本文档说明如何使用浏览器兼容性测试来验证 ZCO WebRTC DataChannel 实现与浏览器 WebRTC API 的兼容性。

## 概述

浏览器兼容性测试包括：
- **HTML 测试页面**：使用浏览器原生 WebRTC API (`RTCPeerConnection`, `RTCDataChannel`)
- **Zig 服务器端**：使用 ZCO WebRTC 实现处理浏览器连接
- **WebSocket 信令服务器**：转发 SDP offer/answer 和 ICE candidates

## 文件说明

- `browser_test.html` - 浏览器端测试页面
- `browser_compat_server.zig` - Zig 服务器端程序
- `test_browser_compat.sh` - 测试启动脚本

## 使用方法

### 方法 1: 使用测试脚本（推荐）

```bash
cd webrtc/examples
./test_browser_compat.sh
```

脚本会自动：
1. 构建并启动服务器
2. 显示访问说明

### 方法 2: 手动启动

#### 1. 启动服务器

```bash
cd webrtc
zig build run-browser-compat-server
```

服务器将在 `ws://127.0.0.1:8080` 启动信令服务器。

#### 2. 打开浏览器测试页面

有两种方式：

**方式 A: 直接打开 HTML 文件**
```bash
# 在浏览器中打开
file:///path/to/zco/webrtc/examples/browser_test.html
```

**方式 B: 使用 HTTP 服务器（推荐，避免 CORS 问题）**
```bash
cd webrtc/examples
python3 -m http.server 8000
# 然后访问 http://localhost:8000/browser_test.html
```

#### 3. 在浏览器中测试

1. 点击 **"连接到服务器"** 按钮
2. 等待连接建立（状态显示 "连接: connected"）
3. 点击 **"运行所有测试"** 按钮运行自动化测试
   - 或手动发送消息测试

## 测试项目

### 基础功能测试

- ✅ **DataChannel 打开** - 验证通道成功打开
- ✅ **发送消息** - 验证消息发送功能
- ✅ **接收消息** - 验证消息接收和 Echo 功能

### 高级功能测试

- ✅ **大数据包传输** - 测试 64KB 数据包传输
- ✅ **多消息传输** - 测试连续发送多条消息
- ✅ **状态转换** - 验证通道状态转换（connecting → open → closed）

### 协议兼容性验证

- ✅ **DCEP 消息格式** - 验证 DCEP Open/Ack 消息格式符合 RFC 8832
- ✅ **SCTP 数据包格式** - 验证 SCTP CommonHeader 和 DataChunk 格式
- ✅ **Stream ID 分配** - 验证 Stream ID 分配策略兼容
- ✅ **通道类型** - 验证 reliable、ordered 等通道类型

## 查看日志

### 浏览器端日志

- **浏览器控制台**：按 `F12` 打开开发者工具，查看 Console 标签
- **页面日志**：在测试页面的"日志"区域查看实时日志

### 服务器端日志

查看终端输出，包括：
- 信令服务器状态
- ICE 连接状态
- DTLS 握手状态
- DataChannel 事件
- 消息收发日志

## 预期结果

### 成功指标

1. ✅ WebSocket 连接成功建立
2. ✅ ICE 连接状态变为 `connected`
3. ✅ DataChannel 状态变为 `open`
4. ✅ 可以成功发送和接收消息
5. ✅ Echo 功能正常工作（服务器回显消息）
6. ✅ 所有自动化测试通过

### 失败排查

如果连接失败，检查：

1. **信令服务器未启动**
   - 检查服务器是否在 `ws://127.0.0.1:8080` 运行
   - 查看服务器终端错误日志

2. **ICE 连接失败**
   - 检查防火墙设置
   - 检查网络配置
   - 查看浏览器控制台的 ICE 错误

3. **DataChannel 未打开**
   - 检查 DTLS 握手是否完成
   - 查看服务器日志中的 SCTP 错误
   - 检查 DCEP 消息格式

4. **消息发送失败**
   - 检查 DataChannel 状态是否为 `open`
   - 查看服务器日志中的 SCTP 发送错误
   - 检查 SCTP 数据包格式

## 技术细节

### DCEP 消息格式

遵循 RFC 8832 Section 5：
- `DATA_CHANNEL_OPEN` (0x03) - 通道打开消息
- `DATA_CHANNEL_ACK` (0x02) - 通道确认消息

### SCTP 数据包格式

遵循 RFC 4960：
- CommonHeader: source_port, destination_port, verification_tag, checksum
- DataChunk: stream_id, sequence_number, payload_protocol_id, user_data

### Stream ID 分配

遵循 RFC 8831：
- Stream ID 从 0 开始
- 偶数递增（0, 2, 4, 6, ...）

## 注意事项

1. **浏览器要求**：Chrome/Edge 浏览器（Chromium 内核）
2. **本地测试**：使用 `127.0.0.1` 进行本地测试
3. **CORS 问题**：建议使用 HTTP 服务器而不是直接打开 HTML 文件
4. **端口冲突**：确保 8080 端口未被占用

## 故障排除

### 常见问题

**Q: 连接失败，显示 "Connection Refused"**
A: 检查服务器是否正在运行，端口 8080 是否被占用

**Q: ICE 连接状态一直显示 "checking"**
A: 检查防火墙设置，确保允许 UDP 流量

**Q: DataChannel 状态一直是 "connecting"**
A: 检查 DTLS 握手是否完成，查看服务器日志

**Q: 消息发送失败**
A: 确保 DataChannel 状态为 "open"，检查服务器日志中的错误

## 贡献

如果发现问题或需要改进，请：
1. 记录详细的错误日志
2. 记录浏览器版本和操作系统
3. 记录复现步骤
4. 提交 Issue 或 PR

