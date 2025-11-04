const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const datachannel = @import("./datachannel.zig");
const association = @import("./association.zig");

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
    const channel = try DataChannel.init(
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
    const assoc = try Association.init(allocator, &schedule);
    defer assoc.deinit();

    // 尝试发送数据（状态不是 open）
    const result = channel.send("test data", assoc);
    try testing.expectError(error.ChannelNotOpen, result);
}

test "DataChannel setState and getState" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建数据通道
    const channel = try DataChannel.init(
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

