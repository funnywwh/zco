const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const request = @import("./request.zig");
const response = @import("./response.zig");

/// HTTP请求上下文，包含请求、响应和中间件数据
pub const Context = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    tcp: *nets.Tcp,
    req: request.Request,
    res: response.Response,
    
    /// 用户自定义数据存储
    values: std.StringHashMap(*anyopaque),

    /// 创建新的上下文
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule, tcp: *nets.Tcp) Self {
        return .{
            .allocator = allocator,
            .schedule = schedule,
            .tcp = tcp,
            .req = request.Request.init(allocator),
            .res = response.Response.init(allocator),
            .values = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    /// 清理上下文资源
    pub fn deinit(self: *Self) void {
        self.req.deinit();
        self.res.deinit();
        
        // 清理values（注意：值指针需要调用者管理）
        self.values.deinit();
    }

    /// 设置上下文值
    pub fn set(self: *Self, key: []const u8, value: *anyopaque) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        try self.values.put(key_dup, value);
    }

    /// 获取上下文值
    pub fn get(self: *Self, key: []const u8) ?*anyopaque {
        return self.values.get(key);
    }

    /// 发送响应
    pub fn send(self: *Self) !void {
        try self.res.send(self.tcp);
    }

    /// 发送JSON响应
    pub fn json(self: *Self, status: u16, data: anytype) !void {
        try self.res.json(status, data, self.allocator);
        try self.send();
    }

    /// 发送文本响应
    pub fn text(self: *Self, status: u16, content: []const u8) !void {
        try self.res.text(status, content);
        try self.send();
    }

    /// 发送HTML响应
    pub fn html(self: *Self, status: u16, content: []const u8) !void {
        try self.res.html(status, content);
        try self.send();
    }

    /// 设置响应头
    pub fn header(self: *Self, key: []const u8, value: []const u8) !void {
        try self.res.header(key, value);
    }

    /// 设置Cookie
    pub fn cookie(self: *Self, name: []const u8, value: []const u8, options: response.CookieOptions) !void {
        try self.res.cookie(name, value, options, self.allocator);
    }
};

