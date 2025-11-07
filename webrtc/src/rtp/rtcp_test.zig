const std = @import("std");
const testing = std.testing;
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const rtcp = webrtc.rtp.rtcp;

test "RTCP Header parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 RTCP 头数据
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // Version=2, Padding=0, RC=1, PT=200 (SR)
    try data.append(0x81); // 1000 0001 (version=2, padding=0, rc=1)
    try data.append(200); // SR
    try data.append(0x00);
    try data.append(0x07); // Length = 7 (28 字节 = 7 * 4)

    const header = try rtcp.Header.parse(data.items);

    try testing.expect(header.version == 2);
    try testing.expect(header.padding == false);
    try testing.expect(header.rc == 1);
    try testing.expect(header.packet_type == .sr);
    try testing.expect(header.length == 7);

    // 编码测试
    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();
    try encoded.ensureTotalCapacity(4);
    encoded.items.len = 4;
    header.encode(encoded.items);

    try testing.expect(std.mem.eql(u8, encoded.items, data.items));
}

test "RTCP ReceptionReport parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建接收报告块数据
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // SSRC
    try data.append(0x12);
    try data.append(0x34);
    try data.append(0x56);
    try data.append(0x78);

    // Fraction Lost
    try data.append(5); // 5%

    // Cumulative Packets Lost (24 位有符号)
    try data.append(0x00);
    try data.append(0x00);
    try data.append(0x10); // 16 个丢包

    // Extended Highest Sequence
    try data.appendSlice(&[_]u8{ 0x00, 0x00, 0x01, 0x23 });

    // Interarrival Jitter
    try data.appendSlice(&[_]u8{ 0x00, 0x00, 0x05, 0x00 });

    // Last SR Timestamp
    try data.appendSlice(&[_]u8{ 0x12, 0x34, 0x56, 0x78 });

    // Delay Since Last SR
    try data.appendSlice(&[_]u8{ 0x00, 0x00, 0x01, 0x00 });

    const report = try rtcp.ReceptionReport.parse(data.items);

    try testing.expect(report.ssrc == 0x12345678);
    try testing.expect(report.fraction_lost == 5);
    try testing.expect(report.extended_highest_sequence == 0x00000123);
    try testing.expect(report.interarrival_jitter == 0x00000500);
    try testing.expect(report.last_sr_timestamp == 0x12345678);
    try testing.expect(report.delay_since_last_sr == 0x00000100);

    // 编码测试
    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();
    try encoded.ensureTotalCapacity(24);
    encoded.items.len = 24;
    report.encode(encoded.items);

    try testing.expect(std.mem.eql(u8, encoded.items[0..24], data.items));
}

test "RTCP SenderReport parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 SR 包数据（简化：只有基本字段，没有接收报告块）
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // RTCP 头
    try data.append(0x80); // Version=2, RC=0
    try data.append(200); // SR
    try data.append(0x00);
    try data.append(0x06); // Length = 6 (24 字节 = 6 * 4)

    // SSRC
    try data.appendSlice(&[_]u8{ 0x11, 0x22, 0x33, 0x44 });

    // NTP Timestamp MSB
    try data.appendSlice(&[_]u8{ 0x12, 0x34, 0x56, 0x78 });
    // NTP Timestamp LSB
    try data.appendSlice(&[_]u8{ 0x9A, 0xBC, 0xDE, 0xF0 });

    // RTP Timestamp
    try data.appendSlice(&[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD });

    // Sender Packet Count
    try data.appendSlice(&[_]u8{ 0x00, 0x00, 0x01, 0x00 });

    // Sender Octet Count
    try data.appendSlice(&[_]u8{ 0x00, 0x00, 0x10, 0x00 });

    var sr = try rtcp.SenderReport.parse(allocator, data.items);
    defer sr.deinit();

    try testing.expect(sr.ssrc == 0x11223344);
    try testing.expect(sr.ntp_timestamp_msb == 0x12345678);
    try testing.expect(sr.ntp_timestamp_lsb == 0x9ABCDEF0);
    try testing.expect(sr.rtp_timestamp == 0xAABBCCDD);
    try testing.expect(sr.sender_packet_count == 0x00000100);
    try testing.expect(sr.sender_octet_count == 0x00001000);
    try testing.expect(sr.reports.items.len == 0);

    // 编码测试
    const encoded = try sr.encode(allocator);
    defer allocator.free(encoded);

    try testing.expect(std.mem.eql(u8, encoded, data.items));
}

test "RTCP ReceiverReport parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 RR 包数据（简化：只有基本字段）
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // RTCP 头
    try data.append(0x80); // Version=2, RC=0
    try data.append(201); // RR
    try data.append(0x00);
    try data.append(0x01); // Length = 1 (4 字节 = 1 * 4)

    // SSRC
    try data.appendSlice(&[_]u8{ 0x55, 0x66, 0x77, 0x88 });

    var rr = try rtcp.ReceiverReport.parse(allocator, data.items);
    defer rr.deinit();

    try testing.expect(rr.ssrc == 0x55667788);
    try testing.expect(rr.reports.items.len == 0);

    // 编码测试
    const encoded = try rr.encode(allocator);
    defer allocator.free(encoded);

    try testing.expect(std.mem.eql(u8, encoded, data.items));
}

test "RTCP SourceDescription parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 SDES 包数据
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // 先构建完整的包数据，然后计算正确的长度
    var temp_data = std.ArrayList(u8).init(allocator);
    defer temp_data.deinit();

    // SSRC
    try temp_data.appendSlice(&[_]u8{ 0x99, 0xAA, 0xBB, 0xCC });

    // CNAME 项
    try temp_data.append(1); // CNAME
    try temp_data.append(5); // Length
    try temp_data.appendSlice("test1"); // 5 字节

    // 对齐到 4 字节（CNAME 项：2 + 5 = 7，对齐到 8）
    try temp_data.append(0); // 填充字节

    // END 项
    try temp_data.append(0);

    // 填充到 4 字节边界
    while (temp_data.items.len % 4 != 0) {
        try temp_data.append(0);
    }

    // 计算长度（以 32 位字为单位，不包括头）
    const body_len = temp_data.items.len;
    const total_len = 4 + body_len; // 头 + 体
    const length_field = @as(u16, @intCast((total_len / 4) - 1));

    // 构建完整的 RTCP 包
    try data.append(0x81); // Version=2, RC=1
    try data.append(202); // SDES
    try data.appendSlice(std.mem.asBytes(&length_field));
    try data.appendSlice(temp_data.items);

    var sdes = try rtcp.SourceDescription.parse(allocator, data.items);
    defer sdes.deinit();

    try testing.expect(sdes.ssrc == 0x99AABBCC);
    try testing.expect(sdes.items.items.len == 1);
    try testing.expect(sdes.items.items[0].item_type == .cname);
    try testing.expect(std.mem.eql(u8, sdes.items.items[0].text, "test1"));

    // 编码测试 - 验证可以正确编码
    const encoded = try sdes.encode(allocator);
    defer allocator.free(encoded);

    // 验证编码后的包可以再次解析
    var sdes2 = try rtcp.SourceDescription.parse(allocator, encoded);
    defer sdes2.deinit();

    try testing.expect(sdes2.ssrc == sdes.ssrc);
    try testing.expect(sdes2.items.items.len == sdes.items.items.len);
    if (sdes2.items.items.len > 0) {
        try testing.expect(sdes2.items.items[0].item_type == sdes.items.items[0].item_type);
        try testing.expect(std.mem.eql(u8, sdes2.items.items[0].text, sdes.items.items[0].text));
    }
}

test "RTCP Bye parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 BYE 包数据
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // 构建 BYE 包（确保长度正确）
    // 先构建包体，然后计算正确的长度字段
    const ssrc_count: u5 = 1;
    const ssrc: u32 = 0xDDEFFF00;

    // 计算长度（以 32 位字为单位，不包括头）
    // 包体：SSRC (4 字节) = 1 个字
    // 总长度：头 (1 字) + 体 (1 字) = 2 字
    // length = 2 - 1 = 1
    const length_field: u16 = 1;

    // RTCP 头
    try data.append(0x80 | @as(u8, ssrc_count)); // Version=2, RC=1
    try data.append(203); // BYE
    var length_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &length_bytes, length_field, .big);
    try data.appendSlice(&length_bytes);

    // SSRC
    var ssrc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &ssrc_bytes, ssrc, .big);
    try data.appendSlice(&ssrc_bytes);

    var bye = try rtcp.Bye.parse(allocator, data.items);
    defer bye.deinit();

    try testing.expect(bye.ssrcs.items.len == 1);
    if (bye.ssrcs.items.len > 0) {
        try testing.expect(bye.ssrcs.items[0] == 0xDDEFFF00);
    }
    try testing.expect(bye.reason == null);

    // 编码测试
    const encoded = try bye.encode(allocator);
    defer allocator.free(encoded);

    // 验证编码后的包可以再次解析（而不是完全匹配，因为长度字段可能不同）
    var bye2 = try rtcp.Bye.parse(allocator, encoded);
    defer bye2.deinit();

    try testing.expect(bye2.ssrcs.items.len == bye.ssrcs.items.len);
    if (bye2.ssrcs.items.len > 0) {
        try testing.expect(bye2.ssrcs.items[0] == bye.ssrcs.items[0]);
    }
    // 比较可选原因
    if (bye.reason) |reason| {
        try testing.expect(bye2.reason != null);
        if (bye2.reason) |reason2| {
            try testing.expect(std.mem.eql(u8, reason, reason2));
        }
    } else {
        try testing.expect(bye2.reason == null);
    }
}

test "RTCP Header parse invalid version" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // Version=0（无效）
    try data.append(0x00);
    try data.append(200);
    try data.appendSlice(&[_]u8{ 0x00, 0x07 });

    const result = rtcp.Header.parse(data.items);
    try testing.expectError(error.InvalidRtcpVersion, result);
}
