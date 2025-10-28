const std = @import("std");
const zco = @import("src/root.zig");

// 测试环形缓冲区+优先级位图调度器
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    std.log.info("=== 测试环形缓冲区+优先级位图调度器 ===", .{});

    // 测试不同优先级的协程
    var results = std.ArrayList(usize).init(allocator);
    defer results.deinit();

    // 创建不同优先级的协程
    // 优先级 0 (最低)
    _ = try schedule.goWithPriority(testCoroutine, .{ &results, 0 }, 0);
    
    // 优先级 5 (中等)
    _ = try schedule.goWithPriority(testCoroutine, .{ &results, 5 }, 5);
    
    // 优先级 10 (高)
    _ = try schedule.goWithPriority(testCoroutine, .{ &results, 10 }, 10);
    
    // 优先级 1 (低)
    _ = try schedule.goWithPriority(testCoroutine, .{ &results, 1 }, 1);
    
    // 优先级 15 (最高)
    _ = try schedule.goWithPriority(testCoroutine, .{ &results, 15 }, 15);

    // 运行调度器
    try schedule.loop();

    // 验证调度顺序（应该按优先级从高到低）
    std.log.info("调度顺序: {any}", .{results.items});
    
    // 验证优先级调度是否正确
    const expected_order = [_]usize{ 15, 10, 5, 1, 0 };
    for (expected_order, 0..) |expected, i| {
        if (i < results.items.len and results.items[i] == expected) {
            std.log.info("✓ 优先级 {d} 协程调度正确", .{expected});
        } else {
            std.log.err("✗ 优先级调度错误: 期望 {d}, 实际 {d}", .{ expected, if (i < results.items.len) results.items[i] else 999 });
        }
    }

    // 测试队列统计信息
    std.log.info("=== 队列统计信息 ===", .{});
    std.log.info("就绪队列协程数: {d}", .{schedule.readyQueue.count()});
    std.log.info("就绪队列是否为空: {}", .{schedule.readyQueue.isEmpty()});
    
    if (schedule.readyQueue.getHighestPriority()) |highest| {
        std.log.info("当前最高优先级: {d}", .{highest});
    } else {
        std.log.info("当前最高优先级: 无", .{});
    }

    // 测试各优先级的协程数量
    for (0..32) |priority| {
        const count = schedule.readyQueue.getPriorityCount(priority);
        if (count > 0) {
            std.log.info("优先级 {d}: {d} 个协程", .{ priority, count });
        }
    }
}

fn testCoroutine(results: *std.ArrayList(usize), priority: usize) !void {
    std.log.info("协程优先级 {d} 开始执行", .{priority});
    
    // 模拟一些工作
    try zco.Sleep(1000000); // 1ms
    
    std.log.info("协程优先级 {d} 完成执行", .{priority});
    
    // 记录执行顺序
    try results.append(priority);
}
