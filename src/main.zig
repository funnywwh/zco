const std = @import("std");
const co = @import("./root.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var schedule = co.Schedule.init(allocator);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = arg; // autofix
            while(true){
                std.log.debug("co1 running",.{});
                try c.Sleep(10);
            }
        }
    }.run,null);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = arg; // autofix
            while(true){
                std.log.debug("co2 running",.{});
                try c.Sleep(10);
            }
        }
    }.run,null);
    _ = try schedule.go(struct{
        fn run(c:*co.Co,arg:?*anyopaque)!void{
            _ = arg; // autofix
            while(true){
                std.log.debug("co2 running",.{});
                try c.Sleep(10);
            }
        }
    }.run,null);
    var exit = false;
    try schedule.loop(&exit);
}

test "simple test" {
}
