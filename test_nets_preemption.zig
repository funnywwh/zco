const std = @import("std");
const zco = @import("src/root.zig");
const nets = @import("nets");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    std.log.info("=== 测试nets模块的时间片抢占调度功能 ===", .{});

    // 创建多个长时间运行的协程来测试抢占
    for (0..5) |i| {
        _ = try schedule.go(struct {
            fn run(id: usize) !void {
                var counter: usize = 0;
                while (counter < 1000000) : (counter += 1) {
                    // 模拟一些计算工作
                    _ = counter * counter;

                    // 每100000次输出一次进度
                    if (counter % 100000 == 0) {
                        std.log.info("协程{}进度: {}", .{ id, counter });
                    }
                }
                std.log.info("协程{}完成", .{id});
            }
        }.run, .{i});
    }

    // 创建一个网络IO协程
    _ = try schedule.go(struct {
        fn run() !void {
            std.log.info("网络IO协程开始", .{});
            var server = try nets.Tcp.init(schedule);
            defer {
                server.close();
                server.deinit();
            }

            const address = try std.net.Address.parseIp4("127.0.0.1", 8081);
            try server.bind(address);
            try server.listen(100);
            std.log.info("测试服务器监听端口8081", .{});

            // 只接受一个连接用于测试
            var client = server.accept() catch |e| {
                std.log.info("接受连接失败: {}", .{@errorName(e)});
                return;
            };
            defer {
                client.close();
                client.deinit();
            }

            std.log.info("接受了一个连接", .{});

            // 处理连接
            var buffer: [1024]u8 = undefined;
            const n = try client.read(buffer[0..]);
            std.log.info("读取了{}字节数据", .{n});

            const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello World!";
            _ = try client.write(response);
            std.log.info("发送了响应", .{});
        }
    }.run, .{});

    // 启动调度器
    std.log.info("开始运行调度器，观察抢占效果...", .{});
    try schedule.loop();

    // 输出性能统计
    schedule.printStats();
    std.log.info("测试完成！", .{});
}
