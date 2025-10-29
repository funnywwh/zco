# HTTP 框架模块

基于 ZCO 协程库实现的高性能 HTTP 框架，提供完整的 Web 开发功能。

## 特性

- 🚀 **高性能**: 基于协程的异步IO，支持高并发
- 📦 **完整的路由系统**: 支持RESTful路由、路径参数、路由组
- 🔌 **中间件支持**: 灵活的中间件链，支持日志、CORS、JWT等
- 🔐 **JWT认证**: 内置JWT token生成和验证
- 📁 **文件上传**: 支持multipart/form-data文件上传
- 🌐 **静态文件服务**: 内置静态文件服务功能
- 🎨 **模板引擎**: 支持模板渲染
- ⚡ **WebSocket升级**: 支持HTTP升级到WebSocket
- 📝 **JSON支持**: 完整的JSON请求/响应处理

## 快速开始

### 构建

```bash
cd http
zig build
```

### 运行示例

```bash
zig build run
```

服务器将在 `http://127.0.0.1:8080` 启动。

## 基本使用

### 创建服务器

```zig
const std = @import("std");
const zco = @import("zco");
const http = @import("http");

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

    // 添加路由
    try server.get("/", handleRoot);
    try server.get("/hello/:name", handleHello);

    // 启动服务器
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try server.listen(address);

    try schedule.loop();
}

fn handleRoot(ctx: *http.Context) !void {
    try ctx.text(200, "Hello from ZCO HTTP Framework!");
}

fn handleHello(ctx: *http.Context) !void {
    const name = ctx.req.getParam("name") orelse "World";
    const message = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name});
    defer ctx.allocator.free(message);
    try ctx.text(200, message);
}
```

## 路由

### 基本路由

```zig
// GET路由
try server.get("/users", handleUsers);

// POST路由
try server.post("/users", createUser);

// PUT路由
try server.put("/users/:id", updateUser);

// DELETE路由
try server.delete("/users/:id", deleteUser);

// PATCH路由
try server.patch("/users/:id", patchUser);
```

### 路径参数

```zig
fn handleUser(ctx: *http.Context) !void {
    // 获取路径参数
    const id = ctx.req.getParam("id") orelse {
        try ctx.text(400, "Missing id parameter");
        return;
    };
    
    try ctx.text(200, id);
}
```

### 查询参数

```zig
fn handleSearch(ctx: *http.Context) !void {
    // 获取查询参数
    const query = ctx.req.getQuery("q") orelse {
        try ctx.text(400, "Missing query parameter");
        return;
    };
    
    try ctx.text(200, query);
}
```

### 请求体

```zig
fn handlePost(ctx: *http.Context) !void {
    // 获取请求体
    const body = ctx.req.body;
    
    // 解析JSON（需要手动解析或使用JSON库）
    // ...
    
    try ctx.text(200, "Success");
}
```

## 响应

### 文本响应

```zig
fn handleText(ctx: *http.Context) !void {
    try ctx.text(200, "Hello, World!");
}
```

### JSON响应

```zig
fn handleJSON(ctx: *http.Context) !void {
    // 方式1: 直接传递字符串
    try ctx.json(200, "{\"message\":\"success\"}");
    
    // 方式2: 使用ArrayList构建
    var json = std.ArrayList(u8).init(ctx.allocator);
    defer json.deinit();
    try json.writer().print("{{\"status\":\"ok\"}}", .{});
    try ctx.json(200, json.items);
}
```

### HTML响应

```zig
fn handleHTML(ctx: *http.Context) !void {
    try ctx.html(200, "<h1>Hello, World!</h1>");
}
```

### 自定义响应头

```zig
fn handleCustomHeaders(ctx: *http.Context) !void {
    try ctx.header("X-Custom-Header", "value");
    try ctx.text(200, "Response with custom header");
}
```

### 设置Cookie

```zig
fn handleCookie(ctx: *http.Context) !void {
    const options = http.response.CookieOptions{
        .max_age = 3600, // 1小时
        .path = "/",
        .http_only = true,
    };
    try ctx.cookie("session_id", "abc123", options);
    try ctx.text(200, "Cookie set");
}
```

## 中间件

### 使用内置中间件

```zig
// 日志中间件
try server.use(http.middleware.Middleware.init(http.middleware.logger, "logger"));

// CORS中间件
try server.use(http.middleware.Middleware.init(http.middleware.cors, "cors"));
```

### 创建自定义中间件

```zig
fn authMiddleware(ctx: *http.Context) !void {
    const token = ctx.req.getHeader("Authorization") orelse {
        ctx.res.status = 401;
        try ctx.text(401, "Unauthorized");
        return;
    };
    
    // 验证token...
    // 如果验证失败，返回错误
    // 如果验证成功，继续执行
}

// 使用自定义中间件
try server.use(http.middleware.Middleware.init(authMiddleware, "auth"));
```

### JWT认证中间件

```zig
// 在路由处理前设置JWT secret
fn setupJWTAuth(ctx: *http.Context) !void {
    const secret = "your-secret-key";
    const secret_slice: *[]const u8 = try ctx.allocator.create([]const u8);
    secret_slice.* = secret;
    try ctx.set("jwt_secret", secret_slice);
}

// 使用JWT认证中间件
try server.use(http.middleware.Middleware.init(http.middleware.jwtAuthMiddleware, "jwt"));
```

## JWT认证

### 生成JWT Token

```zig
fn generateToken(allocator: std.mem.Allocator, user_id: []const u8) ![]u8 {
    const secret = "your-secret-key";
    var jwt_impl = http.JWT.init(http.jwt.Algorithm.HS256, secret);

    var claims = http.jwt.Claims.init(allocator);
    defer claims.deinit();

    claims.sub = user_id;
    const now = std.time.timestamp();
    claims.iat = now;
    claims.exp = now + 3600; // 1小时过期

    const token = try jwt_impl.sign(&claims, allocator);
    return token;
}
```

### 验证JWT Token

```zig
fn verifyToken(ctx: *http.Context, token: []const u8) !void {
    const secret = "your-secret-key";
    var jwt_impl = http.JWT.init(http.jwt.Algorithm.HS256, secret);
    
    var claims = try jwt_impl.verify(token, ctx.allocator);
    defer claims.deinit();
    
    // 使用claims
    const user_id = claims.sub orelse "";
    // ...
}
```

## 文件上传

### 处理文件上传

```zig
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

    // 处理上传的文件
    for (files.items) |*file| {
        std.log.info("File: {}, Size: {}", .{ file.filename, file.data.items.len });
        // 保存文件...
    }

    try ctx.text(200, "File uploaded successfully");
}
```

## 静态文件服务

```zig
// 创建静态文件服务
var static_files = http.static_files.StaticFiles.init(ctx.allocator, "/path/to/static/dir");
defer static_files.deinit();

// 服务静态文件
try server.get("/static/*", handleStaticFiles);

fn handleStaticFiles(ctx: *http.Context) !void {
    // 从路径中提取文件路径
    const file_path = ctx.req.path[8..]; // 跳过"/static/"
    
    // 使用静态文件服务（需要将static_files存储到上下文）
    const static_ptr = ctx.get("static_files") orelse {
        try ctx.text(500, "Static files not configured");
        return;
    };
    const static_files = @as(*http.static_files.StaticFiles, @ptrCast(@alignCast(static_ptr)));
    try static_files.serve(ctx, file_path);
}
```

## 模板引擎

```zig
fn handleTemplate(ctx: *http.Context) !void {
    // 创建模板引擎
    var tmpl = http.template.Template.init(ctx.allocator);
    defer tmpl.deinit();
    
    // 设置变量
    const name_str = "World";
    const name = try ctx.allocator.dupe(u8, name_str);
    defer ctx.allocator.free(name);
    try tmpl.set("name", name);
    
    // 渲染模板
    const template_str = "<h1>Hello, {{name}}!</h1>";
    const rendered = try tmpl.render(template_str);
    defer ctx.allocator.free(rendered);
    
    try ctx.html(200, rendered);
}

// 或使用renderFile从文件加载模板
fn handleTemplateFile(ctx: *http.Context) !void {
    var tmpl = http.template.Template.init(ctx.allocator);
    defer tmpl.deinit();
    
    // 设置变量
    const name_str = "World";
    const name = try ctx.allocator.dupe(u8, name_str);
    defer ctx.allocator.free(name);
    try tmpl.set("name", name);
    
    // 从文件渲染
    const rendered = try tmpl.renderFile("templates/index.html");
    defer ctx.allocator.free(rendered);
    
    try ctx.html(200, rendered);
}

// 或使用renderAndSend直接渲染并发送
fn handleTemplateAndSend(ctx: *http.Context) !void {
    var tmpl = http.template.Template.init(ctx.allocator);
    defer tmpl.deinit();
    
    // 设置变量
    const name_str = "World";
    const name = try ctx.allocator.dupe(u8, name_str);
    defer ctx.allocator.free(name);
    try tmpl.set("name", name);
    
    // 渲染并发送
    try tmpl.renderAndSend(ctx, "<h1>Hello, {{name}}!</h1>");
}
```

## WebSocket升级

```zig
fn handleUpgrade(ctx: *http.Context) !void {
    // 检查是否是WebSocket升级请求
    const upgrade = ctx.req.getHeader("Upgrade") orelse {
        try ctx.text(400, "Not an upgrade request");
        return;
    };
    
    if (std.mem.eql(u8, upgrade, "websocket")) {
        // 使用upgrade模块处理WebSocket升级
        // 注意：需要检查upgrade模块的具体API
        // try http.upgrade.upgradeToWebSocket(ctx);
        // 或者手动处理升级（参考websocket模块的handshake）
    }
    
    try ctx.text(400, "Not a WebSocket upgrade request");
}
```

## 上下文(Context)

### 存储和获取数据

```zig
fn middlewareExample(ctx: *http.Context) !void {
    // 存储数据到上下文
    const user_id = "123";
    const user_id_ptr: *const []const u8 = try ctx.allocator.dupe([]const u8, user_id);
    try ctx.set("user_id", user_id_ptr);
}

fn handlerExample(ctx: *http.Context) !void {
    // 从上下文获取数据
    const user_id_ptr = ctx.get("user_id") orelse {
        try ctx.text(400, "User not found in context");
        return;
    };
    const user_id = @as(*[]const u8, @ptrCast(@alignCast(user_id_ptr))).*;
    // 使用user_id...
}
```

## 错误处理

```zig
fn handleWithError(ctx: *http.Context) !void {
    // 返回错误响应
    ctx.res.status = 400;
    try ctx.text(400, "Bad Request");
    
    // 或使用JSON错误响应
    ctx.res.status = 500;
    try ctx.json(500, "{\"error\":\"Internal Server Error\"}");
}
```

## 完整示例

参见 `http/src/main.zig` 查看完整的示例程序，包括：
- 基本路由
- 路径参数
- POST请求处理
- JWT认证
- 文件上传
- 中间件使用

## API参考

### Server

- `init(allocator, schedule)` - 初始化服务器
- `deinit()` - 清理服务器资源
- `get(path, handler)` - 注册GET路由
- `post(path, handler)` - 注册POST路由
- `put(path, handler)` - 注册PUT路由
- `delete(path, handler)` - 注册DELETE路由
- `patch(path, handler)` - 注册PATCH路由
- `use(middleware)` - 添加中间件
- `listen(address)` - 监听指定地址

### Context

- `text(status, content)` - 发送文本响应
- `json(status, data)` - 发送JSON响应
- `html(status, content)` - 发送HTML响应
- `header(key, value)` - 设置响应头
- `cookie(name, value, options)` - 设置Cookie
- `send()` - 发送响应
- `set(key, value)` - 存储数据到上下文
- `get(key)` - 从上下文获取数据

### Request

- `getParam(name)` - 获取路径参数
- `getQuery(name)` - 获取查询参数
- `getHeader(name)` - 获取HTTP头
- `method` - HTTP方法
- `path` - 请求路径
- `body` - 请求体
- `content_type` - Content-Type
- `content_length` - Content-Length

### Response

- `status` - HTTP状态码
- `header(key, value)` - 设置响应头
- `cookie(name, value, options)` - 设置Cookie

## 性能优化

### 配置缓冲区大小

```zig
var server = http.Server.init(allocator, schedule);
server.read_buffer_size = 16384; // 16KB读取缓冲区
server.max_request_size = 10 * 1024 * 1024; // 10MB最大请求大小
```

### 中间件优化

- 将频繁使用的中间件放在前面
- 避免在中间件中进行耗时的操作
- 使用上下文缓存计算结果

## 注意事项

1. **内存管理**: 所有分配的内存都需要手动释放，使用`defer`确保资源清理
2. **协程环境**: 所有HTTP处理函数必须在协程环境中运行
3. **错误处理**: 确保所有错误都被正确处理，避免协程崩溃
4. **资源释放**: 使用`defer`确保连接和资源正确关闭

## 依赖

- `zco` - ZCO协程库
- `nets` - 网络模块（TCP支持）

## 许可证

本项目采用 MIT 许可证。
