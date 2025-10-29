const std = @import("std");
const root = @import("./root.zig");
const context = @import("./context.zig");

/// 路由处理器类型
pub const Handler = *const fn (ctx: *context.Context) anyerror!void;

/// 路由项
const Route = struct {
    method: root.Method,
    path: []const u8,
    handler: Handler,
    param_names: []const []const u8, // 路径参数名列表

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        for (self.param_names) |name| {
            allocator.free(name);
        }
        allocator.free(self.param_names);
        allocator.free(self.path);
    }
};

/// 路由组
const RouteGroup = struct {
    prefix: []const u8,
    routes: std.ArrayList(*Route),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RouteGroup) void {
        for (self.routes.items) |route| {
            route.deinit(self.allocator);
            self.allocator.destroy(route);
        }
        self.routes.deinit();
        self.allocator.free(self.prefix);
    }
};

/// 路由系统
pub const Router = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    routes: std.ArrayList(*Route),
    groups: std.ArrayList(RouteGroup),

    /// 初始化路由器
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(*Route).init(allocator),
            .groups = std.ArrayList(RouteGroup).init(allocator),
        };
    }

    /// 清理路由器
    pub fn deinit(self: *Self) void {
        // 清理路由
        for (self.routes.items) |route| {
            route.deinit(self.allocator);
            self.allocator.destroy(route);
        }
        self.routes.deinit();

        // 清理路由组
        for (self.groups.items) |*route_group_item| {
            route_group_item.deinit();
        }
        self.groups.deinit();
    }

    /// 注册路由
    pub fn add(self: *Self, method: root.Method, path: []const u8, handler: Handler) !void {
        const path_dup = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_dup);

        // 提取路径参数名
        var param_names = std.ArrayList([]const u8).init(self.allocator);
        var path_parts = std.mem.splitScalar(u8, path, '/');
        while (path_parts.next()) |part| {
            if (part.len > 0 and part[0] == ':') {
                const param_name = part[1..];
                const name_dup = try self.allocator.dupe(u8, param_name);
                try param_names.append(name_dup);
            }
        }

        const route = try self.allocator.create(Route);
        route.* = .{
            .method = method,
            .path = path_dup,
            .handler = handler,
            .param_names = try param_names.toOwnedSlice(),
        };

        try self.routes.append(route);
    }

    /// GET路由
    pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.GET, path, handler);
    }

    /// POST路由
    pub fn post(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.POST, path, handler);
    }

    /// PUT路由
    pub fn put(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.PUT, path, handler);
    }

    /// DELETE路由
    pub fn delete(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.DELETE, path, handler);
    }

    /// PATCH路由
    pub fn patch(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.PATCH, path, handler);
    }

    /// 创建路由组
    pub fn group(self: *Self, prefix: []const u8) !*RouteGroup {
        const prefix_dup = try self.allocator.dupe(u8, prefix);
        const new_group = RouteGroup{
            .prefix = prefix_dup,
            .routes = std.ArrayList(*Route).init(self.allocator),
            .allocator = self.allocator,
        };
        try self.groups.append(new_group);
        return &self.groups.items[self.groups.items.len - 1];
    }

    /// 在路由组中添加路由
    pub fn addToGroup(self: *Self, route_group: *RouteGroup, method: root.Method, path: []const u8, handler: Handler) !void {
        // 组合前缀和路径
        var full_path = std.ArrayList(u8).init(self.allocator);
        defer full_path.deinit();

        try full_path.writer().print("{s}{s}", .{ route_group.prefix, path });
        try self.add(method, full_path.items, handler);
    }

    /// 匹配路由
    pub fn match(self: *Self, method: root.Method, path: []const u8, ctx: *context.Context) !?Handler {
        // 先匹配普通路由
        for (self.routes.items) |route| {
            if (route.method != method) continue;

            if (self.matchPath(route.path, path, ctx)) {
                return route.handler;
            }
        }

        // 匹配路由组
        for (self.groups.items) |*route_group| {
            for (route_group.routes.items) |route| {
                if (route.method != method) continue;

                if (self.matchPath(route.path, path, ctx)) {
                    return route.handler;
                }
            }
        }

        return null;
    }

    /// 匹配路径（支持参数）
    fn matchPath(_: *Self, pattern: []const u8, path: []const u8, ctx: *context.Context) bool {
        var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
        var path_parts = std.mem.splitScalar(u8, path, '/');

        while (true) {
            const pattern_part = pattern_parts.next();
            const path_part = path_parts.next();

            if (pattern_part == null and path_part == null) {
                return true;
            }
            if (pattern_part == null or path_part == null) {
                return false;
            }

            const pattern_val = pattern_part.?;
            const path_val = path_part.?;

            // 检查是否是通配符
            if (std.mem.eql(u8, pattern_val, "*")) {
                return true;
            }

            // 检查是否是参数
            if (pattern_val.len > 0 and pattern_val[0] == ':') {
                // 提取参数名和值
                const param_name = pattern_val[1..];
                const param_value = path_val;

                // 分配并存储参数
                const param_name_dup = ctx.allocator.dupe(u8, param_name) catch return false;
                const param_value_dup = ctx.allocator.dupe(u8, param_value) catch {
                    ctx.allocator.free(param_name_dup);
                    return false;
                };

                ctx.req.params.put(param_name_dup, param_value_dup) catch {
                    ctx.allocator.free(param_name_dup);
                    ctx.allocator.free(param_value_dup);
                    return false;
                };
            } else {
                // 直接匹配
                if (!std.mem.eql(u8, pattern_val, path_val)) {
                    return false;
                }
            }
        }
    }

    /// 查找并执行路由
    pub fn handle(self: *Self, ctx: *context.Context) !void {
        const handler = try self.match(ctx.req.method, ctx.req.path, ctx);
        if (handler) |h| {
            try h(ctx);
        } else {
            // 404 Not Found
            ctx.res.status = 404;
            try ctx.text(404, "Not Found");
        }
    }
};
