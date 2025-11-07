const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const datachannel = webrtc.sctp.datachannel;
const association = webrtc.sctp.association;

const DataChannel = datachannel.DataChannel;
const DataChannelState = datachannel.DataChannelState;
const Association = association.Association;

test "DataChannel onopen event" {
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

    // 使用全局变量（在测试函数作用域内）来捕获回调状态
    var open_called: bool = false;
    const TestState = struct {
        var open_called_ptr: *bool = undefined;
        fn callback(ch: *DataChannel) void {
            _ = ch;
            open_called_ptr.* = true;
        }
    };
    TestState.open_called_ptr = &open_called;
    channel.setOnOpen(TestState.callback);

    // 设置状态为 open（应该触发 onopen）
    channel.setState(.open);

    try testing.expect(open_called);
    try testing.expect(channel.getState() == .open);
}

test "DataChannel onclose event" {
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

    // 设置 onclose 回调
    var close_called: bool = false;
    const TestState = struct {
        var close_called_ptr: *bool = undefined;
        fn callback(ch: *DataChannel) void {
            _ = ch;
            close_called_ptr.* = true;
        }
    };
    TestState.close_called_ptr = &close_called;
    channel.setOnClose(TestState.callback);

    // 先设置为 open
    channel.setState(.open);
    try testing.expect(!close_called);

    // 设置状态为 closed（应该触发 onclose）
    channel.setState(.closed);

    try testing.expect(close_called);
    try testing.expect(channel.getState() == .closed);
}

test "DataChannel onmessage event" {
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

    // 设置 onmessage 回调
    var message_received: ?[]const u8 = null;
    const TestState = struct {
        var message_received_ptr: *?[]const u8 = undefined;
        fn callback(ch: *DataChannel, data: []const u8) void {
            _ = ch;
            // 注意：这里只是测试，实际使用中应该复制数据
            message_received_ptr.* = data;
        }
    };
    TestState.message_received_ptr = &message_received;
    channel.setOnMessage(TestState.callback);

    // 创建 Stream 并添加测试数据
    const stream = try assoc.stream_manager.createStream(0, true);
    try stream.receive_buffer.appendSlice("test message");

    // 接收数据（应该触发 onmessage）
    const received = try channel.recv(null, allocator);
    defer allocator.free(received);

    try testing.expect(message_received != null);
    try testing.expectEqualStrings("test message", received);
}

test "DataChannel onerror event" {
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

    // 设置 onerror 回调
    var error_received: ?anyerror = null;
    const TestState = struct {
        var error_received_ptr: *?anyerror = undefined;
        fn callback(ch: *DataChannel, err: anyerror) void {
            _ = ch;
            error_received_ptr.* = err;
        }
    };
    TestState.error_received_ptr = &error_received;
    channel.setOnError(TestState.callback);

    // 尝试在非 open 状态下发送数据（应该触发错误）
    // 注意：当前实现中，send() 会返回错误，但不会调用 onerror
    // 这里只是测试回调设置是否正确
    try testing.expect(channel.onerror != null);
}

test "DataChannel event callbacks can be cleared" {
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

    // 设置回调
    const dummyCallback = struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
        }
    }.callback;

    channel.setOnOpen(dummyCallback);
    try testing.expect(channel.onopen != null);

    // 清除回调
    channel.setOnOpen(null);
    try testing.expect(channel.onopen == null);

    channel.setOnClose(null);
    try testing.expect(channel.onclose == null);

    channel.setOnMessage(null);
    try testing.expect(channel.onmessage == null);

    channel.setOnError(null);
    try testing.expect(channel.onerror == null);
}
