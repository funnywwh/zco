const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const xev = @import("xev");

const ZCo = zco;
const ZCO_STACK_SIZE = 1024 * 4;
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
            std.log.debug("accept a listen@{d}", .{address.getPort()});
            try server.bind(address);
            try server.listen(10);
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
                        const anyReader = std.io.AnyReader{
                            .context = _client,
                            .readFn = struct {
                                fn read(context: *const anyopaque, buffer: []u8) anyerror!usize {
                                    const _tcp: *nets.Tcp = @constCast(@alignCast(@ptrCast(context)));
                                    return _tcp.read(buffer);
                                }
                            }.read,
                        };
                        var bufferReader = std.io.bufferedReader(anyReader);
                        var reader = bufferReader.reader();
                        _ = &reader; // autofix
                        while (true) {
                            var buf: [1024]u8 = undefined;
                            const line = try reader.readUntilDelimiter(&buf, '\n');
                            std.log.debug("line:{d}", .{line.len});
                            if (line.len <= 1) {
                                const response = "HTTP/1.1 200 OK\r\nContext-type: text/plain\r\nConnection: keep-alive\r\nContent-length:10\r\n\r\nhelloworld";

                                _ = try _client.write(response);
                                // break;
                            }
                        }
                    }
                }.run, null);
            }
        }
    }.run, &mainData);

    try schedule.loop();
}
