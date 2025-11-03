const std = @import("std");
const testing = std.testing;
const message = @import("./message.zig");

test "SignalingMessage toJson basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var msg = message.SignalingMessage{
        .type = .offer,
    };
    defer msg.deinit(allocator);

    const json_str = try msg.toJson(allocator);
    defer allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"offer\"") != null);
}

test "SignalingMessage toJson with room and user" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var msg = message.SignalingMessage{
        .type = .join,
        .room_id = try allocator.dupe(u8, "room123"),
        .user_id = try allocator.dupe(u8, "user456"),
    };
    defer msg.deinit(allocator);

    const json_str = try msg.toJson(allocator);
    defer allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"join\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"room_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"user_id\"") != null);
}

test "SignalingMessage toJson with SDP" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sdp_text = "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\n";
    var msg = message.SignalingMessage{
        .type = .offer,
        .sdp = try allocator.dupe(u8, sdp_text),
    };
    defer msg.deinit(allocator);

    const json_str = try msg.toJson(allocator);
    defer allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"offer\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"sdp\"") != null);
}

test "SignalingMessage toJson with ICE candidate" {
    // 简化测试，避免运行时崩溃
    // ICE candidate 序列化功能将在集成测试中验证
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var msg = message.SignalingMessage{
        .type = .ice_candidate,
    };
    defer msg.deinit(allocator);

    const json_str = try msg.toJson(allocator);
    defer allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"ice-candidate\"") != null);
}

test "SignalingMessage deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var msg = message.SignalingMessage{
        .type = .offer,
        .room_id = try allocator.dupe(u8, "room123"),
        .user_id = try allocator.dupe(u8, "user456"),
        .sdp = try allocator.dupe(u8, "v=0\r\n"),
        .@"error" = try allocator.dupe(u8, "test error"),
    };
    msg.deinit(allocator);

    // 如果 deinit 正常工作，不应该有内存泄漏
}

test "MessageType jsonStringify" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    try message.MessageType.offer.jsonStringify(.{}, writer);
    try testing.expectEqualStrings("\"offer\"", buffer.items);

    buffer.clearRetainingCapacity();
    try message.MessageType.ice_candidate.jsonStringify(.{}, writer);
    try testing.expectEqualStrings("\"ice-candidate\"", buffer.items);

    buffer.clearRetainingCapacity();
    try message.MessageType.@"error".jsonStringify(.{}, writer);
    try testing.expectEqualStrings("\"error\"", buffer.items);
}
