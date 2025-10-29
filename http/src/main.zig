const std = @import("std");
const zco = @import("zco");
const http = @import("http");

/// HTTP服务器示例程序
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    const schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 创建HTTP服务器
    var server = http.Server.init(allocator, schedule);
    defer server.deinit();

    // 添加中间件
    try server.use(http.middleware.Middleware.init(http.middleware.logger, "logger"));
    try server.use(http.middleware.Middleware.init(http.middleware.cors, "cors"));

    // 路由示例
    try server.get("/", handleRoot);
    try server.get("/hello/:name", handleHello);
    try server.post("/api/login", handleLogin);
    try server.get("/api/protected", handleProtected);
    try server.post("/api/upload", handleUpload);

    // 启动服务器
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try server.listen(address);

    // 启动调度器循环
    try schedule.loop();
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
