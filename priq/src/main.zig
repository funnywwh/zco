const std = @import("std");


const Value = struct{
    id:u32 = 0,
    val:u32 = 0,
};
const log = std.log;
pub fn compare(_:void,a:Value,b:Value)std.math.Order{
    return std.math.order(a.val,b.val);
}
pub fn main() !void {
    const Q = std.PriorityQueue(Value,void,compare);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var q1 = Q.init(allocator,{});
    defer q1.deinit();
    try q1.add(.{
        .id = 0,
        .val = 0,
    });
    try q1.add(.{
        .id = 10,
        .val = 0,
    });
    try q1.add(.{
        .id = 1,
        .val = 0,
    });
    while(q1.peek())|q|{
        _ = q1.remove();
        log.debug("{any}",.{q});
    }

    const L = std.ArrayList(Value);
    var l = L.init(allocator);
    defer l.deinit();
    {
        try l.append(.{
            .id = 0,
            .val = 0,
        });
    }
    {
        try l.append(.{
            .id = 1,
            .val = 1,
        });
    }
    while(l.items.len > 0 ){
        const _v = l.getLast();
        std.log.debug("list v:{any}",.{_v});
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
