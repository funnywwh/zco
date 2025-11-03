const std = @import("std");
const testing = std.testing;
const Context = @import("./context.zig").Context;
const Transform = @import("./transform.zig").Transform;

/// 创建一个简单的 RTP 包用于测试
fn createRtpPacket(allocator: std.mem.Allocator, ssrc: u32, sequence: u16, payload: []const u8) ![]u8 {
    // RTP 头（12 字节）
    var rtp_header: [12]u8 = undefined;
    rtp_header[0] = 0x80; // Version (2), Padding (0), Extension (0), CC (0)
    rtp_header[1] = 0x60; // Marker (0), Payload Type (96)
    std.mem.writeInt(u16, rtp_header[2..4], sequence, .big); // Sequence Number
    std.mem.writeInt(u32, rtp_header[4..8], 0x12345678, .big); // Timestamp
    std.mem.writeInt(u32, rtp_header[8..12], ssrc, .big); // SSRC

    const packet = try allocator.alloc(u8, 12 + payload.len);
    @memcpy(packet[0..12], &rtp_header);
    @memcpy(packet[12..], payload);

    return packet;
}

test "Transform protect and unprotect" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化上下文
    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);
    const ssrc: u32 = 0x12345678;

    var ctx = try Context.init(allocator, master_key, master_salt, ssrc);
    defer ctx.deinit();

    // 初始化序列号状态（确保 protect() 和 unprotect() 使用相同的初始状态）
    ctx.sequence_number = 0;
    ctx.rollover_counter = 0;
    ctx.replay_window.reset(); // 重置重放窗口

    var transform = Transform.init(ctx);

    // 创建 RTP 包（使用序列号 0，避免重放窗口问题）
    const rtp_payload = "Hello, SRTP!";
    const rtp_packet = try createRtpPacket(allocator, ssrc, 0, rtp_payload);
    defer allocator.free(rtp_packet);

    // 加密（保护）
    const srtp_packet = try transform.protect(rtp_packet, allocator);
    defer allocator.free(srtp_packet);

    // SRTP 包应该比 RTP 包长（包含认证标签）
    try testing.expect(srtp_packet.len > rtp_packet.len);

    // 解密（恢复）
    const recovered_packet = try transform.unprotect(srtp_packet, allocator);
    defer allocator.free(recovered_packet);

    // 验证恢复的 RTP 包
    try testing.expect(recovered_packet.len == rtp_packet.len);
    try testing.expect(std.mem.eql(u8, rtp_packet, recovered_packet));
}

test "Transform protect and unprotect multiple packets" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);
    const ssrc: u32 = 0x12345678;

    var ctx = try Context.init(allocator, master_key, master_salt, ssrc);
    defer ctx.deinit();

    // 初始化序列号状态
    ctx.sequence_number = 0;
    ctx.rollover_counter = 0;
    ctx.replay_window.reset(); // 重置重放窗口

    var transform = Transform.init(ctx);

    // 加密多个包
    const payloads = [_][]const u8{ "Packet 1", "Packet 2", "Packet 3" };

    for (payloads, 0..) |payload, i| {
        const rtp_packet = try createRtpPacket(allocator, ssrc, @as(u16, @intCast(i)), payload);
        defer allocator.free(rtp_packet);

        const srtp_packet = try transform.protect(rtp_packet, allocator);
        defer allocator.free(srtp_packet);

        const recovered = try transform.unprotect(srtp_packet, allocator);
        defer allocator.free(recovered);

        try testing.expect(std.mem.eql(u8, rtp_packet, recovered));
    }
}

test "Transform unprotect replay detected" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);
    const ssrc: u32 = 0x12345678;

    var ctx = try Context.init(allocator, master_key, master_salt, ssrc);
    defer ctx.deinit();

    // 初始化序列号状态
    ctx.sequence_number = 0;
    ctx.rollover_counter = 0;

    var transform = Transform.init(ctx);

    const rtp_packet = try createRtpPacket(allocator, ssrc, 100, "Test");
    defer allocator.free(rtp_packet);

    // 加密并解密一次
    const srtp_packet = try transform.protect(rtp_packet, allocator);
    defer allocator.free(srtp_packet);

    const recovered1 = try transform.unprotect(srtp_packet, allocator);
    defer allocator.free(recovered1);

    // 再次尝试解密相同的包，应该检测为重放
    const result = transform.unprotect(srtp_packet, allocator);
    try testing.expectError(error.ReplayDetected, result);
}

test "Transform unprotect authentication failed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);
    const ssrc: u32 = 0x12345678;

    var ctx = try Context.init(allocator, master_key, master_salt, ssrc);
    defer ctx.deinit();

    // 初始化序列号状态
    ctx.sequence_number = 0;
    ctx.rollover_counter = 0;

    var transform = Transform.init(ctx);

    const rtp_packet = try createRtpPacket(allocator, ssrc, 100, "Test");
    defer allocator.free(rtp_packet);

    const srtp_packet = try transform.protect(rtp_packet, allocator);
    defer allocator.free(srtp_packet);

    // 修改认证标签
    var tampered_packet = try allocator.dupe(u8, srtp_packet);
    defer allocator.free(tampered_packet);

    tampered_packet[tampered_packet.len - 1] ^= 0xFF; // 翻转最后一个字节

    // 应该验证失败
    const result = transform.unprotect(tampered_packet, allocator);
    try testing.expectError(error.AuthenticationFailed, result);
}

test "Transform protect invalid RTP packet" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);

    var ctx = try Context.init(allocator, master_key, master_salt, 0x12345678);
    defer ctx.deinit();

    var transform = Transform.init(ctx);

    // 太短的 RTP 包应该失败
    const short_packet = "short";
    const result = transform.protect(short_packet, allocator);
    try testing.expectError(error.InvalidRtpPacket, result);
}

test "Transform protectRtcp and unprotectRtcp" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);
    const ssrc: u32 = 0x12345678;

    var ctx = try Context.init(allocator, master_key, master_salt, ssrc);
    defer ctx.deinit();

    // 初始化序列号状态
    ctx.sequence_number = 0;
    ctx.rollover_counter = 0;
    ctx.replay_window.reset(); // 重置重放窗口

    var transform = Transform.init(ctx);

    // 创建简单的 RTCP 包（8 字节头 + 载荷）
    var rtcp_packet = try allocator.alloc(u8, 8 + 20);
    defer allocator.free(rtcp_packet);

    // RTCP 头（简化）
    rtcp_packet[0] = 0x81; // Version (2), Padding (0), Reception Report Count (1)
    rtcp_packet[1] = 0xC8; // Packet Type (200 = SR)
    std.mem.writeInt(u16, rtcp_packet[2..4], 6, .big); // Length
    std.mem.writeInt(u32, rtcp_packet[4..8], ssrc, .big); // SSRC

    // 载荷（18 字节）
    const payload = "RTCP payload data";
    @memcpy(rtcp_packet[8 .. 8 + payload.len], payload);

    // 加密（保护）
    const srtcp_packet = try transform.protectRtcp(rtcp_packet, allocator);
    defer allocator.free(srtcp_packet);

    // SRTCP 包应该比 RTCP 包长（包含认证标签和索引）
    try testing.expect(srtcp_packet.len > rtcp_packet.len);

    // 解密（恢复）
    const recovered_packet = try transform.unprotectRtcp(srtcp_packet, allocator);
    defer allocator.free(recovered_packet);

    // 验证恢复的 RTCP 包
    try testing.expect(recovered_packet.len == rtcp_packet.len);
    try testing.expect(std.mem.eql(u8, rtcp_packet, recovered_packet));
}
