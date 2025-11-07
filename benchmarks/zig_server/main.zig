const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");

// HTTP 响应 - 支持 keep-alive
const HTTP_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhelloworld\n";
const HTTP_KEEPALIVE_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhelloworld";

pub fn main() !void {
    std.log.err("Starting ZCO HelloWorld Server...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 启动服务器协程
    _ = try schedule.go(runServer, .{schedule});

    try schedule.loop();
}

/// 服务器主循环
fn runServer(schedule: *zco.Schedule) !void {
    var server = try nets.Tcp.init(schedule);
    defer {
        server.close();
        server.deinit();
    }

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try server.bind(address);
    try server.listen(1024);

    std.log.err("Server listening on {} (port {d})", .{ address, address.getPort() });

    // 接受连接循环
    while (true) {
        const client = try server.accept();

        // 为每个客户端连接创建协程处理
        _ = try schedule.go(handleClient, .{client});
    }
}

/// 处理客户端连接
fn handleClient(client: *nets.Tcp) !void {
    defer {
        client.close();
        client.deinit();
    }

    var buffer: [1024]u8 = undefined;

    while (true) {
        // 读取请求
        _ = try client.read(buffer[0..]);

        const keepalive = false;
        // 发送响应
        if (keepalive) {
            _ = try client.write(HTTP_KEEPALIVE_RESPONSE);
        } else {
            _ = try client.write(HTTP_RESPONSE);
            client.close();
            break;
        }
    }
}
