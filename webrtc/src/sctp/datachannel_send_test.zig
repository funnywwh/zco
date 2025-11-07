const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const datachannel = webrtc.sctp.datachannel;
const association = webrtc.sctp.association;

const DataChannel = datachannel.DataChannel;
const ChannelType = datachannel.ChannelType;
const Association = association.Association;

test "DataChannel send requires open state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建数据通道（状态为 connecting）
    var channel = try DataChannel.init(
        allocator,
        0,
        "test-channel",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    // 创建关联（用于测试）
    var assoc = try Association.init(allocator, 5000);
    defer assoc.deinit();

    // 尝试发送数据（状态不是 open）
    const result = channel.send("test data", &assoc);
    try testing.expectError(error.ChannelNotOpen, result);
}

test "DataChannel send with associated association" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建数据通道
    var channel = try DataChannel.init(
        allocator,
        0,
        "test-channel",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    // 创建关联
    var assoc = try Association.init(allocator, 5000);
    defer assoc.deinit();

    // 设置关联
    channel.setAssociation(&assoc);

    // 设置状态为 open
    channel.setState(.open);

    // 发送数据（不需要传递 association 参数）
    try channel.send("test data", null);
}

test "DataChannel setState and getState" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建数据通道
    var channel = try DataChannel.init(
        allocator,
        0,
        "test-channel",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    // 初始状态应该是 connecting
    try testing.expect(channel.getState() == .connecting);

    // 设置状态为 open
    channel.setState(.open);
    try testing.expect(channel.getState() == .open);

    // 设置状态为 closed
    channel.setState(.closed);
    try testing.expect(channel.getState() == .closed);
}

test "DataChannel setAssociation and getAssociation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建数据通道
    var channel = try DataChannel.init(
        allocator,
        0,
        "test-channel",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    // 初始应该没有关联
    try testing.expect(channel.getAssociation() == null);

    // 创建关联
    var assoc = try Association.init(allocator, 5000);
    defer assoc.deinit();

    // 设置关联
    channel.setAssociation(&assoc);
    try testing.expect(channel.getAssociation() == &assoc);
}

test "DataChannel recv from stream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建数据通道
    var channel = try DataChannel.init(
        allocator,
        0,
        "test-channel",
        "",
        .reliable,
        0,
        0,
        true,
    );
    defer channel.deinit();

    // 创建关联
    var assoc = try Association.init(allocator, 5000);
    defer assoc.deinit();

    // 设置关联
    channel.setAssociation(&assoc);

    // 设置状态为 open
    channel.setState(.open);

    // 创建 Stream 并添加测试数据
    const stream = try assoc.stream_manager.createStream(0, true);
    try stream.receive_buffer.appendSlice("test data");

    // 接收数据
    const received = try channel.recv(null, allocator);
    defer allocator.free(received);

    try testing.expectEqualStrings("test data", received);
}
