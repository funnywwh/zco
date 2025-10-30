const std = @import("std");
const Parser = @import("./parser.zig").Parser;
const HeaderBuffer = @import("./header_buffer.zig").HeaderBuffer;

/// 流式请求封装：
/// - 负责驱动 Parser、管理头部缓冲与三种 Body 处理策略
/// - 不在此处解析 Cookie/路由，仅做通用数据收集与直通
pub const StreamingRequest = struct {
    const Self = @This();

    pub const HeaderKV = struct { name: []u8, value: []u8 };

    /// Body 处理策略（仅保存指针/句柄，不持有所有权）
    pub const BodyHandler = union(enum) {
        accumulate: *std.ArrayList(u8),
        write_file: std.fs.File,
        callback: *const fn ([]const u8) anyerror!void,
    };

    allocator: std.mem.Allocator,
    parser: Parser,
    /// 将 4KB 头部缓冲放到堆上，避免协程小栈发生栈溢出
    header_buf: *HeaderBuffer,

    /// 已解析到的基础字段（零拷贝或复制）
    method: []const u8 = &[_]u8{},
    path: []const u8 = &[_]u8{},
    version_major: u8 = 1,
    version_minor: u8 = 1,

    /// 头部集合（复制保存，便于上层生命周期管理）
    headers: std.ArrayList(HeaderKV),

    body_handler: ?BodyHandler = null,

    /// 初始化
    pub fn init(allocator: std.mem.Allocator) Self {
        const hb = allocator.create(HeaderBuffer) catch @panic("alloc header buffer failed");
        hb.* = HeaderBuffer.init();
        // 再次确保缓冲区为零，避免 valgrind 因对齐读取报告未初始化字节
        @memset(&hb.data, 0);
        return .{
            .allocator = allocator,
            .parser = Parser.init(.request),
            .header_buf = hb,
            .headers = std.ArrayList(HeaderKV).init(allocator),
        };
    }

    /// 释放内部分配（不处理 body_handler 所属资源）
    pub fn deinit(self: *Self) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit();
        self.allocator.destroy(self.header_buf);
    }

    /// 设置 Body 处理策略
    pub fn setBodyHandler(self: *Self, handler: BodyHandler) void {
        self.body_handler = handler;
    }

    /// 喂入数据块并驱动解析
    pub fn feedData(self: *Self, data: []const u8) !usize {
        // 头部阶段将数据追加到 header 缓冲，便于零拷贝切片
        if (!self.parser.isMessageComplete() and self.parser.state != .BODY_IDENTITY) {
            try self.header_buf.append(data);
        }

        var events = std.ArrayList(Parser.Event).init(self.allocator);
        defer events.deinit();

        const consumed = try self.parser.feed(self.header_buf.slice(), data, &events);

        for (events.items) |ev| {
            switch (ev) {
                .on_method => |m| self.method = m,
                .on_path => |p| self.path = p,
                .on_version => |v| {
                    self.version_major = v.major;
                    self.version_minor = v.minor;
                },
                .on_header => |h| {
                    const name = try self.allocator.dupe(u8, h.name);
                    const value = try self.allocator.dupe(u8, h.value);
                    try self.headers.append(.{ .name = name, .value = value });
                },
                .on_headers_complete => {},
                .on_body_chunk => |chunk| {
                    if (self.body_handler) |bh| {
                        switch (bh) {
                            .accumulate => |list| try list.appendSlice(chunk),
                            .write_file => |file| {
                                _ = try file.write(chunk);
                            },
                            .callback => |cb| try cb(chunk),
                        }
                    }
                },
                .on_message_complete => {},
            }
        }

        return consumed;
    }

    /// 是否完成一条消息
    pub fn isComplete(self: *Self) bool {
        return self.parser.isMessageComplete();
    }

    /// 重置（准备处理下一条消息）；保留已分配容量，减少分配开销
    pub fn reset(self: *Self) void {
        self.header_buf.reset();
        self.parser.reset();
        self.method = &[_]u8{};
        self.path = &[_]u8{};
        self.version_major = 1;
        self.version_minor = 1;

        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.clearRetainingCapacity();
        self.body_handler = null;
    }
};
