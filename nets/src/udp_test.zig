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
