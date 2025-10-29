const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const router = @import("./router.zig");
const middleware = @import("./middleware.zig");
const context = @import("./context.zig");

/// HTTP服务器
pub const Server = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    router: router.Router,
    middleware_chain: middleware.MiddlewareChain,
    tcp: ?*nets.Tcp = null,

    /// 读取缓冲区大小
    read_buffer_size: usize = 8192,

    /// 最大请求大小
    max_request_size: usize = 1024 * 1024, // 1MB

    /// 初始化服务器
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule) Self {
        return .{
            .allocator = allocator,
            .schedule = schedule,
            .router = router.Router.init(allocator),
            .middleware_chain = middleware.MiddlewareChain.init(allocator),
        };
    }

    /// 清理服务器资源
    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.middleware_chain.deinit();
        if (self.tcp) |tcp| {
            tcp.close();
            tcp.deinit();
        }
    }

    /// 添加路由
    pub fn get(self: *Self, path: []const u8, handler: router.Handler) !void {
        try self.router.get(path, handler);
    }

    pub fn post(self: *Self, path: []const u8, handler: router.Handler) !void {
        try self.router.post(path, handler);
    }

    pub fn put(self: *Self, path: []const u8, handler: router.Handler) !void {
        try self.router.put(path, handler);
    }

    pub fn delete(self: *Self, path: []const u8, handler: router.Handler) !void {
        try self.router.delete(path, handler);
    }

    pub fn patch(self: *Self, path: []const u8, handler: router.Handler) !void {
        try self.router.patch(path, handler);
    }

    /// 添加中间件
    pub fn use(self: *Self, mw: middleware.Middleware) !void {
        try self.middleware_chain.use(mw);
    }

    /// 监听指定地址（需要在协程环境中调用）
    pub fn listen(self: *Self, address: std.net.Address) !void {
        const tcp = try nets.Tcp.init(self.schedule);
        errdefer tcp.deinit();

        try tcp.bind(address);
        try tcp.listen(128);

        self.tcp = tcp;

        std.log.info("HTTP server listening on {}", .{address});

        // 接受连接并处理（accept必须在协程环境中调用）
        while (true) {
            const client = tcp.accept() catch |e| {
                std.log.err("Accept error: {s}", .{@errorName(e)});
                continue;
            };

            // 为每个连接启动协程
            _ = try self.schedule.go(handleConnection, .{ self, client });
        }
    }

    /// 处理单个连接（支持HTTP keep-alive）
    fn handleConnection(server: *Self, client: *nets.Tcp) !void {
        defer {
            client.close();
            client.deinit();
        }

        var buffer = try server.allocator.alloc(u8, server.read_buffer_size);
        defer server.allocator.free(buffer);

        // 支持HTTP keep-alive：在同一连接上处理多个请求
        var keep_alive = true;
        while (keep_alive) {
            // 读取请求
            const n = client.read(buffer) catch |e| {
                std.log.err("Read error: {s}", .{@errorName(e)});
                break;
            };

            if (n == 0) {
                // 连接关闭
                break;
            }

            if (n > server.max_request_size) {
                std.log.warn("Request too large: {} bytes", .{n});
                break;
            }

            // 创建上下文（每次请求都需要新的上下文）
            var ctx = context.Context.init(server.allocator, server.schedule, client);
            defer ctx.deinit();

            // 解析请求
            ctx.req.parse(buffer[0..n]) catch |e| {
                std.log.err("Parse error: {s}", .{@errorName(e)});
                ctx.res.status = 400;
                try ctx.text(400, "Bad Request");
                try ctx.send();
                break;
            };

            // 检查Connection头和HTTP版本
            const version = ctx.req.version;
            const is_http11 = std.mem.startsWith(u8, version, "HTTP/1.1");

            // HTTP/1.1 默认keep-alive，HTTP/1.0 默认close
            keep_alive = is_http11;

            // 检查Connection头（优先级高于默认值）
            const connection_header = ctx.req.getHeader("Connection");
            if (connection_header) |conn| {
                const conn_trimmed = std.mem.trim(u8, conn, " ");
                var conn_lower_buf: [16]u8 = undefined;
                if (conn_trimmed.len < conn_lower_buf.len) {
                    for (conn_trimmed, 0..) |c, i| {
                        conn_lower_buf[i] = std.ascii.toLower(c);
                    }
                    const conn_lower = conn_lower_buf[0..conn_trimmed.len];
                    if (std.mem.eql(u8, conn_lower, "close")) {
                        keep_alive = false;
                    } else if (std.mem.eql(u8, conn_lower, "keep-alive")) {
                        keep_alive = true;
                    }
                }
            }

            // 设置响应Connection头
            if (keep_alive) {
                try ctx.header("Connection", "keep-alive");
            } else {
                try ctx.header("Connection", "close");
            }

            // 执行中间件链
            server.middleware_chain.execute(&ctx) catch |e| {
                std.log.err("Middleware error: {s}", .{@errorName(e)});
                ctx.res.status = 500;
                try ctx.text(500, "Internal Server Error");
            };

            // 如果中间件没有发送响应，执行路由
            if (ctx.res.body.items.len == 0 and ctx.res.status == 200) {
                server.router.handle(&ctx) catch |e| {
                    std.log.err("Route error: {s}", .{@errorName(e)});
                    ctx.res.status = 500;
                    try ctx.text(500, "Internal Server Error");
                };
            }

            // 发送响应
            ctx.send() catch |e| {
                std.log.err("Send error: {s}", .{@errorName(e)});
                break;
            };

            // 如果不需要keep-alive，退出循环
            if (!keep_alive) {
                break;
            }
        }
    }
};
