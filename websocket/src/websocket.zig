const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const io = @import("io");
const crypto = std.crypto;
const base64 = std.base64;

/// WebSocket帧操作码
pub const Opcode = enum(u4) {
    CONTINUATION = 0x0,
    TEXT = 0x1,
    BINARY = 0x2,
    CLOSE = 0x8,
    PING = 0x9,
    PONG = 0xA,
};

/// WebSocket帧类型
pub const FrameType = struct {
    opcode: Opcode,
    payload: []u8,
    fin: bool,
};

/// WebSocket错误类型
pub const WebSocketError = error{
    HandshakeFailed,
    InvalidFrame,
    ProtocolError,
    NotUpgraded,
    BufferTooSmall,
    InvalidOpcode,
    InvalidMask,
    ConnectionClosed, // 连接已关闭（EOF）
};

/// WebSocket服务器实现
pub const WebSocket = struct {
    const Self = @This();

    tcp: *nets.Tcp,
    schedule: *zco.Schedule,
    upgraded: bool = false,
    fragment_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// 从TCP连接创建WebSocket
    pub fn fromTcp(tcp: *nets.Tcp) !*Self {
        const ws = try tcp.schedule.allocator.create(Self);
        ws.* = .{
            .tcp = tcp,
            .schedule = tcp.schedule,
            .fragment_buffer = std.ArrayList(u8).init(tcp.schedule.allocator),
            .allocator = tcp.schedule.allocator,
        };
        return ws;
    }

    /// 清理WebSocket资源
    pub fn deinit(self: *Self) void {
        self.fragment_buffer.deinit();
        self.allocator.destroy(self);
    }

    /// 执行WebSocket握手
    pub fn handshake(self: *Self) !void {
        // 读取HTTP升级请求
        var buffer: [4096]u8 = undefined;
        const n = try self.tcp.read(buffer[0..]);
        const request = buffer[0..n];

        // 解析HTTP头部
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            // 释放所有header的key和value（都是我们分配的）
            var header_iter = headers.iterator();
            while (header_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        var lines = std.mem.splitScalar(u8, request, '\n');
        var first_line = true;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;

            if (first_line) {
                first_line = false;
                // 验证是GET请求且是WebSocket升级
                if (!std.mem.startsWith(u8, trimmed, "GET ")) {
                    return error.HandshakeFailed;
                }
                continue;
            }

            // 解析头部字段 Key: Value
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                const key_trimmed = std.mem.trim(u8, trimmed[0..colon_pos], " ");
                const value_trimmed = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " ");

                // 复制key和value到分配的内存中（避免悬空指针）
                const key = try self.allocator.dupe(u8, key_trimmed);
                const value = try self.allocator.dupe(u8, value_trimmed);

                // 如果key已存在，释放旧值
                if (headers.get(key)) |old_value| {
                    self.allocator.free(old_value);
                }

                try headers.put(key, value);
            }
        }

        // 检查必要的头部
        const upgrade = headers.get("Upgrade") orelse return error.HandshakeFailed;
        if (!std.mem.eql(u8, std.mem.trim(u8, upgrade, " "), "websocket")) {
            return error.HandshakeFailed;
        }

        const connection = headers.get("Connection") orelse return error.HandshakeFailed;
        var connection_lower = self.allocator.dupe(u8, connection) catch return error.HandshakeFailed;
        defer self.allocator.free(connection_lower);
        for (connection_lower, 0..) |*c, i| {
            connection_lower[i] = std.ascii.toLower(c.*);
        }
        if (std.mem.indexOf(u8, connection_lower, "upgrade") == null) {
            return error.HandshakeFailed;
        }

        const sec_key = headers.get("Sec-WebSocket-Key") orelse return error.HandshakeFailed;
        const sec_version = headers.get("Sec-WebSocket-Version") orelse return error.HandshakeFailed;
        if (!std.mem.eql(u8, std.mem.trim(u8, sec_version, " "), "13")) {
            return error.HandshakeFailed;
        }

        // 生成Sec-WebSocket-Accept
        const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        const trimmed_key = std.mem.trim(u8, sec_key, " ");
        var key_buf: [1024]u8 = undefined;
        const key_string = std.fmt.bufPrint(key_buf[0..], "{s}{s}", .{ trimmed_key, magic_string }) catch return error.HandshakeFailed;

        // SHA1哈希
        var hash: [crypto.hash.Sha1.digest_length]u8 = undefined;
        crypto.hash.Sha1.hash(key_string, &hash, .{});

        // Base64编码
        const encoder = base64.standard.Encoder;
        var accept_buf: [32]u8 = undefined;
        const accept_str = encoder.encode(accept_buf[0..], &hash);

        // 构建响应
        const response = std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept_str},
        ) catch return error.HandshakeFailed;
        defer self.allocator.free(response);

        _ = try self.tcp.write(response);
        self.upgraded = true;
    }

    /// 执行WebSocket客户端握手（发送HTTP升级请求并读取响应）
    pub fn clientHandshake(self: *Self, path: []const u8, host: []const u8) !void {
        // 生成随机的Sec-WebSocket-Key
        var random_bytes: [16]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
        prng.random().bytes(&random_bytes);
        
        // Base64编码
        const encoder = base64.standard.Encoder;
        var key_buf: [32]u8 = undefined;
        const key_str = encoder.encode(key_buf[0..], &random_bytes);

        // 构建HTTP升级请求
        const request = std.fmt.allocPrint(
            self.allocator,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, key_str },
        ) catch return error.HandshakeFailed;
        defer self.allocator.free(request);

        // 发送请求
        _ = try self.tcp.write(request);

        // 读取响应
        var buffer: [4096]u8 = undefined;
        const n = try self.tcp.read(buffer[0..]);
        const response = buffer[0..n];

        // 验证响应
        // 应该以 "HTTP/1.1 101 Switching Protocols" 开头
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            return error.HandshakeFailed;
        }

        // 检查是否包含 "Upgrade: websocket"
        if (std.mem.indexOf(u8, response, "Upgrade: websocket") == null) {
            return error.HandshakeFailed;
        }

        // 检查是否包含 "Connection: Upgrade"
        if (std.mem.indexOf(u8, response, "Connection: Upgrade") == null and
            std.mem.indexOf(u8, response, "Connection: upgrade") == null)
        {
            return error.HandshakeFailed;
        }

        // 验证Sec-WebSocket-Accept（可选，但推荐）
        // 计算期望的Accept值
        const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var key_string_buf: [1024]u8 = undefined;
        const key_string = std.fmt.bufPrint(key_string_buf[0..], "{s}{s}", .{ key_str, magic_string }) catch return error.HandshakeFailed;

        var hash: [crypto.hash.Sha1.digest_length]u8 = undefined;
        crypto.hash.Sha1.hash(key_string, &hash, .{});

        var accept_buf: [32]u8 = undefined;
        const expected_accept = encoder.encode(accept_buf[0..], &hash);

        // 检查响应中的Sec-WebSocket-Accept
        const accept_line_start = std.mem.indexOf(u8, response, "Sec-WebSocket-Accept:") orelse return error.HandshakeFailed;
        const accept_line_end = std.mem.indexOf(u8, response[accept_line_start..], "\r\n") orelse return error.HandshakeFailed;
        const accept_line = response[accept_line_start + "Sec-WebSocket-Accept:".len .. accept_line_start + accept_line_end];
        const received_accept = std.mem.trim(u8, accept_line, " \r\n");

        if (!std.mem.eql(u8, received_accept, expected_accept)) {
            return error.HandshakeFailed;
        }

        self.upgraded = true;
    }

    /// 读取指定数量的字节（处理部分读取）
    fn readBytes(self: *Self, buffer: []u8, count: usize) !usize {
        var total_read: usize = 0;
        while (total_read < count) {
            const n = self.tcp.read(buffer[total_read..count]) catch |err| {
                // 如果读取失败，可能是连接关闭
                return err;
            };
            if (n == 0) {
                // EOF：连接已关闭
                return error.ConnectionClosed;
            }
            total_read += n;
        }
        return total_read;
    }

    /// 读取WebSocket帧
    /// 返回的payload：如果使用buffer，指向buffer的slice；如果使用动态分配，需要调用者释放
    fn readFrame(self: *Self, buffer: []u8) !FrameType {
        if (!self.upgraded) return error.NotUpgraded;

        // 读取帧头（至少2字节）
        if (buffer.len < 2) return error.BufferTooSmall;
        _ = try self.readBytes(buffer[0..2], 2);

        const byte1 = buffer[0];
        const byte2 = buffer[1];

        const fin = (byte1 & 0x80) != 0;
        const rsv1 = (byte1 & 0x40) != 0;
        const rsv2 = (byte1 & 0x20) != 0;
        const rsv3 = (byte1 & 0x10) != 0;
        _ = rsv1;
        _ = rsv2;
        _ = rsv3;

        const opcode_raw = byte1 & 0x0F;
        const opcode = @as(Opcode, @enumFromInt(opcode_raw));

        const masked = (byte2 & 0x80) != 0;
        var payload_len: u64 = @as(u64, byte2 & 0x7F);

        // 读取扩展payload长度
        var header_len: usize = 2;
        if (payload_len == 126) {
            if (buffer.len < 4) return error.BufferTooSmall;
            _ = try self.readBytes(buffer[2..4], 2);
            payload_len = std.mem.readInt(u16, buffer[2..4], .big);
            header_len = 4;
        } else if (payload_len == 127) {
            if (buffer.len < 10) return error.BufferTooSmall;
            _ = try self.readBytes(buffer[2..10], 8);
            payload_len = std.mem.readInt(u64, buffer[2..10], .big);
            header_len = 10;
        }

        // 读取掩码（如果存在）
        var mask: [4]u8 = undefined;
        if (masked) {
            if (buffer.len < header_len + 4) return error.BufferTooSmall;
            _ = try self.readBytes(buffer[header_len .. header_len + 4], 4);
            @memcpy(&mask, buffer[header_len .. header_len + 4]);
            header_len += 4;
        }

        const payload_len_usize = @as(usize, @intCast(payload_len));
        const max_buffer_payload = if (buffer.len > header_len) buffer.len - header_len else 0;

        var payload: []u8 = undefined;

        // 如果payload太大超出buffer，使用动态分配
        if (payload_len_usize > max_buffer_payload) {
            // 动态分配内存
            payload = try self.allocator.alloc(u8, payload_len_usize);
            _ = try self.readBytes(payload, payload_len_usize);
            // 注意：调用者需要释放这个payload（readMessage会处理）
        } else {
            // 使用buffer存储payload
            _ = try self.readBytes(buffer[header_len .. header_len + payload_len_usize], payload_len_usize);
            payload = buffer[header_len .. header_len + payload_len_usize];
        }

        // 解掩码
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask[i % 4];
            }
        }

        return FrameType{
            .opcode = opcode,
            .payload = payload,
            .fin = fin,
        };
    }

    /// 构建并发送WebSocket帧
    fn sendFrame(self: *Self, opcode: Opcode, payload: []const u8, fin: bool) !void {
        if (!self.upgraded) return error.NotUpgraded;

        var frame = std.ArrayList(u8).init(self.allocator);
        defer frame.deinit();

        // 第一个字节：FIN + RSV + Opcode
        const byte1: u8 = @as(u8, @intFromEnum(opcode));
        const byte1_final = if (fin) byte1 | 0x80 else byte1;
        try frame.append(byte1_final);

        // 第二个字节：MASK + Payload长度
        // 服务器发送的帧不需要掩码（MASK=0）
        var byte2: u8 = undefined;
        var payload_len_bytes: [8]u8 = undefined;

        if (payload.len < 126) {
            byte2 = @as(u8, @intCast(payload.len));
            try frame.append(byte2);
        } else if (payload.len < 65536) {
            byte2 = 126;
            try frame.append(byte2);
            std.mem.writeInt(u16, payload_len_bytes[0..2], @as(u16, @intCast(payload.len)), .big);
            try frame.appendSlice(payload_len_bytes[0..2]);
        } else {
            byte2 = 127;
            try frame.append(byte2);
            std.mem.writeInt(u64, payload_len_bytes[0..8], @as(u64, payload.len), .big);
            try frame.appendSlice(payload_len_bytes[0..8]);
        }

        // 添加payload
        try frame.appendSlice(payload);

        // 发送完整帧
        const total_sent = try self.tcp.write(frame.items);
        if (total_sent != frame.items.len) {
            return error.ProtocolError;
        }
    }

    /// 发送文本消息（必须是有效的UTF-8）
    pub fn sendText(self: *Self, data: []const u8) !void {
        // 验证UTF-8有效性（WebSocket协议要求文本帧必须是有效UTF-8）
        if (!std.unicode.utf8ValidateSlice(data)) {
            return error.ProtocolError;
        }
        try self.sendFrame(.TEXT, data, true);
    }

    /// 发送二进制消息
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        try self.sendFrame(.BINARY, data, true);
    }

    /// 发送分片消息的开始帧
    pub fn sendFragmentStart(self: *Self, opcode: Opcode, data: []const u8) !void {
        try self.sendFrame(opcode, data, false);
    }

    /// 发送分片消息的继续帧
    pub fn sendFragment(self: *Self, data: []const u8, fin: bool) !void {
        try self.sendFrame(.CONTINUATION, data, fin);
    }

    /// 读取完整消息（处理分片）
    /// 返回的payload总是新分配的内存，需要调用者释放
    pub fn readMessage(self: *Self, buffer: []u8) !FrameType {
        // 清理分片缓冲区
        self.fragment_buffer.clearRetainingCapacity();

        var first_frame = true;
        var message_opcode: ?Opcode = null;

        while (true) {
            const frame = try self.readFrame(buffer);

            // 处理控制帧
            switch (frame.opcode) {
                .CLOSE => {
                    // 处理关闭帧
                    const code = if (frame.payload.len >= 2)
                        std.mem.readInt(u16, frame.payload[0..2], .big)
                    else
                        null;
                    _ = code;
                    // 发送关闭确认
                    try self.sendFrame(.CLOSE, frame.payload, true);
                    return error.ProtocolError; // 连接关闭
                },
                .PING => {
                    // 自动响应PING
                    try self.sendFrame(.PONG, frame.payload, true);
                    continue;
                },
                .PONG => {
                    // 忽略PONG（如果应用层需要处理，可以在这里添加）
                    continue;
                },
                else => {},
            }

            // 第一帧确定消息类型（必须是TEXT或BINARY，不能是CONTINUATION）
            if (first_frame) {
                if (frame.opcode == .CONTINUATION) {
                    // 不应该收到CONTINUATION作为第一帧
                    return error.ProtocolError;
                }
                // 第一帧必须是数据帧（TEXT或BINARY）
                if (frame.opcode != .TEXT and frame.opcode != .BINARY) {
                    return error.ProtocolError;
                }
                message_opcode = frame.opcode;
                first_frame = false;
            } else {
                // 后续帧必须是CONTINUATION（如果消息还没结束）
                if (!frame.fin) {
                    // 消息还没结束，必须是CONTINUATION
                    if (frame.opcode != .CONTINUATION) {
                        // 新的消息开始，但之前的消息还没有结束
                        return error.ProtocolError;
                    }
                } else {
                    // 最后一帧，可以是CONTINUATION或新的消息开始
                    if (frame.opcode == .CONTINUATION) {
                        // 这是分片的最后一帧
                    } else if (frame.opcode == .TEXT or frame.opcode == .BINARY) {
                        // 这是一个新的完整消息（单帧）
                        // 但我们还在处理之前的分片消息，这是错误
                        return error.ProtocolError;
                    }
                }
            }

            // 复制payload到fragment_buffer
            // 注意：frame.payload可能指向buffer或动态分配的内存
            // 我们总是复制到fragment_buffer，这样就不需要区分来源
            const payload_copy = try self.allocator.dupe(u8, frame.payload);
            defer {
                // 检查payload是否需要释放（如果是指向buffer，不需要；如果是动态分配，需要）
                const buffer_start = @intFromPtr(buffer.ptr);
                const buffer_end = buffer_start + buffer.len;
                const payload_start = @intFromPtr(frame.payload.ptr);
                const payload_end = payload_start + frame.payload.len;
                const is_payload_in_buffer = payload_start >= buffer_start and payload_end <= buffer_end;

                if (!is_payload_in_buffer) {
                    // payload是动态分配的，需要释放
                    self.allocator.free(frame.payload);
                }
            }

            // 累积payload到fragment_buffer
            try self.fragment_buffer.appendSlice(payload_copy);

            // 立即释放payload_copy，因为已经复制到fragment_buffer了
            self.allocator.free(payload_copy);

            // 如果是最后一帧，返回完整消息
            if (frame.fin) {
                const full_payload = try self.allocator.dupe(u8, self.fragment_buffer.items);
                return FrameType{
                    .opcode = message_opcode orelse .TEXT,
                    .payload = full_payload,
                    .fin = true,
                };
            }
        }
    }

    /// 发送PING帧
    pub fn sendPing(self: *Self, data: ?[]const u8) !void {
        const ping_data = data orelse "";
        try self.sendFrame(.PING, ping_data, true);
    }

    /// 发送PONG帧
    pub fn sendPong(self: *Self, data: []const u8) !void {
        try self.sendFrame(.PONG, data, true);
    }

    /// 关闭WebSocket连接
    pub fn close(self: *Self, code: ?u16, reason: ?[]const u8) !void {
        if (!self.upgraded) return;

        var close_payload = std.ArrayList(u8).init(self.allocator);
        defer close_payload.deinit();

        if (code) |c| {
            var code_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &code_bytes, c, .big);
            try close_payload.appendSlice(&code_bytes);
            if (reason) |r| {
                try close_payload.appendSlice(r);
            }
        }

        try self.sendFrame(.CLOSE, close_payload.items, true);
        self.upgraded = false;
    }

    /// 关闭TCP连接（内部使用）
    pub fn closeTcp(self: *Self) void {
        self.tcp.close();
    }

    /// 清理并关闭
    pub fn cleanup(self: *Self) void {
        if (self.upgraded) {
            self.close(1000, null) catch {};
        }
        self.closeTcp();
    }
};
