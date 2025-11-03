const std = @import("std");
const crypto = std.crypto;
const replay = @import("./replay.zig");
const srtp_crypto = @import("./crypto.zig");

/// SRTP 上下文
/// 管理 SRTP 会话的密钥和状态
pub const Context = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    // Master Key 和 Salt（从 DTLS 派生）
    master_key: [16]u8, // 128-bit master key
    master_salt: [14]u8, // 112-bit master salt

    // 派生的会话密钥（用于加密）
    session_key: [16]u8, // AES-128 会话密钥
    session_salt: [14]u8, // 会话 Salt

    // 派生的认证密钥（用于 HMAC）
    auth_key: []u8, // HMAC-SHA1 认证密钥（动态分配）

    // SSRC 和 Rollover Counter
    ssrc: u32,
    rollover_counter: u32,

    // 序列号（16-bit，用于计算完整索引）
    sequence_number: u16,

    // 重放保护窗口
    replay_window: replay.ReplayWindow,

    /// 初始化 SRTP 上下文
    pub fn init(
        allocator: std.mem.Allocator,
        master_key: [16]u8,
        master_salt: [14]u8,
        ssrc: u32,
    ) !*Self {
        const ctx = try allocator.create(Self);
        errdefer allocator.destroy(ctx);

        ctx.* = .{
            .allocator = allocator,
            .master_key = master_key,
            .master_salt = master_salt,
            .session_key = undefined,
            .session_salt = undefined,
            .auth_key = undefined,
            .ssrc = ssrc,
            .rollover_counter = 0,
            .sequence_number = 0,
            .replay_window = replay.ReplayWindow{},
        };

        // 派生会话密钥和认证密钥
        try ctx.deriveSessionKeys();

        return ctx;
    }

    /// 清理 SRTP 上下文
    pub fn deinit(self: *Self) void {
        if (self.auth_key.len > 0) {
            self.allocator.free(self.auth_key);
        }
        self.allocator.destroy(self);
    }

    /// 派生会话密钥和认证密钥
    /// 遵循 RFC 3711 Section 4.3
    fn deriveSessionKeys(self: *Self) !void {
        // 派生会话密钥（用于加密）
        // Key = PRF(master_key, "SRTP encryption key" || label || index)
        try Self.deriveKey(
            self.master_key,
            self.master_salt,
            "SRTP encryption key",
            &self.session_key,
        );

        // 派生会话 Salt（用于 IV 生成）
        try Self.deriveKey(
            self.master_key,
            self.master_salt,
            "SRTP salt",
            &self.session_salt,
        );

        // 派生认证密钥（用于 HMAC）
        // 简化：HMAC-SHA1 需要 20 字节密钥（SRTP 使用更长的密钥，这里简化）
        self.auth_key = try self.allocator.alloc(u8, 20);
        try Self.deriveKey(
            self.master_key,
            self.master_salt,
            "SRTP authentication key",
            self.auth_key[0..20],
        );
    }

    /// 派生密钥（简化实现）
    /// 使用 HMAC-SHA256 作为 PRF
    fn deriveKey(
        master_key: [16]u8,
        master_salt: [14]u8,
        label: []const u8,
        output: []u8,
    ) !void {
        // 构建 PRF 输入：label || master_salt
        var prf_input = std.ArrayList(u8).init(std.heap.page_allocator);
        defer prf_input.deinit();

        try prf_input.appendSlice(label);
        try prf_input.appendSlice(&master_salt);

        // 使用 HMAC-SHA256 作为 PRF
        const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
        var hmac_output: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&hmac_output, prf_input.items, &master_key);

        // 复制输出（可能需要截断或扩展）
        const copy_len = @min(output.len, hmac_output.len);
        @memcpy(output[0..copy_len], hmac_output[0..copy_len]);

        // 如果输出需要更多字节，使用迭代
        if (output.len > copy_len) {
            var remaining = output[copy_len..];
            var counter: u32 = 1;

            while (remaining.len > 0) {
                var counter_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &counter_bytes, counter, .big);

                var iter_input = std.ArrayList(u8).init(std.heap.page_allocator);
                defer iter_input.deinit();

                try iter_input.appendSlice(&hmac_output);
                try iter_input.appendSlice(&counter_bytes);

                var iter_output: [HmacSha256.mac_length]u8 = undefined;
                HmacSha256.create(&iter_output, iter_input.items, &master_key);

                const copy_len_iter = @min(remaining.len, iter_output.len);
                @memcpy(remaining[0..copy_len_iter], iter_output[0..copy_len_iter]);

                remaining = remaining[copy_len_iter..];
                counter += 1;
            }
        }
    }

    /// 计算完整的 SRTP 索引
    /// 索引 = (Rollover Counter << 16) | Sequence Number
    pub fn computeIndex(self: *const Self) u48 {
        return (@as(u48, self.rollover_counter) << 16) | @as(u48, self.sequence_number);
    }

    /// 更新序列号（处理 rollover）
    pub fn updateSequence(self: *Self, sequence: u16) void {
        // 检查序列号是否回绕
        if (sequence < self.sequence_number and
            @as(i32, sequence) -% @as(i32, self.sequence_number) < -32768)
        {
            // 序列号回绕，增加 rollover counter
            self.rollover_counter += 1;
        }
        self.sequence_number = sequence;
    }

    /// 生成加密 IV
    pub fn generateIV(self: *const Self) [16]u8 {
        const index = self.computeIndex();
        return srtp_crypto.Crypto.generateIV(self.session_salt, self.ssrc, index);
    }

    pub const Error = error{
        OutOfMemory,
    };
};
