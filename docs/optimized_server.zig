// 优化的HTTP服务器实现
// 解决高并发响应延时问题

const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const xev = @import("xev");

// 配置参数
const CONFIG = struct {
    const MAX_CONNECTIONS = 10000;
    const BATCH_SIZE = 32;
    const BUFFER_SIZE = 1024;
    const POOL_SIZE = 1000;
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try zco.init(allocator);
    defer zco.deinit();
    
    const schedule = try zco.newSchedule();
    defer schedule.deinit();
    
    // 启动优化的HTTP服务器
    try runOptimizedServer(schedule);
}

fn runOptimizedServer(schedule: *zco.Schedule) !void {
    var server = try nets.Tcp.init(schedule);
    defer {
        server.close();
        server.deinit();
    }
    
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try server.bind(address);
    try server.listen(CONFIG.MAX_CONNECTIONS);
    
    std.log.info("Optimized server listening on port 8080", .{});
    
    // 预编译的HTTP响应
    const HTTP_200_KEEPALIVE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhelloworld";
    const HTTP_200_CLOSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld";
    
    // 连接计数器
    var connectionCount: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    
    while (true) {
        const client = server.accept() catch |e| {
            break;
        };
        
        // 检查连接数限制
        const currentConnections = connectionCount.load(.monotonic);
        if (currentConnections >= CONFIG.MAX_CONNECTIONS) {
            std.log.warn("Max connections reached, dropping connection", .{});
            client.close();
            client.deinit();
            continue;
        }
        
        _ = connectionCount.fetchAdd(1, .monotonic);
        
        // 为每个连接创建协程
        _ = try schedule.go(struct {
            fn run(_client: *nets.Tcp, _connectionCount: *std.atomic.Value(u32)) !void {
                defer {
                    _ = _connectionCount.fetchSub(1, .monotonic);
                    _client.close();
                    _client.deinit();
                }
                
                var buffer: [CONFIG.BUFFER_SIZE]u8 = undefined;
                var keepAlive = true;
                
                while (keepAlive) {
                    // 读取请求
                    const n = _client.read(buffer[0..]) catch |e| {
                        break;
                    };
                    
                    if (n == 0) break;
                    
                    // 快速处理请求
                    keepAlive = try handleRequestFast(buffer[0..n], _client);
                }
            }
        }.run, .{ client, &connectionCount });
    }
}

fn handleRequestFast(buffer: []const u8, client: *nets.Tcp) !bool {
    // 快速检查请求类型
    if (buffer.len < 3) return false;
    
    // 检查是否是GET请求
    if (!std.mem.eql(u8, buffer[0..3], "GET")) {
        return false;
    }
    
    // 检查是否是shutdown请求
    if (std.mem.indexOf(u8, buffer, "/shutdown") != null) {
        _ = try client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld");
        return false;
    }
    
    // 快速检查Connection头
    const isKeepAlive = std.mem.indexOf(u8, buffer, "Connection: keep-alive") != null;
    
    if (isKeepAlive) {
        _ = try client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhelloworld");
        return true;
    } else {
        _ = try client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld");
        return false;
    }
}

// 批量处理协程的优化调度器
pub const BatchScheduler = struct {
    const Self = @This();
    
    readyQueue: std.ArrayList(*zco.Co),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .readyQueue = std.ArrayList(*zco.Co).init(allocator),
            .allocator = allocator,
        };
        return self;
    }
    
    pub fn addReadyCo(self: *Self, co: *zco.Co) !void {
        try self.readyQueue.append(co);
    }
    
    // 批量处理就绪协程
    pub fn processBatch(self: *Self) !void {
        const count = @min(self.readyQueue.items.len, CONFIG.BATCH_SIZE);
        if (count == 0) return;
        
        // 批量处理
        for (0..count) |i| {
            const co = self.readyQueue.items[i];
            try co.Resume();
        }
        
        // 移除已处理的协程
        for (0..count) |_| {
            _ = self.readyQueue.orderedRemove(0);
        }
    }
    
    pub fn deinit(self: *Self) void {
        self.readyQueue.deinit();
        self.allocator.destroy(self);
    }
};

// 性能监控
pub const PerfMonitor = struct {
    const Self = @This();
    
    requestCount: std.atomic.Value(u64),
    totalLatency: std.atomic.Value(u64),
    maxLatency: std.atomic.Value(u64),
    
    pub fn init() Self {
        return .{
            .requestCount = std.atomic.Value(u64).init(0),
            .totalLatency = std.atomic.Value(u64).init(0),
            .maxLatency = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn recordRequest(self: *Self, latencyNs: u64) void {
        _ = self.requestCount.fetchAdd(1, .monotonic);
        _ = self.totalLatency.fetchAdd(latencyNs, .monotonic);
        
        var currentMax = self.maxLatency.load(.monotonic);
        while (latencyNs > currentMax) {
            if (self.maxLatency.compareAndSwap(currentMax, latencyNs, .monotonic, .monotonic)) |_| {
                break;
            }
            currentMax = self.maxLatency.load(.monotonic);
        }
    }
    
    pub fn printStats(self: *Self) void {
        const count = self.requestCount.load(.monotonic);
        const total = self.totalLatency.load(.monotonic);
        const max = self.maxLatency.load(.monotonic);
        const avg = if (count > 0) total / count else 0;
        
        std.log.info("Performance Stats - Requests: {}, Avg Latency: {}ns, Max Latency: {}ns", .{ count, avg, max });
    }
};
