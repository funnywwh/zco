const std = @import("std");
const zco = @import("zco");

pub const ZCO_STACK_SIZE = 1024 * 8; // 减少栈大小，从32KB降到8KB，提高内存效率

// pub const std_options = .{
//     .log_level = .err,
// };

pub fn main() !void {
    // const t1 = try std.Thread.spawn(.{}, coRun, .{1});
    // t1.join();

    // const t2 = try std.Thread.spawn(.{}, testChan, .{2});
    // t2.join();

    // const t3 = try std.Thread.spawn(.{}, ctxSwithBench, .{});
    // t3.join();

    // const t4 = try std.Thread.spawn(.{}, coNest, .{});
    // t4.join();

    // const t5 = try std.Thread.spawn(.{}, testDataChan, .{});
    // t5.join();

    const t6 = try std.Thread.spawn(.{}, testPreemption, .{});
    t6.join();
}

pub fn testDataChan() !void {
    _ = try zco.loop(struct {
        fn run() !void {
            const s = try zco.getSchedule();
            const DataType = struct {
                name: []const u8,
                id: u32,
                age: u32,
            };
            const Chan = zco.CreateChan(DataType);
            const exitCh = try Chan.init(try zco.getSchedule(), 1);
            defer {
                exitCh.close();
                exitCh.deinit();
            }
            _ = try s.go(struct {
                fn run(ch: *Chan) !void {
                    const v = try ch.recv();
                    std.log.debug("recved:{any}", .{v});
                }
            }.run, .{exitCh});
            try exitCh.send(.{
                .name = "test",
                .age = 45,
                .id = 1,
            });
            s.stop();
        }
    }.run, .{});
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
                    try __co.Sleep(2 * std.time.ns_per_s);
                    __s.stop();
                }
            }.run, .{_s});
            try _co.Sleep(2 * std.time.ns_per_s);
        }
    }.run, .{});
}
pub fn ctxSwithBench() !void {
    _ = try zco.loop(struct {
        const num_bounces = 1_000;
        fn run() !void {
            const s = try zco.getSchedule();
            const _co = try s.getCurrentCo();
            const start = std.time.nanoTimestamp();
            for (0..num_bounces) |_| {
                // try _co.Sleep(1);
                try _co.Resume();
                try _co.Suspend();
            }
            const end = std.time.nanoTimestamp();
            const duration = end - start;
            const ns_per_bounce = @divFloor(duration, num_bounces * 2);
            std.log.err("coid:{d} switch ns:{d}", .{ _co.id, ns_per_bounce });
            s.stop();
        }
    }.run, .{});
}
pub fn coRun(baseIdx: u32) !void {
    defer std.log.debug("coRun exited", .{});
    try zco.loop(struct {
        fn run(_baseIdx: u32) !void {
            const s = try zco.getSchedule();

            for (0..100) |_| {
                _ = try s.go(struct {
                    fn run(idx: u32) !void {
                        var v: usize = idx;
                        var maxSleep: usize = 0;
                        const _co = try (try zco.getSchedule()).getCurrentCo();
                        while (true) {
                            std.log.debug("co{d} running v:{d}", .{ _co.id, v });
                            const start = try std.time.Instant.now();
                            try _co.Sleep(10 * std.time.ns_per_ms);
                            const end = try std.time.Instant.now();
                            v +%= 1;
                            if (v > 10) {
                                break;
                            }
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
            try _co.Sleep(10 * std.time.ns_per_s);
            s.stop();
        }
    }.run, .{baseIdx});
}
pub fn testChan(baseIdx: u32) !void {
    try zco.loop(struct {
        fn run(_baseIdx: u32) !void {
            _ = _baseIdx; // autofix
            const schedule = try zco.getSchedule();
            const co0 = try schedule.getCurrentCo();
            _ = co0; // autofix
            const Chan = zco.CreateChan(bool);
            const SendChan = zco.CreateChan(usize);
            const chn1 = try SendChan.init(schedule, 10);
            const exitCh1 = try Chan.init(schedule, 1);
            const exitCh2 = try Chan.init(schedule, 1);
            const exitCh3 = try Chan.init(schedule, 1);
            const exitCh4 = try Chan.init(schedule, 1);
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
                //     std.log.err("co0 exit", .{});
            }

            _ = try schedule.go(struct {
                fn run(_ch: *SendChan, _exitCh: *Chan) !void {
                    var v: usize = 0;
                    defer {
                        std.log.err("send1 exit", .{});
                    }
                    while (true) {
                        std.log.debug("send1 sending", .{});
                        // try c.Sleep(10);
                        v +%= 1;
                        try _ch.send(v);
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
                fn run(_ch: *SendChan, _exitCh: *Chan) !void {
                    var v: usize = 100;
                    defer {
                        std.log.debug("send2 exit", .{});
                    }
                    while (true) {
                        std.log.debug("send2 sending", .{});
                        // try c.Sleep(10);
                        v +%= 1;
                        _ch.send(v) catch |e| {
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
                fn run(_ch: *SendChan, _exitCh: *Chan) !void {
                    defer {
                        std.log.err("recv1 recv exit", .{});
                    }
                    while (true) {
                        std.log.debug("recv1 recving", .{});
                        const d: usize = _ch.recv() catch |e| {
                            std.log.err("recv1 recv exit error:{s}", .{@errorName(e)});
                            break;
                        };
                        std.log.debug("recv1 recv:{d}", .{d});
                    }
                    std.log.debug("recv1 exitch recving", .{});
                    _ = try _exitCh.recv();
                }
            }.run, .{ chn1, exitCh3 });
            _ = try schedule.go(struct {
                fn run(_ch: *SendChan, _exitCh: *Chan) !void {
                    defer {
                        std.log.err("recv2 recv exit", .{});
                    }
                    while (true) {
                        std.log.debug("recv2 recving", .{});
                        const d: usize = _ch.recv() catch |e| {
                            std.log.err("recv2 recv exit error:{s}", .{@errorName(e)});
                            break;
                        };
                        std.log.debug("recv2 recv:{d}", .{d});
                    }
                    _ = try _exitCh.recv();
                }
            }.run, .{ chn1, exitCh4 });
            std.log.debug("exitch1 send", .{});
            try exitCh1.send(true);
            std.log.debug("exitch2 send", .{});
            try exitCh2.send(true);
            std.log.debug("exitch3 send", .{});
            try exitCh3.send(true);
            std.log.debug("exitch4 send", .{});
            try exitCh4.send(true);
            std.log.debug("all co exited", .{});
        }
    }.run, .{baseIdx});
}

pub fn testPreemption() !void {
    _ = try zco.loop(struct {
        fn run() !void {
            const s = try zco.getSchedule();

            // 协程1：长时间运行的计算，不主动让出CPU
            var counter1: usize = 0;
            _ = try s.go(struct {
                fn run(counter: *usize) !void {
                    std.log.info("协程1开始运行", .{});
                    while (counter.* < 10000000) : (counter.* += 1) {
                        // 简单的整数运算
                        _ = counter.* * 2;

                        // 每100000次输出一次进度
                        if (counter.* % 100000 == 0) {
                            std.log.info("协程1进度: {}", .{counter.*});
                        }
                    }
                    std.log.info("协程1完成，计数: {}", .{counter.*});
                }
            }.run, .{&counter1});

            // 协程2：另一个长时间运行的计算，不主动让出CPU
            var counter2: usize = 0;
            _ = try s.go(struct {
                fn run(counter: *usize) !void {
                    std.log.info("协程2开始运行", .{});
                    while (counter.* < 10000000) : (counter.* += 1) {
                        // 简化计算，避免浮点数操作
                        // _ = std.math.sqrt(@as(f64, @floatFromInt(counter.*)));
                        _ = counter.* * 2; // 简单的整数运算

                        // 每100000次输出一次进度
                        if (counter.* % 100000 == 0) {
                            std.log.info("协程2进度: {}", .{counter.*});
                        }
                    }
                    std.log.info("协程2完成，计数: {}", .{counter.*});
                }
            }.run, .{&counter2});

            // 暂时禁用协程3，只测试协程1和协程2的抢占
            // _ = try s.go(struct {
            //     fn run() !void {
            //         const schedule = try zco.getSchedule();
            //         const co = try schedule.getCurrentCo();
            //         var i: usize = 0;
            //         while (i < 20) : (i += 1) {
            //             try co.Sleep(100 * std.time.ns_per_ms); // 睡眠100ms
            //             std.log.info("状态检查协程运行中... {} (观察抢占效果)", .{i});
            //         }
            //         std.log.info("状态检查协程完成", .{});
            //     }
            // }.run, .{});

            std.log.info("开始运行调度器，测试时间片抢占...", .{});
            std.log.info("如果时间片抢占正常工作，应该看到协程1和协程2交替输出进度", .{});

            // 等待所有协程完成
            const mainCo = try s.getCurrentCo();
            try mainCo.Sleep(10 * std.time.ns_per_s);

            std.log.info("测试完成！", .{});
            std.log.info("协程1最终计数: {}", .{counter1});
            std.log.info("协程2最终计数: {}", .{counter2});

            s.stop();
        }
    }.run, .{});
}

test "simple test" {}
