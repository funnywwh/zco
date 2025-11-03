const std = @import("std");
const testing = std.testing;
const stream = @import("./stream.zig");
const chunk = @import("./chunk.zig");

test "SCTP Stream init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 1, true); // stream_id=1, ordered=true
    defer s.deinit();

    try testing.expect(s.stream_id == 1);
    try testing.expect(s.ordered == true);
    try testing.expect(s.state == .idle);
    try testing.expect(s.next_sequence == 0);
    try testing.expect(s.expected_sequence == 0);
}

test "SCTP Stream open and close" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 1, true);
    defer s.deinit();

    try testing.expect(s.state == .idle);
    try testing.expect(!s.isOpen());

    s.open();
    try testing.expect(s.state == .open);
    try testing.expect(s.isOpen());

    s.close();
    try testing.expect(s.state == .closing);
    try testing.expect(!s.isOpen());
}

test "SCTP Stream createDataChunk ordered" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 1, true); // ordered
    defer s.deinit();
    s.open();

    const test_data = "Hello, SCTP!";
    var data_chunk = try s.createDataChunk(allocator, 100, 51, test_data, true, true);
    defer data_chunk.deinit(allocator);

    try testing.expect(data_chunk.stream_id == 1);
    try testing.expect(data_chunk.tsn == 100);
    try testing.expect(data_chunk.stream_sequence == 0); // 第一个序列号
    try testing.expect(data_chunk.payload_protocol_id == 51);
    try testing.expect(std.mem.eql(u8, data_chunk.user_data, test_data));

    // 检查标志位：有序传输，B=1, E=1
    try testing.expect((data_chunk.flags & 0x04) == 0); // U flag = 0 (ordered)
    try testing.expect((data_chunk.flags & 0x02) != 0); // B flag = 1
    try testing.expect((data_chunk.flags & 0x01) != 0); // E flag = 1

    // 序列号应该已更新
    try testing.expect(s.next_sequence == 1);
}

test "SCTP Stream createDataChunk unordered" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 2, false); // unordered
    defer s.deinit();
    s.open();

    const test_data = "Unordered data";
    var data_chunk = try s.createDataChunk(allocator, 200, 52, test_data, false, false);
    defer data_chunk.deinit(allocator);

    try testing.expect(data_chunk.stream_id == 2);
    try testing.expect((data_chunk.flags & 0x04) != 0); // U flag = 1 (unordered)

    // 无序传输不更新序列号
    try testing.expect(s.next_sequence == 0);
}

test "SCTP Stream processDataChunk ordered" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 1, true); // ordered
    defer s.deinit();
    s.open();

    // 手动创建 DATA 块（序列号 = 0，匹配 expected_sequence）
    const test_data = "Ordered message";
    const user_data = try allocator.alloc(u8, test_data.len);
    @memcpy(user_data, test_data);

    var data_chunk = chunk.DataChunk{
        .flags = 0x03, // B=1, E=1, U=0 (ordered)
        .length = @as(u16, @intCast(16 + test_data.len)),
        .tsn = 100,
        .stream_id = 1,
        .stream_sequence = 0, // 匹配 expected_sequence
        .payload_protocol_id = 51,
        .user_data = user_data, // user_data 的所有权转移到 data_chunk
    };
    defer data_chunk.deinit(allocator); // 这会释放 user_data

    // 处理 DATA 块（序列号应该匹配）
    const can_process = try s.processDataChunk(allocator, &data_chunk);
    try testing.expect(can_process == true);
    try testing.expect(s.expected_sequence == 1);

    // 检查接收缓冲区
    const buffer = s.getReceiveBuffer();
    try testing.expect(std.mem.eql(u8, buffer, test_data));
}

test "SCTP Stream processDataChunk unordered" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 2, false); // unordered
    defer s.deinit();
    s.open();

    // 创建无序 DATA 块
    const test_data = "Unordered message";
    var data_chunk = try s.createDataChunk(allocator, 200, 52, test_data, false, false);
    defer data_chunk.deinit(allocator);

    // 处理无序 DATA 块（应该立即处理）
    const can_process = try s.processDataChunk(allocator, &data_chunk);
    try testing.expect(can_process == true);

    // 检查接收缓冲区
    const buffer = s.getReceiveBuffer();
    try testing.expect(std.mem.eql(u8, buffer, test_data));
}

test "SCTP Stream processDataChunk wrong sequence" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 1, true); // ordered
    defer s.deinit();
    s.open();

    // 手动创建序列号不匹配的 DATA 块
    const test_data = "Wrong sequence";
    const user_data = try allocator.alloc(u8, test_data.len);
    defer allocator.free(user_data);
    @memcpy(user_data, test_data);

    var data_chunk = chunk.DataChunk{
        .flags = 0x03, // B=1, E=1, U=0 (ordered)
        .length = @as(u16, @intCast(16 + test_data.len)),
        .tsn = 100,
        .stream_id = 1,
        .stream_sequence = 5, // 错误的序列号（期望是 0）
        .payload_protocol_id = 51,
        .user_data = user_data,
    };
    defer data_chunk.deinit(allocator);

    // 处理 DATA 块（序列号不匹配，应该返回 false）
    const can_process = try s.processDataChunk(allocator, &data_chunk);
    try testing.expect(can_process == false);
    try testing.expect(s.expected_sequence == 0); // 序列号未更新
}

test "SCTP StreamManager init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try stream.StreamManager.init(allocator);
    defer manager.deinit();

    try testing.expect(manager.streams.items.len == 0);
}

test "SCTP StreamManager createStream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try stream.StreamManager.init(allocator);
    defer manager.deinit();

    const stream_ptr = try manager.createStream(1, true);
    try testing.expect(stream_ptr.stream_id == 1);
    try testing.expect(stream_ptr.isOpen());
    try testing.expect(manager.streams.items.len == 1);
}

test "SCTP StreamManager findStream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try stream.StreamManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createStream(1, true);
    _ = try manager.createStream(2, false);

    const stream1 = manager.findStream(1);
    try testing.expect(stream1 != null);
    if (stream1) |s| {
        try testing.expect(s.stream_id == 1);
    }

    const stream2 = manager.findStream(2);
    try testing.expect(stream2 != null);
    if (stream2) |s| {
        try testing.expect(s.stream_id == 2);
    }

    const stream3 = manager.findStream(999);
    try testing.expect(stream3 == null);
}

test "SCTP StreamManager removeStream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try stream.StreamManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createStream(1, true);
    _ = try manager.createStream(2, false);
    try testing.expect(manager.streams.items.len == 2);

    try manager.removeStream(1);
    try testing.expect(manager.streams.items.len == 1);
    try testing.expect(manager.findStream(1) == null);
    try testing.expect(manager.findStream(2) != null);
}

test "SCTP StreamManager createStream duplicate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try stream.StreamManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createStream(1, true);

    const result = manager.createStream(1, false);
    try testing.expectError(error.StreamAlreadyExists, result);
}

test "SCTP StreamManager removeStream not found" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try stream.StreamManager.init(allocator);
    defer manager.deinit();

    const result = manager.removeStream(999);
    try testing.expectError(error.StreamNotFound, result);
}

test "SCTP Stream clearReceiveBuffer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var s = try stream.Stream.init(allocator, 1, false);
    defer s.deinit();
    s.open();

    // 创建并处理 DATA 块
    const test_data = "Test data";
    var data_chunk = try s.createDataChunk(allocator, 100, 51, test_data, true, true);
    defer data_chunk.deinit(allocator);

    _ = try s.processDataChunk(allocator, &data_chunk);
    try testing.expect(s.getReceiveBuffer().len > 0);

    s.clearReceiveBuffer();
    try testing.expect(s.getReceiveBuffer().len == 0);
}
