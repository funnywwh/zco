const std = @import("std");
const co = @import("./root.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var schedule = co.Schedule.init(allocator);

    
    var chn1 = co.Chan.init(&schedule,10);

    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = c; // autofix
            const _ch:*co.Chan = @alignCast(@ptrCast(arg));
            var v:usize = 0;
            while(true){
                std.log.debug("co0 sending",.{});
                // try c.Sleep(10);
                try _ch.send(&v);
                v +%= 1;
                if(v == 1000){
                    break;
                }
                std.log.debug("co0 sent",.{});
            }
            try _ch.close();
        }
    }.run,&chn1);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = c; // autofix
            const _ch:*co.Chan = @alignCast(@ptrCast(arg));
            var v:usize = 100;
            while(true){
                std.log.debug("co1 sending",.{});
                // try c.Sleep(10);
                try _ch.send(&v);
                v +%= 1;
                std.log.debug("co1 sent",.{});
            }
        }
    }.run,&chn1);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = c; // autofix
            const _ch:*co.Chan = @alignCast(@ptrCast(arg));
            while(true){
                std.log.debug("co2 recving",.{});
                const d:*usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
                std.log.debug("co2 recv:{d}",.{d.*});
            }
        }
    }.run,&chn1);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = c; // autofix
            const _ch:*co.Chan = @alignCast(@ptrCast(arg));
            while(true){
                std.log.debug("co3 recving",.{});
                const d:*usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
                std.log.debug("co3 recv:{d}",.{d.*});
            }
        }
    }.run,&chn1);
    var exit = false;
    try schedule.loop(&exit);
}

test "simple test" {
}
