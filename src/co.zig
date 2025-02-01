const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const Schedule = @import("./schedule.zig").Schedule;
const root = @import("root");
const builtin = @import("builtin");

pub const Co = struct {
    const Self = @This();
    id: usize = 0,
    ctx: Context = std.mem.zeroes(Context),
    func: Func = undefined,
    arg: ?*anyopaque = null,
    state: State = .INITED,
    priority: usize = 0,
    schedule: *Schedule = undefined,
    stack: [DEFAULT_STACK_SZIE]u8 = std.mem.zeroes([DEFAULT_STACK_SZIE]u8),
    wakeupTimestampNs: usize = 0, //纳秒
    const State = enum {
        INITED,
        SUSPEND,
        READY,
        RUNNING,
        STOP,
        FREED,
    };
    const DEFAULT_STACK_SZIE = blk: {
        if (@hasDecl(root, "ZCO_STACK_SIZE")) {
            if (builtin.mode == .Debug) {
                if (root.ZCO_STACK_SIZE < 1024 * 12) {
                    @compileError("root.ZCO_STACK_SIZE < 1024*12");
                }
            } else {
                if (root.ZCO_STACK_SIZE < 1024 * 4) {
                    @compileError("root.ZCO_STACK_SIZE < 1024*4");
                }
            }
            break :blk root.ZCO_STACK_SIZE;
        } else {
            if (builtin.mode == .Debug) {
                break :blk 1024 * 32;
            } else {
                break :blk 1024 * 8;
            }
        }
    };
    pub var nextId: usize = 0;

    pub const Func = *const fn (self: *Co, args: ?*anyopaque) anyerror!void;

    pub fn Suspend(self: *Self) !void {
        const schedule = self.schedule;
        if (schedule.runningCo) |co| {
            if (co != self) {
                unreachable;
            }
            co.state = .SUSPEND;
            self.schedule.runningCo = null;
            if (c.swapcontext(&co.ctx, &schedule.ctx) != 0) {
                return error.swapcontext;
            }
            return;
        }
        unreachable;
    }
    pub fn SuspendInSigHandler(self: *Self) !void {
        const schedule = self.schedule;
        if (schedule.runningCo) |co| {
            if (co != self) {
                return error.runningCoNotSelf;
            }
            co.state = .SUSPEND;
            self.schedule.runningCo = null;
            if (c.setcontext(&schedule.ctx) != 0) {
                return error.swapcontext;
            }
            return;
        }
        return error.runningCoNull;
    }
    pub fn Resume(self: *Self) !void {
        const schedule = self.schedule;
        std.debug.assert(schedule.runningCo == null);
        std.log.debug("coid:{d} Resume state:{any}", .{ self.id, self.state });
        switch (self.state) {
            .INITED => {
                if (c.getcontext(&self.ctx) != 0) {
                    return error.getcontext;
                }
                self.ctx.uc_stack.ss_sp = &self.stack;
                self.ctx.uc_stack.ss_size = self.stack.len;
                self.ctx.uc_flags = 0;
                self.ctx.uc_link = &schedule.ctx;
                std.log.debug("coid:{d} Resume makecontext", .{self.id});
                c.makecontext(&self.ctx, @ptrCast(&contextEntry), 1, self);
                std.log.debug("coid:{d} Resume swapcontext state:{any}", .{ self.id, self.state });
                self.state = .RUNNING;
                schedule.runningCo = self;
                if (c.swapcontext(&schedule.ctx, &self.ctx) != 0) {
                    return error.swapcontext;
                }
            },
            .SUSPEND, .READY => {
                std.log.debug("coid:{d} Resume swapcontext state:{any}", .{ self.id, self.state });
                self.state = .RUNNING;
                schedule.runningCo = self;
                if (c.swapcontext(&schedule.ctx, &self.ctx) != 0) {
                    return error.swapcontext;
                }
            },
            else => {},
        }
        if (self.state == .STOP) {
            schedule.freeCo(self);
        }
    }
    pub fn Sleep(self: *Self, ns: usize) !void {
        _ = ns; // autofix
        const schedule = self.schedule;
        try schedule.readyQueue.add(self);
        _ = try self.Suspend();
    }
    fn contextEntry(self: *Self) callconv(.C) void {
        std.log.debug("Co contextEntry coid:{d} schedule{*}", .{ self.id, self.schedule });
        defer std.log.debug("Co contextEntry coid:{d} exited", .{self.id});
        const schedule = self.schedule;
        self.func(self, self.arg) catch {
            // std.log.err("contextEntry coid:{d} error:{s}",.{self.id,@errorName(e)});
        };
        schedule.runningCo = null;
        self.state = .STOP;
    }
};
