const std = @import("std");
const zco = @import("zco");

pub const ZCO_STACK_SIZE = 1024 * 12;

pub const std_options = .{
    .log_level = .err,
};
pub fn main() !void {
    // const t1 = try std.Thread.spawn(.{}, coRun, .{1});
    // defer t1.join();

    // const t2 = try std.Thread.spawn(.{}, testChan, .{2});
    // defer t2.join();

    // const t3 = try std.Thread.spawn(.{}, ctxSwithBench, .{});
    // defer t3.join();

    const t4 = try std.Thread.spawn(.{}, coNest, .{});
    defer t4.join();
}

pub fn coNest() !void {
    _ = try zco.loop(struct {
        fn run() !void {
            const _s = try zco.getSchedule();
            const _co = _s.runningCo orelse unreachable; // autofix
            _ = try _s.go(struct {
                fn run(__s: *zco.Schedule) !void {
                    const __co = __s.runningCo orelse unreachable; // autofix
                    std.log.debug("coNest co2 will Suspend", .{});
                    try __co.Suspend();
                }
            }.run, .{_s});
            try _co.Suspend();
        }
    }.run, .{});
}
pub fn ctxSwithBench() !void {
    _ = try zco.loop(struct {
        const num_bounces = 1_000_000;
        fn run() !void {
            const s = try zco.getSchedule();
            const _co = try s.getCurrentCo();
            const start = std.time.nanoTimestamp();
            for (0..num_bounces) |_| {
                try _co.Sleep(1);
            }
            const end = std.time.nanoTimestamp();
            const duration = end - start;
            const ns_per_bounce = @divFloor(duration, num_bounces * 2);
            std.log.err("coid:{d} switch ns:{d}", .{ _co.id, ns_per_bounce });
            s.exit = true;
        }
    }.run, .{});
}
pub fn coRun(baseIdx: u32) !void {
    try zco.loop(struct {
        fn run(_baseIdx: u32) !void {
            const s = try zco.getSchedule();

            for (0..1_000) |_| {
                _ = try s.go(struct {
                    fn run(idx: u32) !void {
                        var v: usize = idx;
                        var maxSleep: usize = 0;
                        const _co = try (try zco.getSchedule()).getCurrentCo();
                        while (true) {
                            std.log.debug("co{d} running v:{d}", .{ _co.id, v });
                            const start = try std.time.Instant.now();
                            try _co.Sleep(10);
                            const end = try std.time.Instant.now();
                            v +%= 1;
                            const d = end.since(start) / std.time.ns_per_ms;
                            if (d > maxSleep) {
                                maxSleep = d;
                                std.log.err("coid:{d} sleeped max ms:{d}", .{ _co.id, maxSleep });
                            }
                        }
                    }
                }.run, .{_baseIdx});
            }
            const _co = try s.getCurrentCo();
            try _co.Suspend();
        }
    }.run, .{baseIdx});
}
pub fn testChan(baseIdx: u32) !void {
    try zco.loop(struct {
        fn run(_baseIdx1: u32) !void {
            var _baseIdx = _baseIdx1;
            const schedule = try zco.getSchedule();
            const co0 = try schedule.getCurrentCo();
            _ = co0; // autofix
            const chn1 = try zco.Chan.init(schedule, 10);
            const exitCh1 = try zco.Chan.init(schedule, 1);
            const exitCh2 = try zco.Chan.init(schedule, 1);
            const exitCh3 = try zco.Chan.init(schedule, 1);
            const exitCh4 = try zco.Chan.init(schedule, 1);
            defer {
                exitCh1.close();
                exitCh1.deinit();
                exitCh2.close();
                exitCh2.deinit();
                exitCh3.close();
                exitCh3.deinit();
                exitCh4.close();
                exitCh4.deinit();
                chn1.deinit();
                schedule.stop();
                std.log.err("co0 exit", .{});
            }

            _ = try schedule.go(struct {
                fn run(_ch: *zco.Chan, _exitCh: *zco.Chan) !void {
                    var v: usize = 0;
                    defer {
                        std.log.err("send1 exit", .{});
                    }
                    while (true) {
                        std.log.debug("send1 sending", .{});
                        // try c.Sleep(10);
                        v +%= 1;
                        try _ch.send(&v);
                        if (v == 1) {
                            break;
                        }
                        std.log.debug("send1 sent", .{});
                    }
                    _ch.close();
                    _ = try _exitCh.recv();
                }
            }.run, .{ chn1, exitCh1 });

            _ = try schedule.go(struct {
                fn run(_ch: *zco.Chan, _exitCh: *zco.Chan) !void {
                    var v: usize = 100;
                    defer {
                        std.log.debug("send2 exit", .{});
                    }
                    while (true) {
                        std.log.debug("send2 sending", .{});
                        // try c.Sleep(10);
                        v +%= 1;
                        _ch.send(&v) catch |e| {
                            std.log.debug("send2 send error:{s}", .{@errorName(e)});
                            break;
                        };
                        std.log.debug("send2 sent v:{d}", .{v});
                    }
                    std.log.debug("send2 exitch recving", .{});
                    _ = try _exitCh.recv();
                }
            }.run, .{ chn1, exitCh2 });
            _ = try schedule.go(struct {
                fn run(_ch: *zco.Chan, _exitCh: *zco.Chan) !void {
                    defer {
                        std.log.err("recv1 recv exit", .{});
                    }
                    while (true) {
                        std.log.debug("recv1 recving", .{});
                        const d: *usize = @alignCast(@ptrCast(_ch.recv() catch |e| {
                            std.log.err("recv1 recv exit error:{s}", .{@errorName(e)});
                            break;
                        }));
                        std.log.debug("recv1 recv:{d}", .{d.*});
                    }
                    std.log.debug("recv1 exitch recving", .{});
                    _ = try _exitCh.recv();
                }
            }.run, .{ chn1, exitCh3 });
            _ = try schedule.go(struct {
                fn run(_ch: *zco.Chan, _exitCh: *zco.Chan) !void {
                    defer {
                        std.log.err("recv2 recv exit", .{});
                    }
                    while (true) {
                        std.log.debug("recv2 recving", .{});
                        const d: *usize = @alignCast(@ptrCast(_ch.recv() catch |e| {
                            std.log.err("recv2 recv exit error:{s}", .{@errorName(e)});
                            break;
                        }));
                        std.log.debug("recv2 recv:{d}", .{d.*});
                    }
                    _ = try _exitCh.recv();
                }
            }.run, .{ chn1, exitCh4 });
            try exitCh1.send(&_baseIdx);
            try exitCh2.send(&_baseIdx);
            try exitCh3.send(&_baseIdx);
            try exitCh4.send(&_baseIdx);
        }
    }.run, .{baseIdx});
}

test "simple test" {}
