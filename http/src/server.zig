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

    /// 协程池配置
    worker_pool_size: usize = 100, // 工作协程池大小
    channel_buffer: usize = 1000, // channel 缓冲大小
    max_connections: u32 = 10000, // 最大连接数

    /// 连接计数器（原子操作）
    connection_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 是否使用协程池模式
    use_pool: bool = true, // 默认启用协程池

    /// 初始化服务器
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule) Self {
        return .{
            .allocator = allocator,
            .schedule = schedule,
            .router = router.Router.init(allocator),
            .middleware_chain = middleware.MiddlewareChain.init(allocator),
            .worker_pool_size = 100,
            .channel_buffer = 1000,
            .max_connections = 10000,
            .connection_count = std.atomic.Value(u32).init(0),
            .use_pool = true,
        };
    }

    /// 设置协程池大小
    pub fn setWorkerPoolSize(self: *Self, size: usize) void {
        self.worker_pool_size = size;
    }

    /// 设置 channel 缓冲大小
    pub fn setChannelBuffer(self: *Self, size: usize) void {
        self.channel_buffer = size;
    }

    /// 设置最大连接数
    pub fn setMaxConnections(self: *Self, max: u32) void {
        self.max_connections = max;
    }

    /// 启用/禁用协程池模式
    pub fn setUsePool(self: *Self, use: bool) void {
        self.use_pool = use;
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
        if (self.use_pool) {
            try self.listenWithPool(address);
        } else {
            try self.listenDirect(address);
        }
    }

    /// 直接模式：为每个连接创建协程（原始方式）
    fn listenDirect(self: *Self, address: std.net.Address) !void {
        const tcp = try nets.Tcp.init(self.schedule);
        errdefer tcp.deinit();

        try tcp.bind(address);
        try tcp.listen(128);

        self.tcp = tcp;

        std.log.info("HTTP server listening on {} (direct mode)", .{address});

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

    /// 协程池模式：使用固定数量的工作协程处理连接
    fn listenWithPool(self: *Self, address: std.net.Address) !void {
        const tcp = try nets.Tcp.init(self.schedule);
        errdefer tcp.deinit();

        try tcp.bind(address);
        try tcp.listen(@intCast(self.max_connections));

        self.tcp = tcp;

        std.log.info("HTTP server listening on {} (pool mode)", .{address});
        std.log.info("Worker pool size: {}, Channel buffer: {}, Max connections: {}", .{ self.worker_pool_size, self.channel_buffer, self.max_connections });

        // 创建 channel 用于传递客户端连接
        const TcpChan = zco.CreateChan(*nets.Tcp);
        var client_chan = try TcpChan.init(self.schedule, self.channel_buffer);
        defer {
            client_chan.close();
            client_chan.deinit();
        }

        // 创建固定数量的工作协程池
        for (0..self.worker_pool_size) |_| {
            _ = try self.schedule.go(struct {
                fn run(server_ptr: *Self, chan: *TcpChan) !void {
                    while (true) {
                        var client = chan.recv() catch |e| {
                            // channel 关闭时退出
                            std.log.info("Worker exiting: {s}", .{@errorName(e)});
                            break;
                        };

                        // 检查连接数限制
                        const current_connections = server_ptr.connection_count.load(.monotonic);
                        if (current_connections >= server_ptr.max_connections) {
                            std.log.warn("Max connections reached ({}), dropping connection", .{server_ptr.max_connections});
                            client.close();
                            client.deinit();
                            continue;
                        }

                        _ = server_ptr.connection_count.fetchAdd(1, .monotonic);

                        // 处理客户端连接
                        defer {
                            _ = server_ptr.connection_count.fetchSub(1, .monotonic);
                            client.close();
                            client.deinit();
                        }

                        // 使用现有的 handleConnection 逻辑
                        handleConnection(server_ptr, client) catch |e| {
                            std.log.err("Handle connection error: {s}", .{@errorName(e)});
                        };
                    }
                }
            }.run, .{ self, client_chan });
        }

        // 启动服务器协程：accept 循环并将连接发送到 channel
        _ = try self.schedule.go(struct {
            fn run(tcp_ptr: *nets.Tcp, chan: *TcpChan) !void {
                while (true) {
                    var client = tcp_ptr.accept() catch |e| {
                        std.log.err("Server accept error: {s}", .{@errorName(e)});
                        continue;
                    };

                    // 将客户端连接发送到 channel，由工作协程处理
                    chan.send(client) catch |e| {
                        std.log.err("Failed to send client to channel: {s}", .{@errorName(e)});
                        client.close();
                        client.deinit();
                    };
                }
            }
        }.run, .{ tcp, client_chan });

        // 阻塞等待（listenWithPool 会在协程池中继续运行）
        // 注意：这里不应该返回，应该让协程继续运行
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
        var buffer_used: usize = 0; // 已使用的缓冲区大小（用于处理粘包）
        
        while (keep_alive) {
            // 读取请求（可能需要多次读取才能完整）
            var total_read: usize = buffer_used;
            var header_end: ?usize = null;
            var content_length: ?usize = null;
            
            // 先尝试从现有缓冲区中找到请求边界
            if (buffer_used > 0) {
                if (std.mem.indexOf(u8, buffer[0..buffer_used], "\r\n\r\n")) |pos| {
                    header_end = pos + 4;
                    
                    // 尝试解析Content-Length（简化实现）
                    const h_end = header_end.?;
                    if (std.mem.indexOf(u8, buffer[0..h_end], "Content-Length:")) |cl_start| {
                        var cl_end = cl_start;
                        while (cl_end < h_end and buffer[cl_end] != '\r') {
                            cl_end += 1;
                        }
                        const cl_line = buffer[cl_start + 15..cl_end];
                        const cl_str = std.mem.trim(u8, cl_line, " \t");
                        content_length = std.fmt.parseInt(usize, cl_str, 10) catch null;
                    }
                }
            }
            
            // 需要读取完整的请求
            while (true) {
                // 如果已经找到了头部结束，检查是否需要继续读取请求体
                if (header_end) |h_end| {
                    if (content_length) |cl| {
                        const body_start = h_end;
                        const expected_total = body_start + cl;
                        if (total_read >= expected_total) {
                            // 请求完整
                            break;
                        }
                        if (total_read < expected_total and total_read < buffer.len) {
                            // 继续读取请求体
                            const n = client.read(buffer[total_read..]) catch |e| {
                                std.log.err("Read error: {s}", .{@errorName(e)});
                                return;
                            };
                            if (n == 0) {
                                // 连接关闭
                                keep_alive = false;
                                break;
                            }
                            total_read += n;
                            continue;
                        }
                    } else {
                        // 没有Content-Length，头部结束就是请求结束（GET请求）
                        break;
                    }
                }
                
                // 需要读取更多数据来找到头部结束
                if (total_read >= buffer.len) {
                    std.log.warn("Request buffer too small or request too large", .{});
                    keep_alive = false;
                    break;
                }
                
                const n = client.read(buffer[total_read..]) catch |e| {
                    std.log.err("Read error: {s}", .{@errorName(e)});
                    keep_alive = false;
                    break;
                };

                if (n == 0) {
                    // 连接关闭
                    if (total_read == 0) {
                        keep_alive = false;
                        break;
                    }
                    // 有数据但连接关闭，尝试解析
                    break;
                }
                
                total_read += n;
                
                // 查找头部结束标记
                if (header_end == null) {
                    if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n")) |pos| {
                        const h_end = pos + 4;
                        header_end = h_end;
                        
                        // 解析Content-Length
                        if (std.mem.indexOf(u8, buffer[0..h_end], "Content-Length:")) |cl_start| {
                            var cl_end = cl_start;
                            while (cl_end < h_end and buffer[cl_end] != '\r') {
                                cl_end += 1;
                            }
                            if (cl_end > cl_start + 15) {
                                const cl_line = buffer[cl_start + 15..cl_end];
                                const cl_str = std.mem.trim(u8, cl_line, " \t");
                                content_length = std.fmt.parseInt(usize, cl_str, 10) catch null;
                            }
                        }
                    }
                } else if (content_length) |cl| {
                    // 已找到头部，检查请求体是否完整
                    const h_end = header_end.?;
                    const body_start = h_end;
                    const expected_total = body_start + cl;
                    if (total_read >= expected_total) {
                        break;
                    }
                }
            }

            if (total_read == 0) {
                // 没有数据，连接已关闭
                break;
            }

            // 确定实际请求的大小（处理粘包）
            const h_end = header_end orelse total_read;
            const request_size = if (content_length) |cl| 
                h_end + cl
            else 
                h_end;
                
            if (request_size > total_read) {
                std.log.warn("Incomplete request, total: {}, expected: {}", .{ total_read, request_size });
                break;
            }

            // 创建上下文（每次请求都需要新的上下文）
            var ctx = context.Context.init(server.allocator, server.schedule, client);
            defer ctx.deinit();

            // 解析请求（只解析当前请求部分）
            ctx.req.parse(buffer[0..request_size]) catch |e| {
                std.log.err("Parse error: {s}", .{@errorName(e)});
                ctx.res.status = 400;
                try ctx.text(400, "Bad Request");
                try ctx.send();
                break;
            };
            
            // 处理粘包：如果有剩余数据，移到缓冲区开头
            if (total_read > request_size) {
                const remaining = total_read - request_size;
                @memcpy(buffer[0..remaining], buffer[request_size..total_read]);
                buffer_used = remaining;
            } else {
                buffer_used = 0;
            }

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
