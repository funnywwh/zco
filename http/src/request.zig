const std = @import("std");
const root = @import("./root.zig");

/// HTTP请求解析器
pub const Request = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// HTTP方法
    method: root.Method = .GET,

    /// 请求路径
    path: []u8 = undefined,

    /// 查询参数字符串
    query_string: []u8 = undefined,

    /// HTTP版本
    version: []u8 = undefined,

    /// HTTP头部
    headers: std.StringHashMap([]const u8),

    /// 查询参数（解析后的）
    query: std.StringHashMap([]const u8),

    /// 路径参数（从路由中提取）
    params: std.StringHashMap([]const u8),

    /// 请求体（如果是空则 len = 0，ptr 可能为 null）
    body: []u8 = &[0]u8{},

    /// Content-Length
    content_length: usize = 0,

    /// Content-Type
    content_type: ?[]const u8 = null,

    /// 初始化请求
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// 清理请求资源
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

        // 释放query
        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*.len > 0) {
                self.allocator.free(entry.value_ptr.*);
            }
        }
        self.query.deinit();

        // 释放params
        var param_iter = self.params.iterator();
        while (param_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*.len > 0) {
                self.allocator.free(entry.value_ptr.*);
            }
        }
        self.params.deinit();

        // 释放path, query_string, version
        if (self.path.len > 0) {
            self.allocator.free(self.path);
        }
        if (self.query_string.len > 0) {
            self.allocator.free(self.query_string);
        }
        if (self.version.len > 0) {
            self.allocator.free(self.version);
        }

        // 释放body
        // body 初始化为空切片，只有在 parse 时分配了内存才需要释放
        // 检查 body.ptr 是否有效（不等于 undefined 且不为 null）
        if (self.body.len > 0) {
            // body 可能是从 buffer 复制的，确保是通过 allocator.dupe 分配的
            self.allocator.free(self.body);
        }

        if (self.content_type) |ct| {
            self.allocator.free(ct);
        }
    }

    /// 解析HTTP请求
    pub fn parse(self: *Self, raw: []const u8) !void {
        var lines = std.mem.splitScalar(u8, raw, '\n');
        var first_line = true;
        var header_end: ?usize = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) {
                // 空行表示头部结束
                if (header_end == null) {
                    header_end = @as(usize, @intCast(line.ptr - raw.ptr)) + line.len;
                }
                continue;
            }

            if (first_line) {
                // 解析请求行: METHOD PATH VERSION
                try self.parseRequestLine(trimmed);
                first_line = false;
                continue;
            }

            if (header_end == null) {
                // 解析头部
                try self.parseHeader(trimmed);
            }
        }

        // 解析查询参数
        try self.parseQuery();

        // 提取Content-Length和Content-Type
        if (self.headers.get("Content-Length")) |cl_str| {
            self.content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
        }

        if (self.headers.get("Content-Type")) |ct| {
            self.content_type = try self.allocator.dupe(u8, ct);
        }

        // 提取请求体
        if (header_end) |end_pos| {
            const body_start = end_pos + 2; // \r\n
            if (raw.len > body_start) {
                const body_raw = raw[body_start..];
                if (self.content_length > 0 and body_raw.len >= self.content_length) {
                    self.body = try self.allocator.dupe(u8, body_raw[0..self.content_length]);
                } else if (body_raw.len > 0) {
                    self.body = try self.allocator.dupe(u8, body_raw);
                }
            }
        }
    }

    /// 解析请求行
    fn parseRequestLine(self: *Self, line: []const u8) !void {
        var parts = std.mem.splitScalar(u8, line, ' ');
        var part_count: usize = 0;
        var method_str: ?[]const u8 = null;
        var path_with_query: ?[]const u8 = null;
        var version_str: ?[]const u8 = null;

        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (part_count == 0) {
                method_str = part;
            } else if (part_count == 1) {
                path_with_query = part;
            } else if (part_count == 2) {
                version_str = part;
            }
            part_count += 1;
        }

        // 解析方法
        if (method_str) |m| {
            if (std.mem.eql(u8, m, "GET")) {
                self.method = .GET;
            } else if (std.mem.eql(u8, m, "POST")) {
                self.method = .POST;
            } else if (std.mem.eql(u8, m, "PUT")) {
                self.method = .PUT;
            } else if (std.mem.eql(u8, m, "DELETE")) {
                self.method = .DELETE;
            } else if (std.mem.eql(u8, m, "PATCH")) {
                self.method = .PATCH;
            } else if (std.mem.eql(u8, m, "OPTIONS")) {
                self.method = .OPTIONS;
            } else if (std.mem.eql(u8, m, "HEAD")) {
                self.method = .HEAD;
            } else if (std.mem.eql(u8, m, "CONNECT")) {
                self.method = .CONNECT;
            } else if (std.mem.eql(u8, m, "TRACE")) {
                self.method = .TRACE;
            }
        }

        // 解析路径和查询字符串
        if (path_with_query) |path_query| {
            if (std.mem.indexOfScalar(u8, path_query, '?')) |query_pos| {
                const path_only = path_query[0..query_pos];
                const query_only = path_query[query_pos + 1 ..];
                self.path = try self.allocator.dupe(u8, path_only);
                self.query_string = try self.allocator.dupe(u8, query_only);
            } else {
                self.path = try self.allocator.dupe(u8, path_query);
                self.query_string = try self.allocator.dupe(u8, "");
            }
        } else {
            self.path = try self.allocator.dupe(u8, "/");
            self.query_string = try self.allocator.dupe(u8, "");
        }

        // 解析版本
        if (version_str) |v| {
            self.version = try self.allocator.dupe(u8, v);
        } else {
            self.version = try self.allocator.dupe(u8, "HTTP/1.1");
        }
    }

    /// 解析HTTP头部
    fn parseHeader(self: *Self, line: []const u8) !void {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
            const key_trimmed = std.mem.trim(u8, line[0..colon_pos], " ");
            const value_trimmed = std.mem.trim(u8, line[colon_pos + 1 ..], " ");

            // 转换key为小写，标准化头部名称
            const key_lower = try self.allocator.alloc(u8, key_trimmed.len);
            for (key_trimmed, 0..) |c, i| {
                key_lower[i] = std.ascii.toLower(c);
            }

            const value_dup = try self.allocator.dupe(u8, value_trimmed);

            // 如果key已存在，释放旧值
            if (self.headers.get(key_lower)) |old_value| {
                self.allocator.free(old_value);
            }

            try self.headers.put(key_lower, value_dup);
        }
    }

    /// 解析查询参数
    fn parseQuery(self: *Self) !void {
        if (self.query_string.len == 0) return;

        var pairs = std.mem.splitScalar(u8, self.query_string, '&');
        while (pairs.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                const key_raw = pair[0..eq_pos];
                const value_raw = pair[eq_pos + 1 ..];

                // URL解码
                const key_decoded = try self.urlDecode(key_raw);
                defer self.allocator.free(key_decoded);
                const value_decoded = try self.urlDecode(value_raw);
                defer self.allocator.free(value_decoded);

                const key_dup = try self.allocator.dupe(u8, key_decoded);
                errdefer self.allocator.free(key_dup);
                const value_dup = try self.allocator.dupe(u8, value_decoded);
                errdefer self.allocator.free(value_dup);

                // 如果key已存在，释放旧值
                if (self.query.get(key_dup)) |old_value| {
                    self.allocator.free(old_value);
                }

                try self.query.put(key_dup, value_dup);
            }
        }
    }

    /// URL解码
    fn urlDecode(self: *Self, encoded: []const u8) ![]u8 {
        var decoded = std.ArrayList(u8).init(self.allocator);
        defer decoded.deinit();

        var i: usize = 0;
        while (i < encoded.len) {
            if (encoded[i] == '%' and i + 2 < encoded.len) {
                const hex = encoded[i + 1 .. i + 3];
                const byte = std.fmt.parseInt(u8, hex, 16) catch {
                    try decoded.append(encoded[i]);
                    i += 1;
                    continue;
                };
                try decoded.append(byte);
                i += 3;
            } else if (encoded[i] == '+') {
                try decoded.append(' ');
                i += 1;
            } else {
                try decoded.append(encoded[i]);
                i += 1;
            }
        }

        return decoded.toOwnedSlice();
    }

    /// 获取头部值
    pub fn getHeader(self: *Self, name: []const u8) ?[]const u8 {
        var name_lower = std.ArrayList(u8).init(self.allocator);
        defer name_lower.deinit();
        for (name) |c| {
            name_lower.append(std.ascii.toLower(c)) catch return null;
        }
        return self.headers.get(name_lower.items);
    }

    /// 获取查询参数值
    pub fn getQuery(self: *Self, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    /// 获取路径参数值
    pub fn getParam(self: *Self, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }
};
