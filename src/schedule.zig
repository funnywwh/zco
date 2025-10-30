const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const cozig = @import("./co.zig");
const builtin = @import("builtin");
const xev = @import("xev");
const Co = cozig.Co;
const cfg = @import("./config.zig");

const DEFAULT_ZCO_STACK_SZIE = cfg.DEFAULT_ZCO_STACK_SZIE;

// 环形缓冲区+优先级位图配置
const RING_BUFFER_SIZE = cfg.RING_BUFFER_SIZE;
const MAX_PRIORITY_LEVELS = cfg.MAX_PRIORITY_LEVELS;

// 线程专用定时器配置
// 使用 CLOCK_MONOTONIC 以便等待时也继续计时
const CLOCK_MONOTONIC = if (@hasDecl(c, "CLOCK_MONOTONIC"))
    c.CLOCK_MONOTONIC
else
    1; // Linux中 CLOCK_MONOTONIC 的值

// 使用 SIGEV_THREAD_ID 让信号只发给特定线程
const SIGEV_THREAD_ID = if (@hasDecl(c, "SIGEV_THREAD_ID"))
    c.SIGEV_THREAD_ID
else
    4; // Linux中 SIGEV_THREAD_ID 的值

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

// 环形缓冲区+优先级位图队列
const RingBufferPriorityQueue = struct {
    const RingBuffer = struct {
        buffer: []?*Co,
        head: usize,
        tail: usize,
        count: usize,

        pub fn init(allocator: std.mem.Allocator) !RingBuffer {
            const buffer = try allocator.alloc(?*Co, RING_BUFFER_SIZE);
            // 初始化为null
            for (0..RING_BUFFER_SIZE) |i| {
                buffer[i] = null;
            }
            return RingBuffer{
                .buffer = buffer,
                .head = 0,
                .tail = 0,
                .count = 0,
            };
        }

        pub fn deinit(self: *RingBuffer, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn add(self: *RingBuffer, co: *Co) !void {
            if (self.count >= RING_BUFFER_SIZE) {
                return error.RingBufferFull;
            }
            self.buffer[self.tail] = co;
            self.tail = (self.tail + 1) % RING_BUFFER_SIZE;
            self.count += 1;
        }

        pub fn remove(self: *RingBuffer) ?*Co {
            if (self.count == 0) {
                return null;
            }
            const co = self.buffer[self.head] orelse return null;
            self.buffer[self.head] = null;
            self.head = (self.head + 1) % RING_BUFFER_SIZE;
            self.count -= 1;
            return co;
        }

        pub fn isEmpty(self: *const RingBuffer) bool {
            return self.count == 0;
        }

        pub fn isFull(self: *const RingBuffer) bool {
            return self.count >= RING_BUFFER_SIZE;
        }
    };

    // 环形缓冲区数组
    rings: [MAX_PRIORITY_LEVELS]RingBuffer,

    // 优先级位图 (32位，每位表示一个优先级级别是否有协程)
    priority_bitmap: u32,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !RingBufferPriorityQueue {
        var queue = RingBufferPriorityQueue{
            .rings = undefined,
            .priority_bitmap = 0,
            .allocator = allocator,
        };

        // 初始化所有优先级的环形缓冲区
        for (0..MAX_PRIORITY_LEVELS) |i| {
            queue.rings[i] = try RingBuffer.init(allocator);
        }

        return queue;
    }

    pub fn deinit(self: *RingBufferPriorityQueue) void {
        for (0..MAX_PRIORITY_LEVELS) |i| {
            self.rings[i].deinit(self.allocator);
        }
    }

    pub fn add(self: *RingBufferPriorityQueue, co: *Co) !void {
        const priority = @min(co.priority, MAX_PRIORITY_LEVELS - 1);
        try self.rings[priority].add(co);

        // 设置对应优先级的位图位
        self.priority_bitmap |= (@as(u32, 1) << @intCast(priority));
    }

    pub fn remove(self: *RingBufferPriorityQueue) ?*Co {
        if (self.priority_bitmap == 0) {
            return null;
        }

        // 使用 @clz() 快速找到最高优先级位 (O(1))
        const highest_priority = 31 - @clz(self.priority_bitmap);

        // 从对应环形缓冲区头部取出协程
        const co = self.rings[highest_priority].remove();

        // 如果该优先级队列为空，清除位图位
        if (self.rings[highest_priority].isEmpty()) {
            self.priority_bitmap &= ~(@as(u32, 1) << @intCast(highest_priority));
        }

        return co;
    }

    pub fn count(self: *const RingBufferPriorityQueue) usize {
        var total: usize = 0;
        for (0..MAX_PRIORITY_LEVELS) |i| {
            total += self.rings[i].count;
        }
        return total;
    }

    pub fn isEmpty(self: *const RingBufferPriorityQueue) bool {
        return self.priority_bitmap == 0;
    }

    // 获取指定优先级的协程数量
    pub fn getPriorityCount(self: *const RingBufferPriorityQueue, priority: usize) usize {
        if (priority >= MAX_PRIORITY_LEVELS) return 0;
        return self.rings[priority].count;
    }

    // 获取当前最高优先级
    pub fn getHighestPriority(self: *const RingBufferPriorityQueue) ?usize {
        if (self.priority_bitmap == 0) return null;
        return 31 - @clz(self.priority_bitmap);
    }

    // 迭代器支持（为了兼容现有代码）
    const Iterator = struct {
        queue: *RingBufferPriorityQueue,
        current_priority: usize = 0,
        current_index: usize = 0,

        fn next(self: *Iterator) ?*Co {
            // 找到下一个有协程的优先级
            while (self.current_priority < MAX_PRIORITY_LEVELS) {
                const ring = &self.queue.rings[self.current_priority];
                if (self.current_index < ring.count) {
                    const buffer_index = (ring.head + self.current_index) % RING_BUFFER_SIZE;
                    const co = ring.buffer[buffer_index];
                    self.current_index += 1;
                    return co;
                } else {
                    self.current_priority += 1;
                    self.current_index = 0;
                }
            }
            return null;
        }
    };

    pub fn iterator(self: *RingBufferPriorityQueue) Iterator {
        return Iterator{
            .queue = self,
            .current_priority = 0,
            .current_index = 0,
        };
    }

    // 移除指定索引的协程（为了兼容现有代码）
    // 注意：这个方法效率不高，因为需要遍历所有优先级
    pub fn removeIndex(self: *RingBufferPriorityQueue, idx: usize) ?*Co {
        var current_idx: usize = 0;

        for (0..MAX_PRIORITY_LEVELS) |priority| {
            const ring = &self.rings[priority];
            if (current_idx + ring.count > idx) {
                // 目标协程在这个优先级的环形缓冲区中
                const local_idx = idx - current_idx;
                const buffer_idx = (ring.head + local_idx) % RING_BUFFER_SIZE;
                const co = ring.buffer[buffer_idx];

                if (co) |found_co| {
                    // 移除协程（将后面的协程前移）
                    var i = local_idx;
                    while (i < ring.count - 1) {
                        const current_buffer_idx = (ring.head + i) % RING_BUFFER_SIZE;
                        const next_buffer_idx = (ring.head + i + 1) % RING_BUFFER_SIZE;
                        ring.buffer[current_buffer_idx] = ring.buffer[next_buffer_idx];
                        i += 1;
                    }

                    // 清除最后一个位置
                    const last_buffer_idx = (ring.head + ring.count - 1) % RING_BUFFER_SIZE;
                    ring.buffer[last_buffer_idx] = null;
                    ring.count -= 1;

                    // 如果该优先级队列为空，清除位图位
                    if (ring.isEmpty()) {
                        self.priority_bitmap &= ~(@as(u32, 1) << @intCast(priority));
                    }

                    return found_co;
                }
            }
            current_idx += ring.count;
        }

        return null;
    }
};

pub const Schedule = struct {
    ctx: Context = std.mem.zeroes(Context),
    runningCo: ?*Co = null,
    sleepQueue: PriorityQueue,
    readyQueue: RingBufferPriorityQueue,
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
            .readyQueue = try RingBufferPriorityQueue.init(allocator),
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

        localSchedule = schedule;
        schedule.tid = std.Thread.getCurrentId();

        // 创建线程专用定时器
        // 使用 CLOCK_MONOTONIC 以便等待时也继续计时
        // 使用 SIGEV_THREAD_ID 让信号只发给当前线程
        var sev: c.struct_sigevent = undefined;
        @memset(@as([*]u8, @ptrCast(&sev))[0..@sizeOf(c.struct_sigevent)], 0);

        // 获取当前线程的系统TID（用于SIGEV_THREAD_ID）
        const tid = c.syscall(c.SYS_gettid);

        sev.sigev_notify = SIGEV_THREAD_ID;
        sev.sigev_signo = c.SIGALRM;
        // SIGEV_THREAD_ID 需要设置 _sigev_un._tid 字段为线程的系统TID
        // 这是 Linux 特定的结构体字段访问方式
        sev._sigev_un._tid = @intCast(tid);

        var timerid: c.timer_t = undefined;
        if (c.timer_create(CLOCK_MONOTONIC, &sev, &timerid) != 0) {
            return error.timer_create;
        }
        schedule.timer_id = timerid;

        // 初始化调度器上下文，确保信号处理器可以安全使用
        if (c.getcontext(&schedule.ctx) != 0) {
            return error.getcontext;
        }

        // 暂时不启动定时器，等到第一次 Resume 之后再启动
        // 这样可以确保 schedule.ctx 已经被正确初始化
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
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

        const _co = self.runningCo orelse {
            // 恢复信号屏蔽
            restoreSignals(&oldset);
            return error.NotInCo;
        };

        // === 关键区结束：恢复信号屏蔽 ===
        restoreSignals(&oldset);
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
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

        try self.allCoMap.put(co.id, co);

        // === 关键区结束：恢复信号屏蔽 ===
        restoreSignals(&oldset);

        try self.ResumeCo(co);
        return co;
    }

    // 带优先级的协程创建方法
    pub fn goWithPriority(self: *Schedule, comptime func: anytype, args: anytype, priority: usize) !*Co {
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
            .priority = priority,
        };
        Co.nextId +%= 1;

        // === 关键区开始：屏蔽信号 ===
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

        try self.allCoMap.put(co.id, co);

        // === 关键区结束：恢复信号屏蔽 ===
        restoreSignals(&oldset);

        try self.ResumeCo(co);
        return co;
    }

    fn queueCompare(_: void, a: *Co, b: *Co) std.math.Order {
        return std.math.order(a.priority, b.priority);
    }

    // 抢占缓冲区操作 - 使用关中断方式
    fn sleepCo(self: *Schedule, co: *Co) !void {
        // === 关键区开始：屏蔽信号 ===
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

        try self.sleepQueue.add(co);

        // === 关键区结束：恢复信号屏蔽 ===
        restoreSignals(&oldset);
    }
    pub fn ResumeCo(self: *Schedule, co: *Co) !void {

        // === 关键区开始：屏蔽信号 ===
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

        // 检查就绪队列大小，防止内存爆炸
        const currentCount = self.readyQueue.count();
        if (currentCount >= MAX_READY_COUNT) {
            std.log.warn("Ready queue full ({}), dropping coroutine {}", .{ currentCount, co.id });
            // 恢复信号屏蔽
            restoreSignals(&oldset);
            return;
        }

        // 当队列接近满时发出警告
        if (currentCount >= MAX_READY_COUNT * 0.8) {
            std.log.warn("Ready queue nearly full: {}/{}", .{ currentCount, MAX_READY_COUNT });
        }

        try self.readyQueue.add(co);

        // === 关键区结束：恢复信号屏蔽 ===
        restoreSignals(&oldset);
    }
    pub fn freeCo(self: *Schedule, co: *Co) void {

        // === 关键区开始：屏蔽信号 ===
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

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
        restoreSignals(&oldset);
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
        var oldset: c.sigset_t = undefined;
        blockPreemptSignals(&oldset);

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
            restoreSignals(&oldset); // 恢复信号屏蔽

            for (0..processCount) |_| {
                const nextCo = self.readyQueue.remove();
                if (nextCo) |co| {
                    try cozig.Resume(co);
                } else {
                    break; // 队列为空，停止处理
                }
            }

            blockPreemptSignals(&oldset); // 重新屏蔽信号
        } else {
            // 恢复信号屏蔽
            restoreSignals(&oldset);

            if (self.xLoop) |*xLoop| {
                try xLoop.run(.once);
            } else {
                std.log.err("xLoop is null!", .{});
                return;
            }
        }

        // === 关键区结束：恢复信号屏蔽 ===
        restoreSignals(&oldset);
    }
};

// 信号屏蔽/恢复工具函数（针对 SIGALRM 的抢占信号）
pub inline fn blockPreemptSignals(oldset: *c.sigset_t) void {
    var sigset: c.sigset_t = undefined;
    _ = c.sigemptyset(&sigset);
    _ = c.sigaddset(&sigset, c.SIGALRM);
    _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, oldset);
}

pub inline fn restoreSignals(oldset: *const c.sigset_t) void {
    _ = c.pthread_sigmask(c.SIG_SETMASK, oldset, null);
}
