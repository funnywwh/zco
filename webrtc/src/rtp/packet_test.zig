const std = @import("std");
const testing = std.testing;
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const packet = webrtc.rtp.packet;

test "RTP Packet parse basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建一个基本的 RTP 包（12 字节头 + 载荷）
    var rtp_data = std.ArrayList(u8).init(allocator);
    defer rtp_data.deinit();

    // 第一个字节：version=2, padding=0, extension=0, csrc_count=0
    try rtp_data.append(0x80); // 1000 0000
    // 第二个字节：marker=0, payload_type=96
    try rtp_data.append(0x60); // 0110 0000 (payload_type=96)
    // 序列号：0x1234
    try rtp_data.append(0x12);
    try rtp_data.append(0x34);
    // 时间戳：0x12345678
    try rtp_data.append(0x12);
    try rtp_data.append(0x34);
    try rtp_data.append(0x56);
    try rtp_data.append(0x78);
    // SSRC：0xABCDEF01
    try rtp_data.append(0xAB);
    try rtp_data.append(0xCD);
    try rtp_data.append(0xEF);
    try rtp_data.append(0x01);
    // 载荷："Hello"
    try rtp_data.appendSlice("Hello");

    var parsed = try packet.Packet.parse(allocator, rtp_data.items);
    defer parsed.deinit();
    defer allocator.free(parsed.payload);

    try testing.expect(parsed.version == 2);
    try testing.expect(parsed.payload_type == 96);
    try testing.expect(parsed.sequence_number == 0x1234);
    try testing.expect(parsed.timestamp == 0x12345678);
    try testing.expect(parsed.ssrc == 0xABCDEF01);
    try testing.expect(std.mem.eql(u8, parsed.payload, "Hello"));
}

test "RTP Packet parse with CSRC" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rtp_data = std.ArrayList(u8).init(allocator);
    defer rtp_data.deinit();

    // 第一个字节：version=2, padding=0, extension=0, csrc_count=2
    try rtp_data.append(0x82); // 1000 0010
    // 第二个字节：marker=0, payload_type=0
    try rtp_data.append(0x00);
    // 序列号：0
    try rtp_data.appendSlice(&[_]u8{ 0x00, 0x00 });
    // 时间戳：0
    try rtp_data.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    // SSRC：0x11111111
    try rtp_data.appendSlice(&[_]u8{ 0x11, 0x11, 0x11, 0x11 });
    // CSRC 1：0x22222222
    try rtp_data.appendSlice(&[_]u8{ 0x22, 0x22, 0x22, 0x22 });
    // CSRC 2：0x33333333
    try rtp_data.appendSlice(&[_]u8{ 0x33, 0x33, 0x33, 0x33 });
    // 载荷："Test"
    try rtp_data.appendSlice("Test");

    var parsed = try packet.Packet.parse(allocator, rtp_data.items);
    defer parsed.deinit();
    defer allocator.free(parsed.payload);

    try testing.expect(parsed.csrc_count == 2);
    try testing.expect(parsed.csrc_list.items.len == 2);
    try testing.expect(parsed.csrc_list.items[0] == 0x22222222);
    try testing.expect(parsed.csrc_list.items[1] == 0x33333333);
}

test "RTP Packet encode basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pkt = packet.Packet{
        .allocator = allocator,
        .version = 2,
        .padding = false,
        .extension = false,
        .csrc_count = 0,
        .marker = false,
        .payload_type = 96,
        .sequence_number = 0x1234,
        .timestamp = 0x12345678,
        .ssrc = 0xABCDEF01,
        .csrc_list = std.ArrayList(u32).init(allocator),
        .extension_profile = null,
        .extension_data = undefined,
        .payload = try allocator.dupe(u8, "Hello"),
    };
    defer pkt.deinit();
    defer allocator.free(pkt.payload);

    const encoded = try pkt.encode();
    defer allocator.free(encoded);

    try testing.expect(encoded.len == 12 + 5); // 12 字节头 + 5 字节载荷
    try testing.expect(encoded[0] == 0x80); // version=2, 其他位为0
    try testing.expect(encoded[1] == 0x60); // payload_type=96
    try testing.expect(encoded[2] == 0x12);
    try testing.expect(encoded[3] == 0x34);
    try testing.expect(std.mem.eql(u8, encoded[12..], "Hello"));
}

test "RTP Packet round-trip parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建原始包
    var original = packet.Packet{
        .allocator = allocator,
        .version = 2,
        .padding = false,
        .extension = false,
        .csrc_count = 0,
        .marker = true, // 设置 marker
        .payload_type = 111,
        .sequence_number = 54321,
        .timestamp = 1234567890,
        .ssrc = 987654321,
        .csrc_list = std.ArrayList(u32).init(allocator),
        .extension_profile = null,
        .extension_data = undefined,
        .payload = try allocator.dupe(u8, "Round-trip test"),
    };
    defer original.deinit();
    defer allocator.free(original.payload);

    // 编码
    const encoded = try original.encode();
    defer allocator.free(encoded);

    // 解析
    var parsed = try packet.Packet.parse(allocator, encoded);
    defer parsed.deinit();
    defer allocator.free(parsed.payload);

    // 验证所有字段
    try testing.expect(parsed.version == original.version);
    try testing.expect(parsed.padding == original.padding);
    try testing.expect(parsed.extension == original.extension);
    try testing.expect(parsed.csrc_count == original.csrc_count);
    try testing.expect(parsed.marker == original.marker);
    try testing.expect(parsed.payload_type == original.payload_type);
    try testing.expect(parsed.sequence_number == original.sequence_number);
    try testing.expect(parsed.timestamp == original.timestamp);
    try testing.expect(parsed.ssrc == original.ssrc);
    try testing.expect(std.mem.eql(u8, parsed.payload, original.payload));
}

test "RTP Packet nextSequenceNumber wrap around" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pkt = packet.Packet{
        .allocator = allocator,
        .payload_type = 96,
        .sequence_number = 0xFFFF, // 最大值
        .timestamp = 0,
        .ssrc = 0,
        .csrc_list = std.ArrayList(u32).init(allocator),
        .payload = try allocator.dupe(u8, "test"),
    };
    defer pkt.deinit();
    defer allocator.free(pkt.payload);

    const next = pkt.nextSequenceNumber();
    try testing.expect(next == 0); // 应该回绕到 0
}

test "RTP Packet parse invalid version" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建无效版本的 RTP 包（version=0）
    var invalid_data = std.ArrayList(u8).init(allocator);
    defer invalid_data.deinit();

    try invalid_data.append(0x00); // version=0
    try invalid_data.append(0x60);
    try invalid_data.appendSlice(&[_]u8{0} ** 10);

    const result = packet.Packet.parse(allocator, invalid_data.items);
    try testing.expectError(error.InvalidRtpVersion, result);
}

test "RTP Packet parse too short" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 数据太短（小于 12 字节）
    const short_data = "short";

    const result = packet.Packet.parse(allocator, short_data);
    try testing.expectError(error.InvalidRtpPacket, result);
}
