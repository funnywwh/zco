const std = @import("std");
const switch_timer = @import("./switch_timer.zig");
const schedule = @import("./schedule.zig");
const co = @import("./co.zig");
const chan = @import("./chan.zig");
pub usingnamespace switch_timer;
pub usingnamespace schedule;
pub usingnamespace co;
pub usingnamespace chan;

const SwitchTimer = switch_timer.SwitchTimer;
const Schedule = schedule.Schedule;

// pub const ZCo = struct {
var allocator: std.mem.Allocator = undefined;

const Self = @This();
pub fn init(_allocator: std.mem.Allocator) !void {
    try SwitchTimer.init(_allocator);
    errdefer SwitchTimer.deinit(_allocator);
    allocator = _allocator;
}

pub fn deinit() void {
    SwitchTimer.deinit(allocator);
}

pub fn newSchedule() !*Schedule {
    const s = try Schedule.init(allocator);
    return s;
}
// };
