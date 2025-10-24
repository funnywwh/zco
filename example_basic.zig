const std = @import("std");
const zco = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 测试协程1：长时间运行的计算
    var counter1: usize = 0;
    _ = try schedule.go(struct {
        fn run(counter: *usize) !void {
            std.log.info("协程1开始运行", .{});
            while (counter.* < 1000000) : (counter.* += 1) {
                // 模拟一些计算工作
                _ = std.math.sqrt(@as(f64, @floatFromInt(counter.*)));
            }
            std.log.info("协程1完成，计数: {}", .{counter.*});
        }
    }.run, .{&counter1});

    // 测试协程2：另一个长时间运行的计算
    var counter2: usize = 0;
    _ = try schedule.go(struct {
        fn run(counter: *usize) !void {
            std.log.info("协程2开始运行", .{});
            while (counter.* < 1000000) : (counter.* += 1) {
                // 模拟一些计算工作
                _ = std.math.sqrt(@as(f64, @floatFromInt(counter.*)));
            }
            std.log.info("协程2完成，计数: {}", .{counter.*});
        }
    }.run, .{&counter2});

    // 测试协程3：定期输出状态
    _ = try schedule.go(struct {
        fn run() !void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                try zco.Sleep(100 * std.time.ns_per_ms); // 睡眠100ms
                std.log.info("状态检查协程运行中... {}", .{i});
            }
            std.log.info("状态检查协程完成", .{});
        }
    }.run, .{});

    std.log.info("开始运行调度器，测试时间片抢占...", .{});
    try schedule.loop();

    std.log.info("测试完成！", .{});
    std.log.info("协程1最终计数: {}", .{counter1});
    std.log.info("协程2最终计数: {}", .{counter2});
}
