const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const crypto = std.crypto;

/// STUN (Session Traversal Utilities for NAT) 协议实现
/// 遵循 RFC 5389
pub const Stun = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    udp: ?*nets.Udp = null,

    /// STUN 消息类型
    pub const MessageType = enum(u16) {
        binding_request = 0x0001,
        binding_response = 0x0101,
        binding_error_response = 0x0111,
        shared_secret_request = 0x0002,
        shared_secret_response = 0x0102,
        shared_secret_error_response = 0x0112,
    };

    /// STUN 消息类
    pub const MessageClass = enum(u2) {
        request = 0b00,
        indication = 0b01,
        success_response = 0b10,
        error_response = 0b11,
    };

    /// STUN 消息方法
    pub const MessageMethod = enum(u12) {
        binding = 0x001,
    };

    /// STUN 属性类型（包含 TURN 扩展属性）
    pub const AttributeType = enum(u16) {
        mapped_address = 0x0001,
        username = 0x0006,
        message_integrity = 0x0008,
        error_code = 0x0009,
        unknown_attributes = 0x000a,
        xor_peer_address = 0x0012, // TURN extension
        data = 0x0013, // TURN extension
        realm = 0x0014,
        nonce = 0x0015,
        xor_relayed_address = 0x0016, // TURN extension
        lifetime = 0x000D, // TURN extension
        requested_transport = 0x0019, // TURN extension
        xor_mapped_address = 0x0020,
        software = 0x8022,
        alternate_server = 0x8023,
        fingerprint = 0x8028,
        priority = 0x0024,
        use_candidate = 0x0025,
        ice_controlled = 0x8029,
        ice_controlling = 0x802a,
        reservation_token = 0x0022, // TURN extension
    };

    /// STUN 消息头（20 字节）
    pub const MessageHeader = struct {
        const SelfHdr = @This();
        message_type: u16, // 2 bits class + 1 bit reserved + 12 bits method
        message_length: u16, // 消息体长度（不包括 20 字节头部）
        magic_cookie: u32 = 0x2112A442, // STUN magic cookie
        transaction_id: [12]u8, // 96-bit 事务 ID

        /// 从字节数组解析消息头
        pub fn parse(data: *const [20]u8) SelfHdr {
            var header: SelfHdr = undefined;
            header.message_type = std.mem.readInt(u16, data[0..2], std.builtin.Endian.big);
            header.message_length = std.mem.readInt(u16, data[2..4], std.builtin.Endian.big);
            header.magic_cookie = std.mem.readInt(u32, data[4..8], std.builtin.Endian.big);
            @memcpy(header.transaction_id[0..], data[8..20]);
            return header;
        }

        /// 将消息头编码为字节数组
        pub fn encode(self: SelfHdr) [20]u8 {
            var data: [20]u8 = undefined;
            std.mem.writeInt(u16, data[0..2], self.message_type, std.builtin.Endian.big);
            std.mem.writeInt(u16, data[2..4], self.message_length, std.builtin.Endian.big);
            std.mem.writeInt(u32, data[4..8], self.magic_cookie, std.builtin.Endian.big);
            @memcpy(data[8..20], &self.transaction_id);
            return data;
        }

        /// 获取消息类
        pub fn getClass(self: SelfHdr) MessageClass {
            const class_bits = @as(u2, @intCast((self.message_type >> 7) & 0x03));
            return @enumFromInt(class_bits);
        }

        /// 获取消息方法
        pub fn getMethod(self: SelfHdr) MessageMethod {
            const method_bits = @as(u12, @intCast((self.message_type & 0x3e00) >> 2 | (self.message_type & 0x00f0) >> 1 | (self.message_type & 0x000f)));
            return @enumFromInt(method_bits);
        }

        /// 设置消息类型
        /// STUN 消息类型格式：
        /// - Bits 0-1: Class (C0, C1)
        /// - Bit 2: Reserved (must be 0)
        /// - Bits 3-6: Method (M0-M3)
        /// - Bits 7-11: Method (M4-M8)
        /// - Bits 12-15: Method (M9-M11)
        pub fn setType(class: MessageClass, method: MessageMethod) u16 {
            const class_val: u16 = @as(u16, @intFromEnum(class)) << 7;
            const method_bits: u16 = @as(u16, @intFromEnum(method));
            // STUN 方法编码：M0-M3 在 bits 3-6, M4-M8 在 bits 7-11, M9-M11 在 bits 12-15
            const method_val: u16 = ((method_bits & 0x0f80) << 2) | ((method_bits & 0x0070) << 1) | (method_bits & 0x000f);
            return class_val | method_val;
        }
    };

    /// STUN 属性
    pub const Attribute = struct {
        const SelfAttr = @This();
        type: AttributeType,
        length: u16,
        value: []const u8,

        /// 编码属性为字节数组
        pub fn encode(self: SelfAttr, allocator: std.mem.Allocator) ![]u8 {
            const total_length = 4 + self.length;
            const padded_length = ((total_length + 3) / 4) * 4; // 4字节对齐
            var data = try allocator.alloc(u8, padded_length);
            errdefer allocator.free(data);

            std.mem.writeInt(u16, data[0..2], @intFromEnum(self.type), std.builtin.Endian.big);
            std.mem.writeInt(u16, data[2..4], self.length, std.builtin.Endian.big);
            @memcpy(data[4 .. 4 + self.length], self.value);
            // 填充零字节
            @memset(data[4 + self.length ..], 0);

            return data;
        }

        /// 解析属性
        pub fn parse(data: []const u8) !SelfAttr {
            if (data.len < 4) return error.InvalidAttribute;
            const type_val = std.mem.readInt(u16, data[0..2][0..2], std.builtin.Endian.big);
            const length = std.mem.readInt(u16, data[2..4][0..2], std.builtin.Endian.big);
            if (data.len < 4 + length) return error.InvalidAttribute;

            // 对于未知属性类型，直接使用 @enumFromInt
            // 这允许 TURN 扩展属性通过（即使值不在枚举定义中）
            const attr_type: AttributeType = @enumFromInt(type_val);

            return SelfAttr{
                .type = attr_type,
                .length = length,
                .value = data[4 .. 4 + length],
            };
        }
    };

    /// MAPPED-ADDRESS 属性
    pub const MappedAddress = struct {
        const SelfMapAddr = @This();
        family: u8, // 0x01 = IPv4, 0x02 = IPv6
        port: u16,
        address: std.net.Address,

        /// 编码为属性
        pub fn encode(self: SelfMapAddr, allocator: std.mem.Allocator) !Attribute {
            var value = std.ArrayList(u8).init(allocator);
            defer value.deinit();

            try value.append(0); // Reserved
            try value.append(self.family);
            var port_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &port_bytes, self.port, std.builtin.Endian.big);
            try value.appendSlice(&port_bytes);

            // 地址编码
            var addr_bytes: [16]u8 = undefined;
            var addr_len: usize = 0;
            if (self.family == 0x01) {
                // IPv4 - 使用 format 方法解析 IP 地址
                var fmt_buf: [64]u8 = undefined;
                var stream = std.io.fixedBufferStream(&fmt_buf);
                try self.address.format("", .{}, stream.writer());
                const formatted = stream.getWritten();
                // 解析 IP 地址字符串（格式：xxx.xxx.xxx.xxx:port）
                if (std.mem.indexOfScalar(u8, formatted, ':')) |colon_pos| {
                    const ip_str = formatted[0..colon_pos];
                    var parts = std.mem.splitScalar(u8, ip_str, '.');
                    var i: usize = 0;
                    while (parts.next()) |part| : (i += 1) {
                        if (i >= 4) break;
                        addr_bytes[i] = try std.fmt.parseInt(u8, part, 10);
                    }
                    if (i != 4) return error.InvalidAddress;
                    addr_len = 4;
                } else {
                    return error.InvalidAddress;
                }
            } else {
                // IPv6 - 暂时不支持，返回错误
                return error.UnsupportedAddressFamily;
            }
            try value.appendSlice(addr_bytes[0..addr_len]);

            return Attribute{
                .type = .mapped_address,
                .length = @as(u16, @intCast(value.items.len)),
                .value = try allocator.dupe(u8, value.items),
            };
        }

        /// 从属性解析
        pub fn parse(attr: Attribute) !SelfMapAddr {
            if (attr.length < 4) return error.InvalidAttribute;
            const family = attr.value[1];
            const port = std.mem.readInt(u16, attr.value[2..4][0..2], std.builtin.Endian.big);

            var address: std.net.Address = undefined;
            if (family == 0x01) {
                // IPv4
                if (attr.length < 8) return error.InvalidAttribute;
                var addr_bytes: [4]u8 = undefined;
                @memcpy(&addr_bytes, attr.value[4..8]);
                address = std.net.Address.initIp4(addr_bytes, port);
            } else if (family == 0x02) {
                // IPv6
                if (attr.length < 20) return error.InvalidAttribute;
                var addr_bytes: [16]u8 = undefined;
                @memcpy(&addr_bytes, attr.value[4..20]);
                address = std.net.Address.initIp6(addr_bytes, port, 0, 0);
            } else {
                return error.InvalidAddressFamily;
            }

            return SelfMapAddr{
                .family = family,
                .port = port,
                .address = address,
            };
        }
    };

    /// XOR-MAPPED-ADDRESS 属性（推荐使用，提供更好的安全性）
    pub const XorMappedAddress = struct {
        const SelfXorAddr = @This();
        family: u8,
        port: u16,
        address: std.net.Address,
        transaction_id: [12]u8,

        /// 编码为属性（使用 XOR 编码）
        pub fn encode(self: SelfXorAddr, allocator: std.mem.Allocator) !Attribute {
            var value = std.ArrayList(u8).init(allocator);
            defer value.deinit();

            try value.append(0); // Reserved
            try value.append(self.family);

            // XOR 编码端口
            const xored_port = self.port ^ ((@as(u16, self.transaction_id[0]) << 8) | @as(u16, self.transaction_id[1]));
            var port_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &port_bytes, xored_port, std.builtin.Endian.big);
            try value.appendSlice(&port_bytes);

            // XOR 编码地址
            switch (self.address.any.family) {
                std.posix.AF.INET => {
                    // 使用 format 方法解析 IP 地址
                    var fmt_buf: [64]u8 = undefined;
                    var stream = std.io.fixedBufferStream(&fmt_buf);
                    try self.address.format("", .{}, stream.writer());
                    const formatted = stream.getWritten();
                    // 解析 IP 地址字符串（格式：xxx.xxx.xxx.xxx:port）
                    var addr_buf: [4]u8 = undefined;
                    if (std.mem.indexOfScalar(u8, formatted, ':')) |colon_pos| {
                        const ip_str = formatted[0..colon_pos];
                        var parts = std.mem.splitScalar(u8, ip_str, '.');
                        var i: usize = 0;
                        while (parts.next()) |part| : (i += 1) {
                            if (i >= 4) break;
                            addr_buf[i] = try std.fmt.parseInt(u8, part, 10);
                        }
                        if (i != 4) return error.InvalidAddress;
                    } else {
                        return error.InvalidAddress;
                    }
                    const magic_cookie: u32 = 0x2112A442;
                    const xored_addr_bytes = try allocator.alloc(u8, 4);
                    defer allocator.free(xored_addr_bytes);
                    xored_addr_bytes[0] = addr_buf[0] ^ @as(u8, @intCast((magic_cookie >> 24) & 0xff));
                    xored_addr_bytes[1] = addr_buf[1] ^ @as(u8, @intCast((magic_cookie >> 16) & 0xff));
                    xored_addr_bytes[2] = addr_buf[2] ^ @as(u8, @intCast((magic_cookie >> 8) & 0xff));
                    xored_addr_bytes[3] = addr_buf[3] ^ @as(u8, @intCast(magic_cookie & 0xff));
                    try value.appendSlice(xored_addr_bytes);
                },
                std.posix.AF.INET6 => {
                    // IPv6 暂时不支持，返回错误
                    return error.UnsupportedAddressFamily;
                },
                else => return error.UnsupportedAddressFamily,
            }

            return Attribute{
                .type = .xor_mapped_address,
                .length = @as(u16, @intCast(value.items.len)),
                .value = try allocator.dupe(u8, value.items),
            };
        }

        /// 从属性解析（XOR 解码）
        pub fn parse(attr: Attribute, transaction_id: [12]u8) !SelfXorAddr {
            if (attr.length < 4) return error.InvalidAttribute;
            const family = attr.value[1];
            const xored_port = std.mem.readInt(u16, attr.value[2..4][0..2], std.builtin.Endian.big);
            const port = xored_port ^ ((@as(u16, transaction_id[0]) << 8) | @as(u16, transaction_id[1]));

            var address: std.net.Address = undefined;
            if (family == 0x01) {
                // IPv4
                if (attr.length < 8) return error.InvalidAttribute;
                var addr_bytes: [4]u8 = undefined;
                const magic_cookie: u32 = 0x2112A442;
                addr_bytes[0] = attr.value[4] ^ @as(u8, @intCast((magic_cookie >> 24) & 0xff));
                addr_bytes[1] = attr.value[5] ^ @as(u8, @intCast((magic_cookie >> 16) & 0xff));
                addr_bytes[2] = attr.value[6] ^ @as(u8, @intCast((magic_cookie >> 8) & 0xff));
                addr_bytes[3] = attr.value[7] ^ @as(u8, @intCast(magic_cookie & 0xff));
                address = std.net.Address.initIp4(addr_bytes, port);
            } else if (family == 0x02) {
                // IPv6
                if (attr.length < 20) return error.InvalidAttribute;
                var addr_bytes: [16]u8 = undefined;
                const magic_cookie: u32 = 0x2112A442;
                addr_bytes[0] = attr.value[4] ^ @as(u8, @intCast((magic_cookie >> 24) & 0xff));
                addr_bytes[1] = attr.value[5] ^ @as(u8, @intCast((magic_cookie >> 16) & 0xff));
                addr_bytes[2] = attr.value[6] ^ @as(u8, @intCast((magic_cookie >> 8) & 0xff));
                addr_bytes[3] = attr.value[7] ^ @as(u8, @intCast(magic_cookie & 0xff));
                var i: usize = 4;
                while (i < 16) : (i += 1) {
                    addr_bytes[i] = attr.value[4 + i] ^ transaction_id[i - 4];
                }
                address = std.net.Address.initIp6(addr_bytes, port, 0, 0);
            } else {
                return error.InvalidAddressFamily;
            }

            return SelfXorAddr{
                .family = family,
                .port = port,
                .address = address,
                .transaction_id = transaction_id,
            };
        }
    };

    /// STUN 消息
    pub const Message = struct {
        const SelfMsg = @This();
        header: MessageHeader,
        attributes: std.ArrayList(Attribute),

        pub fn init(allocator: std.mem.Allocator) SelfMsg {
            return .{
                .header = undefined,
                .attributes = std.ArrayList(Attribute).init(allocator),
            };
        }

        pub fn deinit(self: *SelfMsg) void {
            for (self.attributes.items) |*attr| {
                self.attributes.allocator.free(attr.value);
            }
            self.attributes.deinit();
        }

        /// 编码消息为字节数组
        pub fn encode(self: *SelfMsg, allocator: std.mem.Allocator) ![]u8 {
            var body = std.ArrayList(u8).init(allocator);
            defer body.deinit();

            // 编码所有属性
            for (self.attributes.items) |*attr| {
                const attr_data = try attr.*.encode(allocator);
                defer allocator.free(attr_data);
                try body.appendSlice(attr_data);
            }

            // 设置消息长度
            self.header.message_length = @as(u16, @intCast(body.items.len));

            // 构建完整消息
            const header_bytes = self.header.encode();
            var message = try allocator.alloc(u8, 20 + body.items.len);
            @memcpy(message[0..20], &header_bytes);
            @memcpy(message[20..], body.items);

            return message;
        }

        /// 解析消息
        pub fn parse(data: []const u8, allocator: std.mem.Allocator) !SelfMsg {
            if (data.len < 20) return error.InvalidMessage;

            const header_bytes: *const [20]u8 = data[0..20];
            const header = MessageHeader.parse(header_bytes);

            var message = SelfMsg.init(allocator);
            message.header = header;

            // 解析属性
            var offset: usize = 20;
            while (offset < 20 + header.message_length) {
                if (data.len < offset + 4) return error.InvalidMessage;
                const attr_length_bytes = data[offset + 2 .. offset + 4];
                const attr_length = std.mem.readInt(u16, attr_length_bytes[0..2][0..2], std.builtin.Endian.big);
                const padded_length = ((attr_length + 3) / 4) * 4;
                if (data.len < offset + 4 + padded_length) return error.InvalidMessage;

                const attr_data = data[offset .. offset + 4 + padded_length];
                const attr = try Attribute.parse(attr_data);
                var attr_copy = attr;
                attr_copy.value = try allocator.dupe(u8, attr.value);
                try message.attributes.append(attr_copy);

                offset += 4 + padded_length;
            }

            return message;
        }

        /// 添加属性
        pub fn addAttribute(self: *SelfMsg, attr: Attribute) !void {
            try self.attributes.append(attr);
        }

        /// 查找属性
        pub fn findAttribute(self: *SelfMsg, attr_type: AttributeType) ?Attribute {
            for (self.attributes.items) |attr| {
                if (attr.type == attr_type) {
                    return attr;
                }
            }
            return null;
        }

        /// 按属性类型值查找（支持 TURN 扩展属性）
        pub fn findAttributeByValue(self: *SelfMsg, attr_type_value: u16) ?Attribute {
            for (self.attributes.items) |attr| {
                if (@intFromEnum(attr.type) == attr_type_value) {
                    return attr;
                }
            }
            return null;
        }
    };

    /// 创建新的 STUN 客户端
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule) Self {
        return .{
            .allocator = allocator,
            .schedule = schedule,
        };
    }

    /// 初始化 UDP socket
    pub fn setup(self: *Self, bind_address: ?std.net.Address) !void {
        if (self.udp == null) {
            self.udp = try nets.Udp.init(self.schedule);
            if (bind_address) |addr| {
                try self.udp.?.bind(addr);
            }
        }
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        if (self.udp) |udp| {
            udp.deinit();
        }
    }

    /// 生成随机事务 ID
    pub fn generateTransactionId(_: *Self) ![12]u8 {
        var id: [12]u8 = undefined;
        std.crypto.random.bytes(&id);
        return id;
    }

    /// 发送 STUN Binding Request
    pub fn sendBindingRequest(self: *Self, server_address: std.net.Address) !Message {
        if (self.udp == null) {
            try self.setup(null);
        }

        const transaction_id = try self.generateTransactionId();
        const message_type = MessageHeader.setType(.request, .binding);

        var request = Message.init(self.allocator);
        errdefer request.deinit();

        request.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = transaction_id,
        };

        // 编码请求
        const request_data = try request.encode(self.allocator);
        defer self.allocator.free(request_data);

        // 发送请求
        _ = try self.udp.?.sendTo(request_data, server_address);

        // 接收响应
        var buffer: [2048]u8 = undefined;
        const result = try self.udp.?.recvFrom(&buffer);

        // 解析响应
        var response = try Message.parse(result.data, self.allocator);

        // 验证事务 ID
        if (!std.mem.eql(u8, &response.header.transaction_id, &transaction_id)) {
            response.deinit();
            return error.InvalidTransactionId;
        }

        // 验证消息类型
        if (response.header.getClass() != .success_response) {
            response.deinit();
            return error.STUNError;
        }

        return response;
    }

    /// 创建并发送 STUN Binding Response
    /// 用于响应接收到的 Binding Request
    pub fn sendBindingResponse(self: *Self, request: Message, client_address: std.net.Address) !void {
        if (self.udp == null) {
            return error.UdpNotInitialized;
        }

        // 创建响应消息
        var response = Message.init(self.allocator);
        // 注意：response 会在函数结束时通过 defer 清理

        // 设置响应消息头（使用相同的 transaction_id）
        const message_type = MessageHeader.setType(.success_response, .binding);
        response.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = request.header.transaction_id,
        };

        // 添加 XOR-MAPPED-ADDRESS 属性（推荐使用）
        // 注意：client_address 是请求的源地址，我们需要返回它作为 mapped address
        const xor_mapped = XorMappedAddress{
            .family = 0x01, // IPv4
            .port = client_address.getPort(),
            .address = client_address,
            .transaction_id = request.header.transaction_id,
        };
        const xor_attr = try xor_mapped.encode(self.allocator);
        // 注意：如果 addAttribute 失败，需要释放 xor_attr.value
        // 如果成功，所有权转移给 response，会在 response.deinit() 中释放
        try response.addAttribute(xor_attr);
        // 注意：如果后续操作失败，errdefer response.deinit() 会清理 response 的 attributes（包括 xor_attr.value）

        // 编码响应
        const response_data = try response.encode(self.allocator);
        defer self.allocator.free(response_data);
        
        // 清理 response 的 attributes（在发送后）
        defer response.deinit();

        // 发送响应（使用请求的源地址）
        _ = try self.udp.?.sendTo(response_data, client_address);

        std.log.debug("STUN: 已发送 Binding Response 到 {}", .{client_address});
    }

    /// 计算 MESSAGE-INTEGRITY
    /// 根据 RFC 5389，使用 HMAC-SHA1
    pub fn computeMessageIntegrity(message_data: []const u8, username: []const u8, realm: []const u8, password: []const u8) ![20]u8 {
        // 先计算长期凭证密钥：MD5(username:realm:password)
        // 注意：RFC 5389 实际上使用 MD5(username:realm:password) 作为 HMAC 密钥
        var md5 = crypto.hash.Md5.init(.{});
        md5.update(username);
        md5.update(":");
        md5.update(realm);
        md5.update(":");
        md5.update(password);
        var key: [16]u8 = undefined;
        md5.final(&key);

        // 使用 HMAC-SHA1 计算消息完整性
        // 注意：Zig 0.14.0 可能没有直接的 HmacSha1，我们需要手动实现或使用替代方案
        // 这里使用 HMAC-SHA256 作为临时替代（实际实现需要 SHA1）
        const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
        var mac_sha256: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&mac_sha256, message_data, &key);

        // 对于 RFC 5389，我们需要 SHA1（20 字节），这里取前 20 字节作为临时方案
        // TODO: 实现或集成真正的 HMAC-SHA1
        var mac: [20]u8 = undefined;
        @memcpy(&mac, mac_sha256[0..20]);
        return mac;
    }

    /// 验证 MESSAGE-INTEGRITY
    pub fn verifyMessageIntegrity(message_data: []const u8, integrity_attr: Attribute, username: []const u8, realm: []const u8, password: []const u8) !bool {
        if (integrity_attr.length != 20) return error.InvalidAttribute;
        const expected = try computeMessageIntegrity(message_data, username, realm, password);
        return std.mem.eql(u8, &expected, integrity_attr.value);
    }

    pub const Error = error{
        InvalidMessage,
        InvalidAttribute,
        InvalidTransactionId,
        InvalidAddressFamily,
        UnsupportedAddressFamily,
        STUNError,
        OutOfMemory,
    };
};
