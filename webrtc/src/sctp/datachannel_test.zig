const std = @import("std");
const testing = std.testing;
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const datachannel = webrtc.sctp.datachannel;

test "DCEP Open parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 DCEP Open 消息
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // Message Type
    try data.append(0x03);
    // Channel Type
    try data.append(0x00); // Reliable
    // Priority
    try data.appendSlice(&[_]u8{ 0x00, 0x10 }); // 16
    // Reliability Parameter
    try data.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // 0
    // Label Length
    try data.appendSlice(&[_]u8{ 0x00, 0x05 }); // 5
    // Protocol Length
    try data.appendSlice(&[_]u8{ 0x00, 0x04 }); // 4
    // Label
    try data.appendSlice("label");
    // Protocol
    try data.appendSlice("json");

    var dcep_open = try datachannel.DcepOpen.parse(allocator, data.items);
    defer dcep_open.deinit(allocator);

    try testing.expect(dcep_open.message_type == 0x03);
    try testing.expect(dcep_open.channel_type == 0x00);
    try testing.expect(dcep_open.priority == 16);
    try testing.expect(dcep_open.reliability_parameter == 0);
    try testing.expect(dcep_open.label_length == 5);
    try testing.expect(dcep_open.protocol_length == 4);
    try testing.expect(std.mem.eql(u8, dcep_open.label, "label"));
    try testing.expect(std.mem.eql(u8, dcep_open.protocol, "json"));

    // 编码测试
    const encoded = try dcep_open.encode(allocator);
    defer allocator.free(encoded);

    // 验证编码后的数据可以再次解析
    var dcep_open2 = try datachannel.DcepOpen.parse(allocator, encoded);
    defer dcep_open2.deinit(allocator);

    try testing.expect(dcep_open2.message_type == dcep_open.message_type);
    try testing.expect(dcep_open2.channel_type == dcep_open.channel_type);
    try testing.expect(dcep_open2.priority == dcep_open.priority);
    try testing.expect(dcep_open2.reliability_parameter == dcep_open.reliability_parameter);
    try testing.expect(std.mem.eql(u8, dcep_open2.label, dcep_open.label));
    try testing.expect(std.mem.eql(u8, dcep_open2.protocol, dcep_open.protocol));
}

test "DCEP ACK parse and encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 构建 DCEP ACK 消息
    const data: [1]u8 = .{0x02};

    const dcep_ack = try datachannel.DcepAck.parse(allocator, &data);

    try testing.expect(dcep_ack.message_type == 0x02);

    // 编码测试
    const encoded = try dcep_ack.encode(allocator);
    defer allocator.free(encoded);

    try testing.expect(encoded.len == 1);
    try testing.expect(encoded[0] == 0x02);
}

test "DataChannel init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = try datachannel.DataChannel.init(
        allocator,
        1, // stream_id
        "test-channel", // label
        "json", // protocol
        .reliable, // channel_type
        100, // priority
        0, // reliability_parameter
        true, // ordered
    );
    defer channel.deinit();

    try testing.expect(channel.stream_id == 1);
    try testing.expect(std.mem.eql(u8, channel.label, "test-channel"));
    try testing.expect(std.mem.eql(u8, channel.protocol, "json"));
    try testing.expect(channel.channel_type == .reliable);
    try testing.expect(channel.priority == 100);
    try testing.expect(channel.ordered == true);
    try testing.expect(channel.state == .connecting);
}

test "DataChannel createDcepOpen" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = try datachannel.DataChannel.init(
        allocator,
        1,
        "my-channel",
        "binary",
        .reliable,
        50,
        0,
        true,
    );
    defer channel.deinit();

    const dcep_open_data = try channel.createDcepOpen(allocator);
    defer allocator.free(dcep_open_data);

    // 解析验证
    var dcep_open = try datachannel.DcepOpen.parse(allocator, dcep_open_data);
    defer dcep_open.deinit(allocator);

    try testing.expect(dcep_open.message_type == 0x03);
    try testing.expect(dcep_open.channel_type == @intFromEnum(channel.channel_type));
    try testing.expect(dcep_open.priority == channel.priority);
    try testing.expect(std.mem.eql(u8, dcep_open.label, channel.label));
    try testing.expect(std.mem.eql(u8, dcep_open.protocol, channel.protocol));
}

test "DataChannel processDcepOpen" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = try datachannel.DataChannel.init(
        allocator,
        1,
        "initial-label",
        "initial-protocol",
        .reliable,
        100,
        0,
        true,
    );
    defer channel.deinit();

    // 创建 DCEP Open 消息
    var dcep_open = datachannel.DcepOpen{
        .message_type = 0x03,
        .channel_type = @intFromEnum(datachannel.ChannelType.partial_reliable_rexmit),
        .priority = 200,
        .reliability_parameter = 5,
        .label_length = 9, // "new-label" 的长度
        .protocol_length = 4, // "json" 的长度
        .label = try allocator.dupe(u8, "new-label"),
        .protocol = try allocator.dupe(u8, "json"),
    };
    defer dcep_open.deinit(allocator);

    const dcep_open_data = try dcep_open.encode(allocator);
    defer allocator.free(dcep_open_data);

    // 处理 DCEP Open
    const dcep_ack_data = try channel.processDcepOpen(allocator, dcep_open_data);
    defer allocator.free(dcep_ack_data);

    try testing.expect(channel.state == .open);
    try testing.expect(channel.channel_type == .partial_reliable_rexmit);
    try testing.expect(channel.priority == 200);
    try testing.expect(std.mem.eql(u8, channel.label, "new-label"));
    try testing.expect(std.mem.eql(u8, channel.protocol, "json"));

    // 验证返回的是 DCEP ACK
    try testing.expect(dcep_ack_data.len == 1);
    try testing.expect(dcep_ack_data[0] == 0x02);
}

test "DataChannel processDcepAck" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = try datachannel.DataChannel.init(
        allocator,
        1,
        "test-channel",
        "json",
        .reliable,
        100,
        0,
        true,
    );
    defer channel.deinit();

    try testing.expect(channel.state == .connecting);

    // 创建 DCEP ACK 消息
    const dcep_ack_data: [1]u8 = .{0x02};

    try channel.processDcepAck(allocator, &dcep_ack_data);

    try testing.expect(channel.state == .open);
}

test "DataChannel getState and isOpen" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = try datachannel.DataChannel.init(
        allocator,
        1,
        "test",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    try testing.expect(channel.getState() == .connecting);
    try testing.expect(!channel.isOpen());

    // 手动设置状态（在实际使用中通过 processDcepAck）
    channel.state = .open;
    try testing.expect(channel.getState() == .open);
    try testing.expect(channel.isOpen());
}

test "DCEP Open parse invalid message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 数据太短
    const short_data: [1]u8 = .{0x03};

    const result = datachannel.DcepOpen.parse(allocator, &short_data);
    try testing.expectError(error.InvalidDcepMessage, result);
}

test "DCEP Open parse wrong message type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 错误的消息类型
    const wrong_data: [12]u8 = .{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    const result = datachannel.DcepOpen.parse(allocator, &wrong_data);
    try testing.expectError(error.InvalidDcepMessage, result);
}

test "DCEP ACK parse invalid message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 空数据
    const empty_data: [0]u8 = .{};

    const result = datachannel.DcepAck.parse(allocator, &empty_data);
    try testing.expectError(error.InvalidDcepMessage, result);
}

test "DCEP ACK parse wrong message type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 错误的消息类型
    const wrong_data: [1]u8 = .{0x03};

    const result = datachannel.DcepAck.parse(allocator, &wrong_data);
    try testing.expectError(error.InvalidDcepMessage, result);
}

test "DataChannel sendData" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = try datachannel.DataChannel.init(
        allocator,
        1,
        "test",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    const Stream = webrtc.sctp.stream.Stream;
    var sctp_stream = try Stream.init(allocator, 1, true);
    defer sctp_stream.deinit();
    sctp_stream.open();

    const test_data = "Hello, DataChannel!";
    var data_chunk = try channel.sendData(&sctp_stream, allocator, 100, test_data);
    defer data_chunk.deinit(allocator);

    try testing.expect(data_chunk.stream_id == 1);
    try testing.expect(data_chunk.tsn == 100);
    try testing.expect(data_chunk.payload_protocol_id == @intFromEnum(datachannel.DataChannelProtocol.dcep));
    try testing.expect(std.mem.eql(u8, data_chunk.user_data, test_data));
}
