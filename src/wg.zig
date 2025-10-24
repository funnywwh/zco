const std = @import("std");
const zco = @import("./co.zig");
const Co = zco.Co;
const Schedule = zco.Schedule;
const Chan = zco.CreateChan(bool);

pub const WaitGroup = struct {
    const Self = @This();

    count: usize = 0,
    waitChn: *Chan,

    pub fn init(s: *Schedule) !Self {
        return .{
            .waitChn = try Chan.init(s, 1),
        };
    }
    pub fn deinit(self: *Self) void {
        self.waitChn.deinit();
    }
    pub fn add(self: *Self, count: usize) !void {
        self.count +|= count;
    }
    pub fn done(self: *Self) void {
        std.debug.assert(self.count > 0);
        self.count -|= 1;
        if (self.count == 0) {
            _ = self.waitChn.recv() catch |e| {
                std.log.err("wg recv error: {any}", .{e});
            };
        }
    }

    pub fn wait(self: *Self) void {
        if (self.count == 0) {
            return;
        }
        _ = self.waitChn.send(true) catch |e| {
            std.log.err("wg send error: {any}", .{e});
        };
    }
};
