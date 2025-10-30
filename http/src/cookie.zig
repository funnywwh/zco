const std = @import("std");

/// Cookie 结构（请求/响应通用，响应会附带属性）
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,

    // 以下为 Set-Cookie 可选属性（请求 Cookie 不涉及）
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    max_age: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,

    pub const SameSite = enum { Strict, Lax, None };
};

/// 解析请求 Cookie 头："a=1; b=2" → 多个 Cookie 元素
pub fn parseCookies(allocator: std.mem.Allocator, cookie_header: []const u8) ![]Cookie {
    var list = std.ArrayList(Cookie).init(allocator);
    errdefer list.deinit();

    var it = std.mem.splitSequence(u8, cookie_header, ";");
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const name = std.mem.trim(u8, pair[0..eq], " \t");
            const val = std.mem.trim(u8, pair[eq + 1 ..], " \t");
            // 注意：此处不解码分号，建议业务侧 URL 解码
            try list.append(.{ .name = name, .value = val });
        }
    }

    return list.toOwnedSlice();
}

/// 解析响应 Set-Cookie：name=value; Attr=...; Secure; HttpOnly; SameSite=Strict
pub fn parseSetCookie(allocator: std.mem.Allocator, set_cookie_header: []const u8) !Cookie {
    _ = allocator; // 当前实现不分配，仅返回对输入切片的引用
    var result = Cookie{ .name = &[_]u8{}, .value = &[_]u8{} };

    var parts = std.mem.splitSequence(u8, set_cookie_header, ";");
    var first = true;
    while (parts.next()) |raw| {
        const seg = std.mem.trim(u8, raw, " \t");
        if (seg.len == 0) continue;
        if (first) {
            first = false;
            if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
                result.name = std.mem.trim(u8, seg[0..eq], " \t");
                result.value = std.mem.trim(u8, seg[eq + 1 ..], " \t");
            }
            continue;
        }

        if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
            const k = std.mem.trim(u8, seg[0..eq], " \t");
            const v = std.mem.trim(u8, seg[eq + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(k, "Path")) {
                result.path = v;
            } else if (std.ascii.eqlIgnoreCase(k, "Domain")) {
                result.domain = v;
            } else if (std.ascii.eqlIgnoreCase(k, "Expires")) {
                result.expires = v;
            } else if (std.ascii.eqlIgnoreCase(k, "Max-Age")) {
                result.max_age = std.fmt.parseInt(i64, v, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(k, "SameSite")) {
                if (std.ascii.eqlIgnoreCase(v, "Strict")) {
                    result.same_site = .Strict;
                } else if (std.ascii.eqlIgnoreCase(v, "Lax")) {
                    result.same_site = .Lax;
                } else if (std.ascii.eqlIgnoreCase(v, "None")) {
                    result.same_site = .None;
                }
            }
        } else {
            // 布尔属性
            if (std.ascii.eqlIgnoreCase(seg, "Secure")) {
                result.secure = true;
            } else if (std.ascii.eqlIgnoreCase(seg, "HttpOnly")) {
                result.http_only = true;
            }
        }
    }

    return result;
}


