const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const peer = @import("./root.zig");

const PeerConnection = peer.PeerConnection;

test "PeerConnection createDataChannel without DTLS handshake returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 尝试创建数据通道（DTLS 握手未完成）
    const result = pc.createDataChannel("test-channel", null);
    try testing.expectError(error.DtlsHandshakeNotComplete, result);
}

test "PeerConnection createDataChannel with default options" {
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

    // 创建数据通道（使用默认选项）
    const channel = try pc.createDataChannel("test-channel", null);
    defer channel.deinit();

    // 验证数据通道已创建
    try testing.expect(channel != null);
}

test "PeerConnection createDataChannel with custom options" {
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

    // 创建数据通道（使用自定义选项）
    const options = PeerConnection.DataChannelOptions{
        .ordered = false,
        .max_retransmits = 5,
        .protocol = "json",
    };

    const channel = try pc.createDataChannel("custom-channel", options);
    defer channel.deinit();

    // 验证数据通道已创建
    try testing.expect(channel != null);
}
