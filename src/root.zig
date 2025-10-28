const std = @import("std");
const schedule = @import("./schedule.zig");
const co = @import("./co.zig");
const chan = @import("./chan.zig");
const wg = @import("./wg.zig");
const xev_module = @import("xev");

// 协程栈大小配置 - 优化内存使用
pub const DEFAULT_ZCO_STACK_SZIE = 4 * 1024; // 4KB栈大小，适合HTTP服务器

pub usingnamespace schedule;
pub usingnamespace co;
pub usingnamespace chan;
pub usingnamespace wg;
pub const xev = xev_module;

const Schedule = schedule.Schedule;

var mainSchedule: ?*Schedule = null;
var allocator: ?std.mem.Allocator = null;

const Self = @This();
pub fn init(_allocator: std.mem.Allocator) !void {
    allocator = _allocator;
}

pub fn deinit() void {
    // 时间片抢占功能已集成到 Schedule 中，无需额外清理
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
