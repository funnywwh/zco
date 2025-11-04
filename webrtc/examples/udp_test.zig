const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");

/// 简单的 UDP 发送/接收测试
pub fn main() !void {
    std.log.info("=== UDP 发送/接收测试 ===", .{});
    try zco.loop(runUdpTest, .{});
}

fn runUdpTest() !void {
    const schedule = try zco.getSchedule();

    std.log.info("创建两个 UDP Socket...", .{});

    // 创建发送方 UDP Socket（端口 20000）
    const sender = try nets.Udp.init(schedule);
    defer sender.deinit();
    const sender_addr = try std.net.Address.parseIp4("127.0.0.1", 20000);
    try sender.bind(sender_addr);
    std.log.info("发送方 UDP Socket 已绑定到 127.0.0.1:20000", .{});

    // 创建接收方 UDP Socket（端口 20001）
    const receiver = try nets.Udp.init(schedule);
    defer receiver.deinit();
    const receiver_addr = try std.net.Address.parseIp4("127.0.0.1", 20001);
    try receiver.bind(receiver_addr);
    std.log.info("接收方 UDP Socket 已绑定到 127.0.0.1:20001", .{});

    // 等待一小段时间确保绑定完成
    const current_co = try schedule.getCurrentCo();
    try current_co.Sleep(100 * std.time.ns_per_ms);

    // 启动接收协程
    _ = try schedule.go(receiveMessages, .{ receiver, schedule });

    // 等待接收协程启动
    try current_co.Sleep(200 * std.time.ns_per_ms);

    // 启动发送协程
    _ = try schedule.go(sendMessages, .{ sender, receiver_addr, schedule });

    // 等待发送和接收完成
    try current_co.Sleep(5 * std.time.ns_per_s);

    std.log.info("UDP 测试完成", .{});
    schedule.stop();
}

fn sendMessages(udp: *nets.Udp, target_addr: std.net.Address, schedule: *zco.Schedule) !void {
    const messages = [_][]const u8{
        "Hello from sender!",
        "Message 2",
        "Message 3: Test",
    };

    std.log.info("[发送方] 开始发送消息...", .{});

    for (messages, 0..) |msg, i| {
        const current_co = try schedule.getCurrentCo();
        try current_co.Sleep(500 * std.time.ns_per_ms);

        std.log.info("[发送方] 发送消息 {}: {s}", .{ i + 1, msg });
        const sent = try udp.sendTo(msg, target_addr);
        std.log.info("[发送方] ✓ 已发送 {} 字节", .{sent});
    }

    std.log.info("[发送方] 所有消息已发送", .{});
}

fn receiveMessages(udp: *nets.Udp, _: *zco.Schedule) !void {
    std.log.info("[接收方] 开始接收消息...", .{});

    var buffer: [1024]u8 = undefined;
    var received_count: u32 = 0;
    const max_received = 10;

    while (received_count < max_received) {
        std.log.info("[接收方] 等待接收数据...", .{});
        const result = udp.recvFrom(&buffer) catch |err| {
            std.log.err("[接收方] 接收失败: {}", .{err});
            return err;
        };

        received_count += 1;
        std.log.info("[接收方] ✓ 收到消息 {}: {s} ({} 字节，来自 {})", .{ received_count, result.data, result.data.len, result.addr });

        // 如果收到足够的数据，可以提前退出
        if (received_count >= 3) {
            break;
        }
    }

    std.log.info("[接收方] 接收完成，共收到 {} 条消息", .{received_count});
}

