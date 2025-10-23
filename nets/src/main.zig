const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const builtin = @import("builtin");

pub fn main() !void {
    std.log.info("Starting ZCO HTTP Server...", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();

    std.log.info("ZCO initialized, starting HTTP server...", .{});
    try httpHelloworld();
}

// 预编译的HTTP响应，避免运行时字符串操作
const HTTP_200_KEEPALIVE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhelloworld";
const HTTP_200_CLOSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld";

// 连接数限制
const MAX_CONNECTIONS = 10000;
var connectionCount: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// 性能监控
const PerfMonitor = struct {
    requestCount: std.atomic.Value(u64),
    totalLatency: std.atomic.Value(u64),
    maxLatency: std.atomic.Value(u64),

    pub fn init() PerfMonitor {
        return .{
            .requestCount = std.atomic.Value(u64).init(0),
            .totalLatency = std.atomic.Value(u64).init(0),
            .maxLatency = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordRequest(self: *PerfMonitor, latencyNs: u64) void {
        _ = self.requestCount.fetchAdd(1, .monotonic);
        _ = self.totalLatency.fetchAdd(latencyNs, .monotonic);

        // 简化最大值更新，避免复杂的原子操作
        const currentMax = self.maxLatency.load(.monotonic);
        if (latencyNs > currentMax) {
            _ = self.maxLatency.swap(latencyNs, .monotonic);
        }
    }

    pub fn printStats(self: *PerfMonitor) void {
        const count = self.requestCount.load(.monotonic);
        const total = self.totalLatency.load(.monotonic);
        const max = self.maxLatency.load(.monotonic);
        const avg = if (count > 0) total / count else 0;

        std.log.info("Performance Stats - Requests: {}, Avg Latency: {}ns, Max Latency: {}ns", .{ count, avg, max });
    }
};

var perfMonitor = PerfMonitor.init();

fn httpHelloworld() !void {
    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 启动性能统计协程
    _ = try schedule.go(struct {
        fn run(s: *zco.Schedule) !void {
            while (true) {
                const currentCo = try s.getCurrentCo();
                try currentCo.Sleep(5 * std.time.ns_per_s); // 每5秒输出一次统计
                perfMonitor.printStats();
            }
        }
    }.run, .{schedule});

    _ = try schedule.go(struct {
        fn run(s: *zco.Schedule) !void {
            var server = try nets.Tcp.init(s);
            defer {
                server.close();
                server.deinit();
            }
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            std.log.info("Starting server on port {d}", .{address.getPort()});
            try server.bind(address);
            try server.listen(MAX_CONNECTIONS); // 增加监听队列大小
            std.log.info("Server listening on port {d}", .{address.getPort()});
            while (true) {
                const _s = server.schedule;
                var client = server.accept() catch |e| {
                    std.log.debug("server accept error:{any}", .{e});
                    break;
                };
                errdefer {
                    client.close();
                    client.deinit();
                }

                // 检查连接数限制
                const currentConnections = connectionCount.load(.monotonic);
                if (currentConnections >= MAX_CONNECTIONS) {
                    std.log.warn("Max connections reached, dropping connection", .{});
                    client.close();
                    client.deinit();
                    continue;
                }

                _ = connectionCount.fetchAdd(1, .monotonic);
                std.log.debug("accept a client, total connections: {}", .{currentConnections + 1});

                _ = try _s.go(struct {
                    fn run(_client: *nets.Tcp) !void {
                        defer {
                            _ = connectionCount.fetchSub(1, .monotonic);
                            std.log.debug("client loop exited", .{});
                        }

                        defer {
                            _client.close();
                            _client.deinit();
                        }

                        var keepalive = true;
                        var buffer: [1024]u8 = undefined;

                        while (keepalive) {
                            const n = try _client.read(buffer[0..]);
                            if (n == 0) break;

                            // 快速处理请求
                            keepalive = try handleRequestFast(buffer[0..n], _client);
                        }
                    }
                }.run, .{client});
            }
        }
    }.run, .{schedule});

    try schedule.loop();
}

// 优化的请求处理函数
fn handleRequestFast(buffer: []const u8, client: *nets.Tcp) !bool {
    const startTime = std.time.nanoTimestamp();

    // 快速检查请求类型
    if (buffer.len < 3) return false;

    // 检查是否是GET请求
    if (!std.mem.eql(u8, buffer[0..3], "GET")) {
        return false;
    }

    // 检查是否是shutdown请求
    if (std.mem.indexOf(u8, buffer, "/shutdown") != null) {
        _ = try client.write(HTTP_200_CLOSE);
        return false;
    }

    // 快速检查Connection头
    const isKeepAlive = std.mem.indexOf(u8, buffer, "Connection: keep-alive") != null;

    if (isKeepAlive) {
        _ = try client.write(HTTP_200_KEEPALIVE);
    } else {
        _ = try client.write(HTTP_200_CLOSE);
    }

    // 记录性能指标
    const endTime = std.time.nanoTimestamp();
    const latency = @as(u64, @intCast(endTime - startTime));
    perfMonitor.recordRequest(latency);

    return isKeepAlive;
}
