const std = @import("std");
const c = @import("./c.zig");
const xev = @import("xev");
const Context = c.ucontext_t;
const Schedule = @import("./schedule.zig").Schedule;
const root = @import("root");
const builtin = @import("builtin");
const coro = @import("./coro_base.zig");

const cfg = @import("./config.zig");
const USE_ZIG_CORO = cfg.USE_ZIG_CORO;
const DEFAULT_ZCO_STACK_SZIE = cfg.DEFAULT_ZCO_STACK_SZIE;

pub fn freeArgs(self: *Co) void {
    if (self.args) |args| {
        self.args = null;
        self.argsFreeFunc(self, args);
    }
}

pub fn Resume(self: *Co) !void {
    const schedule = self.schedule;
    std.debug.assert(schedule.runningCo == null);
    std.log.debug("coid:{d} Resume state:{any}", .{ self.id, self.state });
    switch (self.state) {
        .INITED => {
            if (USE_ZIG_CORO) {
                self.state = .RUNNING;
                schedule.runningCo = self;
                self.coro.resumeFrom(&schedule.coro);
            } else {
                if (c.getcontext(&self.ctx) != 0) {
                    return error.getcontext;
                }
                self.ctx.uc_stack.ss_sp = &self.stack;
                self.ctx.uc_stack.ss_size = self.stack.len;
                self.ctx.uc_flags = 0;
                self.ctx.uc_link = &schedule.ctx;
                std.log.debug("coid:{d} Resume makecontext", .{self.id});
                c.makecontext(&self.ctx, @ptrCast(&Co.contextEntry), 1, self);
                std.log.debug("coid:{d} Resume swapcontext state:{any}", .{ self.id, self.state });
                self.state = .RUNNING;
                schedule.runningCo = self;
                if (c.swapcontext(&schedule.ctx, &self.ctx) != 0) {
                    return error.swapcontext;
                }
            }
        },
        .SUSPEND, .READY => {
            std.log.debug("coid:{d} Resume swapcontext state:{any}", .{ self.id, self.state });
            self.state = .RUNNING;
            schedule.runningCo = self;
            if (USE_ZIG_CORO) {
                self.coro.resumeFrom(&schedule.coro);
            } else {
                if (c.swapcontext(&schedule.ctx, &self.ctx) != 0) {
                    return error.swapcontext;
                }
            }
        },
        else => {},
    }
    if (self.state == .STOP) {
        schedule.freeCo(self);
    }
}

pub fn SuspendInSigHandler(self: *Co) !void {
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

pub const Co = struct {
    const Self = @This();
    id: usize = 0,
    ctx: Context = std.mem.zeroes(Context),
    coro: brk: {
        if (USE_ZIG_CORO) {
            break :brk coro.Coro;
        } else {
            break :brk void;
        }
    } = brk: {
        if (USE_ZIG_CORO) {
            break :brk undefined;
        } else {
            break :brk {};
        }
    },
    func: Func = undefined,
    args: ?*anyopaque = null,
    argsFreeFunc: *const fn (*Co, *anyopaque) void,
    state: State = .INITED,
    priority: usize = 0,
    schedule: *Schedule = undefined,
    stack: [DEFAULT_ZCO_STACK_SZIE]u8 align(16) = std.mem.zeroes([DEFAULT_ZCO_STACK_SZIE]u8),
    wakeupTimestampNs: usize = 0, //纳秒
    const State = enum {
        INITED,
        SUSPEND,
        READY,
        RUNNING,
        STOP,
        FREED,
    };
    pub var nextId: usize = 0;

    pub const Func = *const fn (args: ?*anyopaque) anyerror!void;

    pub fn Suspend(self: *Self) !void {
        const schedule = self.schedule;
        if (schedule.runningCo) |co| {
            if (co != self) {
                std.log.err("Co Suspend co:{d} != self:{d}", .{ co.id, self.id });
                return error.RunningCo;
            }
            co.state = .SUSPEND;
            self.schedule.runningCo = null;
            if (USE_ZIG_CORO) {
                schedule.coro.resumeFrom(&self.coro);
            } else {
                if (c.swapcontext(&co.ctx, &schedule.ctx) != 0) {
                    return error.swapcontext;
                }
            }
            return;
        }
        std.log.err("Co Suspend RunningCoNull", .{});
        return error.RunningCoNull;
    }
    pub fn Resume(self: *Co) !void {
        try self.schedule.ResumeCo(self);
    }

    pub fn Sleep(self: *Self, ns: usize) !void {
        const ms = ns / std.time.ns_per_ms;
        std.log.debug("Co Sleep ms:{d}", .{ms});
        const w = try xev.Timer.init();
        defer w.deinit();
        const _co = try self.schedule.getCurrentCo();
        const Result = struct {
            co: *Co,
            result: xev.Timer.RunError!void = undefined,
            ns: usize,
        };

        var result: Result = .{
            .co = _co,
            .ns = ns,
        };

        var _c: xev.Completion = undefined;
        w.run(&(self.schedule.xLoop.?), &_c, ms, Result, &result, struct {
            fn callback(
                userdata: ?*Result,
                loop: *xev.Loop,
                __c: *xev.Completion,
                _result: xev.Timer.RunError!void,
            ) xev.CallbackAction {
                _ = __c; // autofix
                _ = loop; // autofix
                const _ud = userdata orelse unreachable;
                _ud.result = _result;
                _ud.co.Resume() catch |e| {
                    std.log.err("Co Sleep ns:{d} Resume error:{s}", .{ _ud.ns, @errorName(e) });
                };
                return .disarm;
            }
        }.callback);
        try _co.Suspend();
    }
    fn contextEntry(self: *Self) callconv(.C) void {
        const args = self.args orelse unreachable;
        std.log.debug("Co contextEntry coid:{d} schedule{*}", .{ self.id, self.schedule });
        defer std.log.debug("Co contextEntry coid:{d} exited", .{self.id});
        const schedule = self.schedule;
        defer {
            freeArgs(self);
        }

        self.func(args) catch {
            // std.log.err("contextEntry coid:{d} error:{s}",.{self.id,@errorName(e)});
        };
        schedule.runningCo = null;
        self.state = .STOP;
    }
};
