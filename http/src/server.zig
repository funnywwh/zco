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
    worker_pool_size: usize = 2000, // 工作协程池大小（增加到 2000 以处理高并发）
    channel_buffer: usize = 20000, // channel 缓冲大小（增加到 20000 以处理高并发）
    max_connections: u32 = 10000, // 最大连接数

    /// 连接计数器（原子操作）
    connection_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 是否使用协程池模式
    use_pool: bool = true, // 默认启用协程池

    /// Channel 用于协程池（生命周期需要与 Server 一致）
    client_chan: ?*zco.CreateChan(*nets.Tcp) = null,

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
            .client_chan = null,
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
    pub fn setUsePool(self: *Self, enable: bool) void {
        self.use_pool = enable;
    }

    /// 清理服务器资源
    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.middleware_chain.deinit();
        if (self.tcp) |tcp| {
            tcp.close();
            tcp.deinit();
        }
        // 清理 channel（如果使用了协程池）
        if (self.client_chan) |chan| {
            chan.close();
            chan.deinit();
            self.client_chan = null;
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

            // 为每个连接启动协程（直接模式下，handleConnection 需要清理 client）
            _ = try self.schedule.go(struct {
                fn run(server_ptr: *Self, client_ptr: *nets.Tcp) !void {
                    defer {
                        client_ptr.close();
                        client_ptr.deinit();
                    }
                    try handleConnection(server_ptr, client_ptr);
                }
            }.run, .{ self, client });
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

        // 创建 channel 用于传递客户端连接（生命周期与 Server 一致）
        const TcpChan = zco.CreateChan(*nets.Tcp);
        const client_chan = try TcpChan.init(self.schedule, self.channel_buffer);
        self.client_chan = client_chan; // 保存引用，在 deinit 时清理

        // 创建固定数量的工作协程池
        // 注意：必须捕获 channel 指针，确保生命周期一致
        for (0..self.worker_pool_size) |_| {
            _ = try self.schedule.go(struct {
                fn run(server_ptr: *Self, chan_ptr: *TcpChan) !void {
                    // 确保 channel 指针有效
                    const chan = chan_ptr;
                    while (true) {
                        // 捕获 recv 可能抛出的错误（包括 closed 错误）
                        var client = chan.recv() catch |e| {
                            // channel 关闭或错误时退出
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

                        // 使用现有的 handleConnection 逻辑处理连接
                        // handleConnection 会处理 keep-alive 连接的所有请求
                        handleConnection(server_ptr, client) catch |e| {
                            std.log.err("Handle connection error: {s}", .{@errorName(e)});
                        };

                        // 连接处理完成后清理资源并更新计数器
                        _ = server_ptr.connection_count.fetchSub(1, .monotonic);
                        client.close();
                        client.deinit();
                    }
                }
            }.run, .{ self, client_chan });
        }

        // 启动服务器协程：accept 循环并将连接发送到 channel
        // 注意：必须确保 channel 和 tcp 的生命周期一致
        _ = try self.schedule.go(struct {
            fn run(tcp_ptr: *nets.Tcp, chan_ptr: *TcpChan) !void {
                const chan = chan_ptr; // 保存本地引用
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

        // listenWithPool 必须在协程中运行并阻塞
        // 由于 accept 和 worker 协程都在后台运行，
        // 这个函数需要无限阻塞，保持 channel 的生命周期
        // 使用一个永不退出的循环来阻塞
        while (true) {
            // 使用协程的 Suspend 来阻塞，而不是 Sleep
            // 这样可以避免 CPU 占用，同时保持函数不返回
            const co = self.schedule.runningCo orelse {
                std.log.err("listenWithPool must be called in a coroutine context", .{});
                return error.CallInSchedule;
            };
            try co.Sleep(60 * std.time.ns_per_s); // 睡眠60秒，避免频繁检查
        }
    }

    /// 处理单个连接（支持HTTP keep-alive）
    /// 注意：调用者负责 client 的清理（close 和 deinit）
    /// - 直接模式：协程中使用 defer 清理
    /// - 协程池模式：工作协程中手动清理
    fn handleConnection(server: *Self, client: *nets.Tcp) !void {
        var buffer = try server.allocator.alloc(u8, server.read_buffer_size);
        defer server.allocator.free(buffer);

        // 支持HTTP keep-alive：在同一连接上处理多个请求
        var keep_alive = false; // 默认关闭，需要通过 Connection 头明确指定
        var buffer_used: usize = 0; // 已使用的缓冲区大小（用于处理粘包）

        // 参考 nets 的实现：循环处理请求，直到连接关闭或 keep_alive = false
        while (true) {
            // 每次请求开始时重置 keep_alive（会根据当前请求的 Connection 头重新设置）
            keep_alive = false;

            // 参考 nets：每次循环开始时尝试读取，检测连接是否关闭
            // nets 的做法是 while (keepalive) { n = read(buffer[0..]); if (n == 0) break; ... }
            // 关键：即使有粘包数据，也要在循环开始时先读取一次来检测连接关闭
            // 但如果有粘包数据，我们可以先处理它们，不需要先读取
            var total_read: usize = buffer_used;
            var header_end: ?usize = null;
            var content_length: ?usize = null;

            // 如果有缓冲区剩余数据（粘包），先尝试从中找到请求边界
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
                        const cl_line = buffer[cl_start + 15 .. cl_end];
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
                        if (total_read < expected_total) {
                            if (total_read >= buffer.len) {
                                std.log.warn("Request body too large, buffer: {}, expected: {}", .{ buffer.len, expected_total });
                                keep_alive = false;
                                break;
                            }
                            // 继续读取请求体
                            const n = client.read(buffer[total_read..]) catch |e| {
                                // EOF 错误表示连接关闭，这是正常情况，不需要记录错误
                                if (std.mem.eql(u8, @errorName(e), "EOF")) {
                                    keep_alive = false;
                                    return;
                                }
                                std.log.err("Read error: {s}", .{@errorName(e)});
                                keep_alive = false;
                                return;
                            };
                            if (n == 0) {
                                // 连接关闭，请求体不完整
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

                // 参考 nets：读取数据，如果连接关闭（n == 0），直接退出
                const n = client.read(buffer[total_read..]) catch |e| {
                    // EOF 错误表示连接关闭，这是正常情况，不需要记录错误
                    if (std.mem.eql(u8, @errorName(e), "EOF")) {
                        keep_alive = false;
                        return;
                    }
                    std.log.err("Read error: {s}", .{@errorName(e)});
                    keep_alive = false;
                    return;
                };

                if (n == 0) {
                    // 连接关闭（参考 nets：if (n == 0) break）
                    if (total_read == 0) {
                        // 没有读取任何数据，连接已关闭（这是循环开始时的第一次读取）
                        return;
                    }
                    // 有数据但连接关闭，尝试解析最后一个请求
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
                                const cl_line = buffer[cl_start + 15 .. cl_end];
                                const cl_str = std.mem.trim(u8, cl_line, " \t");
                                content_length = std.fmt.parseInt(usize, cl_str, 10) catch null;
                            }
                        }
                    } else {
                        // 没有找到头部结束标记，且已经读取了一些数据
                        // 如果连接关闭（n == 0），说明这是最后一个请求的最后一个片段
                        // 在下一个循环中，如果没有找到 header_end，且没有更多数据，会退出
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

            // 如果没有找到完整的请求头部，且连接已关闭，直接退出
            if (header_end == null) {
                // 数据不完整，无法解析请求，退出
                keep_alive = false;
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

            // 解析请求（只解析当前请求部分）
            ctx.req.parse(buffer[0..request_size]) catch |e| {
                std.log.err("Parse error: {s}", .{@errorName(e)});
                ctx.res.status = 400;
                try ctx.text(400, "Bad Request");
                try ctx.send();
                ctx.deinit();
                break;
            };

            // 检查Connection头（在清理上下文之前检查，因为需要用到 req）
            // keep_alive 在循环开始时已重置为 false，只需要检查是否启用

            // 检查Connection头（只有明确指定 keep-alive 时才启用）
            const connection_header = ctx.req.getHeader("Connection");
            if (connection_header) |conn| {
                const conn_trimmed = std.mem.trim(u8, conn, " ");
                var conn_lower_buf: [16]u8 = undefined;
                if (conn_trimmed.len < conn_lower_buf.len) {
                    for (conn_trimmed, 0..) |c, i| {
                        conn_lower_buf[i] = std.ascii.toLower(c);
                    }
                    const conn_lower = conn_lower_buf[0..conn_trimmed.len];
                    if (std.mem.eql(u8, conn_lower, "keep-alive")) {
                        keep_alive = true;
                    }
                    // 如果是 "close" 或未指定，keep_alive 保持 false
                }
            }

            // 处理粘包：如果有剩余数据，移到缓冲区开头
            // 注意：必须在解析和检查 Connection 之后进行，因为需要使用 request_size
            if (total_read > request_size) {
                const remaining = total_read - request_size;
                @memcpy(buffer[0..remaining], buffer[request_size..total_read]);
                buffer_used = remaining;
            } else {
                buffer_used = 0;
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
            if (!ctx.res.sent and ctx.res.body.items.len == 0 and ctx.res.status == 200) {
                server.router.handle(&ctx) catch |e| {
                    std.log.err("Route error: {s}", .{@errorName(e)});
                    ctx.res.status = 500;
                    try ctx.text(500, "Internal Server Error");
                };
            }

            // 发送响应（如果还没有发送）
            if (!ctx.res.sent) {
                ctx.send() catch |e| {
                    std.log.err("Send error: {s}", .{@errorName(e)});
                    ctx.deinit();
                    break;
                };
            }

            // 清理上下文（在发送响应后清理）
            ctx.deinit();

            // 如果不需要keep-alive，退出循环
            if (!keep_alive) {
                break;
            }

            // 参考 nets：如果需要 keep-alive 且缓冲区为空，先读取一次检测连接是否关闭
            // 这确保我们在下一个循环开始时能及时检测到连接关闭
            if (buffer_used == 0) {
                const test_read = client.read(buffer[0..1]) catch |e| {
                    // EOF 错误表示连接关闭，这是正常情况，不需要记录错误
                    if (std.mem.eql(u8, @errorName(e), "EOF")) {
                        break;
                    }
                    std.log.err("Read error: {s}", .{@errorName(e)});
                    break;
                };
                if (test_read == 0) {
                    // 连接已关闭（参考 nets：if (n == 0) break）
                    break;
                }
                // 有一个字节的数据，设置 buffer_used，下次循环时会处理
                buffer_used = test_read;
            }
        }
    }
};
