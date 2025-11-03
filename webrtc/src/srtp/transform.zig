const std = @import("std");
const context = @import("./context.zig");
const srtp_crypto = @import("./crypto.zig");

/// SRTP/SRTCP 包转换器
/// 负责 SRTP 包的加密/解密和 SRTCP 包的加密/解密
pub const Transform = struct {
    const Self = @This();

    ctx: *context.Context,

    /// 初始化转换器
    pub fn init(ctx: *context.Context) Self {
        return .{
            .ctx = ctx,
        };
    }

    /// 加密 SRTP 包（保护 RTP 包）
    /// 遵循 RFC 3711 Section 3
    ///
    /// 流程：
    /// 1. 提取 RTP 包中的序列号
    /// 2. 更新发送方的序列号状态（用于生成 IV）
    /// 3. 生成 IV（基于序列号和 rollover counter）
    /// 4. 使用 IV 加密 RTP 载荷（AES-128-CTR）
    /// 5. 构建认证数据（RTP 头 + 加密载荷）
    /// 6. 生成认证标签（HMAC-SHA1）
    /// 7. 构建 SRTP 包（RTP 头 + 加密载荷 + 认证标签）
    pub fn protect(self: *Self, rtp_packet: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // SRTP 包格式：[RTP 头 12 字节] [加密载荷] [认证标签 10 字节]

        if (rtp_packet.len < 12) return error.InvalidRtpPacket;

        const rtp_header = rtp_packet[0..12];
        const rtp_payload = rtp_packet[12..];

        // 步骤 1: 提取序列号（RTP 头字节 2-3，大端序）
        const sequence_number = std.mem.readInt(u16, rtp_header[2..4], .big);

        // 步骤 2: 更新发送方的序列号状态（用于生成 IV）
        // 注意：这会修改上下文状态，用于后续包的 IV 生成
        self.ctx.updateSequence(sequence_number);

        // 步骤 3: 生成 IV（基于当前的序列号和 rollover counter）
        const iv = self.ctx.generateIV();

        // 步骤 4: 加密载荷（AES-128-CTR，流密码模式）
        const encrypted_payload = try srtp_crypto.Crypto.aes128Ctr(
            self.ctx.session_key,
            iv,
            rtp_payload,
            allocator,
        );
        defer allocator.free(encrypted_payload);

        // 步骤 5: 构建认证数据（RTP 头 + 加密载荷）
        // 注意：认证数据不包含认证标签本身
        var auth_data = std.ArrayList(u8).init(allocator);
        defer auth_data.deinit();
        try auth_data.appendSlice(rtp_header);
        try auth_data.appendSlice(encrypted_payload);

        // 步骤 6: 生成认证标签（HMAC-SHA1，SRTP 使用前 10 字节）
        const auth_tag_full = try srtp_crypto.Crypto.hmacSha1(
            self.ctx.auth_key,
            auth_data.items,
            allocator,
        );
        defer allocator.free(auth_tag_full);

        // SRTP 使用 10 字节认证标签（RFC 3711 Section 4.2）
        const auth_tag = auth_tag_full[0..10];

        // 步骤 7: 构建 SRTP 包
        const srtp_packet = try allocator.alloc(u8, rtp_header.len + encrypted_payload.len + 10);
        @memcpy(srtp_packet[0..rtp_header.len], rtp_header);
        @memcpy(srtp_packet[rtp_header.len .. rtp_header.len + encrypted_payload.len], encrypted_payload);
        @memcpy(srtp_packet[rtp_header.len + encrypted_payload.len ..], auth_tag[0..10]);

        return srtp_packet;
    }

    /// 解密 SRTP 包（恢复 RTP 包）
    /// 遵循 RFC 3711 Section 3
    ///
    /// 流程：
    /// 1. 解析 SRTP 包（RTP 头、加密载荷、认证标签）
    /// 2. 提取序列号
    /// 3. 保存当前状态（用于失败时恢复）
    /// 4. 更新接收方的序列号状态（用于生成与发送方相同的 IV）
    /// 5. 生成 IV（应该与 protect() 时相同）
    /// 6. 检查重放保护
    /// 7. 构建认证数据并验证认证标签
    /// 8. 解密载荷（AES-128-CTR）
    /// 9. 构建并返回 RTP 包
    ///
    /// 注意：protect() 和 unprotect() 使用不同的上下文（发送方和接收方）
    /// 但为了生成相同的 IV，它们需要使用相同的序列号状态
    /// 发送方和接收方的初始序列号状态必须一致（通常都是 0）
    pub fn unprotect(self: *Self, srtp_packet: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // SRTP 包格式：[RTP 头 12 字节] [加密载荷] [认证标签 10 字节]

        if (srtp_packet.len < 12 + 10) return error.InvalidSrtpPacket;

        // 步骤 1: 解析 SRTP 包
        const rtp_header = srtp_packet[0..12];
        const auth_tag_len = 10;
        const encrypted_payload_len = srtp_packet.len - 12 - auth_tag_len;
        const encrypted_payload = srtp_packet[12 .. 12 + encrypted_payload_len];
        const auth_tag = srtp_packet[srtp_packet.len - auth_tag_len ..];

        // 步骤 2: 提取序列号
        const sequence_number = std.mem.readInt(u16, rtp_header[2..4], .big);

        // 步骤 3: 保存当前状态（用于认证失败时恢复）
        const saved_sequence = self.ctx.sequence_number;
        const saved_roc = self.ctx.rollover_counter;
        const saved_replay_last = self.ctx.replay_window.last_sequence;
        const saved_replay_bitmap = self.ctx.replay_window.bitmap;

        // 步骤 4: 更新序列号以生成正确的 IV
        // 关键：接收方需要使用与发送方 protect() 时相同的序列号状态
        // - 发送方在 protect() 时：updateSequence(seq) -> generateIV()
        // - 接收方在 unprotect() 时：也需要 updateSequence(seq) -> generateIV()
        // 只要两者的初始序列号状态相同，就会生成相同的 IV
        self.ctx.updateSequence(sequence_number);

        // 步骤 5: 生成 IV（应该与 protect() 时相同）
        const iv = self.ctx.generateIV();

        // 步骤 6: 检查重放保护（在认证前）
        // 注意：checkReplay 内部会调用 update，所以如果认证失败需要恢复状态
        if (self.ctx.replay_window.checkReplay(sequence_number)) {
            // 重放检测失败，恢复状态
            self.ctx.sequence_number = saved_sequence;
            self.ctx.rollover_counter = saved_roc;
            self.ctx.replay_window.last_sequence = saved_replay_last;
            self.ctx.replay_window.bitmap = saved_replay_bitmap;
            return error.ReplayDetected;
        }

        // 步骤 7: 构建认证数据（与 protect() 一致：RTP 头 + 加密载荷）
        var auth_data = std.ArrayList(u8).init(allocator);
        defer auth_data.deinit();
        try auth_data.appendSlice(rtp_header);
        try auth_data.appendSlice(encrypted_payload);

        // 步骤 8: 验证认证标签
        if (!srtp_crypto.Crypto.verifyHmacSha1(
            self.ctx.auth_key,
            auth_data.items,
            auth_tag,
        )) {
            // 认证失败，恢复状态
            self.ctx.sequence_number = saved_sequence;
            self.ctx.rollover_counter = saved_roc;
            self.ctx.replay_window.last_sequence = saved_replay_last;
            self.ctx.replay_window.bitmap = saved_replay_bitmap;
            return error.AuthenticationFailed;
        }

        // 步骤 9: 解密载荷（AES-128-CTR，与加密相同）
        const decrypted_payload = try srtp_crypto.Crypto.aes128CtrDecrypt(
            self.ctx.session_key,
            iv,
            encrypted_payload,
            allocator,
        );
        errdefer allocator.free(decrypted_payload);

        // 步骤 10: 构建 RTP 包（RTP 头 + 解密载荷）
        const rtp_packet = try allocator.alloc(u8, rtp_header.len + decrypted_payload.len);
        @memcpy(rtp_packet[0..rtp_header.len], rtp_header);
        @memcpy(rtp_packet[rtp_header.len..], decrypted_payload);

        // 注意：认证和重放检查通过后，状态已经更新（序列号和重放窗口）
        return rtp_packet;
    }

    /// 加密 SRTCP 包（保护 RTCP 包）
    /// 遵循 RFC 3711 Section 3.4
    pub fn protectRtcp(self: *Self, rtcp_packet: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // SRTCP 包格式：
        // [RTCP 头] [加密载荷] [认证标签] [索引 (32-bit)]

        if (rtcp_packet.len < 8) return error.InvalidRtcpPacket;

        // RTCP 包通常以 RTCP 头开始
        // 简化：假设前 8 字节是 RTCP 头
        const rtcp_header = rtcp_packet[0..8];
        const rtcp_payload = rtcp_packet[8..];

        // 获取索引（使用当前的 rollover_counter 和序列号）
        const index = self.ctx.computeIndex();

        // 生成 IV（SRTCP 使用不同的 Salt 派生，这里简化使用相同的）
        const iv = self.ctx.generateIV();

        // 加密载荷
        const encrypted_payload = try srtp_crypto.Crypto.aes128Ctr(
            self.ctx.session_key,
            iv,
            rtcp_payload,
            allocator,
        );
        defer allocator.free(encrypted_payload);

        // 构建认证数据：RTCP 头 + 加密载荷 + 索引
        var auth_data = std.ArrayList(u8).init(allocator);
        defer auth_data.deinit();

        try auth_data.appendSlice(rtcp_header);
        try auth_data.appendSlice(encrypted_payload);

        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, @as(u32, @truncate(index)), .big);
        try auth_data.appendSlice(&index_bytes);

        // 生成认证标签
        const auth_tag = try srtp_crypto.Crypto.hmacSha1(
            self.ctx.auth_key,
            auth_data.items,
            allocator,
        );
        defer allocator.free(auth_tag);

        // 构建 SRTCP 包：RTCP 头 + 加密载荷 + 认证标签 + 索引
        const srtcp_packet = try allocator.alloc(
            u8,
            rtcp_header.len + encrypted_payload.len + 10 + 4,
        );

        @memcpy(srtcp_packet[0..rtcp_header.len], rtcp_header);
        @memcpy(srtcp_packet[rtcp_header.len .. rtcp_header.len + encrypted_payload.len], encrypted_payload);
        @memcpy(srtcp_packet[rtcp_header.len + encrypted_payload.len .. rtcp_header.len + encrypted_payload.len + 10], auth_tag[0..10]);
        @memcpy(srtcp_packet[rtcp_header.len + encrypted_payload.len + 10 ..], &index_bytes);

        return srtcp_packet;
    }

    /// 解密 SRTCP 包（恢复 RTCP 包）
    pub fn unprotectRtcp(self: *Self, srtcp_packet: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // SRTCP 包格式：
        // [RTCP 头] [加密载荷] [认证标签 (10 字节)] [索引 (4 字节)]

        if (srtcp_packet.len < 8 + 10 + 4) return error.InvalidSrtcpPacket;

        const rtcp_header = srtcp_packet[0..8];
        const auth_tag_len = 10;
        const index_len = 4;
        const encrypted_payload_len = srtcp_packet.len - 8 - auth_tag_len - index_len;
        const encrypted_payload = srtcp_packet[8 .. 8 + encrypted_payload_len];
        const auth_tag = srtcp_packet[8 + encrypted_payload_len .. 8 + encrypted_payload_len + auth_tag_len];
        const index_bytes_slice = srtcp_packet[srtcp_packet.len - index_len ..];
        const index_bytes_array: *const [4]u8 = index_bytes_slice[0..4];
        const index_bytes: []const u8 = index_bytes_array;

        // 提取索引
        const index = std.mem.readInt(u32, index_bytes_array, .big);

        // 构建认证数据
        var auth_data = std.ArrayList(u8).init(allocator);
        defer auth_data.deinit();

        try auth_data.appendSlice(rtcp_header);
        try auth_data.appendSlice(encrypted_payload);
        try auth_data.appendSlice(index_bytes);

        // 验证认证标签
        if (!srtp_crypto.Crypto.verifyHmacSha1(
            self.ctx.auth_key,
            auth_data.items,
            auth_tag,
        )) {
            return error.AuthenticationFailed;
        }

        // 生成 IV（使用索引）
        // 简化：从索引恢复 rollover_counter 和 sequence_number
        self.ctx.rollover_counter = @as(u32, @truncate(index >> 16));
        self.ctx.sequence_number = @as(u16, @truncate(index));

        const iv = self.ctx.generateIV();

        // 解密载荷
        const decrypted_payload = try srtp_crypto.Crypto.aes128CtrDecrypt(
            self.ctx.session_key,
            iv,
            encrypted_payload,
            allocator,
        );
        errdefer allocator.free(decrypted_payload);

        // 构建 RTCP 包：RTCP 头 + 解密载荷
        const rtcp_packet = try allocator.alloc(u8, rtcp_header.len + decrypted_payload.len);

        @memcpy(rtcp_packet[0..rtcp_header.len], rtcp_header);
        @memcpy(rtcp_packet[rtcp_header.len..], decrypted_payload);

        return rtcp_packet;
    }

    pub const Error = error{
        InvalidRtpPacket,
        InvalidSrtpPacket,
        InvalidRtcpPacket,
        InvalidSrtcpPacket,
        ReplayDetected,
        AuthenticationFailed,
        OutOfMemory,
    };
};
