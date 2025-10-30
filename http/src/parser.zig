const std = @import("std");
const HeaderBuffer = @import("./header_buffer.zig").HeaderBuffer;

/// HTTP/1.x 流式解析器（事件驱动，零拷贝头部）
/// 说明：
/// - 仅在头部阶段依赖 `HeaderBuffer` 提供的只读切片进行零拷贝引用
/// - Body 阶段通过事件 `on_body_chunk` 直接输出数据片段，不做累计
/// - 当前实现覆盖：请求行、头部、Content-Length body 的流式事件
///   后续将补充：chunked 编码状态与事件
pub const Parser = struct {
    const Self = @This();

    /// 解析器类型：请求/响应（当前优先支持请求）
    pub const Type = enum { request, response };

    /// 解析状态
    pub const State = enum {
        START,
        REQUEST_LINE_METHOD,
        REQUEST_LINE_PATH,
        REQUEST_LINE_VERSION,
        HEADER_NAME,
        HEADER_VALUE,
        HEADERS_COMPLETE,
        BODY_IDENTITY, // Content-Length body
        BODY_CHUNKED_SIZE, // 读取 chunk 大小（十六进制，以 CRLF 结束）
        BODY_CHUNKED_DATA, // 读取 chunk 数据
        BODY_CHUNKED_CR, // 读取 chunk 末尾的 \r
        BODY_CHUNKED_LF, // 读取 chunk 末尾的 \n
        MESSAGE_COMPLETE,
    };

    /// 解析事件（由解析器抛出，上层按需处理）
    pub const Event = union(enum) {
        on_method: []const u8,
        on_path: []const u8,
        on_version: struct { major: u8, minor: u8 },
        on_header: struct { name: []const u8, value: []const u8 },
        on_headers_complete: void,
        on_body_chunk: []const u8,
        on_message_complete: void,
    };

    // 配置（后续扩展严格/宽松模式、行长等）
    pub const Config = struct {
        max_header_lines: usize = 256,
    };

    // 内部字段
    parser_type: Type = .request,
    state: State = .START,
    config: Config = .{},

    // 请求行临时引用（零拷贝，来自 HeaderBuffer）
    method: []const u8 = &[_]u8{},
    path: []const u8 = &[_]u8{},
    version_major: u8 = 1,
    version_minor: u8 = 1,

    // 头部解析辅助
    header_lines: usize = 0,
    content_length: ?usize = null,
    body_received: usize = 0,
    is_chunked: bool = false,
    chunk_size: usize = 0,
    chunk_received: usize = 0,
    chunk_line_buf: [32]u8 = undefined,
    chunk_line_len: usize = 0,

    /// 初始化解析器
    pub fn init(t: Type) Self {
        return .{ .parser_type = t };
    }

    /// 重置解析器（处理下一条消息）
    pub fn reset(self: *Self) void {
        self.* = Self.init(self.parser_type);
    }

    /// 是否完成一条完整消息
    pub fn isMessageComplete(self: *const Self) bool {
        return self.state == .MESSAGE_COMPLETE;
    }

    /// 还需要的 body 字节数（仅当已知 Content-Length 时返回具体数值）
    pub fn bytesNeeded(self: *const Self) ?usize {
        if (self.content_length) |cl| {
            if (self.body_received < cl) return cl - self.body_received;
            return 0;
        }
        return null;
    }

    /// 核心解析：
    /// - header_buf: 头部阶段的完整只读切片（来自 HeaderBuffer.slice()）
    /// - chunk: 新读取的数据
    /// - events: 事件收集容器
    /// 返回：本次消耗的 `chunk` 字节数（用于上层精确移动剩余数据）
    pub fn feed(self: *Self, header_buf: []const u8, chunk: []const u8, events: *std.ArrayList(Event)) !usize {
        // 快速路径：若已进入 BODY_IDENTITY，则直接根据 Content-Length 产生 body 事件
        if (self.state == .BODY_IDENTITY) {
            if (self.content_length == null) return error.InvalidContentLength;
            const cl = self.content_length.?;
            if (self.body_received >= cl) return 0;

            const remaining = cl - self.body_received;
            const take = @min(remaining, chunk.len);
            if (take > 0) {
                try events.append(.{ .on_body_chunk = chunk[0..take] });
                self.body_received += take;
                if (self.body_received == cl) {
                    self.state = .MESSAGE_COMPLETE;
                    try events.append(.on_message_complete);
                }
                return take;
            }
            return 0;
        }

        // chunked 模式：处理 chunk 大小/数据/CRLF
        if (self.state == .BODY_CHUNKED_SIZE or self.state == .BODY_CHUNKED_DATA or self.state == .BODY_CHUNKED_CR or self.state == .BODY_CHUNKED_LF) {
            var consumed: usize = 0;
            var i: usize = 0;
            while (i < chunk.len) : (i += 1) {
                const b = chunk[i];
                switch (self.state) {
                    .BODY_CHUNKED_SIZE => {
                        // 累积十六进制数字，直到 CRLF
                        if (b == '\r') {
                            self.state = .BODY_CHUNKED_LF; // 复用 LF 状态读取 size 行的 \n
                            // 解析十六进制大小
                            const size_str = self.chunk_line_buf[0..self.chunk_line_len];
                            // 去掉可能存在的扩展: ";ext"
                            var end_idx: usize = size_str.len;
                            if (std.mem.indexOfScalar(u8, size_str, ';')) |semi| end_idx = semi;
                            self.chunk_size = std.fmt.parseInt(usize, size_str[0..end_idx], 16) catch return error.InvalidChunk;
                            self.chunk_line_len = 0;
                        } else if (b == '\n') {
                            // 容错：单独的 \n（不推荐），尝试继续
                            continue;
                        } else {
                            if (self.chunk_line_len >= self.chunk_line_buf.len) return error.InvalidChunk;
                            self.chunk_line_buf[self.chunk_line_len] = b;
                            self.chunk_line_len += 1;
                        }
                    },
                    .BODY_CHUNKED_LF => {
                        // 读取 size 行或数据后的 \n
                        if (b != '\n') return error.InvalidChunk;
                        if (self.chunk_size == 0) {
                            // 0-chunk 后应还有一个空行 CRLF，简单起见视为完成
                            self.state = .MESSAGE_COMPLETE;
                            try events.append(.on_message_complete);
                        } else {
                            self.state = .BODY_CHUNKED_DATA;
                            self.chunk_received = 0;
                        }
                        // 新增else分支处理，chunk_data结尾LF后进入下一个SIZE
                        if (self.state == .BODY_CHUNKED_CR) {
                            self.state = .BODY_CHUNKED_SIZE;
                        }
                    },
                    .BODY_CHUNKED_DATA => {
                        const remaining = self.chunk_size - self.chunk_received;
                        const left_in_chunk = chunk.len - i;
                        const take = @min(remaining, left_in_chunk);
                        if (take > 0) {
                            try events.append(.{ .on_body_chunk = chunk[i .. i + take] });
                            self.chunk_received += take;
                            i += take;
                            i -= 1; // 修正for +1导致的漏读 CR/LF
                            consumed += take;
                            if (self.chunk_received == self.chunk_size) {
                                self.state = .BODY_CHUNKED_CR;
                            }
                            continue;
                        }
                    },
                    .BODY_CHUNKED_CR => {
                        if (b != '\r') return error.InvalidChunk;
                        self.state = .BODY_CHUNKED_SIZE;
                        self.chunk_size = 0; // 下一轮重新赋值
                    },
                    else => {},
                }
                consumed += 1;
                if (self.state == .MESSAGE_COMPLETE) break;
            }
            return consumed;
        }

        // 非 body 阶段：结合 header_buf（累积）进行行级解析
        // 查找头部结束标记："\r\n\r\n"
        if (self.state != .MESSAGE_COMPLETE) {
            if (@import("builtin").mode == .Debug) {
                const max_dump: usize = if (header_buf.len < 64) header_buf.len else 64;
                var buf: [64 * 3]u8 = undefined; // "HH " * 64
                var k: usize = 0;
                var i_dbg: usize = 0;
                while (i_dbg < max_dump) : (i_dbg += 1) {
                    const b = header_buf[i_dbg];
                    const hi = "0123456789ABCDEF"[b >> 4];
                    const lo = "0123456789ABCDEF"[b & 0xF];
                    buf[k] = hi;
                    buf[k + 1] = lo;
                    buf[k + 2] = ' ';
                    k += 3;
                }
                std.log.debug("[dbg] header_len={}, chunk_len={}, head={s}", .{ header_buf.len, chunk.len, buf[0..k] });
            }
            if (std.mem.indexOf(u8, header_buf, "\r\n\r\n")) |pos| {
                // 解析请求行与头部（零拷贝切片均引用 header_buf）
                // 传入完整头部（包含最后的 CRLFCRLF），避免半行导致不确定行为
                const header_total = pos + 4; // "\r\n\r\n"
                if (@import("builtin").mode == .Debug) {
                    // 打印 pos/header_total 以及终止符四字节
                    var four: [4]u8 = .{ 0, 0, 0, 0 };
                    if (header_total <= header_buf.len and header_total >= 4) {
                        four = .{ header_buf[header_total - 4], header_buf[header_total - 3], header_buf[header_total - 2], header_buf[header_total - 1] };
                    }
                    std.log.debug("[dbg] pos={}, total={}, tail4={x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{ pos, header_total, four[0], four[1], four[2], four[3] });
                }
                std.debug.assert(header_total <= header_buf.len);
                try self.parseStartLineAndHeaders(header_buf[0..header_total], events);
                try events.append(.on_headers_complete);
                self.state = .HEADERS_COMPLETE;

                // 根据头部决策下一步
                if (self.is_chunked) {
                    self.state = .BODY_CHUNKED_SIZE;
                    // chunked 模式下，不处理 content_length，只走 chunked 状态机
                    // return chunk.len;
                    return chunk.len;
                } else if (self.content_length) |cl2| {
                    self.state = .BODY_IDENTITY;
                    // 直接从 header_buf 末尾开始读取已在缓冲区中的 body 字节
                    const hb_len = header_buf.len;
                    if (hb_len > header_total and self.body_received < cl2) {
                        const body_in_buf = hb_len - header_total;
                        const take = @min(body_in_buf, cl2 - self.body_received);
                        if (take > 0) {
                            try events.append(.{ .on_body_chunk = header_buf[header_total .. header_total + take] });
                            self.body_received += take;
                            if (self.body_received == cl2) {
                                self.state = .MESSAGE_COMPLETE;
                                try events.append(.on_message_complete);
                            }
                        }
                    }
                    // 在头部阶段，一律认为本次 chunk 全部被消费（由上层累积 header_buf）
                    return chunk.len;
                } else {
                    // 无 body，消息完成
                    self.state = .MESSAGE_COMPLETE;
                    try events.append(.on_message_complete);
                    return chunk.len;
                }
            }
        }

        // 未形成完整头部，暂不消费 body；本次 chunk 完全用于累积到 HeaderBuffer，由上层认为全部已“消耗”
        return chunk.len;
    }

    fn parseStartLineAndHeaders(self: *Self, header_part: []const u8, events: *std.ArrayList(Event)) !void {
        // 逐行解析：请求行 + 多个头部行（以 CRLF 结尾）
        // 传入的 header_part 已包含最后的 CRLFCRLF；按行切分是安全的
        var it = std.mem.splitSequence(u8, header_part, "\r\n");

        // 请求行
        if (it.next()) |line| {
            try self.parseRequestLine(line, events);
        } else return error.InvalidRequest;

        // 头部
        while (it.next()) |line| {
            if (line.len == 0) break; // 安全防御
            if (self.header_lines >= self.config.max_header_lines) return error.HeaderTooLarge;
            self.header_lines += 1;
            if (@import("builtin").mode == .Debug) {
                const max_dump: usize = if (line.len < 32) line.len else 32;
                var buf: [32 * 3]u8 = undefined;
                var k: usize = 0;
                var i_dbg: usize = 0;
                while (i_dbg < max_dump) : (i_dbg += 1) {
                    const b = line[i_dbg];
                    const hi = "0123456789ABCDEF"[b >> 4];
                    const lo = "0123456789ABCDEF"[b & 0xF];
                    buf[k] = hi;
                    buf[k + 1] = lo;
                    buf[k + 2] = ' ';
                    k += 3;
                }
                std.log.debug("[dbg] header_line_len={}, head={s}", .{ line.len, buf[0..k] });
            }
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name_trim = std.mem.trim(u8, line[0..colon], " ");
                const value_trim = std.mem.trim(u8, line[colon + 1 ..], " ");
                try events.append(.{ .on_header = .{ .name = name_trim, .value = value_trim } });

                // 特别关注 Content-Length / Transfer-Encoding（分支预测：常见路径为 Content-Length）
                if (std.ascii.eqlIgnoreCase(name_trim, "Content-Length")) {
                    // 如果头部之前已标记 chunked，本 Content-Length 忽略
                    if (!self.is_chunked) {
                        self.content_length = std.fmt.parseInt(usize, value_trim, 10) catch return error.InvalidContentLength;
                    }
                } else if (std.ascii.eqlIgnoreCase(name_trim, "Transfer-Encoding")) {
                    // 无分配大小写不敏感查找 "chunked"
                    if (containsTokenCI(value_trim, "chunked")) {
                        self.is_chunked = true;
                        self.content_length = null; // 有chunked立即清空CL
                    }
                }
            } else {
                // 非空且不含冒号，表明可能是半行；返回错误并等待更多数据（由上层重试）
                return error.InvalidRequest;
            }
        }
    }

    /// 无分配大小写不敏感包含判断
    fn containsTokenCI(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var eq = true;
            var j: usize = 0;
            while (j < needle.len) : (j += 1) {
                const a = haystack[i + j];
                const b = needle[j];
                if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                    eq = false;
                    break;
                }
            }
            if (eq) return true;
        }
        return false;
    }

    fn parseRequestLine(self: *Self, line: []const u8, events: *std.ArrayList(Event)) !void {
        if (@import("builtin").mode == .Debug) {
            const max_dump: usize = if (line.len < 64) line.len else 64;
            var buf: [64 * 3]u8 = undefined;
            var k: usize = 0;
            var i_dbg: usize = 0;
            while (i_dbg < max_dump) : (i_dbg += 1) {
                const b = line[i_dbg];
                const hi = "0123456789ABCDEF"[b >> 4];
                const lo = "0123456789ABCDEF"[b & 0xF];
                buf[k] = hi;
                buf[k + 1] = lo;
                buf[k + 2] = ' ';
                k += 3;
            }
            std.log.debug("[dbg] request_line_len={}, head={s}", .{ line.len, buf[0..k] });
        }
        // 形如：METHOD SP PATH SP HTTP/1.1
        // 手动扫描空格，避免 split/trim 造成边界不明确
        if (line.len == 0) return error.InvalidRequest;
        var i: usize = 0;
        while (i < line.len and line[i] != ' ') : (i += 1) {}
        if (i == 0 or i >= line.len) return error.InvalidRequest;
        const m = line[0..i];

        var j: usize = i + 1; // 跳过空格
        const path_start = j;
        while (j < line.len and line[j] != ' ') : (j += 1) {}
        if (j <= path_start or j >= line.len) return error.InvalidRequest;
        const p = line[path_start..j];

        const v_start = j + 1;
        if (v_start >= line.len) return error.InvalidRequest;
        const v = line[v_start..];

        self.method = m;
        self.path = p;

        // 解析 HTTP/1.x 版本，失败则回退到 1.1
        self.version_major = 1;
        self.version_minor = 1;
        if (std.mem.startsWith(u8, v, "HTTP/")) {
            const ver = v[5..];
            if (std.mem.indexOfScalar(u8, ver, '.')) |dot| {
                if (dot > 0 and dot + 1 < ver.len) {
                    self.version_major = std.fmt.parseInt(u8, ver[0..dot], 10) catch 1;
                    self.version_minor = std.fmt.parseInt(u8, ver[dot + 1 ..], 10) catch 1;
                }
            }
        }

        try events.append(.{ .on_method = self.method });
        try events.append(.{ .on_path = self.path });
        try events.append(.{ .on_version = .{ .major = self.version_major, .minor = self.version_minor } });
    }
};
