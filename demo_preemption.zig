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

    std.log.info("=== 时间片抢占调度演示 ===", .{});
    std.log.info("如果抢占正常工作，应该看到协程A和协程B交替输出", .{});

    // 协程A：输出字母A
    _ = try schedule.go(struct {
        fn run() !void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                // 模拟一些计算工作
                _ = i * i;
                std.log.info("A", .{});
            }
            std.log.info("协程A完成", .{});
        }
    }.run, .{});

    // 协程B：输出字母B
    _ = try schedule.go(struct {
        fn run() !void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                // 模拟一些计算工作
                _ = i * i;
                std.log.info("B", .{});
            }
            std.log.info("协程B完成", .{});
        }
    }.run, .{});

    // 协程C：定期输出状态
    _ = try schedule.go(struct {
        fn run() !void {
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                try zco.Sleep(50 * std.time.ns_per_ms); // 睡眠50ms
                std.log.info("状态检查 {}", .{i});
            }
            std.log.info("状态检查完成", .{});
        }
    }.run, .{});

    std.log.info("开始运行调度器...", .{});
    try schedule.loop();

    // 输出性能统计
    schedule.printStats();
    std.log.info("演示完成！", .{});
}
