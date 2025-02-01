const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const xev = @import("xev");

const ZCo = zco;
const ZCO_STACK_SIZE = 1024 * 100;
pub const std_options = .{
    .log_level = .err,
};
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();
    try httpHelloworld();
}

fn httpHelloworld() !void {
    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    const MainData = struct {
        schedule: *zco.Schedule,
    };
    var mainData = MainData{
        .schedule = schedule,
    };
    _ = &mainData; // autofix

    _ = try schedule.go(struct {
        fn run(co: *zco.Co, _data: ?*MainData) !void {
            _ = co; // autofix
            const data = _data orelse unreachable;
            var server = try nets.Tcp.init(data.schedule.allocator, data.schedule.runningCo.?);
            defer {
                server.close();
                server.deinit();
            }
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            std.log.err("accept a listen@{d}", .{address.getPort()});
            try server.bind(address);
            try server.listen(200);
            while (true) {
                const _s = server.co.schedule;
                var client = try server.accept();
                errdefer {
                    client.close();
                    client.deinit();
                }
                std.log.debug("accept a client", .{});
                _ = try _s.iogo(client, struct {
                    fn run(_client: *nets.Tcp, arg: ?*anyopaque) !void {
                        _ = arg; // autofix
                        std.log.debug("entry client co", .{});
                        defer {
                            std.log.debug("client loop exited", .{});
                            _client.close();
                            _client.deinit();
                        }
                        std.log.debug("client co will loop", .{});
                        var keepalive = true;

                        var listBuf = try std.ArrayList(u8).initCapacity(_client.allocator, 1024);
                        defer {
                            listBuf.clearAndFree();
                            listBuf.deinit();
                        }
                        var offset: usize = 0;
                        while (true) {
                            var buf = listBuf.items[offset..];
                            if (buf.len < 1024) {
                                try listBuf.appendNTimes(0, 1024);
                                buf = listBuf.items[offset..];
                            }
                            const n = try _client.read(buf);

                            var leftBuf = buf[0..n];
                            //从剩下的字符串中分行处理
                            while (leftBuf.len > 0) {
                                const found = std.mem.indexOfPos(u8, leftBuf, 0, "\r\n") orelse break;
                                offset += found + 2;
                                const line = leftBuf[0..found];
                                leftBuf = leftBuf[found + 2 ..];

                                // std.log.err("line:{s}", .{line});
                                if (keepalive == false) {
                                    if (std.mem.indexOfPos(u8, line, offset, "Keep-Alive") != null) {
                                        keepalive = true;
                                    }
                                }
                                if (line.len <= 0) {
                                    //找到body分割
                                    const response = "HTTP/1.1 200 OK\r\nContext-type: text/plain\r\nConnection: keep-alive\r\nContent-length:10\r\n\r\nhelloworld";
                                    _ = try _client.write(response);
                                    if (!keepalive) {
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }.run, null);
            }
        }
    }.run, &mainData);

    try schedule.loop();
}
