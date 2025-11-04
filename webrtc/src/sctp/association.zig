const std = @import("std");
const chunk = @import("./chunk.zig");
const stream = @import("./stream.zig");

/// SCTP 关联状态
pub const AssociationState = enum {
    closed, // 关闭
    cookie_wait, // 等待 COOKIE-ECHO
    cookie_echoed, // COOKIE-ECHO 已发送
    established, // 已建立
    shutdown_pending, // 关闭中
    shutdown_sent, // SHUTDOWN 已发送
    shutdown_received, // SHUTDOWN 已接收
    shutdown_ack_sent, // SHUTDOWN-ACK 已发送
};

/// SCTP 关联
/// 遵循 RFC 4960 Section 5
pub const Association = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    state: AssociationState,

    // 本地参数
    local_verification_tag: u32,
    local_port: u16,
    local_tsn: u32, // Initial TSN
    local_a_rwnd: u32, // Advertised Receiver Window Credit
    local_outbound_streams: u16,
    local_inbound_streams: u16,

    // 远程参数
    remote_verification_tag: u32,
    remote_port: u16,
    remote_tsn: u32,
    remote_a_rwnd: u32,
    remote_outbound_streams: u16,
    remote_inbound_streams: u16,

    // State Cookie（用于四路握手）
    state_cookie: ?[]u8,

    // 接收缓冲区
    receive_buffer: std.ArrayList(u8),

    // 待发送的 TSN
    next_tsn: u32,
    // 待确认的 TSN
    expected_tsn: u32,

    // 流管理器
    stream_manager: stream.StreamManager,

    /// 初始化 SCTP 关联
    pub fn init(
        allocator: std.mem.Allocator,
        local_port: u16,
    ) !Self {
        // 生成随机的验证标签
        var verification_tag_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&verification_tag_bytes);
        const verification_tag = std.mem.readInt(u32, &verification_tag_bytes, .little);

        // 生成随机的初始 TSN
        var initial_tsn_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&initial_tsn_bytes);
        const initial_tsn = std.mem.readInt(u32, &initial_tsn_bytes, .little);

        return Self{
            .allocator = allocator,
            .state = .closed,
            .local_verification_tag = verification_tag,
            .local_port = local_port,
            .local_tsn = initial_tsn,
            .local_a_rwnd = 65536, // 默认接收窗口大小
            .local_outbound_streams = 10,
            .local_inbound_streams = 10,
            .remote_verification_tag = 0,
            .remote_port = 0,
            .remote_tsn = 0,
            .remote_a_rwnd = 0,
            .remote_outbound_streams = 0,
            .remote_inbound_streams = 0,
            .state_cookie = null,
            .receive_buffer = std.ArrayList(u8).init(allocator),
            .next_tsn = initial_tsn,
            .expected_tsn = 0,
            .stream_manager = try stream.StreamManager.init(allocator),
        };
    }

    /// 释放关联资源
    pub fn deinit(self: *Self) void {
        if (self.state_cookie) |cookie| {
            self.allocator.free(cookie);
        }
        self.receive_buffer.deinit();
        self.stream_manager.deinit();
    }

    /// 创建并发送 INIT 块
    /// 步骤 1：发起方发送 INIT
    pub fn sendInit(self: *Self, allocator: std.mem.Allocator, remote_port: u16) ![]u8 {
        if (self.state != .closed) return error.InvalidState;

        self.remote_port = remote_port;
        self.state = .cookie_wait;

        // 创建 INIT 块
        var init_chunk = chunk.InitChunk{
            .allocator = allocator,
            .flags = 0,
            .length = 20, // 最小 INIT 块长度（无参数）
            .initiate_tag = self.local_verification_tag,
            .a_rwnd = self.local_a_rwnd,
            .outbound_streams = self.local_outbound_streams,
            .inbound_streams = self.local_inbound_streams,
            .initial_tsn = self.local_tsn,
            .parameters = try allocator.alloc(u8, 0),
        };
        errdefer init_chunk.deinit();

        const encoded = try init_chunk.encode(allocator);
        init_chunk.deinit(); // 释放 init_chunk（parameters 已经复制到 encoded）

        return encoded;
    }

    /// 处理接收到的 INIT 块并创建 INIT-ACK
    /// 步骤 2：接收方处理 INIT，发送 INIT-ACK（包含 State Cookie）
    pub fn processInit(self: *Self, allocator: std.mem.Allocator, init_data: []const u8) ![]u8 {
        if (self.state != .closed) return error.InvalidState;

        // 解析 INIT 块
        var init_chunk = try chunk.InitChunk.parse(allocator, init_data);
        defer init_chunk.deinit();

        // 保存远程参数
        self.remote_verification_tag = init_chunk.initiate_tag;
        self.remote_tsn = init_chunk.initial_tsn;
        self.remote_a_rwnd = init_chunk.a_rwnd;
        self.remote_outbound_streams = init_chunk.outbound_streams;
        self.remote_inbound_streams = init_chunk.inbound_streams;

        // 生成 State Cookie（简化实现：包含关联参数）
        const cookie_len = 32; // 简化：固定长度
        const state_cookie = try allocator.alloc(u8, cookie_len);
        errdefer allocator.free(state_cookie);

        // State Cookie 内容：验证标签 + 初始 TSN + 随机数
        @memcpy(state_cookie[0..4], std.mem.asBytes(&self.local_verification_tag));
        @memcpy(state_cookie[4..8], std.mem.asBytes(&self.local_tsn));
        var random_bytes: [24]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        @memcpy(state_cookie[8..], &random_bytes);

        self.state_cookie = state_cookie;
        self.state = .cookie_wait;

        // 创建 INIT-ACK 块
        // INIT-ACK 格式与 INIT 相同，但包含 State Cookie 参数
        var init_ack_chunk = chunk.InitChunk{
            .allocator = allocator,
            .flags = 0,
            .length = @as(u16, @intCast(20 + cookie_len)),
            .initiate_tag = self.local_verification_tag,
            .a_rwnd = self.local_a_rwnd,
            .outbound_streams = self.local_outbound_streams,
            .inbound_streams = self.local_inbound_streams,
            .initial_tsn = self.local_tsn,
            .parameters = try allocator.dupe(u8, state_cookie),
        };
        errdefer init_ack_chunk.deinit();

        // 将块类型改为 INIT-ACK (2)
        const encoded = try init_ack_chunk.encode(allocator);
        init_ack_chunk.deinit(); // 释放 init_ack_chunk（parameters 已经复制到 encoded）
        encoded[0] = 2; // INIT-ACK

        return encoded;
    }

    /// 处理 INIT-ACK 并发送 COOKIE-ECHO
    /// 步骤 3：发起方处理 INIT-ACK，发送 COOKIE-ECHO
    pub fn processInitAck(self: *Self, allocator: std.mem.Allocator, init_ack_data: []const u8) ![]u8 {
        if (self.state != .cookie_wait) return error.InvalidState;

        // 解析 INIT-ACK 块（格式与 INIT 相同）
        var init_ack_chunk = try chunk.InitChunk.parse(allocator, init_ack_data);
        defer init_ack_chunk.deinit();

        // 保存远程参数
        self.remote_verification_tag = init_ack_chunk.initiate_tag;
        self.remote_tsn = init_ack_chunk.initial_tsn;
        self.remote_a_rwnd = init_ack_chunk.a_rwnd;
        self.remote_outbound_streams = init_ack_chunk.outbound_streams;
        self.remote_inbound_streams = init_ack_chunk.inbound_streams;

        // 提取 State Cookie（在 parameters 中）
        if (init_ack_chunk.parameters.len == 0) return error.InvalidStateCookie;

        const cookie = try allocator.dupe(u8, init_ack_chunk.parameters);
        errdefer allocator.free(cookie);
        if (self.state_cookie) |old_cookie| {
            allocator.free(old_cookie);
        }
        self.state_cookie = cookie;

        self.state = .cookie_echoed;

        // 创建 COOKIE-ECHO 块
        const cookie_len = cookie.len;
        // 我们需要创建一个 CookieEchoChunk 来编码
        // 但是 cookie 的所有权在 self.state_cookie 中，我们只是借用它
        // encode 会复制 cookie，所以我们需要创建一个临时 chunk
        const cookie_copy = try allocator.dupe(u8, cookie);
        errdefer allocator.free(cookie_copy);

        var cookie_echo_chunk = chunk.CookieEchoChunk{
            .flags = 0,
            .length = @as(u16, @intCast(4 + cookie_len)),
            .cookie = cookie_copy, // 使用副本
        };
        errdefer cookie_echo_chunk.deinit(allocator);

        // encode 会分配新的内存并复制 cookie
        const encoded = try cookie_echo_chunk.encode(allocator);
        cookie_echo_chunk.deinit(allocator); // 释放 cookie_copy

        return encoded;
    }

    /// 处理 COOKIE-ECHO 并发送 COOKIE-ACK
    /// 步骤 4：接收方处理 COOKIE-ECHO，发送 COOKIE-ACK，关联建立完成
    pub fn processCookieEcho(self: *Self, allocator: std.mem.Allocator, cookie_echo_data: []const u8) ![]u8 {
        if (self.state != .cookie_wait) return error.InvalidState;

        // 解析 COOKIE-ECHO 块
        var cookie_echo_chunk = try chunk.CookieEchoChunk.parse(allocator, cookie_echo_data);
        defer cookie_echo_chunk.deinit(allocator);

        // 验证 State Cookie（简化：只检查是否存在）
        if (cookie_echo_chunk.cookie.len == 0) return error.InvalidStateCookie;

        // TODO: 验证 State Cookie 的有效性和完整性（应该与之前保存的 cookie 比较）
        // 当前简化实现只检查长度

        // 关联建立完成
        self.state = .established;
        self.expected_tsn = self.local_tsn;

        // 创建 COOKIE-ACK 块
        var cookie_ack_chunk = chunk.CookieAckChunk{
            .flags = 0,
            .length = 4,
        };

        return try cookie_ack_chunk.encode(allocator);
    }

    /// 处理 COOKIE-ACK
    /// 发起方收到 COOKIE-ACK，关联建立完成
    pub fn processCookieAck(self: *Self, cookie_ack_data: []const u8) !void {
        if (self.state != .cookie_echoed) return error.InvalidState;

        // 解析 COOKIE-ACK 块
        _ = try chunk.CookieAckChunk.parse(self.allocator, cookie_ack_data);

        // 关联建立完成
        self.state = .established;
        self.expected_tsn = self.remote_tsn;
    }

    /// 获取当前状态
    pub fn getState(self: *const Self) AssociationState {
        return self.state;
    }

    /// 检查关联是否已建立
    pub fn isEstablished(self: *const Self) bool {
        return self.state == .established;
    }

    pub const Error = error{
        InvalidState,
        InvalidStateCookie,
        OutOfMemory,
    };
};
