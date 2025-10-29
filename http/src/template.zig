const std = @import("std");
const context = @import("./context.zig");

/// 模板引擎
pub const Template = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    
    /// 模板变量
    vars: std.StringHashMap([]const u8),

    /// 初始化模板引擎
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit();
    }

    /// 设置变量
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);

        const value_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_dup);

        // 如果key已存在，释放旧值
        if (self.vars.get(key_dup)) |old_value| {
            self.allocator.free(old_value);
        }

        try self.vars.put(key_dup, value_dup);
    }

    /// 渲染模板
    pub fn render(self: *Self, template: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var mut_i: usize = 0;
        while (mut_i < template.len) {
            if (template[mut_i] == '{' and mut_i + 1 < template.len and template[mut_i + 1] == '{') {
                // 找到变量 {{var}}
                var var_start = mut_i + 2;
                var var_end = var_start;

                // 查找闭合 }}
                while (var_end < template.len) {
                    if (template[var_end] == '}' and var_end + 1 < template.len and template[var_end + 1] == '}') {
                        break;
                    }
                    var_end += 1;
                }

                if (var_end < template.len) {
                    // 提取变量名
                    const var_name = std.mem.trim(u8, template[var_start..var_end], " ");
                    
                    // 查找变量值
                    if (self.vars.get(var_name)) |value| {
                        try result.appendSlice(value);
                    }

                    mut_i = var_end + 2;
                } else {
                    try result.append(template[mut_i]);
                    mut_i += 1;
                }
            } else {
                try result.append(template[mut_i]);
                mut_i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// 渲染文件模板
    pub fn renderFile(self: *Self, file_path: []const u8) ![]u8 {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        var buffer = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(buffer);

        const n = try file.readAll(buffer);
        const template = buffer[0..n];

        return self.render(template);
    }

    /// 在上下文中渲染并发送
    pub fn renderAndSend(self: *Self, ctx: *context.Context, template: []const u8) !void {
        const rendered = try self.render(template);
        defer self.allocator.free(rendered);

        ctx.res.status = 200;
        try ctx.html(200, rendered);
        try ctx.send();
    }
};

