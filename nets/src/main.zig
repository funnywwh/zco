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

// 协程池配置
const WORKER_POOL_SIZE = 100; // 固定协程池大小
const CHANNEL_BUFFER = 1000; // channel 缓冲大小

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

    // 创建带缓冲的 channel 用于传递客户端连接
    const TcpChan = zco.CreateChan(*nets.Tcp);
    var clientChan = try TcpChan.init(schedule, CHANNEL_BUFFER);
    defer {
        clientChan.close();
        clientChan.deinit();
    }

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

    // 创建固定数量的工作协程池
    for (0..WORKER_POOL_SIZE) |_| {
        _ = try schedule.go(struct {
            fn run(chan: *TcpChan) !void {
                while (true) {
                    var client = chan.recv() catch |e| {
                        // channel 关闭时退出
                        std.log.info("Worker exiting: {any}", .{e});
                        break;
                    };

                    // 检查连接数限制
                    const currentConnections = connectionCount.load(.monotonic);
                    if (currentConnections >= MAX_CONNECTIONS) {
                        std.log.warn("Max connections reached, dropping connection", .{});
                        client.close();
                        client.deinit();
                        continue;
                    }

                    _ = connectionCount.fetchAdd(1, .monotonic);

                    // 处理客户端连接
                    defer {
                        _ = connectionCount.fetchSub(1, .monotonic);
                        client.close();
                        client.deinit();
                    }

                    var keepalive = true;
                    var buffer: [1024]u8 = std.mem.zeroes([1024]u8);

                    while (keepalive) {
                        const n = client.read(buffer[0..]) catch |e| {
                            std.log.debug("Read error: {any}", .{e});
                            break;
                        };
                        if (n == 0) break;

                        // 快速处理请求
                        keepalive = handleRequestFast(buffer[0..n], client) catch |e| {
                            std.log.err("Handle request error: {any}", .{e});
                            break;
                        };
                    }
                }
            }
        }.run, .{clientChan});
    }

    // 启动服务器协程：accept 循环并将连接发送到 channel
    _ = try schedule.go(struct {
        fn run(s: *zco.Schedule, chan: *TcpChan) !void {
            var server = try nets.Tcp.init(s);
            defer {
                server.close();
                server.deinit();
            }
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            std.log.info("Starting server on port {d}", .{address.getPort()});
            try server.bind(address);
            try server.listen(MAX_CONNECTIONS);
            std.log.info("Server listening on port {d}", .{address.getPort()});
            std.log.info("Worker pool size: {d}, Channel buffer: {d}", .{ WORKER_POOL_SIZE, CHANNEL_BUFFER });

            while (true) {
                var client = server.accept() catch |e| {
                    std.log.err("server accept error: {any}", .{e});
                    break;
                };

                // 将客户端连接发送到 channel，由工作协程处理
                chan.send(client) catch |e| {
                    std.log.err("Failed to send client to channel: {any}", .{e});
                    client.close();
                    client.deinit();
                };
            }
        }
    }.run, .{ schedule, clientChan });

    try schedule.loop();
}

// 优化的请求处理函数 - 使用快速字节比较代替indexOf
fn handleRequestFast(buffer: []const u8, client: *nets.Tcp) !bool {
    const startTime = std.time.nanoTimestamp();

    // 快速检查请求类型
    if (buffer.len < 3) return false;

    // 检查是否是GET请求 - 快速路径
    if (buffer[0] != 'G' or buffer[1] != 'E' or buffer[2] != 'T') {
        return false;
    }

    // 快速扫描Connection头 (避免使用indexOf)
    var isKeepAlive = false;
    var i: usize = 0;

    // 扫描"Connection:"字符串
    while (i < buffer.len - 10) {
        if (buffer[i] == 'C' and
            buffer[i + 1] == 'o' and
            buffer[i + 2] == 'n' and
            buffer[i + 3] == 'n' and
            buffer[i + 4] == 'e' and
            buffer[i + 5] == 'c' and
            buffer[i + 6] == 't' and
            buffer[i + 7] == 'i' and
            buffer[i + 8] == 'o' and
            buffer[i + 9] == 'n' and
            buffer[i + 10] == ':')
        {
            // 找到Connection头，检查是否是keep-alive
            const remain = if (i + 11 < buffer.len) buffer[i + 11 ..] else break;
            if (remain.len >= 10 and
                remain[1] == 'k' and
                remain[2] == 'e' and
                remain[3] == 'e' and
                remain[4] == 'p' and
                remain[5] == '-' and
                remain[6] == 'a' and
                remain[7] == 'l' and
                remain[8] == 'i' and
                remain[9] == 'v' and
                remain[10] == 'e')
            {
                isKeepAlive = true;
            }
            break;
        }
        i += 1;
    }

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
