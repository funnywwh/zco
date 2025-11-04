const std = @import("std");
const zco = @import("zco");
const webrtc = @import("webrtc");

/// WebRTC 信令服务器示例
/// 启动一个 WebSocket 信令服务器，用于转发 WebRTC 信令消息
pub fn main() !void {
    std.log.info("=== WebRTC 信令服务器 ===", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 创建信令服务器
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    std.log.info("信令服务器启动在 ws://127.0.0.1:8080", .{});

    const server = try webrtc.signaling.server.SignalingServer.init(schedule, address);
    defer server.deinit();

    // 在协程中启动服务器
    _ = try schedule.go(runServer, .{server});

    // 运行调度器
    try schedule.loop();
}

/// 运行信令服务器
fn runServer(server: *webrtc.signaling.server.SignalingServer) !void {
    std.log.info("信令服务器正在运行...", .{});
    try server.start();
}
