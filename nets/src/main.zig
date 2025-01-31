const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const xev = @import("xev");

const ZCO_STACK_SIZE = 1024*20;
pub const std_options = .{
    .log_level = .err,
};
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try zco.SwitchTimer.init(allocator);
    defer {
        zco.SwitchTimer.deinit(allocator);
    }

    // try tcpRun();
    try httpHelloworld();
}

fn tcpRun()!void{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    std.log.debug("main schedule inited",.{});
    defer {
        schedule.deinit();
        allocator.destroy(schedule);
    }
    const MainData = struct{
        allocator:std.mem.Allocator,
        schedule:*zco.Schedule,
    };
    var mainData = .{
        .allocator = allocator,
        .schedule = schedule,
    };
    
    _ = try schedule.go(struct{
        fn run(co:*zco.Co,_data:?*MainData)!void{
            const data = _data orelse unreachable;
            _ = try data.schedule.go(struct{
                fn run(_c:*zco.Co,_:?*void)!void{
                    try _c.Suspend();
                }
            }.run,@constCast(&{}));
            const s = data.schedule;
            _ = s; // autofix
            var server = try nets.Tcp.init(data.allocator,co); 
            defer {
                server.close();
                server.deinit();
            }
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            std.log.debug("accept a listen@{d}",.{address.getPort()});
            try server.bind(address);
            try server.listen(1);
            while(true){
                std.log.debug("acceptting",.{});
                var client = try server.accept();
                errdefer {
                    client.close();
                    client.deinit();
                    server.allocator.destroy(client);
                }
                std.log.debug("accept a client",.{});
                _ = try client.go(struct{
                    fn run(_client:*nets.Tcp,arg:?*anyopaque)!void{
                        _ = arg; // autofix
                        std.log.debug("entry client co",.{});
                        defer {
                            std.log.debug("client loop exited",.{});
                            _client.close();
                            _client.deinit();
                            var _allocator = _client.allocator;
                            _allocator.destroy(_client);
                        }
                        std.log.debug("client co will loop",.{});
                        while(true){
                            var buf:[1024]u8 = undefined;
                            std.log.debug("client co will read",.{});
                            const nread = try _client.read(&buf);
                            std.log.debug("client read nread:{d} buf:{s}",.{nread,buf[0..nread]});
                        }
                    }
                }.run,null);
            }
        }
    }.run, &mainData);
    
    try schedule.loop();
}
fn httpHelloworld()!void{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    std.log.debug("main schedule inited",.{});
    defer {
        schedule.deinit();
        allocator.destroy(schedule);
    }
    const MainData = struct{
        allocator:std.mem.Allocator,
        schedule:*zco.Schedule,
    };
    var mainData = .{
        .allocator = allocator,
        .schedule = schedule,
    };
    
    _ = try schedule.go(struct{
        fn run(co:*zco.Co,_data:?*MainData)!void{
            const data = _data orelse unreachable;
            _ = try data.schedule.go(struct{
                fn run(_c:*zco.Co,_:?*void)!void{
                    try _c.Suspend();
                }
            }.run,@constCast(&{}));
            const s = data.schedule;
            _ = s; // autofix
            var server = try nets.Tcp.init(data.allocator,co); 
            defer {
                server.close();
                server.deinit();
            }
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            std.log.debug("accept a listen@{d}",.{address.getPort()});
            try server.bind(address);
            try server.listen(10);
            while(true){
                std.log.debug("acceptting",.{});
                var client = try server.accept();
                errdefer {
                    client.close();
                    client.deinit();
                    server.allocator.destroy(client);
                }
                std.log.debug("accept a client",.{});
                _ = try client.go(struct{
                    fn run(_client:*nets.Tcp,arg:?*anyopaque)!void{
                        _ = arg; // autofix
                        std.log.debug("entry client co",.{});
                        defer {
                            std.log.debug("client loop exited",.{});
                            _client.close();
                            _client.deinit();
                            var _allocator = _client.allocator;
                            _allocator.destroy(_client);
                        }
                        std.log.debug("client co will loop",.{});
                        const anyReader = std.io.AnyReader{
                            .context = _client,
                            .readFn = struct{
                                fn read(context: *const anyopaque, buffer: []u8) anyerror!usize{
                                    const _tcp:*nets.Tcp = @constCast(@alignCast(@ptrCast(context)));
                                    return _tcp.read(buffer);
                                }
                            }.read,
                        };
                        var bufferReader = std.io.bufferedReader(anyReader);
                        var reader = bufferReader.reader();
                        _ = &reader; // autofix
                        while(true){
                            var buf:[1024]u8 = undefined;
                            const line = try reader.readUntilDelimiter(&buf,'\n');
                            std.log.debug("line:{d}",.{line.len});
                            if(line.len <= 1){
                                const response = "HTTP/1.1 200 OK\r\nContext-type: text/plain\r\nConnection: keep-alive\r\nContent-length:10\r\n\r\nhelloworld";

                                _ = try _client.write(response);
                                // break;
                            }
                        }
                    }
                }.run,null);
            }
        }
    }.run, &mainData);
    
    try schedule.loop();
}