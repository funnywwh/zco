const std = @import("std");
const zco = @import("zco");
const webrtc = @import("webrtc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建信令服务器
    const addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const signaling_server = try webrtc.signaling.server.SignalingServer.init(schedule, addr);
    defer signaling_server.deinit();

    // 在协程中启动信令服务器
    _ = try schedule.go(handleSignalingServer, .{signaling_server});

    std.log.info("WebRTC signaling server started on 127.0.0.1:8080", .{});

    try schedule.loop();
}

fn handleSignalingServer(server: *webrtc.signaling.server.SignalingServer) !void {
    try server.start();
}
