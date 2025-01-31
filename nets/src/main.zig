const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const xev = @import("xev");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try zco.SwitchTimer.init(allocator);
    defer {
        zco.SwitchTimer.deinit(allocator);
    }

    try run();
}


fn run()!void{
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
                _ = try s.go(struct{
                    fn run(coClient:*zco.Co,tcpClientPtr:?*nets.Tcp)!void{
                        std.log.debug("entry client co",.{});
                        const _client = tcpClientPtr orelse unreachable;
                        _client.co = coClient;
                        defer {
                            std.log.debug("client loop exited",.{});
                            _client.close();
                            _client.deinit();
                            coClient.schedule.allocator.destroy(_client);
                        }
                        std.log.debug("client co will loop",.{});
                        while(true){
                            var buf:[1024]u8 = undefined;
                            std.log.debug("client co will read",.{});
                            const nread = try _client.read(&buf);
                            std.log.debug("client read nread:{d} buf:{s}",.{nread,buf[0..nread]});
                        }
                    }
                }.run,client);
            }
        }
    }.run, &mainData);
    
    try schedule.loop();
}