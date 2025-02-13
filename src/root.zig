const std = @import("std");
const switch_timer = @import("./switch_timer.zig");
const schedule = @import("./schedule.zig");
const co = @import("./co.zig");
const chan = @import("./chan.zig");
const wg = @import("./wg.zig");
pub usingnamespace switch_timer;
pub usingnamespace schedule;
pub usingnamespace co;
pub usingnamespace chan;
pub usingnamespace wg;

const SwitchTimer = switch_timer.SwitchTimer;
const Schedule = schedule.Schedule;

var mainSchedule: ?*Schedule = null;
var allocator: ?std.mem.Allocator = null;

const Self = @This();
pub fn init(_allocator: std.mem.Allocator) !void {
    try SwitchTimer.init(_allocator);
    errdefer SwitchTimer.deinit(_allocator);
    allocator = _allocator;
}

pub fn deinit() void {
    if (allocator) |_allocator| {
        SwitchTimer.deinit(_allocator);
    }
}

pub fn newSchedule() !*Schedule {
    const _allocator = allocator orelse return error.NotInit;
    const s = try Schedule.init(_allocator);
    return s;
}

pub fn getSchedule() !*Schedule {
    const s = mainSchedule orelse return error.NotLoop;
    return s;
}
pub fn loop(f: anytype, args: anytype) !void {
    if (mainSchedule != null) {
        std.log.err("The loop can only be called once.", .{});
        return error.HasLooped;
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const _allocator = gpa.allocator();
    try init(_allocator);
    defer deinit();

    const s = try newSchedule();
    mainSchedule = s;
    defer {
        s.deinit();
        mainSchedule = null;
    }
    _ = try s.go(f, args);
    try s.loop();
}
