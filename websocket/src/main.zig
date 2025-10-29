const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const websocket = @import("websocket");

pub fn main() !void {
    std.log.info("Starting WebSocket server...", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();

    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 创建TCP服务器
    const server = try nets.Tcp.init(schedule);
    defer {
        server.close();
        server.deinit();
    }

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    std.log.info("WebSocket server listening on ws://127.0.0.1:8080", .{});
    try server.bind(address);
    try server.listen(128);

    // 接受连接并处理
    _ = try schedule.go(struct {
        fn run(s: *zco.Schedule, svr: *nets.Tcp) !void {
            while (true) {
                const client = svr.accept() catch |e| {
                    std.log.err("Accept error: {any}", .{e});
                    continue;
                };

                // 为每个客户端创建协程
                _ = try s.go(struct {
                    fn handleClient(client_tcp: *nets.Tcp) !void {
                        defer {
                            client_tcp.close();
                            client_tcp.deinit();
                        }

                        // 创建WebSocket连接
                        var ws = try websocket.WebSocket.fromTcp(client_tcp);
                        defer ws.deinit();

                        // 执行握手
                        ws.handshake() catch |e| {
                            std.log.err("Handshake error: {any}", .{e});
                            return;
                        };
                        std.log.info("WebSocket connection established", .{});

                        // 消息处理循环
                        // 使用较小的缓冲区，大消息会通过分片处理
                        var buffer: [4096]u8 = undefined;
                        while (true) {
                            const frame = ws.readMessage(buffer[0..]) catch |e| {
                                switch (e) {
                                    error.ProtocolError => {
                                        std.log.info("Connection closed", .{});
                                        break;
                                    },
                                    else => {
                                        std.log.err("Read error: {any}", .{e});
                                        break;
                                    },
                                }
                            };

                            // 处理消息
                            switch (frame.opcode) {
                                .TEXT => {
                                    const text = frame.payload;
                                    std.log.info("Received text: {} bytes", .{text.len});
                                    // Echo回客户端
                                    try ws.sendText(text);
                                    ws.allocator.free(frame.payload);
                                },
                                .BINARY => {
                                    std.log.info("Received binary: {} bytes", .{frame.payload.len});
                                    // Echo回客户端
                                    try ws.sendBinary(frame.payload);
                                    ws.allocator.free(frame.payload);
                                },
                                else => {
                                    std.log.warn("Unhandled opcode: {}", .{frame.opcode});
                                    if (frame.payload.len > 0) {
                                        ws.allocator.free(frame.payload);
                                    }
                                },
                            }
                        }

                        std.log.info("Client disconnected", .{});
                    }
                }.handleClient, .{client});
            }
        }
    }.run, .{ schedule, server });

    try schedule.loop();
}
