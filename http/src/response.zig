const std = @import("std");
const nets = @import("nets");

/// HTTP响应构建器
pub const Response = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    
    /// 状态码
    status: u16 = 200,
    
    /// 响应头
    headers: std.StringHashMap([]const u8),
    
    /// 响应体
    body: std.ArrayList(u8),
    
    /// Cookies
    cookies: std.ArrayList(Cookie),

    /// Cookie选项
    pub const CookieOptions = struct {
        max_age: ?i64 = null,
        domain: ?[]const u8 = null,
        path: ?[]const u8 = null,
        secure: bool = false,
        http_only: bool = false,
        same_site: ?[]const u8 = null, // "Strict", "Lax", "None"
    };

    /// Cookie结构
    const Cookie = struct {
        name: []const u8,
        value: []const u8,
        options: CookieOptions,
    };

    /// 初始化响应
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
            .cookies = std.ArrayList(Cookie).init(allocator),
        };
    }

    /// 清理响应资源
    pub fn deinit(self: *Self) void {
        // 释放headers
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*.len > 0) {
                self.allocator.free(entry.value_ptr.*);
            }
        }
        self.headers.deinit();

        // 释放cookies
        for (self.cookies.items) |cookie_item| {
            self.allocator.free(cookie_item.name);
            self.allocator.free(cookie_item.value);
            if (cookie_item.options.domain) |d| {
                self.allocator.free(d);
            }
            if (cookie_item.options.path) |p| {
                self.allocator.free(p);
            }
            if (cookie_item.options.same_site) |ss| {
                self.allocator.free(ss);
            }
        }
        self.cookies.deinit();

        self.body.deinit();
    }

    /// 设置状态码（通过直接访问status字段）

    /// 设置响应头
    pub fn header(self: *Self, key: []const u8, value: []const u8) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        const value_dup = try self.allocator.dupe(u8, value);

        // 如果key已存在，释放旧值
        if (self.headers.get(key_dup)) |old_value| {
            self.allocator.free(old_value);
        }

        try self.headers.put(key_dup, value_dup);
    }

    /// 设置Cookie
    pub fn cookie(self: *Self, name: []const u8, value: []const u8, options: CookieOptions, allocator: std.mem.Allocator) !void {
        const name_dup = try allocator.dupe(u8, name);
        errdefer allocator.free(name_dup);
        
        const value_dup = try allocator.dupe(u8, value);
        errdefer allocator.free(value_dup);

        var opts = options;
        if (options.domain) |d| {
            opts.domain = try allocator.dupe(u8, d);
        }
        if (options.path) |p| {
            opts.path = try allocator.dupe(u8, p);
        }
        if (options.same_site) |ss| {
            opts.same_site = try allocator.dupe(u8, ss);
        }

        try self.cookies.append(Cookie{
            .name = name_dup,
            .value = value_dup,
            .options = opts,
        });
    }

    /// 写入响应体
    pub fn write(self: *Self, data: []const u8) !void {
        try self.body.appendSlice(data);
    }

    /// 发送文本响应
    pub fn text(self: *Self, status: u16, content: []const u8) !void {
        self.status = status;
        try self.header("Content-Type", "text/plain; charset=utf-8");
        try self.body.clearRetainingCapacity();
        try self.write(content);
    }

    /// 发送HTML响应
    pub fn html(self: *Self, status: u16, content: []const u8) !void {
        self.status = status;
        try self.header("Content-Type", "text/html; charset=utf-8");
        try self.body.clearRetainingCapacity();
        try self.write(content);
    }

    /// 发送JSON响应
    pub fn json(self: *Self, status: u16, data: anytype, allocator: std.mem.Allocator) !void {
        self.status = status;
        try self.header("Content-Type", "application/json; charset=utf-8");
        try self.body.clearRetainingCapacity();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try std.json.stringify(data, .{}, buffer.writer());
        try self.write(buffer.items);
    }

    /// 发送响应到TCP连接
    pub fn send(self: *Self, tcp: *nets.Tcp) !void {
        // 构建响应行和头部
        var response_buf = std.ArrayList(u8).init(self.allocator);
        defer response_buf.deinit();

        // 状态文本
        const status_text = switch (self.status) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };

        // 写入响应行
        try response_buf.writer().print("HTTP/1.1 {} {}\r\n", .{ self.status, status_text });

        // 写入Content-Length（如果没有设置）
        if (!self.headers.contains("Content-Length")) {
            try response_buf.writer().print("Content-Length: {}\r\n", .{self.body.items.len});
        }

        // 写入头部
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            try response_buf.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // 写入Cookies
        for (self.cookies.items) |cookie_item| {
            try response_buf.writer().print("Set-Cookie: {s}={s}", .{ cookie_item.name, cookie_item.value });
            if (cookie_item.options.max_age) |max_age| {
                try response_buf.writer().print("; Max-Age={}", .{max_age});
            }
            if (cookie_item.options.domain) |domain| {
                try response_buf.writer().print("; Domain={s}", .{domain});
            }
            if (cookie_item.options.path) |path| {
                try response_buf.writer().print("; Path={s}", .{path});
            }
            if (cookie_item.options.secure) {
                try response_buf.writeAll("; Secure");
            }
            if (cookie_item.options.http_only) {
                try response_buf.writeAll("; HttpOnly");
            }
            if (cookie_item.options.same_site) |same_site| {
                try response_buf.writer().print("; SameSite={s}", .{same_site});
            }
            try response_buf.writeAll("\r\n");
        }

        // 头部结束
        try response_buf.writeAll("\r\n");

        // 写入响应体
        try response_buf.appendSlice(self.body.items);

        // 发送响应
        _ = try tcp.write(response_buf.items);
    }
};

