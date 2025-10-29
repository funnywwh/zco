const std = @import("std");
const context = @import("./context.zig");

/// 上传的文件
pub const UploadedFile = struct {
    filename: []const u8,
    content_type: ?[]const u8,
    data: []u8,
    size: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UploadedFile) void {
        self.allocator.free(self.filename);
        if (self.content_type) |ct| {
            self.allocator.free(ct);
        }
        self.allocator.free(self.data);
    }
};

/// 文件上传解析器
pub const Upload = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    
    /// 最大文件大小（字节）
    max_file_size: usize = 10 * 1024 * 1024, // 10MB

    /// 初始化上传解析器
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// 解析multipart/form-data请求
    pub fn parseMultipart(self: *Self, body: []const u8, content_type: []const u8) !std.ArrayList(UploadedFile) {
        // 提取boundary
        const boundary_prefix = "boundary=";
        const boundary_pos = std.mem.indexOf(u8, content_type, boundary_prefix) orelse {
            return error.InvalidFormat;
        };
        
        const boundary_start = boundary_pos + boundary_prefix.len;
        var boundary_end = boundary_start;
        while (boundary_end < content_type.len and content_type[boundary_end] != ';' and content_type[boundary_end] != ' ') {
            boundary_end += 1;
        }
        
        const boundary_str = content_type[boundary_start..boundary_end];
        const boundary = try std.fmt.allocPrint(self.allocator, "--{s}", .{boundary_str});
        defer self.allocator.free(boundary);

        var files = std.ArrayList(UploadedFile).init(self.allocator);

        // 分割multipart数据
        var parts = std.mem.split(u8, body, boundary);
        _ = parts.next(); // 跳过第一个空部分

        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, "\r\n");
            if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "--")) {
                continue;
            }

            // 解析part头部和内容
            if (std.mem.indexOf(u8, trimmed, "\r\n\r\n")) |header_end| {
                const headers_raw = trimmed[0..header_end];
                const content = trimmed[header_end + 4 ..];
                
                // 移除末尾的\r\n
                const content_clean = if (content.len >= 2 and content[content.len - 2] == '\r' and content[content.len - 1] == '\n')
                    content[0..content.len - 2]
                else
                    content;

                // 解析头部
                var filename: ?[]const u8 = null;
                var content_type_value: ?[]const u8 = null;
                var name: ?[]const u8 = null;

                var header_lines = std.mem.splitScalar(u8, headers_raw, '\n');
                while (header_lines.next()) |line| {
                    const line_trimmed = std.mem.trim(u8, line, " \r");
                    if (std.mem.indexOf(u8, line_trimmed, "Content-Disposition:")) |_| {
                        // 提取filename
                        if (std.mem.indexOf(u8, line_trimmed, "filename=\"")) |fn_start| {
                            const fn_start_pos = fn_start + 10;
                            if (std.mem.indexOfPos(u8, line_trimmed, fn_start_pos, "\"")) |fn_end| {
                                const fn_raw = line_trimmed[fn_start_pos..fn_end];
                                filename = try self.allocator.dupe(u8, fn_raw);
                            }
                        }
                        
                        // 提取name
                        if (std.mem.indexOf(u8, line_trimmed, "name=\"")) |name_start| {
                            const name_start_pos = name_start + 6;
                            if (std.mem.indexOfPos(u8, line_trimmed, name_start_pos, "\"")) |name_end| {
                                const name_raw = line_trimmed[name_start_pos..name_end];
                                name = try self.allocator.dupe(u8, name_raw);
                            }
                        }
                    }
                    
                    if (std.mem.indexOf(u8, line_trimmed, "Content-Type:")) |_| {
                        const ct_start = std.mem.indexOf(u8, line_trimmed, ":") orelse continue;
                        const ct_raw = std.mem.trim(u8, line_trimmed[ct_start + 1 ..], " ");
                        content_type_value = try self.allocator.dupe(u8, ct_raw);
                    }
                }

                // 创建上传文件
                if (filename) |file_name| {
                    if (content_clean.len > self.max_file_size) {
                        if (file_name.len > 0) self.allocator.free(file_name);
                        if (content_type_value) |ct| self.allocator.free(ct);
                        if (name) |n| self.allocator.free(n);
                        continue;
                    }

                    const data = try self.allocator.dupe(u8, content_clean);
                    errdefer self.allocator.free(data);

                    try files.append(UploadedFile{
                        .filename = file_name,
                        .content_type = content_type_value,
                        .data = data,
                        .size = content_clean.len,
                        .allocator = self.allocator,
                    });
                }

                // 清理临时变量
                if (name) |n| {
                    self.allocator.free(n);
                }
            }
        }

        return files;
    }

    /// 保存文件到磁盘
    pub fn saveFile(self: *Self, file: *UploadedFile, dest_path: []const u8) !void {
        const dest_dir = std.fs.path.dirname(dest_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(dest_dir);

        const dest_file = try std.fs.cwd().createFile(dest_path, .{});
        defer dest_file.close();

        try dest_file.writeAll(file.data);
    }
};

