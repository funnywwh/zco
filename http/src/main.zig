const std = @import("std");
const zco = @import("zco");
const http = @import("http");

/// HTTP服务器示例程序
pub fn main() !void {
    // 使用 zco.loop 包装整个服务器启动逻辑
    _ = try zco.loop(struct {
        fn run() !void {
            const allocator = (try zco.getSchedule()).allocator;
            const schedule = try zco.getSchedule();

            // 创建HTTP服务器
            // 注意：server.deinit() 不应该在这里使用 defer
            // 因为 listen() 会一直运行，直到程序退出
            var server = http.Server.init(allocator, schedule);
            // 启用新的流式解析器（事件驱动、零内存积累）
            server.setUseStreamingParser(true);
            // defer server.deinit(); // 不在这里清理，避免在 listen 运行时清理资源

            // 添加中间件
            try server.use(http.middleware.Middleware.init(http.middleware.logger, "logger"));
            // try server.use(http.middleware.Middleware.init(http.middleware.cors, "cors")); // 已禁用 CORS 中间件

            // 路由示例
            try server.get("/", handleRoot);
            try server.get("/hello/:name", handleHello);
            try server.post("/api/login", handleLogin);
            try server.get("/api/protected", handleProtected);
            try server.post("/api/upload", handleUpload);

            // 启动服务器（listen需要在协程环境中调用）
            const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
            try server.listen(address);
        }
    }.run, .{});
}

/// 根路径处理
fn handleRoot(ctx: *http.Context) !void {
    try ctx.text(200, "Hello from ZCO HTTP Framework!");
}

/// Hello路由（带参数）
fn handleHello(ctx: *http.Context) !void {
    const name = ctx.req.getParam("name") orelse "World";
    const message = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name});
    defer ctx.allocator.free(message);
    try ctx.text(200, message);
}

/// 登录处理（JWT示例）
fn handleLogin(ctx: *http.Context) !void {
    // 解析请求体（JSON）
    if (ctx.req.body.len == 0) {
        try ctx.text(400, "Missing request body");
        return;
    }

    // 简单的登录验证（示例）
    // 实际应用中应该从数据库验证用户
    const token = try generateToken(ctx.allocator, "user123");
    defer ctx.allocator.free(token);

    var response_json = std.ArrayList(u8).init(ctx.allocator);
    defer response_json.deinit();

    try response_json.writer().print("{{\"token\":\"{s}\"}}", .{token});
    try ctx.jsonString(200, response_json.items);
}

/// 生成JWT Token (暂时返回简单token字符串)
fn generateToken(allocator: std.mem.Allocator, user_id: []const u8) ![]u8 {
    // TODO: 修复JSON解析问题后恢复完整JWT实现
    // const secret = "your-secret-key";
    // var jwt_impl = http.JWT.init(http.jwt.Algorithm.HS256, secret);
    // var claims = http.jwt.Claims.init(allocator);
    // defer claims.deinit();
    // claims.sub = user_id;
    // const now = std.time.timestamp();
    // claims.iat = now;
    // claims.exp = now + 3600;
    // const token = try jwt_impl.sign(&claims, allocator);
    // return token;

    // 临时返回简单token
    const token = try std.fmt.allocPrint(allocator, "simple-token-for-{s}", .{user_id});
    return token;
}

/// 受保护的路由处理
fn handleProtected(ctx: *http.Context) !void {
    // 这个路由需要JWT认证
    // 在实际应用中，应该使用JWT中间件

    // 简单的token检查
    const auth_header = ctx.req.getHeader("Authorization") orelse {
        try ctx.text(401, "Unauthorized");
        return;
    };

    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        try ctx.text(401, "Invalid Authorization header");
        return;
    }

    try ctx.text(200, "Protected resource accessed successfully");
}

/// 文件上传处理
fn handleUpload(ctx: *http.Context) !void {
    const content_type = ctx.req.content_type orelse {
        try ctx.text(400, "Missing Content-Type");
        return;
    };

    if (!std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        try ctx.text(400, "Invalid Content-Type");
        return;
    }

    var uploader = http.upload.Upload.init(ctx.allocator);
    const files = try uploader.parseMultipart(ctx.req.body, content_type);
    defer {
        for (files.items) |*file| {
            file.deinit();
        }
        files.deinit();
    }

    var response_msg = std.ArrayList(u8).init(ctx.allocator);
    defer response_msg.deinit();

    try response_msg.writer().print("Uploaded {} file(s)", .{files.items.len});
    try ctx.text(200, response_msg.items);
}
