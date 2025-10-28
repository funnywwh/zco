const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const cozig = @import("./co.zig");
const builtin = @import("builtin");
const xev = @import("xev");
const Co = cozig.Co;
const cfg = @import("./config.zig");

const DEFAULT_ZCO_STACK_SZIE = cfg.DEFAULT_ZCO_STACK_SZIE;

// 协程池配置
const CO_POOL_SIZE = 500; // 协程池大小

// 内存池配置
const MEMORY_POOL_SIZE = 1000; // 内存池大小
const MEMORY_POOL_BLOCK_SIZE = 1024; // 内存块大小

// 协程池结构
const CoPool = struct {
    co_list: [CO_POOL_SIZE]*Co,
    free_co_list: std.ArrayList(usize),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !CoPool {
        var pool = CoPool{
            .co_list = undefined,
            .free_co_list = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
        
        // 预分配协程
        for (0..CO_POOL_SIZE) |i| {
            pool.co_list[i] = try allocator.create(Co);
            try pool.free_co_list.append(i);
        }
        
        return pool;
    }
    
    pub fn deinit(self: *CoPool) void {
        for (0..CO_POOL_SIZE) |i| {
            self.allocator.destroy(self.co_list[i]);
        }
        self.free_co_list.deinit();
    }
    
    pub fn alloc(self: *CoPool) ?*Co {
        if (self.free_co_list.items.len == 0) return null;
        const index = self.free_co_list.pop();
        return self.co_list[index];
    }
    
    pub fn free(self: *CoPool, co: *Co) void {
        for (0..CO_POOL_SIZE) |i| {
            if (self.co_list[i] == co) {
                self.free_co_list.append(i) catch return;
                break;
            }
        }
    }
};

// 内存池结构
const MemoryPool = struct {
    blocks: [MEMORY_POOL_SIZE][]u8,
    free_blocks: std.ArrayList(usize),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !MemoryPool {
        var pool = MemoryPool{
            .blocks = undefined,
            .free_blocks = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
        
        // 预分配内存块
        for (0..MEMORY_POOL_SIZE) |i| {
            pool.blocks[i] = try allocator.alloc(u8, MEMORY_POOL_BLOCK_SIZE);
            try pool.free_blocks.append(i);
        }
        
        return pool;
    }
    
    pub fn deinit(self: *MemoryPool) void {
        for (0..MEMORY_POOL_SIZE) |i| {
            self.allocator.free(self.blocks[i]);
        }
        self.free_blocks.deinit();
    }
    
    pub fn alloc(self: *MemoryPool) ?[]u8 {
        if (self.free_blocks.items.len == 0) return null;
        const index = self.free_blocks.pop();
        return self.blocks[index];
    }
    
    pub fn free(self: *MemoryPool, block: []u8) void {
        for (0..MEMORY_POOL_SIZE) |i| {
            if (self.blocks[i].ptr == block.ptr) {
                self.free_blocks.append(i) catch return;
                break;
            }
        }
    }
};

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
    memoryPool: MemoryPool, // 内存池
    coPool: CoPool, // 协程池

    // 定时器
    timer_id: ?c.timer_t = null,

    // 性能统计
    preemption_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_switches: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_time: ?std.time.Instant = null,

    var localSchedule: ?*Schedule = null;

    // 信号处理函数 - 在被中断协程的上下文中执行
    fn signalHandler() callconv(.C) void {
        const schedule = localSchedule orelse return;

        // 获取当前协程
        const co = schedule.getCurrentCo() catch return;

        // 使用Suspend进行抢占处理
        co.Suspend() catch return;

        // 这里不会执行到，因为 Suspend 不会返回
    }

    // 抢占信号处理器 - 使用关中断方式，彻底解决竞态条件
    fn preemptSigHandler(_: c_int, _: [*c]c.siginfo_t, uctx_ptr: ?*anyopaque) callconv(.C) void {
        _ = uctx_ptr;
        const schedule = localSchedule orelse return;

        // 在关中断状态下安全地获取runningCo
        const co = schedule.runningCo orelse {
            // _ = c.sigprocmask(c.SIG_SETMASK, &oldset, null);
            return;
        };

        // 增加抢占计数（在关中断状态下安全）
        schedule.preemption_count.raw += 1;

        co.Resume() catch return;
        co.Suspend() catch return;
    }

    const CoMap = std.AutoArrayHashMap(usize, *Co);
    // const PriorityQueue = std.PriorityQueue(*Co, void, Schedule.queueCompare);
    const PriorityQueue = ListQueue; // 使用ListQueue获得O(1)插入性能

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
            .memoryPool = try MemoryPool.init(allocator),
            .coPool = try CoPool.init(allocator),
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
        sev.sigev_notify = c.SIGEV_SIGNAL;
        sev.sigev_signo = c.SIGALRM;

        var timerid: c.timer_t = undefined;
        if (c.timer_create(c.CLOCK_REALTIME, &sev, &timerid) != 0) {
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
            try cozig.Resume(co);
        }
    }
    pub fn deinit(self: *Schedule) void {

        // 停止定时器
        if (self.timer_id) |tid| {
            _ = c.timer_delete(tid);
        }

        self.resumeAll() catch |e| {
            std.log.err("Schedule deinit resumeAll error:{s}", .{@errorName(e)});
        };
        
        // 清理内存池
        self.memoryPool.deinit();
        
        // 清理协程池
        self.coPool.deinit();
        
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
                    _ = @call(.auto, _argsTuple.func, _argsTuple.args) catch |err| {
                        // EOF错误是正常的网络连接关闭，不需要记录为错误
                        if (err != error.EOF) {
                            std.log.err("schedule wrap func error: {any}", .{err});
                        }
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
                _ = self.readyQueue.removeIndex(i);
                break;
            }
            i +|= 1;
        }

        // 从协程映射中移除并销毁
        if (self.allCoMap.get(co.id)) |_| {
            _ = self.allCoMap.swapRemove(co.id);
            cozig.freeArgs(co);
            self.allocator.destroy(co);
        }

        // === 关键区结束：恢复信号屏蔽 ===
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
    }
    pub fn startTimer(self: *Schedule) !void {
        const timerid = self.timer_id orelse return error.NoTimer;

        // 设置定时器（10ms，平衡性能和公平性）
        // 每次都重置定时器，确保协程获得完整时间片
        var its: c.struct_itimerspec = undefined;
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 10 * std.time.ns_per_ms; // 10ms
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 10 * std.time.ns_per_ms; // 10ms

        if (c.timer_settime(timerid, 0, &its, null) != 0) {
            return error.timer_settime;
        }
    }

    pub fn stopTimer(self: *Schedule) void {
        const timerid = self.timer_id orelse return;

        // 停止定时器：将 it_value 和 it_interval 都设置为0
        var its: c.struct_itimerspec = undefined;
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 0;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 0;

        _ = c.timer_settime(timerid, 0, &its, null);
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
    // 批量处理配置 - 动态调整
    const BATCH_SIZE_MIN = 16; // 最小批处理大小
    const BATCH_SIZE_MAX = 128; // 最大批处理大小
    const MAX_READY_COUNT = 200000; // 最大就绪协程数，增加到20万

    // 根据队列长度动态确定批处理大小
    fn getBatchSize(queue_len: usize) usize {
        return if (queue_len < 100)
            BATCH_SIZE_MIN // 队列短，小批量处理
        else if (queue_len < 500)
            32 // 中等队列
        else if (queue_len < 1000)
            64 // 较大队列
        else
            BATCH_SIZE_MAX; // 队列很长，大批量处理
    }

    inline fn checkNextCo(self: *Schedule) !void {
        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);

        // 定时器现在完全由协程 Resume/Suspend 控制
        // 不再需要在这里管理定时器状态

        const count = self.readyQueue.count();
        if (builtin.mode == .Debug) {
            if (count > 0) {}
        }

        if (count > 0) {
            // 动态调整批处理大小，根据队列长度优化调度效率
            const batch_size = getBatchSize(count);
            const processCount = @min(count, batch_size);
            
            // 批量处理：只在开始时恢复信号屏蔽，结束时重新屏蔽
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null); // 恢复信号屏蔽
            
            for (0..processCount) |_| {
                const nextCo = self.readyQueue.remove();
                try cozig.Resume(nextCo);
            }
            
            _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset); // 重新屏蔽信号
        } else {
            // 恢复信号屏蔽
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);

            if (self.xLoop) |*xLoop| {
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
