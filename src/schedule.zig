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
    preempted_buffer: [256]*Co = undefined,
    preempted_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    preempted_tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // 定时器
    timer_id: ?c.timer_t = null,
    timer_started: bool = false,

    threadlocal var localSchedule: ?*Schedule = null;

    // 抢占信号处理器
    fn preemptSigHandler(_: c_int, _: [*c]c.siginfo_t, uctx_ptr: ?*anyopaque) callconv(.C) void {
        const schedule = localSchedule orelse {
            std.log.debug("抢占信号处理器：localSchedule 为空", .{});
            return;
        };
        const co = schedule.runningCo orelse {
            std.log.debug("抢占信号处理器：runningCo 为空", .{});
            return;
        };

        std.log.debug("抢占信号处理器：抢占协程 {}", .{co.id});

        const interrupted_ctx: *c.ucontext_t = @ptrCast(@alignCast(uctx_ptr.?));

        // 保存被中断的上下文
        co.ctx = interrupted_ctx.*;

        // 清除 runningCo
        schedule.runningCo = null;

        // 加入抢占缓冲区（内部有 release 屏障）
        if (!schedule.pushPreempted(co)) {
            // 缓冲区满，不抢占
            std.log.debug("抢占信号处理器：缓冲区满，不抢占", .{});
            // 如果缓冲区满，恢复 runningCo
            schedule.runningCo = co;
            return;
        }

        // 使用 setcontext 切换到调度器
        std.log.debug("抢占信号处理器：切换到调度器", .{});
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
        const _co = self.runningCo orelse return error.NotInCo;
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
        try self.allCoMap.put(co.id, co);
        try self.ResumeCo(co);
        return co;
    }

    fn queueCompare(_: void, a: *Co, b: *Co) std.math.Order {
        return std.math.order(a.priority, b.priority);
    }

    // 抢占缓冲区操作
    fn pushPreempted(self: *Schedule, co: *Co) bool {
        const head = self.preempted_head.load(.monotonic);
        const next_head = (head + 1) % self.preempted_buffer.len;
        const tail = self.preempted_tail.load(.acquire);

        if (next_head == tail) {
            return false; // 缓冲区满，降级处理
        }

        // 写入数据
        self.preempted_buffer[head] = co;

        // 确保数据写入完成后再更新 head（release 语义）
        self.preempted_head.store(next_head, .release);
        return true;
    }

    fn popPreempted(self: *Schedule) ?*Co {
        const tail = self.preempted_tail.load(.monotonic);
        const head = self.preempted_head.load(.acquire); // 同步 push 的 release

        if (tail == head) {
            return null; // 缓冲区空
        }

        const co = self.preempted_buffer[tail];
        const next_tail = (tail + 1) % self.preempted_buffer.len;
        self.preempted_tail.store(next_tail, .release);
        return co;
    }
    fn sleepCo(self: *Schedule, co: *Co) !void {
        try self.sleepQueue.add(co);
    }
    pub fn ResumeCo(self: *Schedule, co: *Co) !void {
        std.log.debug("ResumeCo id:{d}", .{co.id});

        // 检查就绪队列大小，防止内存爆炸
        if (self.readyQueue.count() >= MAX_READY_COUNT) {
            std.log.warn("Ready queue full, dropping coroutine {}", .{co.id});
            return;
        }

        try self.readyQueue.add(co);
    }
    pub fn freeCo(self: *Schedule, co: *Co) void {
        std.log.debug("Schedule freeCo coid:{}", .{co.id});

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
    }
    fn startTimer(self: *Schedule) !void {
        if (self.timer_started) return;

        const timerid = self.timer_id orelse return error.NoTimer;

        // 设置定时器（10ms）
        var its: c.struct_itimerspec = undefined;
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 10 * std.time.ns_per_ms;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 10 * std.time.ns_per_ms;

        if (c.timer_settime(timerid, 0, &its, null) != 0) {
            return error.timer_settime;
        }

        self.timer_started = true;
        std.log.debug("定时器已启动", .{});
    }

    pub fn stop(self: *Schedule) void {
        self.exit = true;
    }
    pub fn loop(self: *Schedule) !void {
        const xLoop = &(self.xLoop orelse unreachable);
        defer {
            xLoop.stop();
            std.log.debug("schedule loop exited", .{});
        }
        while (!self.exit) {
            try xLoop.run(.no_wait);
            self.checkNextCo() catch |e| {
                std.log.err("Schedule loop checkNextCo error:{s}", .{@errorName(e)});
            };
        }
    }
    // 批量处理配置
    const BATCH_SIZE = 32; // 每次处理32个协程
    const MAX_READY_COUNT = 10000; // 最大就绪协程数

    inline fn checkNextCo(self: *Schedule) !void {
        // 先处理被抢占的协程（acquire 屏障确保看到完整数据）
        while (self.popPreempted()) |co| {
            std.log.info("协程 {} 被抢占，重新加入就绪队列", .{co.id});
            co.state = .READY;
            // 不要在这里设置 runningCo = null，因为协程可能还在运行
            try self.readyQueue.add(co);
        }

        // 在第一次调度协程后启动定时器
        // 此时 schedule.ctx 已经被 swapcontext 正确初始化
        if (!self.timer_started and self.readyQueue.count() > 0) {
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
                try cozig.Resume(nextCo);
            }
        } else {
            if (self.xLoop) |*xLoop| {
                // std.log.debug("Schedule no co",.{});
                try xLoop.run(.once);
            } else {
                std.log.err("xLoop is null!", .{});
                return;
            }
        }
    }
};
