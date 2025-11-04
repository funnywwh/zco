const std = @import("std");
const zco = @import("zco");
const Record = @import("./record.zig").Record;
const crypto = std.crypto;

/// DTLS 握手协议实现
/// 遵循 RFC 6347
pub const Handshake = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    record: *Record,

    // 握手状态
    state: HandshakeState,

    // 握手参数
    client_random: [32]u8,
    server_random: [32]u8,
    master_secret: [48]u8,

    // 会话 ID
    session_id: []u8,

    // 证书（简化：暂不支持证书链）
    certificate: ?[]const u8 = null,

    // Flight 计数器（用于重传）
    flight: u8 = 0,

    /// DTLS 握手状态
    pub const HandshakeState = enum {
        initial, // 初始状态
        client_hello_sent, // ClientHello 已发送（客户端）
        client_hello_received, // ClientHello 已接收（服务器）
        server_hello_sent, // ServerHello 已发送（服务器）
        server_hello_received, // ServerHello 已接收（客户端）
        server_certificate_received, // Certificate 已接收（客户端）
        server_certificate_sent, // Certificate 已发送（服务器）
        server_key_exchange_received, // ServerKeyExchange 已接收（客户端）
        server_hello_done_received, // ServerHelloDone 已接收（客户端）
        server_hello_done_sent, // ServerHelloDone 已发送（服务器）
        client_key_exchange_sent, // ClientKeyExchange 已发送（客户端）
        client_key_exchange_received, // ClientKeyExchange 已接收（服务器）
        change_cipher_spec_sent, // ChangeCipherSpec 已发送
        finished_sent, // Finished 已发送
        handshake_complete, // 握手完成
    };

    /// DTLS 握手消息类型
    pub const HandshakeType = enum(u8) {
        hello_request = 0,
        client_hello = 1,
        server_hello = 2,
        hello_verify_request = 3,
        certificate = 11,
        server_key_exchange = 12,
        certificate_request = 13,
        server_hello_done = 14,
        certificate_verify = 15,
        client_key_exchange = 16,
        finished = 20,
    };

    /// 握手消息头
    pub const HandshakeHeader = struct {
        msg_type: HandshakeType,
        length: u24, // 3 字节长度
        message_sequence: u16,
        fragment_offset: u24,
        fragment_length: u24,

        /// 编码握手消息头
        pub fn encode(self: HandshakeHeader) [12]u8 {
            var data: [12]u8 = undefined;
            data[0] = @intFromEnum(self.msg_type);
            data[1] = @as(u8, @truncate(self.length >> 16));
            data[2] = @as(u8, @truncate(self.length >> 8));
            data[3] = @as(u8, @truncate(self.length));
            std.mem.writeInt(u16, data[4..6], self.message_sequence, std.builtin.Endian.big);
            data[6] = @as(u8, @truncate(self.fragment_offset >> 16));
            data[7] = @as(u8, @truncate(self.fragment_offset >> 8));
            data[8] = @as(u8, @truncate(self.fragment_offset));
            data[9] = @as(u8, @truncate(self.fragment_length >> 16));
            data[10] = @as(u8, @truncate(self.fragment_length >> 8));
            data[11] = @as(u8, @truncate(self.fragment_length));
            return data;
        }

        /// 解析握手消息头
        pub fn parse(data: []const u8) !HandshakeHeader {
            if (data.len < 12) return error.InvalidHandshakeHeader;

            const msg_type: HandshakeType = @enumFromInt(data[0]);
            const length = (@as(u24, data[1]) << 16) | (@as(u24, data[2]) << 8) | @as(u24, data[3]);
            const message_sequence = std.mem.readInt(u16, data[4..6], std.builtin.Endian.big);
            const fragment_offset = (@as(u24, data[6]) << 16) | (@as(u24, data[7]) << 8) | @as(u24, data[8]);
            const fragment_length = (@as(u24, data[9]) << 16) | (@as(u24, data[10]) << 8) | @as(u24, data[11]);

            return HandshakeHeader{
                .msg_type = msg_type,
                .length = length,
                .message_sequence = message_sequence,
                .fragment_offset = fragment_offset,
                .fragment_length = fragment_length,
            };
        }
    };

    /// ClientHello 消息
    pub const ClientHello = struct {
        client_version: Record.ProtocolVersion,
        random: [32]u8,
        session_id: []u8,
        cookie: []u8,
        cipher_suites: []const u16,
        compression_methods: []const u8,

        /// 编码 ClientHello
        pub fn encode(self: ClientHello, allocator: std.mem.Allocator) ![]u8 {
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();

            // 客户端版本
            var version_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &version_bytes, @intFromEnum(self.client_version), std.builtin.Endian.big);
            try buffer.appendSlice(&version_bytes);

            // Random (32 bytes)
            try buffer.appendSlice(&self.random);

            // Session ID (1 byte length + data)
            try buffer.append(@as(u8, @intCast(self.session_id.len)));
            try buffer.appendSlice(self.session_id);

            // Cookie (1 byte length + data)
            try buffer.append(@as(u8, @intCast(self.cookie.len)));
            try buffer.appendSlice(self.cookie);

            // Cipher Suites (2 bytes length + data)
            const cipher_suites_length = @as(u16, @intCast(self.cipher_suites.len * 2));
            var cs_length_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &cs_length_bytes, cipher_suites_length, std.builtin.Endian.big);
            try buffer.appendSlice(&cs_length_bytes);
            for (self.cipher_suites) |suite| {
                var suite_bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &suite_bytes, suite, std.builtin.Endian.big);
                try buffer.appendSlice(&suite_bytes);
            }

            // Compression Methods (1 byte length + data)
            try buffer.append(@as(u8, @intCast(self.compression_methods.len)));
            try buffer.appendSlice(self.compression_methods);

            return try buffer.toOwnedSlice();
        }

        /// 解析 ClientHello
        pub fn parse(data: []const u8, allocator: std.mem.Allocator) !ClientHello {
            var offset: usize = 0;

            if (data.len < offset + 2) return error.InvalidClientHello;
            const client_version: Record.ProtocolVersion = @enumFromInt(std.mem.readInt(u16, data[offset..][0..2], std.builtin.Endian.big));
            offset += 2;

            if (data.len < offset + 32) return error.InvalidClientHello;
            var random: [32]u8 = undefined;
            @memcpy(&random, data[offset..][0..32]);
            offset += 32;

            // Session ID
            if (data.len < offset + 1) return error.InvalidClientHello;
            const session_id_len = data[offset];
            offset += 1;
            if (data.len < offset + session_id_len) return error.InvalidClientHello;
            const session_id = try allocator.dupe(u8, data[offset..][0..session_id_len]);
            errdefer allocator.free(session_id);
            offset += session_id_len;

            // Cookie
            if (data.len < offset + 1) return error.InvalidClientHello;
            const cookie_len = data[offset];
            offset += 1;
            if (data.len < offset + cookie_len) return error.InvalidClientHello;
            const cookie = try allocator.dupe(u8, data[offset..][0..cookie_len]);
            errdefer allocator.free(cookie);
            offset += cookie_len;

            // Cipher Suites
            if (data.len < offset + 2) return error.InvalidClientHello;
            const cipher_suites_length = std.mem.readInt(u16, data[offset..][0..2], std.builtin.Endian.big);
            offset += 2;
            if (data.len < offset + cipher_suites_length) return error.InvalidClientHello;
            const cipher_suites_count = cipher_suites_length / 2;
            const cipher_suites = try allocator.alloc(u16, cipher_suites_count);
            errdefer allocator.free(cipher_suites);
            for (0..cipher_suites_count) |i| {
                cipher_suites[i] = std.mem.readInt(u16, data[offset..][0..2], std.builtin.Endian.big);
                offset += 2;
            }

            // Compression Methods
            if (data.len < offset + 1) return error.InvalidClientHello;
            const compression_methods_len = data[offset];
            offset += 1;
            if (data.len < offset + compression_methods_len) return error.InvalidClientHello;
            const compression_methods = try allocator.dupe(u8, data[offset..][0..compression_methods_len]);

            return ClientHello{
                .client_version = client_version,
                .random = random,
                .session_id = session_id,
                .cookie = cookie,
                .cipher_suites = cipher_suites,
                .compression_methods = compression_methods,
            };
        }

        pub fn deinit(self: *ClientHello, allocator: std.mem.Allocator) void {
            allocator.free(self.session_id);
            allocator.free(self.cookie);
            allocator.free(self.cipher_suites);
            allocator.free(self.compression_methods);
        }
    };

    /// ServerHello 消息
    pub const ServerHello = struct {
        server_version: Record.ProtocolVersion,
        random: [32]u8,
        session_id: []u8,
        cipher_suite: u16,
        compression_method: u8,

        /// 编码 ServerHello
        pub fn encode(self: ServerHello, allocator: std.mem.Allocator) ![]u8 {
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();

            // 服务器版本
            var version_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &version_bytes, @intFromEnum(self.server_version), std.builtin.Endian.big);
            try buffer.appendSlice(&version_bytes);

            // Random (32 bytes)
            try buffer.appendSlice(&self.random);

            // Session ID (1 byte length + data)
            try buffer.append(@as(u8, @intCast(self.session_id.len)));
            try buffer.appendSlice(self.session_id);

            // Cipher Suite (2 bytes)
            var suite_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &suite_bytes, self.cipher_suite, std.builtin.Endian.big);
            try buffer.appendSlice(&suite_bytes);

            // Compression Method (1 byte)
            try buffer.append(self.compression_method);

            return try buffer.toOwnedSlice();
        }

        /// 解析 ServerHello
        pub fn parse(data: []const u8, allocator: std.mem.Allocator) !ServerHello {
            var offset: usize = 0;

            if (data.len < offset + 2) return error.InvalidServerHello;
            const server_version: Record.ProtocolVersion = @enumFromInt(std.mem.readInt(u16, data[offset..][0..2], std.builtin.Endian.big));
            offset += 2;

            if (data.len < offset + 32) return error.InvalidServerHello;
            var random: [32]u8 = undefined;
            @memcpy(&random, data[offset..][0..32]);
            offset += 32;

            // Session ID
            if (data.len < offset + 1) return error.InvalidServerHello;
            const session_id_len = data[offset];
            offset += 1;
            if (data.len < offset + session_id_len) return error.InvalidServerHello;
            const session_id = try allocator.dupe(u8, data[offset..][0..session_id_len]);
            errdefer allocator.free(session_id);
            offset += session_id_len;

            // Cipher Suite
            if (data.len < offset + 2) return error.InvalidServerHello;
            const cipher_suite = std.mem.readInt(u16, data[offset..][0..2], std.builtin.Endian.big);
            offset += 2;

            // Compression Method
            if (data.len < offset + 1) return error.InvalidServerHello;
            const compression_method = data[offset];

            return ServerHello{
                .server_version = server_version,
                .random = random,
                .session_id = session_id,
                .cipher_suite = cipher_suite,
                .compression_method = compression_method,
            };
        }

        pub fn deinit(self: *ServerHello, allocator: std.mem.Allocator) void {
            allocator.free(self.session_id);
        }
    };

    /// 初始化 DTLS 握手
    pub fn init(allocator: std.mem.Allocator, record: *Record) !*Self {
        const self = try allocator.create(Self);

        // 生成随机数
        var client_random: [32]u8 = undefined;
        crypto.random.bytes(&client_random);

        self.* = .{
            .allocator = allocator,
            .record = record,
            .state = .initial,
            .client_random = client_random,
            .server_random = undefined,
            .master_secret = undefined,
            .session_id = try allocator.dupe(u8, &[_]u8{}), // 空会话 ID
        };
        return self;
    }

    /// 设置证书（用于服务器端）
    pub fn setCertificate(self: *Self, cert: []const u8) !void {
        if (self.certificate) |old_cert| {
            self.allocator.free(old_cert);
        }
        self.certificate = try self.allocator.dupe(u8, cert);
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.session_id);
        if (self.certificate) |cert| {
            self.allocator.free(cert);
        }
        self.allocator.destroy(self);
    }

    /// 发送 ClientHello
    pub fn sendClientHello(self: *Self, address: std.net.Address) !void {
        if (self.state != .initial) {
            return error.InvalidState;
        }

        // 构建 ClientHello
        var cookie: [32]u8 = undefined; // 简化：初始为空
        const cipher_suites = &[_]u16{0xc02b}; // TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        const compression_methods = &[_]u8{0}; // NULL compression

        const client_hello = ClientHello{
            .client_version = .dtls_1_2,
            .random = self.client_random,
            .session_id = self.session_id,
            .cookie = &cookie,
            .cipher_suites = cipher_suites,
            .compression_methods = compression_methods,
        };

        const client_hello_data = try client_hello.encode(self.allocator);
        defer self.allocator.free(client_hello_data);

        // 构建握手消息头
        const handshake_header = HandshakeHeader{
            .msg_type = .client_hello,
            .length = @as(u24, @intCast(client_hello_data.len)),
            .message_sequence = self.flight,
            .fragment_offset = 0,
            .fragment_length = @as(u24, @intCast(client_hello_data.len)),
        };

        const header_bytes = handshake_header.encode();

        // 构建完整的握手消息
        var handshake_msg = std.ArrayList(u8).init(self.allocator);
        defer handshake_msg.deinit();

        try handshake_msg.appendSlice(&header_bytes);
        try handshake_msg.appendSlice(client_hello_data);

        // 通过记录层发送
        try self.record.send(.handshake, handshake_msg.items, address);

        self.state = .client_hello_sent;
        self.flight += 1;
    }

    /// 接收 ServerHello
    pub fn recvServerHello(self: *Self) !void {
        if (self.state != .client_hello_sent) {
            return error.InvalidState;
        }

        var buffer: [2048]u8 = undefined;
        const result = try self.record.recv(&buffer);

        if (result.content_type != .handshake) {
            return error.UnexpectedMessageType;
        }

        if (result.data.len < 12) return error.InvalidHandshakeMessage;

        // 解析握手消息头
        const handshake_header = try HandshakeHeader.parse(result.data);

        if (handshake_header.msg_type != .server_hello) {
            return error.UnexpectedHandshakeType;
        }

        // 解析 ServerHello
        const server_hello_data = result.data[12..];
        var server_hello = try ServerHello.parse(server_hello_data, self.allocator);
        defer server_hello.deinit(self.allocator);

        // 保存服务器随机数
        @memcpy(&self.server_random, &server_hello.random);
        self.allocator.free(self.session_id);
        self.session_id = try self.allocator.dupe(u8, server_hello.session_id);

        self.state = .server_hello_received;
    }

    /// 计算 Master Secret（简化：使用固定密钥交换）
    pub fn computeMasterSecret(self: *Self) !void {
        // 简化实现：使用 PRF 计算 Master Secret
        // 实际应该从密钥交换中派生
        var prf_input: [64]u8 = undefined;
        @memcpy(prf_input[0..32], &self.client_random);
        @memcpy(prf_input[32..64], &self.server_random);

        // 使用 SHA256 作为 PRF（简化实现）
        var hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&prf_input, &hash, .{});

        // Master Secret 是 48 字节，重复哈希直到足够
        @memcpy(self.master_secret[0..32], &hash);
        crypto.hash.sha2.Sha256.hash(&hash, &hash, .{});
        @memcpy(self.master_secret[32..48], hash[0..16]);
    }

    /// 接收 ClientHello（服务器端）
    pub fn recvClientHello(self: *Self) !void {
        if (self.state != .initial and self.state != .client_hello_received) {
            return error.InvalidState;
        }

        // 注意：recv 是阻塞的，在服务器端应该使用异步方式
        // 简化实现：使用同步接收（实际应该使用协程）
        var buffer: [2048]u8 = undefined;
        const result = try self.record.recv(&buffer);

        if (result.content_type != .handshake) {
            return error.UnexpectedMessageType;
        }

        if (result.data.len < 12) return error.InvalidHandshakeMessage;

        // 解析握手消息头
        const handshake_header = try HandshakeHeader.parse(result.data);

        if (handshake_header.msg_type != .client_hello) {
            return error.UnexpectedHandshakeType;
        }

        // 解析 ClientHello
        const client_hello_data = result.data[12..];
        var client_hello = try ClientHello.parse(client_hello_data, self.allocator);
        defer client_hello.deinit(self.allocator);

        // 保存客户端随机数
        @memcpy(&self.client_random, &client_hello.random);

        self.state = .client_hello_received;
    }

    /// 发送 ServerHello（服务器端）
    pub fn sendServerHello(self: *Self, address: std.net.Address) !void {
        if (self.state != .client_hello_received) {
            return error.InvalidState;
        }

        // 生成服务器随机数
        crypto.random.bytes(&self.server_random);

        // 生成会话 ID（简化：使用空会话 ID）
        self.allocator.free(self.session_id);
        self.session_id = try self.allocator.dupe(u8, &[_]u8{});

        // 构建 ServerHello
        const server_hello = ServerHello{
            .server_version = .dtls_1_2,
            .random = self.server_random,
            .session_id = self.session_id,
            .cipher_suite = 0xc02b, // TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
            .compression_method = 0, // NULL compression
        };

        const server_hello_data = try server_hello.encode(self.allocator);
        defer self.allocator.free(server_hello_data);

        // 构建握手消息头
        const handshake_header = HandshakeHeader{
            .msg_type = .server_hello,
            .length = @as(u24, @intCast(server_hello_data.len)),
            .message_sequence = self.flight,
            .fragment_offset = 0,
            .fragment_length = @as(u24, @intCast(server_hello_data.len)),
        };

        const header_bytes = handshake_header.encode();

        // 构建完整的握手消息
        var handshake_msg = std.ArrayList(u8).init(self.allocator);
        defer handshake_msg.deinit();

        try handshake_msg.appendSlice(&header_bytes);
        try handshake_msg.appendSlice(server_hello_data);

        // 通过记录层发送
        try self.record.send(.handshake, handshake_msg.items, address);

        self.state = .server_hello_sent;
        self.flight += 1;
    }

    /// 发送 Certificate（服务器端）
    pub fn sendCertificate(self: *Self, address: std.net.Address) !void {
        if (self.state != .server_hello_sent) {
            return error.InvalidState;
        }

        if (self.certificate == null) {
            return error.NoCertificate;
        }

        // 构建 Certificate 消息
        // Certificate 格式：3字节证书列表长度 + 每个证书（3字节长度 + DER数据）
        const cert_data = self.certificate.?;
        var cert_msg = std.ArrayList(u8).init(self.allocator);
        defer cert_msg.deinit();

        // 证书列表长度（3字节）
        const cert_list_len = @as(u24, @intCast(3 + cert_data.len)); // 3字节证书长度 + 证书数据
        var len_bytes: [3]u8 = undefined;
        len_bytes[0] = @as(u8, @truncate(cert_list_len >> 16));
        len_bytes[1] = @as(u8, @truncate(cert_list_len >> 8));
        len_bytes[2] = @as(u8, @truncate(cert_list_len));
        try cert_msg.appendSlice(&len_bytes);

        // 单个证书长度（3字节）
        var cert_len_bytes: [3]u8 = undefined;
        cert_len_bytes[0] = @as(u8, @truncate(cert_data.len >> 16));
        cert_len_bytes[1] = @as(u8, @truncate(cert_data.len >> 8));
        cert_len_bytes[2] = @as(u8, @truncate(cert_data.len));
        try cert_msg.appendSlice(&cert_len_bytes);

        // 证书数据
        try cert_msg.appendSlice(cert_data);

        // 构建握手消息头
        const handshake_header = HandshakeHeader{
            .msg_type = .certificate,
            .length = @as(u24, @intCast(cert_msg.items.len)),
            .message_sequence = self.flight,
            .fragment_offset = 0,
            .fragment_length = @as(u24, @intCast(cert_msg.items.len)),
        };

        const header_bytes = handshake_header.encode();

        // 构建完整的握手消息
        var handshake_msg = std.ArrayList(u8).init(self.allocator);
        defer handshake_msg.deinit();

        try handshake_msg.appendSlice(&header_bytes);
        try handshake_msg.appendSlice(cert_msg.items);

        // 通过记录层发送
        try self.record.send(.handshake, handshake_msg.items, address);

        self.state = .server_certificate_sent;
        self.flight += 1;
    }

    /// 发送 ServerHelloDone（服务器端）
    pub fn sendServerHelloDone(self: *Self, address: std.net.Address) !void {
        if (self.state != .server_certificate_sent) {
            return error.InvalidState;
        }

        // ServerHelloDone 消息为空（只有握手头）
        const handshake_header = HandshakeHeader{
            .msg_type = .server_hello_done,
            .length = 0,
            .message_sequence = self.flight,
            .fragment_offset = 0,
            .fragment_length = 0,
        };

        const header_bytes = handshake_header.encode();

        // 通过记录层发送
        try self.record.send(.handshake, &header_bytes, address);

        self.state = .server_hello_done_sent;
        self.flight += 1;
    }

    /// 处理服务器端握手流程（简化：一次性发送所有服务器消息）
    pub fn processServerHandshake(self: *Self, address: std.net.Address) !void {
        // 接收 ClientHello
        try self.recvClientHello();

        // 发送 ServerHello
        try self.sendServerHello(address);

        // 发送 Certificate（如果有）
        if (self.certificate != null) {
            try self.sendCertificate(address);
        }

        // 发送 ServerHelloDone
        try self.sendServerHelloDone(address);

        // 计算 Master Secret（简化实现）
        try self.computeMasterSecret();

        // 注意：实际流程中还需要：
        // 1. 接收 ClientKeyExchange
        // 2. 接收 ChangeCipherSpec
        // 3. 接收 Finished
        // 4. 发送 ChangeCipherSpec
        // 5. 发送 Finished
        // 这里简化实现，只完成到 ServerHelloDone
    }

    /// 发送 ChangeCipherSpec（客户端/服务器端通用）
    pub fn sendChangeCipherSpec(self: *Self, address: std.net.Address) !void {
        // ChangeCipherSpec 不是握手消息，而是独立的记录类型
        // 消息内容只有 1 字节：0x01
        const change_cipher_spec_data = [_]u8{0x01};
        try self.record.send(.change_cipher_spec, &change_cipher_spec_data, address);

        // 更新状态（客户端和服务器端状态不同）
        // 注意：ChangeCipherSpec 不是握手状态的一部分，这里只是标记已发送
        _ = self.state; // 状态保持不变，或者可以通过其他方式跟踪
    }

    /// 发送 ClientKeyExchange（客户端）
    pub fn sendClientKeyExchange(self: *Self, address: std.net.Address) !void {
        if (self.state != .server_hello_done_received) {
            return error.InvalidState;
        }

        // ClientKeyExchange 消息格式（简化实现）
        // 实际应该包含加密的预主密钥（PreMasterSecret）
        // 这里简化：发送空消息
        const client_key_exchange_data = &[_]u8{};

        // 构建握手消息头
        const handshake_header = HandshakeHeader{
            .msg_type = .client_key_exchange,
            .length = 0,
            .message_sequence = self.flight,
            .fragment_offset = 0,
            .fragment_length = 0,
        };

        const header_bytes = handshake_header.encode();

        // 构建完整的握手消息
        var handshake_msg = std.ArrayList(u8).init(self.allocator);
        defer handshake_msg.deinit();

        try handshake_msg.appendSlice(&header_bytes);
        try handshake_msg.appendSlice(client_key_exchange_data);

        // 通过记录层发送
        try self.record.send(.handshake, handshake_msg.items, address);

        self.state = .client_key_exchange_sent;
        self.flight += 1;
    }

    /// 接收 ClientKeyExchange（服务器端）
    pub fn recvClientKeyExchange(self: *Self) !void {
        if (self.state != .server_hello_done_sent) {
            return error.InvalidState;
        }

        var buffer: [2048]u8 = undefined;
        const result = try self.record.recv(&buffer);

        if (result.content_type != .handshake) {
            return error.UnexpectedMessageType;
        }

        if (result.data.len < 12) return error.InvalidHandshakeMessage;

        // 解析握手消息头
        const handshake_header = try HandshakeHeader.parse(result.data);

        if (handshake_header.msg_type != .client_key_exchange) {
            return error.UnexpectedHandshakeType;
        }

        // 简化：不需要解析 ClientKeyExchange 内容
        // 实际应该解密 PreMasterSecret 并计算 Master Secret

        self.state = .client_key_exchange_received;
    }

    /// 发送 Finished（客户端/服务器端通用）
    pub fn sendFinished(self: *Self, address: std.net.Address) !void {
        // Finished 消息包含验证数据（VerifyData）
        // VerifyData = PRF(master_secret, "client finished" || handshake_messages_hash)
        // 简化实现：使用固定验证数据
        var verify_data: [12]u8 = undefined;
        crypto.random.bytes(&verify_data);

        // 构建握手消息头
        const handshake_header = HandshakeHeader{
            .msg_type = .finished,
            .length = @as(u24, @intCast(verify_data.len)),
            .message_sequence = self.flight,
            .fragment_offset = 0,
            .fragment_length = @as(u24, @intCast(verify_data.len)),
        };

        const header_bytes = handshake_header.encode();

        // 构建完整的握手消息
        var handshake_msg = std.ArrayList(u8).init(self.allocator);
        defer handshake_msg.deinit();

        try handshake_msg.appendSlice(&header_bytes);
        try handshake_msg.appendSlice(&verify_data);

        // 通过记录层发送
        try self.record.send(.handshake, handshake_msg.items, address);

        self.flight += 1;

        // 如果 Finished 已发送，标记为已发送
        // 注意：握手完成应该在收到对方的 Finished 后完成
        // 这里简化实现，直接标记为完成
        self.state = .handshake_complete;
    }

    /// 接收 Finished（服务器端）
    pub fn recvFinished(self: *Self) !void {
        if (self.state != .client_key_exchange_received) {
            return error.InvalidState;
        }

        var buffer: [2048]u8 = undefined;
        const result = try self.record.recv(&buffer);

        if (result.content_type != .handshake) {
            return error.UnexpectedMessageType;
        }

        if (result.data.len < 12) return error.InvalidHandshakeMessage;

        // 解析握手消息头
        const handshake_header = try HandshakeHeader.parse(result.data);

        if (handshake_header.msg_type != .finished) {
            return error.UnexpectedHandshakeType;
        }

        // 简化：不需要验证 VerifyData
        // 实际应该验证 VerifyData 是否正确

        // 发送服务器端的 ChangeCipherSpec 和 Finished
        // 注意：这里应该在调用此方法后由调用者发送
        self.state = .handshake_complete;
    }

    /// 处理客户端握手流程（接收服务器消息后）
    pub fn processClientHandshakeAfterServerHello(self: *Self) !void {
        if (self.state != .server_hello_received) {
            return error.InvalidState;
        }

        // 接收 Certificate（如果有）
        // 接收 ServerHelloDone
        // 简化：假设已经接收了 ServerHelloDone
        self.state = .server_hello_done_received;

        // 计算 Master Secret
        try self.computeMasterSecret();
    }

    /// 完成客户端握手（发送 ClientKeyExchange、ChangeCipherSpec、Finished）
    pub fn completeClientHandshake(self: *Self, address: std.net.Address) !void {
        if (self.state != .server_hello_done_received) {
            return error.InvalidState;
        }

        // 发送 ClientKeyExchange
        try self.sendClientKeyExchange(address);

        // 发送 ChangeCipherSpec
        try self.sendChangeCipherSpec(address);

        // 发送 Finished
        try self.sendFinished(address);
    }

    /// 完成服务器端握手（发送 ChangeCipherSpec、Finished）
    pub fn completeServerHandshake(self: *Self, address: std.net.Address) !void {
        // 接收 ClientKeyExchange
        try self.recvClientKeyExchange();

        // 接收 ChangeCipherSpec
        // 注意：ChangeCipherSpec 不是握手消息，需要单独处理
        var buffer: [2048]u8 = undefined;
        const result = try self.record.recv(&buffer);
        if (result.content_type != .change_cipher_spec) {
            return error.UnexpectedMessageType;
        }

        // 接收 Finished
        try self.recvFinished();

        // 发送 ChangeCipherSpec
        try self.sendChangeCipherSpec(address);

        // 发送 Finished
        try self.sendFinished(address);
    }

    pub const Error = error{
        InvalidState,
        InvalidHandshakeHeader,
        InvalidHandshakeMessage,
        UnexpectedMessageType,
        UnexpectedHandshakeType,
        InvalidClientHello,
        InvalidServerHello,
        OutOfMemory,
        NoCertificate,
    };
};
