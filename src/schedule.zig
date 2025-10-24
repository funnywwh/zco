const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const cozig = @import("./co.zig");
const builtin = @import("builtin");
const xev = @import("xev");
const Co = cozig.Co;
const cfg = @import("./config.zig");

const DEFAULT_ZCO_STACK_SZIE = cfg.DEFAULT_ZCO_STACK_SZIE;

pub const Schedule = struct {
    ctx: Context = std.mem.zeroes(Context),
    runningCo: ?*Co = null,
    sleepQueue: PriorityQueue,
    readyQueue: PriorityQueue,
    allocator: std.mem.Allocator,
    exit: bool = false,
    allCoMap: CoMap,

    tid: usize = 0,

    xLoop: ?xev.Loop = null,

    // 抢占缓冲区
    preempted_buffer: [1024]*Co = undefined,
    preempted_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    preempted_tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // 定时器
    timer_id: ?c.timer_t = null,
    timer_started: bool = false,

    // 性能统计
    preemption_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_switches: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_time: ?std.time.Instant = null,

    threadlocal var localSchedule: ?*Schedule = null;

    // 抢占信号处理器 - 使用关中断方式，彻底解决竞态条件
    fn preemptSigHandler(_: c_int, _: [*c]c.siginfo_t, uctx_ptr: ?*anyopaque) callconv(.C) void {
        const schedule = localSchedule orelse {
            return; // 静默返回，避免日志洪水
        };

        // 立即屏蔽SIGALRM信号，防止嵌套调用
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.sigprocmask(c.SIG_BLOCK, &sigset, &oldset);

        // 在关中断状态下安全地获取runningCo
        const co = schedule.runningCo orelse {
            _ = c.sigprocmask(c.SIG_SETMASK, &oldset, null);
            return;
        };

        // 增加抢占计数（在关中断状态下安全）
        schedule.preemption_count.raw += 1;

        // 检查协程状态，确保它是正在运行的
        if (co.state != .RUNNING) {
            _ = c.sigprocmask(c.SIG_SETMASK, &oldset, null);
            return;
        }

        const interrupted_ctx: *c.ucontext_t = @ptrCast(@alignCast(uctx_ptr.?));

        // 保存被中断的上下文
        co.ctx = interrupted_ctx.*;

        // 清除runningCo
        schedule.runningCo = null;

        // 尝试加入抢占缓冲区
        if (!schedule.pushPreempted(co)) {
            // 缓冲区满，不抢占，恢复runningCo
            schedule.runningCo = co;
            _ = c.sigprocmask(c.SIG_SETMASK, &oldset, null);
            return;
        }

        // 使用 setcontext 切换到调度器
        _ = c.setcontext(&schedule.ctx);
    }

    const CoMap = std.AutoArrayHashMap(usize, *Co);
    const PriorityQueue = std.PriorityQueue(*Co, void, Schedule.queueCompare);
    // const PriorityQueue = ListQueue;

    const ListQueue = struct {
        const List = std.ArrayList(*Co);
        list: List,
        pub fn init(allocator: std.mem.Allocator, _: anytype) ListQueue {
            return .{
                .list = List.init(allocator),
            };
        }
        pub fn deinit(self: *ListQueue) void {
            self.list.deinit();
        }
        pub fn add(self: *ListQueue, co: *Co) !void {
            return self.list.append(co);
        }
        pub fn remove(self: *ListQueue) *Co {
            return self.list.orderedRemove(0);
        }
        pub fn removeIndex(self: *ListQueue, idx: usize) *Co {
            return self.list.orderedRemove(idx);
        }
        pub fn count(self: *ListQueue) usize {
            return self.list.items.len;
        }
        const Iterator = struct {
            list: *ListQueue,
            idx: usize = 0,
            fn next(self: *Iterator) ?*Co {
                if (self.idx >= self.list.list.items.len) {
                    return null;
                }
                const co = self.list.list.items[self.idx];
                self.idx += 1;
                return co;
            }
        };
        pub fn iterator(self: *ListQueue) Iterator {
            return .{
                .list = self,
            };
        }
    };
    pub fn mainInit() !void {}
    pub fn init(allocator: std.mem.Allocator) !*Schedule {
        const schedule = try allocator.create(Schedule);
        schedule.* = .{
            .sleepQueue = PriorityQueue.init(allocator, {}),
            .readyQueue = PriorityQueue.init(allocator, {}),
            .allocator = allocator,
            .allCoMap = CoMap.init(allocator),
        };
        errdefer {
            schedule.deinit();
        }
        schedule.xLoop = try xev.Loop.init(.{
            .entries = 1024 * 4, // 事件循环条目数
        });

        // 注册抢占信号处理器
        var sa: c.struct_sigaction = undefined;
        @memset(@as([*]u8, @ptrCast(&sa))[0..@sizeOf(c.struct_sigaction)], 0);
        sa.__sigaction_handler.sa_sigaction = @ptrCast(&preemptSigHandler);
        sa.sa_flags = c.SA_SIGINFO;
        _ = c.sigemptyset(&sa.sa_mask);

        if (c.sigaction(c.SIGALRM, &sa, null) == -1) {
            return error.sigaction;
        }

        // 创建线程定时器
        var sev: c.struct_sigevent = undefined;
        @memset(@as([*]u8, @ptrCast(&sev))[0..@sizeOf(c.struct_sigevent)], 0);
        sev.sigev_notify = c.SIGEV_THREAD_ID;
        sev.sigev_signo = c.SIGALRM;
        sev._sigev_un._tid = @intCast(std.Thread.getCurrentId());

        var timerid: c.timer_t = undefined;
        if (c.timer_create(c.CLOCK_MONOTONIC, &sev, &timerid) != 0) {
            return error.timer_create;
        }
        schedule.timer_id = timerid;

        // 初始化调度器上下文，确保信号处理器可以安全使用
        if (c.getcontext(&schedule.ctx) != 0) {
            return error.getcontext;
        }

        // 暂时不启动定时器，等到第一次 Resume 之后再启动
        // 这样可以确保 schedule.ctx 已经被正确初始化

        localSchedule = schedule;
        schedule.tid = std.Thread.getCurrentId();
        return schedule;
    }
    pub fn resumeAll(self: *Schedule) !void {
        var it = self.allCoMap.iterator();
        while (it.next()) |kv| {
            const co = kv.value_ptr.*;
            std.log.debug("Schedule resumeAll will resume coid:{d}", .{co.id});
            try cozig.Resume(co);
        }
    }
    pub fn deinit(self: *Schedule) void {
        std.log.debug("Schedule deinit readyQueue count:{}", .{self.readyQueue.count()});
        std.log.debug("Schedule deinit sleepQueue count:{}", .{self.sleepQueue.count()});

        // 停止定时器
        if (self.timer_id) |tid| {
            _ = c.timer_delete(tid);
        }

        self.resumeAll() catch |e| {
            std.log.err("Schedule deinit resumeAll error:{s}", .{@errorName(e)});
        };
        if (self.xLoop) |*xLoop| {
            xLoop.deinit();
            self.xLoop = null;
        }
        self.sleepQueue.deinit();
        self.readyQueue.deinit();
        while (self.allCoMap.pop()) |kv| {
            const co: *Co = kv.value;
            cozig.freeArgs(co);
            self.allocator.destroy(co);
        }
        self.allCoMap.deinit();

        const allocator = self.allocator;
        allocator.destroy(self);
    }
    test "go" {
        const s = Schedule{};
        s.go(struct {
            fn run(_: *Schedule) !void {}
        }.run, (&s));
        try s.loop();
    }
    pub fn getCurrentCo(self: *Schedule) !*Co {
        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        const _co = self.runningCo orelse {
            // 恢复信号屏蔽
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
            return error.NotInCo;
        };

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
        return _co;
    }
    pub fn go(self: *Schedule, comptime func: anytype, args: anytype) !*Co {
        const allocator = self.allocator;
        const co = try allocator.create(Co);
        errdefer allocator.destroy(co);
        const FuncType = @TypeOf(func);
        const FuncArgsTupleType = @TypeOf(args);
        const WrapArgs = struct {
            func: *const FuncType,
            args: FuncArgsTupleType,
            allocator: std.mem.Allocator,
        };
        const wrapArgs = try allocator.create(WrapArgs);
        errdefer allocator.destroy(wrapArgs);

        wrapArgs.args = args;
        wrapArgs.func = &func;
        wrapArgs.allocator = allocator;

        co.* = .{
            .args = wrapArgs,
            .argsFreeFunc = struct {
                fn free(_co: *Co, p: *anyopaque) void {
                    const _args: *WrapArgs = @alignCast(@ptrCast(p));
                    const _allocator = _co.schedule.allocator;
                    _allocator.destroy(_args);
                }
            }.free,
            .func = &struct {
                fn run(_argsTupleOpt: ?*anyopaque) !void {
                    const _argsTuple: *WrapArgs = @alignCast(@ptrCast(_argsTupleOpt orelse unreachable));
                    @call(.auto, _argsTuple.func, _argsTuple.args) catch |err| {
                        std.log.debug("schedule wrap func error:{any}", .{err});
                    };
                }
            }.run,
            .id = Co.nextId,
            .schedule = self,
        };
        Co.nextId +%= 1;

        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        try self.allCoMap.put(co.id, co);

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);

        try self.ResumeCo(co);
        return co;
    }

    fn queueCompare(_: void, a: *Co, b: *Co) std.math.Order {
        return std.math.order(a.priority, b.priority);
    }

    // 抢占缓冲区操作 - 使用关中断方式
    fn pushPreempted(self: *Schedule, co: *Co) bool {
        // 在关中断状态下安全地操作缓冲区
        const head = self.preempted_head.raw;
        const next_head = (head + 1) % self.preempted_buffer.len;
        const tail = self.preempted_tail.raw;

        if (next_head == tail) {
            return false; // 缓冲区满，降级处理
        }

        // 再次检查协程状态，确保它仍然是运行状态
        if (co.state != .RUNNING) {
            return false; // 协程状态已改变，不进行抢占
        }

        // 写入数据
        self.preempted_buffer[head] = co;

        // 更新 head
        self.preempted_head.raw = next_head;
        return true;
    }

    fn popPreempted(self: *Schedule) ?*Co {
        // 在关中断状态下安全地操作缓冲区
        const tail = self.preempted_tail.raw;
        const head = self.preempted_head.raw;

        if (tail == head) {
            return null; // 缓冲区空
        }

        const co = self.preempted_buffer[tail];
        const next_tail = (tail + 1) % self.preempted_buffer.len;
        self.preempted_tail.raw = next_tail;
        return co;
    }
    fn sleepCo(self: *Schedule, co: *Co) !void {
        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        try self.sleepQueue.add(co);

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
    }
    pub fn ResumeCo(self: *Schedule, co: *Co) !void {
        std.log.debug("ResumeCo id:{d}", .{co.id});

        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        // 检查就绪队列大小，防止内存爆炸
        const currentCount = self.readyQueue.count();
        if (currentCount >= MAX_READY_COUNT) {
            std.log.warn("Ready queue full ({}), dropping coroutine {}", .{ currentCount, co.id });
            // 恢复信号屏蔽
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
            return;
        }

        // 当队列接近满时发出警告
        if (currentCount >= MAX_READY_COUNT * 0.8) {
            std.log.warn("Ready queue nearly full: {}/{}", .{ currentCount, MAX_READY_COUNT });
        }

        try self.readyQueue.add(co);

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
    }
    pub fn freeCo(self: *Schedule, co: *Co) void {
        std.log.debug("Schedule freeCo coid:{}", .{co.id});

        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        // 优化：使用更高效的查找方式
        // 从睡眠队列中移除
        var sleepIt = self.sleepQueue.iterator();
        var i: usize = 0;
        while (sleepIt.next()) |_co| {
            if (_co == co) {
                _ = self.sleepQueue.removeIndex(i);
                break;
            }
            i +|= 1;
        }

        // 从就绪队列中移除
        var readyIt = self.readyQueue.iterator();
        i = 0;
        while (readyIt.next()) |_co| {
            if (_co == co) {
                std.log.debug("Schedule freed ready coid:{}", .{co.id});
                _ = self.readyQueue.removeIndex(i);
                break;
            }
            i +|= 1;
        }

        // 从协程映射中移除并销毁
        if (self.allCoMap.get(co.id)) |_| {
            std.log.debug("Schedule destroy coid:{} co:{*}", .{ co.id, co });
            _ = self.allCoMap.swapRemove(co.id);
            cozig.freeArgs(co);
            self.allocator.destroy(co);
        }

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
    }
    fn startTimer(self: *Schedule) !void {
        if (self.timer_started) return;

        const timerid = self.timer_id orelse return error.NoTimer;

        // 设置定时器（10ms，平衡性能和公平性）
        var its: c.struct_itimerspec = undefined;
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 10 * std.time.ns_per_ms; // 10ms
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 10 * std.time.ns_per_ms; // 10ms

        if (c.timer_settime(timerid, 0, &its, null) != 0) {
            return error.timer_settime;
        }

        self.timer_started = true;
        std.log.debug("定时器已启动 (10ms)", .{});
    }

    pub fn stop(self: *Schedule) void {
        self.exit = true;
    }

    pub fn printStats(self: *Schedule) void {
        const preemptions = self.preemption_count.raw;
        const switches = self.total_switches.raw;

        std.log.info("=== 调度器性能统计 ===", .{});
        std.log.info("总切换次数: {}", .{switches});
        std.log.info("抢占次数: {}", .{preemptions});
        if (switches > 0) {
            const preemption_rate = @as(f64, @floatFromInt(preemptions)) / @as(f64, @floatFromInt(switches)) * 100.0;
            std.log.info("抢占率: {d:.2}%", .{preemption_rate});
        } else {
            std.log.info("抢占率: 0.00% (无切换)", .{});
        }

        if (self.start_time) |start| {
            const now = std.time.Instant.now() catch return;
            const elapsed = now.since(start);
            const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
            std.log.info("运行时间: {d:.2}ms", .{elapsed_ms});
            if (elapsed_ms > 0) {
                const switches_per_ms = @as(f64, @floatFromInt(switches)) / elapsed_ms;
                std.log.info("切换频率: {d:.2} 次/ms", .{switches_per_ms});
            }
        }
        std.log.info("===================", .{});
    }
    pub fn loop(self: *Schedule) !void {
        const xLoop = &(self.xLoop orelse unreachable);
        defer {
            xLoop.stop();
            std.log.debug("schedule loop exited", .{});
        }

        // 记录开始时间
        self.start_time = try std.time.Instant.now();

        while (!self.exit) {
            try xLoop.run(.no_wait);
            self.checkNextCo() catch |e| {
                std.log.err("Schedule loop checkNextCo error:{s}", .{@errorName(e)});
            };
        }
    }
    // 批量处理配置
    const BATCH_SIZE = 32; // 每次处理32个协程
    const MAX_READY_COUNT = 100000; // 最大就绪协程数，增加到10万

    inline fn checkNextCo(self: *Schedule) !void {
        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        // 先处理被抢占的协程（acquire 屏障确保看到完整数据）
        while (self.popPreempted()) |co| {
            std.log.info("协程 {} 被抢占，重新加入就绪队列", .{co.id});
            co.state = .READY;
            // 不要在这里设置 runningCo = null，因为协程可能还在运行
            try self.readyQueue.add(co);
        }

        // 在第一次调度协程后启动定时器
        // 此时 schedule.ctx 已经被 swapcontext 正确初始化
        // 只有在有多个协程时才启动抢占，避免不必要的开销
        if (!self.timer_started and self.readyQueue.count() > 1) {
            try self.startTimer();
        }

        const count = self.readyQueue.count();
        if (builtin.mode == .Debug) {
            if (count > 0) {
                std.log.debug("checkNextCo begin, ready count:{}", .{count});
            }
        }

        if (count > 0) {
            // 批量处理协程，提高调度效率
            const processCount = @min(count, BATCH_SIZE);
            for (0..processCount) |_| {
                const nextCo = self.readyQueue.remove();
                std.log.debug("coid:{d} will running readyQueue.count:{d}", .{ nextCo.id, self.readyQueue.count() });

                // 恢复信号屏蔽，让 Resume 函数自己处理信号屏蔽
                _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);

                try cozig.Resume(nextCo);

                // 重新屏蔽信号，继续处理下一个协程
                _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);
            }
        } else {
            // 恢复信号屏蔽
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);

            if (self.xLoop) |*xLoop| {
                // std.log.debug("Schedule no co",.{});
                try xLoop.run(.once);
            } else {
                std.log.err("xLoop is null!", .{});
                return;
            }
        }

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
    }
};
