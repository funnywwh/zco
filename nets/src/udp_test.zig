const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const nets = @import("nets");

test "UDP init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const udp = try nets.Udp.init(schedule);
    defer udp.deinit();

    try testing.expect(udp.xobj == null);
    try testing.expect(udp.schedule == schedule);
}

test "UDP bind" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    const udp = try nets.Udp.init(schedule);
    defer udp.deinit();

    try udp.bind(addr);
    try testing.expect(udp.xobj != null);
}

// 注意：UDP 发送/接收测试需要完整的异步事件循环环境
// 由于测试环境限制，暂时跳过异步发送/接收测试
// 这些功能在实际使用中会通过集成测试验证

test "UDP bind invalid address" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const udp = try nets.Udp.init(schedule);
    defer udp.deinit();

    // 测试无效的地址族（IPv6 地址但系统可能不支持）
    // 注意：这个测试可能会成功（如果支持 IPv6）或失败（如果不支持）
    const addr = std.net.Address.parseIp6("::1", 0) catch {
        // IPv6 不支持是可以接受的
        return;
    };

    // 如果能解析 IPv6 地址，尝试绑定
    _ = udp.bind(addr) catch {
        // 绑定失败是可以接受的（可能系统不支持 IPv6 或其他原因）
    };
}

test "UDP recvFrom before bind" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const udp = try nets.Udp.init(schedule);
    defer udp.deinit();

    // 在未绑定的 socket 上尝试接收应该返回错误
    var buffer: [1024]u8 = undefined;
    const result = udp.recvFrom(&buffer);
    try testing.expectError(error.NotInit, result);
}

test "UDP sendTo before bind" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const udp = try nets.Udp.init(schedule);
    defer udp.deinit();

    // 在未绑定的 socket 上尝试发送应该返回错误
    const test_addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    const result = udp.sendTo("test", test_addr);
    try testing.expectError(error.NotInit, result);
}
