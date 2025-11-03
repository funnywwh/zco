const std = @import("std");
const testing = std.testing;
const association = @import("./association.zig");

test "SCTP Association init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assoc = try association.Association.init(allocator, 5000);
    defer assoc.deinit();

    try testing.expect(assoc.local_port == 5000);
    try testing.expect(assoc.state == .closed);
    try testing.expect(assoc.local_verification_tag != 0);
    try testing.expect(assoc.local_tsn != 0);
}

test "SCTP Association sendInit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assoc = try association.Association.init(allocator, 5000);
    defer assoc.deinit();

    const init_data = try assoc.sendInit(allocator, 6000);
    defer allocator.free(init_data);

    try testing.expect(assoc.state == .cookie_wait);
    try testing.expect(assoc.remote_port == 6000);
    try testing.expect(init_data.len >= 20); // 最小 INIT 块长度
}

test "SCTP Association processInit and sendInitAck" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建两个关联：一个发送 INIT，一个接收并响应
    var initiator = try association.Association.init(allocator, 5000);
    defer initiator.deinit();

    var responder = try association.Association.init(allocator, 6000);
    defer responder.deinit();

    // 步骤 1：发起方发送 INIT
    const init_data = try initiator.sendInit(allocator, 6000);
    defer allocator.free(init_data);

    // 步骤 2：接收方处理 INIT，发送 INIT-ACK
    const init_ack_data = try responder.processInit(allocator, init_data);
    defer allocator.free(init_ack_data);

    try testing.expect(responder.state == .cookie_wait);
    try testing.expect(responder.remote_verification_tag == initiator.local_verification_tag);
    try testing.expect(responder.state_cookie != null);
    try testing.expect(init_ack_data[0] == 2); // INIT-ACK chunk type
}

test "SCTP Association complete handshake" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建两个关联：完整的四路握手
    var initiator = try association.Association.init(allocator, 5000);
    defer initiator.deinit();

    var responder = try association.Association.init(allocator, 6000);
    defer responder.deinit();

    // 步骤 1：发起方发送 INIT
    const init_data = try initiator.sendInit(allocator, 6000);
    defer allocator.free(init_data);

    // 步骤 2：接收方处理 INIT，发送 INIT-ACK
    const init_ack_data = try responder.processInit(allocator, init_data);
    defer allocator.free(init_ack_data);

    // 步骤 3：发起方处理 INIT-ACK，发送 COOKIE-ECHO
    const cookie_echo_data = try initiator.processInitAck(allocator, init_ack_data);
    defer allocator.free(cookie_echo_data);

    try testing.expect(initiator.state == .cookie_echoed);
    try testing.expect(initiator.remote_verification_tag == responder.local_verification_tag);
    try testing.expect(cookie_echo_data[0] == 10); // COOKIE-ECHO chunk type

    // 步骤 4：接收方处理 COOKIE-ECHO，发送 COOKIE-ACK
    const cookie_ack_data = try responder.processCookieEcho(allocator, cookie_echo_data);
    defer allocator.free(cookie_ack_data);

    try testing.expect(responder.state == .established);
    try testing.expect(cookie_ack_data[0] == 11); // COOKIE-ACK chunk type

    // 步骤 5：发起方处理 COOKIE-ACK，关联建立完成
    try initiator.processCookieAck(cookie_ack_data);

    try testing.expect(initiator.state == .established);
    try testing.expect(initiator.isEstablished());
    try testing.expect(responder.isEstablished());
}

test "SCTP Association state transitions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assoc = try association.Association.init(allocator, 5000);
    defer assoc.deinit();

    // 初始状态
    try testing.expect(assoc.getState() == .closed);
    try testing.expect(!assoc.isEstablished());

    // 发送 INIT
    _ = try assoc.sendInit(allocator, 6000);
    try testing.expect(assoc.getState() == .cookie_wait);
}

test "SCTP Association invalid state transitions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assoc = try association.Association.init(allocator, 5000);
    defer assoc.deinit();

    // 在 closed 状态下处理 INIT-ACK 应该失败
    var dummy_init_ack = std.ArrayList(u8).init(allocator);
    defer dummy_init_ack.deinit();
    // INIT-ACK 块格式：类型(2) + flags(0) + length(20) + 参数(16字节)
    try dummy_init_ack.append(2); // INIT-ACK
    try dummy_init_ack.append(0); // Flags
    try dummy_init_ack.appendSlice(&[_]u8{ 0, 20 }); // Length = 20
    // INIT 块参数：20 字节（最小长度）
    var init_params: [16]u8 = undefined;
    @memset(&init_params, 0);
    try dummy_init_ack.appendSlice(&init_params);

    const result = assoc.processInitAck(allocator, dummy_init_ack.items);
    try testing.expectError(error.InvalidState, result);
}

test "SCTP Association getState and isEstablished" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assoc = try association.Association.init(allocator, 5000);
    defer assoc.deinit();

    try testing.expect(assoc.getState() == .closed);
    try testing.expect(!assoc.isEstablished());

    // 通过手动设置状态测试（简化）
    // 在实际使用中，状态应该通过四路握手改变
    assoc.state = .established;
    try testing.expect(assoc.isEstablished());
}
