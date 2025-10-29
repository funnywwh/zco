const std = @import("std");
const context = @import("./context.zig");

/// 中间件函数类型
pub const MiddlewareFn = *const fn (ctx: *context.Context) anyerror!void;

/// 中间件
pub const Middleware = struct {
    const Self = @This();

    handler: MiddlewareFn,
    name: ?[]const u8 = null,

    /// 创建中间件
    pub fn init(handler: MiddlewareFn, name: ?[]const u8) Self {
        return .{
            .handler = handler,
            .name = name,
        };
    }
};

/// 中间件链
pub const MiddlewareChain = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    middlewares: std.ArrayList(Middleware),

    /// 初始化中间件链
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .middlewares = std.ArrayList(Middleware).init(allocator),
        };
    }

    /// 清理中间件链
    pub fn deinit(self: *Self) void {
        self.middlewares.deinit();
    }

    /// 添加中间件
    pub fn use(self: *Self, middleware: Middleware) !void {
        try self.middlewares.append(middleware);
    }

    /// 执行中间件链
    pub fn execute(self: *Self, ctx: *context.Context) !void {
        // 中间件链执行逻辑
        for (self.middlewares.items) |mw| {
            try mw.handler(ctx);
            
            // 如果响应已发送，停止执行
            if (ctx.res.body.items.len > 0 or ctx.res.status != 200) {
                break;
            }
        }
    }
};

/// 内置日志中间件
pub fn logger(ctx: *context.Context) !void {
    const start_time = std.time.nanoTimestamp();
    const method = switch (ctx.req.method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .OPTIONS => "OPTIONS",
        .HEAD => "HEAD",
        .CONNECT => "CONNECT",
        .TRACE => "TRACE",
    };
    
    std.log.info("{s} {s}", .{ method, ctx.req.path });
    
    // 这个中间件只是记录日志，不阻止请求继续
}

/// CORS中间件
pub fn cors(ctx: *context.Context) !void {
    // 设置CORS头
    try ctx.header("Access-Control-Allow-Origin", "*");
    try ctx.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try ctx.header("Access-Control-Allow-Headers", "Content-Type, Authorization");
    
    if (ctx.req.method == .OPTIONS) {
        ctx.res.status = 204;
        try ctx.send();
    }
}

/// 错误处理中间件（简化版本）
pub fn errorHandler(ctx: *context.Context) !void {
    _ = ctx;
    // 错误处理在路由层面完成
}

/// JWT认证中间件（简化版本，需要在使用时设置secret）
/// 注意：由于Zig函数指针不能捕获变量，secret需要通过上下文或其他方式传递
pub fn jwtAuthMiddleware(ctx: *context.Context) !void {
    const jwt = @import("./jwt.zig");
    
    // 从上下文中获取secret（需要在使用前设置）
    const secret_ptr = ctx.get("jwt_secret");
    if (secret_ptr == null) {
        ctx.res.status = 500;
        try ctx.text(500, "JWT secret not configured");
        return;
    }
    
    const secret = @as(*[]const u8, @ptrCast(@alignCast(secret_ptr))).*;
    
    const auth_header = ctx.req.getHeader("Authorization") orelse {
        ctx.res.status = 401;
        try ctx.text(401, "Unauthorized");
        return;
    };

    // 检查Bearer格式
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        ctx.res.status = 401;
        try ctx.text(401, "Invalid Authorization header");
        return;
    }

    const token = auth_header[7..]; // 跳过"Bearer "
    var jwt_impl = jwt.JWT.init(.HS256, secret);

    // 验证token
    var claims = jwt_impl.verify(token, ctx.allocator) catch |e| {
        ctx.res.status = 401;
        const msg = switch (e) {
            error.InvalidToken, error.InvalidSignature => "Invalid token",
            error.ExpiredToken => "Token expired",
            else => "Token verification failed",
        };
        try ctx.text(401, msg);
        return;
    };
    defer claims.deinit();

    // 将claims存储到上下文中
    try ctx.set("claims", @as(*anyopaque, @ptrCast(&claims)));
}
