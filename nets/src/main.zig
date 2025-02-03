const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const xev = @import("xev");
const opts = @import("opts");
const builtin = @import("builtin");
const ZCo = zco;
// pub const ZCO_STACK_SIZE = 1024 * 32;
// pub const std_options = .{
//     .log_level = .debug,
// };
pub fn main() !void {
    var threads = std.mem.zeroes([opts.threads]?std.Thread);
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = if (builtin.single_threaded) false else threads.len > 1,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();
    defer {
        for (threads, 0..) |_, i| {
            // try httpHelloworld();
            if (threads[i]) |t| {
                t.join();
            }
        }
    }
    if (builtin.single_threaded == false) {
        for (threads, 0..) |_, i| {
            // try httpHelloworld();
            threads[i] = try std.Thread.spawn(.{}, httpHelloworld, .{});
        }
    } else {
        try httpHelloworld();
    }
}

fn httpHelloworld() !void {
    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    _ = try schedule.go(struct {
        fn run(s: *zco.Schedule) !void {
            var server = try nets.Tcp.init(s.allocator, s);
            defer {
                server.close();
                server.deinit();
            }
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            std.log.err("accept a listen@{d}", .{address.getPort()});
            try server.bind(address);
            try server.listen(200);
            while (true) {
                const _s = server.schedule;
                var client = try server.accept();
                errdefer {
                    client.close();
                    client.deinit();
                }
                std.log.debug("accept a client", .{});
                _ = try _s.go(struct {
                    fn run(_client: *nets.Tcp) !void {
                        std.log.debug("entry client co", .{});
                        defer {
                            std.log.debug("client loop exited", .{});
                            _client.close();
                            _client.deinit();
                        }
                        std.log.debug("client co will loop", .{});
                        var keepalive = true;

                        var buffer: [1024]u8 = undefined;
                        var offset: usize = 0;
                        while (true) {
                            var buf = buffer[offset..];
                            const n = try _client.read(buf);

                            var leftBuf = buf[0..n];
                            var versionCheck = false;
                            //从剩下的字符串中分行处理
                            while (leftBuf.len > 0) {
                                const found = std.mem.indexOfPos(u8, leftBuf, 0, "\r\n") orelse break;
                                offset += found + 2;
                                const line = leftBuf[0..found];
                                leftBuf = leftBuf[found + 2 ..];
                                if (versionCheck == false) {
                                    if (std.ascii.indexOfIgnoreCasePos(line, 0, "HTTP/1.0") != null) {
                                        keepalive = false;
                                    } else {
                                        keepalive = true;
                                    }
                                    versionCheck = true;
                                }
                                std.log.debug("line:{s}", .{line});
                                if (keepalive == true) {
                                    if (std.ascii.indexOfIgnoreCasePos(line, 0, "connection")) |pos| {
                                        if (std.ascii.indexOfIgnoreCasePos(line, pos + "connection".len, "close") != null) {
                                            keepalive = false;
                                        }
                                    }
                                } else {
                                    if (std.ascii.indexOfIgnoreCasePos(line, 0, "connection")) |pos| {
                                        if (std.ascii.indexOfIgnoreCasePos(line, pos + "connection".len, "keep-alive") != null) {
                                            keepalive = true;
                                        }
                                    }
                                }
                                if (line.len <= 0) {
                                    offset = 0;
                                    //找到body分割
                                    if (keepalive) {
                                        const response = "HTTP/1.1 200 OK\r\nContext-type: text/plain\r\nConnection: keep-alive\r\nContent-length:10\r\n\r\nhelloworld";
                                        _ = try _client.write(response);
                                    } else {
                                        const response = "HTTP/1.1 200 OK\r\nContext-type: text/plain\r\nConnection: close\r\nContent-length:10\r\n\r\nhelloworld";
                                        _ = try _client.write(response);
                                    }
                                    if (!keepalive) {
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }.run, .{client});
            }
        }
    }.run, .{schedule});

    try schedule.loop();
}
