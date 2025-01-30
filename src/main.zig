const std = @import("std");
const co = @import("./root.zig");

pub const ZCO_STACK_SIZE = 1024*100;

pub fn main() !void {
      var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
 
    try co.SwitchTimer.init(allocator);
    defer {
        co.SwitchTimer.deinit();
    }
    const t1 = try std.Thread.spawn(.{},coRun,.{1});
    const t2 = try std.Thread.spawn(.{},coRun1,.{5});

    t1.join();
    t2.join();
}


pub fn coRun(baseIdx:u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var schedule = try co.Schedule.init(allocator);
    defer {
        schedule.deinit();
        allocator.destroy(schedule);
    }

    const CoArg = struct{
        baseIdx:usize,
    };
    for(0..10_000)|i|{

        var arg1 = CoArg{.baseIdx = baseIdx+i};

        _ = try schedule.go(struct{
            fn run(_co:*co.Co,_args:?*CoArg)!void{
                const args = _args orelse return error.noArg;
                const idx = args.baseIdx;
                var v:usize = idx;
                while(true){
                    std.log.debug("co{d} running v:{d}",.{idx,v});
                    const start = try std.time.Instant.now();
                    try _co.Sleep(10);
                    const end = try std.time.Instant.now();
                    v +%= 1;
                    std.log.err("idx{d} sleeped ms:{d}",.{v,end.since(start)/std.time.ns_per_ms});
                }
            }
        }.run,&arg1);
    }

}
pub fn coRun1(baseIdx:u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var schedule = try co.Schedule.init(allocator);
    defer {
        schedule.deinit();
        allocator.destroy(schedule);
    }
    var chn1 = co.Chan.init(schedule,10);
    defer chn1.deinit();

    const CoArg = struct{
        chn:*co.Chan,
        baseIdx:u32,
    };
    var arg1 = CoArg{.chn = &chn1,.baseIdx = baseIdx};

    _ = try schedule.go(struct{
        fn run(_co:*co.Co,_args:?*CoArg)!void{
            var v:usize = 0;
            const args = _args orelse return error.noArg;
            const _ch:*co.Chan = @alignCast(@ptrCast(args.chn));
            const idx = args.baseIdx;
            while(true){
                std.log.debug("co{d} sending",.{idx});
                // try c.Sleep(10);
                v +%= 1;
                try _ch.send(&v);
                // if(v == 1000){
                //     break;
                // }
                std.log.debug("co{d} sent",.{idx});
            }
            _ch.close();
            _co.schedule.stop();
        }
    }.run,&arg1);

    _ = try schedule.go(struct{
        fn run(_:*co.Co,_args:?*CoArg)!void{
            var v:usize = 100;
            const args = _args orelse return error.noArg;
            const _ch:*co.Chan = @alignCast(@ptrCast(args.chn));
            const idx = args.baseIdx + 1;
            while(true){
                std.log.debug("co{d} sending",.{idx});
                // try c.Sleep(10);
                v +%= 1;
                try _ch.send(&v);
                std.log.debug("co{d} sent",.{idx});
            }
        }
    }.run,&arg1);
    _ = try schedule.go(struct{
        fn run(_:*co.Co,_arg:?*CoArg)!void{
            const args = _arg orelse return error.noArg;
            const _ch:*co.Chan = @alignCast(@ptrCast(args.chn));
            const idx = args.baseIdx + 2;
            while(true){
                std.log.debug("co{d} recving",.{idx});
                const d:*usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
                std.log.debug("co{d} recv:{d}",.{idx,d.*});
            }
            
        }
    }.run,&arg1);
    _ = try schedule.go(struct{
        fn run(_:*co.Co,_arg:?*CoArg)!void{
            const args = _arg orelse return error.noArg;
            const _ch:*co.Chan = @alignCast(@ptrCast(args.chn));
            const idx = args.baseIdx + 3;
            while(true){
                std.log.debug("co{d} recving",.{idx});
                const d:*usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
                std.log.debug("co{d} recv:{d}",.{idx,d.*});
            }
            
        }
    }.run,&arg1);
    try schedule.loop();
}

test "simple test" {
}
