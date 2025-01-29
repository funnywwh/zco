const std = @import("std");
const co = @import("./root.zig");

pub const ZCO_STACK_SIZE = 1024*32;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var schedule = co.Schedule.init(allocator);
    defer schedule.deinit();

    var chn1 = co.Chan.init(&schedule,10);
    defer chn1.deinit();

    const CoArg = struct{
        chn:*co.Chan,
    };
    var arg1:?*const CoArg = &CoArg{.chn = &chn1};
    _ = try schedule.go(struct{
        fn run(c:*co.Co,_args:?*anyopaque)!void{
            var v:usize = 0;
            const args = @as(*const CoArg,@alignCast(@ptrCast(_args orelse return error.noArg )));
            const _ch:*co.Chan = @alignCast(@ptrCast(args.chn));
            while(true){
                std.log.debug("co0 sending",.{});
                // try c.Sleep(10);
                v +%= 1;
                try _ch.send(&v);
                if(v == 10000){
                    break;
                }
                std.log.debug("co0 sent",.{});
            }
            _ch.close();
            c.schedule.stop();
        }
    }.run,arg1);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = c; // autofix
            var v:usize = 100;
            const _ch:*co.Chan = @constCast(@alignCast(@ptrCast(arg)));
            
            while(true){
                std.log.debug("co1 sending",.{});
                // try c.Sleep(10);
                v +%= 1;
                try _ch.send(&v);
                std.log.debug("co1 sent",.{});
            }
        }
    }.run,&chn1);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = c; // autofix
            const _ch:*co.Chan = @constCast(@alignCast(@ptrCast(arg)));
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
            const _ch:*co.Chan = @constCast(@alignCast(@ptrCast(arg)));
            while(true){
                std.log.debug("co3 recving",.{});
                const d:*usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
                std.log.debug("co3 recv:{d}",.{d.*});
            }
            
        }
    }.run,&chn1);
    try schedule.loop();
}

test "simple test" {
}
