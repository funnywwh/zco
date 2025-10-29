const std = @import("std");
const context = @import("./context.zig");

/// 静态文件服务
pub const StaticFiles = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    root_path: []const u8,
    
    /// MIME类型映射
    mime_types: std.StringHashMap([]const u8),

    /// 初始化静态文件服务
    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) Self {
        var mime_types = std.StringHashMap([]const u8).init(allocator);
        
        // 初始化常用MIME类型
        mime_types.put(".html", "text/html; charset=utf-8") catch {};
        mime_types.put(".css", "text/css; charset=utf-8") catch {};
        mime_types.put(".js", "application/javascript; charset=utf-8") catch {};
        mime_types.put(".json", "application/json; charset=utf-8") catch {};
        mime_types.put(".png", "image/png") catch {};
        mime_types.put(".jpg", "image/jpeg") catch {};
        mime_types.put(".jpeg", "image/jpeg") catch {};
        mime_types.put(".gif", "image/gif") catch {};
        mime_types.put(".svg", "image/svg+xml") catch {};
        mime_types.put(".ico", "image/x-icon") catch {};
        mime_types.put(".pdf", "application/pdf") catch {};
        mime_types.put(".txt", "text/plain; charset=utf-8") catch {};

        return .{
            .allocator = allocator,
            .root_path = root_path,
            .mime_types = mime_types,
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.mime_types.deinit();
    }

    /// 获取MIME类型
    fn getMimeType(self: *Self, path: []const u8) []const u8 {
        _ = path;
        if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot_pos| {
            const ext = path[dot_pos..];
            return self.mime_types.get(ext) orelse "application/octet-stream";
        }
        return "application/octet-stream";
    }

    /// 服务静态文件
    pub fn serve(self: *Self, ctx: *context.Context, file_path: []const u8) !void {
        // 构建完整路径
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_path, file_path });
        defer self.allocator.free(full_path);

        // 读取文件
        const file = std.fs.cwd().openFile(full_path, .{}) catch |e| {
            ctx.res.status = 404;
            try ctx.text(404, "File Not Found");
            return;
        };
        defer file.close();

        const stat = try file.stat();
        
        // 读取文件内容
        var buffer = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(buffer);

        const n = try file.readAll(buffer);
        
        // 设置Content-Type
        const mime_type = self.getMimeType(file_path);
        try ctx.header("Content-Type", mime_type);
        try ctx.header("Content-Length", try std.fmt.allocPrint(self.allocator, "{}", .{n}));

        // 设置ETag（简单的基于文件大小的ETag）
        const etag = try std.fmt.allocPrint(self.allocator, "\"{x}\"", .{stat.size});
        defer self.allocator.free(etag);
        try ctx.header("ETag", etag);

        // 检查If-None-Match
        if (ctx.req.getHeader("If-None-Match")) |if_none_match| {
            if (std.mem.eql(u8, if_none_match, etag)) {
                ctx.res.status = 304;
                try ctx.header("Content-Length", "0");
                try ctx.send();
                return;
            }
        }

        // 发送文件内容
        try ctx.res.write(buffer[0..n]);
        ctx.res.status = 200;
        try ctx.send();
    }
};

