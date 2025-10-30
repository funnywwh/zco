const std = @import("std");
const c = @import("./c.zig");
const xev = @import("xev");
const Context = c.ucontext_t;
const schedule_mod = @import("./schedule.zig");
const Schedule = schedule_mod.Schedule;
const root = @import("root");
const builtin = @import("builtin");

const cfg = @import("./config.zig");
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
    switch (self.state) {
        .INITED => {
            if (c.getcontext(&self.ctx) != 0) {
                return error.getcontext;
            }
            self.ctx.uc_stack.ss_sp = &self.stack;
            self.ctx.uc_stack.ss_size = self.stack.len;
            self.ctx.uc_flags = 0;
            self.ctx.uc_link = &schedule.ctx;
            c.makecontext(&self.ctx, @ptrCast(&Co.contextEntry), 1, self);

            // === 关键区开始：屏蔽信号 ===
            var oldset: c.sigset_t = undefined;
            schedule_mod.blockPreemptSignals(&oldset);

            // 在关中断状态下安全地设置协程状态和runningCo
            self.state = .RUNNING;
            schedule.runningCo = self;

            // 增加切换计数（在关中断状态下安全）
            schedule.total_switches.raw += 1;
            // 恢复信号
            schedule_mod.restoreSignals(&oldset);
            // === 关键区结束 ===

            // 启动定时器（在协程开始运行前，重置计时）
            schedule.startTimer() catch |e| {
                std.log.err("启动定时器失败: {s}", .{@errorName(e)});
            };

            // swapcontext 不会返回，所以不需要恢复信号屏蔽
            // 信号屏蔽会在协程被抢占时由信号处理器处理
            const swap_result = c.swapcontext(&schedule.ctx, &self.ctx);

            // 这里永远不会执行到，因为 swapcontext 不会返回
            if (swap_result != 0) return error.swapcontext;
        },
        .SUSPEND, .READY => {

            // === 关键区开始：屏蔽信号 ===
            var oldset: c.sigset_t = undefined;
            schedule_mod.blockPreemptSignals(&oldset);

            // 在关中断状态下安全地设置协程状态和runningCo
            self.state = .RUNNING;
            schedule.runningCo = self;

            // 增加切换计数（在关中断状态下安全）
            schedule.total_switches.raw += 1;
            // 恢复信号
            schedule_mod.restoreSignals(&oldset);
            // === 关键区结束 ===

            // 启动定时器（在协程开始运行前，重置计时）
            schedule.startTimer() catch |e| {
                std.log.err("启动定时器失败: {s}", .{@errorName(e)});
            };

            // swapcontext 不会返回，所以不需要恢复信号屏蔽
            // 信号屏蔽会在协程被抢占时由信号处理器处理
            const swap_result = c.swapcontext(&schedule.ctx, &self.ctx);

            // 这里永远不会执行到，因为 swapcontext 不会返回
            if (swap_result != 0) return error.swapcontext;
        },
        else => {},
    }
    if (self.state == .STOP) {
        schedule.freeCo(self);
    }
}

pub const Co = struct {
    const Self = @This();
    
    // 协程ID - 8字节对齐
    id: usize align(8) = 0,
    
    // 协程上下文 - 16字节对齐
    ctx: Context align(16) = std.mem.zeroes(Context),
    
    // 协程函数 - 8字节对齐
    func: Func align(8) = undefined,
    
    // 协程参数 - 8字节对齐
    args: ?*anyopaque align(8) = null,
    argsFreeFunc: *const fn (*Co, *anyopaque) void align(8),
    
    // 协程状态 - 8字节对齐
    state: State align(8) = .INITED,
    priority: usize align(8) = 0,
    
    // 调度器引用 - 8字节对齐
    schedule: *Schedule align(8) = undefined,
    
    // 协程栈 - 16字节对齐
    stack: [DEFAULT_ZCO_STACK_SZIE]u8 align(16) = std.mem.zeroes([DEFAULT_ZCO_STACK_SZIE]u8),
    
    // 唤醒时间戳 - 8字节对齐
    wakeupTimestampNs: usize align(8) = 0, //纳秒
    
    // 内存对齐填充
    _padding: [8]u8 align(8) = std.mem.zeroes([8]u8),
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
            if (self.schedule.exit) {
                return error.ScheduleExited;
            }

            // === 关键区开始：屏蔽信号 ===
            var oldset: c.sigset_t = undefined;
            schedule_mod.blockPreemptSignals(&oldset);

            // 在关中断状态下安全地设置协程状态和runningCo
            co.state = .SUSPEND;
            // 停止定时器（协程挂起时）
            self.schedule.stopTimer();
            self.schedule.runningCo = null;
            // 恢复信号
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
            // === 关键区结束 ===

            const swap_result = c.swapcontext(&co.ctx, &schedule.ctx);

            if (swap_result != 0) return error.swapcontext;

            if (self.schedule.exit) {
                return error.ScheduleExited;
            }
            return;
        }
        std.log.err("Co Suspend RunningCoNull", .{});
        return error.RunningCoNull;
    }
    pub fn Resume(self: *Co) !void {
        if (self.schedule.exit) {
            return error.ScheduleExited;
        }
        try self.schedule.ResumeCo(self);
    }

    pub fn Sleep(self: *Self, ns: usize) !void {
        const ms = ns / std.time.ns_per_ms;
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
        const schedule = self.schedule;

        self.func(args) catch {
            // std.log.err("contextEntry coid:{d} error:{s}",.{self.id,@errorName(e)});
        };

        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        // 在关中断状态下安全地设置协程状态和runningCo
        // 协程结束时，定时器由调度器管理，不需要在这里停止
        schedule.runningCo = null;
        self.state = .STOP;

            // === 关键区结束：恢复信号屏蔽 ===
            schedule_mod.restoreSignals(&oldset);
    }
};
