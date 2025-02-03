const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const cozig = @import("./co.zig");
const SwitchTimer = @import("./switch_timer.zig").SwitchTimer;
const builtin = @import("builtin");
const xev = @import("xev");
const Co = cozig.Co;

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

    threadlocal var localSchedule: ?*Schedule = null;

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
            .entries = 1024 * 4,
        });

        var sa = c.struct_sigaction{};
        sa.__sigaction_handler.sa_sigaction = @ptrCast(&user2SigHandler);
        sa.sa_flags = 0;
        _ = c.sigemptyset(&sa.sa_mask);
        _ = c.sigaddset(&sa.sa_mask, SwitchTimer.SIGNO);
        if (c.sigaction(SwitchTimer.SIGNO, &sa, null) == -1) {
            return error.sigaction;
        }
        var set = c.sigset_t{};
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set, SwitchTimer.SIGNO);
        _ = c.pthread_sigmask(c.SIG_UNBLOCK, &set, null);

        localSchedule = schedule;
        schedule.tid = std.Thread.getCurrentId();
        try SwitchTimer.addSchedule(schedule);
        return schedule;
    }
    fn user2SigHandler(_: c_int, siginfo: [*c]c.siginfo_t, ctx: *c.ucontext_t) void {
        _ = ctx; // autofix
        _ = siginfo; // autofix
        const schedule: *Schedule = localSchedule orelse {
            std.log.err("Schedule user2SigHandler localSchedule == null", .{});
            return;
        };
        std.log.err("Schedule user2SigHandler tid:{d}", .{schedule.tid});
        if (schedule.runningCo) |co| {
            schedule.ResumeCo(co) catch |e| {
                std.log.err("Schedule user2SigHandler ResumeCo error:{s}", .{@errorName(e)});
                return;
            };
            co.state = .SUSPEND;
            schedule.runningCo = null;
            _ = c.setcontext(&schedule.ctx);
            cozig.SuspendInSigHandler(co) catch |e| {
                std.log.err("Schedule user2SigHandler SuspendInSigHandler error:{s}", .{@errorName(e)});
                return;
            };
        } else {
            std.log.err("Schedule user2SigHandler localSchedule.runningCo == null tid:{d}", .{std.Thread.getCurrentId()});
        }
    }
    pub fn deinit(self: *Schedule) void {
        std.log.debug("Schedule deinit readyQueue count:{}", .{self.readyQueue.count()});
        std.log.debug("Schedule deinit sleepQueue count:{}", .{self.sleepQueue.count()});
        var readyIt = self.readyQueue.iterator();
        while (readyIt.next()) |co| {
            std.log.debug("Schedule deinit resume ready coid:{}", .{co.id});
            co.Resume() catch {};
        }
        if (self.xLoop) |*xLoop| {
            xLoop.deinit();
        }
        self.sleepQueue.deinit();
        self.readyQueue.deinit();
        while (self.allCoMap.popOrNull()) |kv| {
            self.allocator.destroy(kv.value);
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
                    defer {}
                    try @call(.auto, _argsTuple.func, _argsTuple.args);
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
    fn sleepCo(self: *Schedule, co: *Co) !void {
        try self.sleepQueue.add(co);
    }
    pub fn ResumeCo(self: *Schedule, co: *Co) !void {
        std.log.debug("ResumeCo id:{d}", .{co.id});
        try self.readyQueue.add(co);
    }
    pub fn freeCo(self: *Schedule, co: *Co) void {
        std.log.debug("Schedule freeCo coid:{}", .{co.id});
        var sleepIt = self.sleepQueue.iterator();
        var i: usize = 0;
        cozig.freeArgs(co);
        while (sleepIt.next()) |_co| {
            if (_co == co) {
                _ = self.sleepQueue.removeIndex(i);
                break;
            }
            i +|= 1;
        }
        i = 0;
        var readyIt = self.readyQueue.iterator();
        while (readyIt.next()) |_co| {
            if (_co == co) {
                std.log.debug("Schedule freed ready coid:{}", .{co.id});
                _ = self.readyQueue.removeIndex(i);
                break;
            }
            i +|= 1;
        }
        if (self.allCoMap.get(co.id)) |_| {
            std.log.debug("Schedule destroy coid:{} co:{*}", .{ co.id, co });
            _ = self.allCoMap.swapRemove(co.id);
            self.allocator.destroy(co);
        }
    }
    pub fn stop(self: *Schedule) void {
        self.exit = true;
    }
    pub fn loop(self: *Schedule) !void {
        const xLoop = &(self.xLoop orelse unreachable);
        defer {
            xLoop.stop();
        }
        while (!self.exit) {
            try xLoop.run(.no_wait);
            self.checkNextCo() catch |e| {
                std.log.err("Schedule loop checkNextCo error:{s}", .{@errorName(e)});
            };
        }
    }
    inline fn checkNextCo(self: *Schedule) !void {
        const count = self.readyQueue.count();
        var iter = self.readyQueue.iterator();
        if (builtin.mode == .Debug) {
            if (count > 0) {
                std.log.debug("checkNextCo begin", .{});
                while (iter.next()) |_co| {
                    std.log.debug("checkNextCo cid:{d}", .{_co.id});
                }
            }
        }
        if (count > 0) {
            const nextCo = self.readyQueue.remove();
            std.log.debug("coid:{d} will running readyQueue.count:{d}", .{ nextCo.id, self.readyQueue.count() });
            try cozig.Resume(nextCo);
        } else {
            const xLoop = &(self.xLoop orelse unreachable);
            // std.log.debug("Schedule no co",.{});
            try xLoop.run(.once);
        }
    }
};
