const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const peer = @import("./root.zig");

const PeerConnection = peer.PeerConnection;

test "PeerConnection getDataChannels returns all channels" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 模拟 DTLS 握手完成
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
    }

    // 创建多个数据通道
    const channel1 = try pc.createDataChannel("channel-1", null);
    defer channel1.deinit();

    const channel2 = try pc.createDataChannel("channel-2", null);
    defer channel2.deinit();

    const channel3 = try pc.createDataChannel("channel-3", null);
    defer channel3.deinit();

    // 获取所有数据通道
    const channels = pc.getDataChannels();
    try testing.expect(channels.len == 3);

    // 验证所有通道都在列表中
    var found1 = false;
    var found2 = false;
    var found3 = false;
    for (channels) |ch| {
        if (ch == channel1) found1 = true;
        if (ch == channel2) found2 = true;
        if (ch == channel3) found3 = true;
    }
    try testing.expect(found1 and found2 and found3);
}

test "PeerConnection findDataChannel by label" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 模拟 DTLS 握手完成
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
    }

    // 创建数据通道
    const channel = try pc.createDataChannel("my-channel", null);
    defer channel.deinit();

    // 查找数据通道
    const found = pc.findDataChannel("my-channel");
    try testing.expect(found != null);
    try testing.expect(found.? == channel);

    // 查找不存在的通道
    const not_found = pc.findDataChannel("non-existent");
    try testing.expect(not_found == null);
}

test "PeerConnection findDataChannelByStreamId" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 模拟 DTLS 握手完成
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
    }

    // 创建数据通道
    const channel = try pc.createDataChannel("test-channel", null);
    defer channel.deinit();

    // 查找数据通道（第一个通道应该是 stream_id = 0）
    const found = pc.findDataChannelByStreamId(0);
    try testing.expect(found != null);
    try testing.expect(found.? == channel);
    try testing.expect(found.?.stream_id == 0);

    // 查找不存在的 stream_id
    const not_found = pc.findDataChannelByStreamId(999);
    try testing.expect(not_found == null);
}

test "PeerConnection Stream ID auto-increment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 模拟 DTLS 握手完成
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
    }

    // 创建多个数据通道，验证 Stream ID 自动递增
    const channel1 = try pc.createDataChannel("channel-1", null);
    defer channel1.deinit();
    try testing.expect(channel1.stream_id == 0);

    const channel2 = try pc.createDataChannel("channel-2", null);
    defer channel2.deinit();
    try testing.expect(channel2.stream_id == 1);

    const channel3 = try pc.createDataChannel("channel-3", null);
    defer channel3.deinit();
    try testing.expect(channel3.stream_id == 2);

    // 验证所有通道都有唯一的 Stream ID
    try testing.expect(channel1.stream_id != channel2.stream_id);
    try testing.expect(channel2.stream_id != channel3.stream_id);
    try testing.expect(channel1.stream_id != channel3.stream_id);
}

test "PeerConnection removeDataChannel" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 模拟 DTLS 握手完成
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
    }

    // 创建数据通道
    const channel = try pc.createDataChannel("test-channel", null);

    // 验证通道已添加
    try testing.expect(pc.getDataChannels().len == 1);

    // 移除数据通道
    try pc.removeDataChannel(channel);

    // 验证通道已移除
    try testing.expect(pc.getDataChannels().len == 0);

    // 尝试移除不存在的通道
    const result = pc.removeDataChannel(channel);
    try testing.expectError(error.ChannelNotFound, result);
}

test "PeerConnection multiple channels with different stream IDs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 模拟 DTLS 握手完成
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
    }

    // 创建 5 个数据通道
    const DataChannel = @import("../sctp/datachannel.zig").DataChannel;
    var channels: [5]*DataChannel = undefined;
    for (&channels, 0..) |*ch, i| {
        var label_buf: [20]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "channel-{}", .{i});
        ch.* = try pc.createDataChannel(label, null);
    }
    defer for (channels) |ch| ch.deinit();

    // 验证所有通道都有唯一的 Stream ID
    var stream_ids: [5]u16 = undefined;
    for (channels, 0..) |ch, i| {
        stream_ids[i] = ch.stream_id;
    }

    // 检查是否有重复的 Stream ID
    for (stream_ids, 0..) |id1, i| {
        for (stream_ids[i + 1..], 0..) |id2, j| {
            try testing.expect(id1 != id2);
            _ = j;
        }
    }

    // 验证 Stream ID 是连续的（0, 1, 2, 3, 4）
    for (stream_ids, 0..) |id, expected| {
        try testing.expect(id == expected);
    }
}
