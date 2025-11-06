const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const Stun = @import("./stun.zig").Stun;

/// TURN (Traversal Using Relays around NAT) 协议实现
/// 基于 RFC 5766，扩展 STUN 协议
pub const Turn = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    udp: ?*nets.Udp = null,

    // TURN 服务器地址
    server_address: std.net.Address,
    username: []const u8,
    password: []const u8,

    // Allocation 信息
    allocation: ?Allocation = null,

    // 状态
    state: State,

    // STUN 客户端（用于复用 STUN 功能）
    stun: ?*Stun = null,

    /// TURN 状态
    pub const State = enum {
        idle, // 空闲
        allocating, // 正在分配
        allocated, // 已分配
        refreshing, // 正在刷新
        error_state, // 错误状态
    };

    /// Allocation 信息
    pub const Allocation = struct {
        relay_address: std.net.Address, // 中继地址（服务器分配的）
        relayed_address: std.net.Address, // 实际中继的地址
        lifetime: u32, // 生存时间（秒）
        reservation_token: ?[]const u8 = null, // 预留令牌

        pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
            if (self.reservation_token) |token| {
                allocator.free(token);
            }
        }
    };

    /// TURN 消息方法（扩展 STUN 方法）
    pub const TurnMethod = enum(u12) {
        allocate = 0x003,
        refresh = 0x004,
        send_indication = 0x006,
        data_indication = 0x007,
        create_permission = 0x008,
        channel_bind = 0x009,
    };

    /// TURN 特定属性类型
    pub const TurnAttributeType = enum(u16) {
        channel_number = 0x000C, // Channel 编号
        lifetime = 0x000D, // 生存时间
        xor_peer_address = 0x0012, // XOR 对等地址
        data = 0x0013, // 数据
        xor_relayed_address = 0x0016, // XOR 中继地址
        requested_transport = 0x0019, // 请求的传输协议
        even_port = 0x0018, // 偶数端口
        requested_address_family = 0x0017, // 请求的地址族
        dont_fragment = 0x001A, // 不分片
        reservation_token = 0x0022, // 预留令牌
    };

    /// 初始化 TURN 客户端
    pub fn init(
        allocator: std.mem.Allocator,
        schedule: *zco.Schedule,
        server_address: std.net.Address,
        username: []const u8,
        password: []const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .schedule = schedule,
            .server_address = server_address,
            .username = try allocator.dupe(u8, username),
            .password = try allocator.dupe(u8, password),
            .state = .idle,
        };
        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.username);
        self.allocator.free(self.password);

        if (self.allocation) |*alloc| {
            alloc.deinit(self.allocator);
        }

        if (self.udp) |udp| {
            udp.deinit();
        }

        if (self.stun) |stun| {
            stun.deinit();
            self.allocator.destroy(stun);
        }

        self.allocator.destroy(self);
    }

    /// 获取当前状态
    pub fn getState(self: *const Self) State {
        return self.state;
    }

    /// 获取 Allocation 信息
    pub fn getAllocation(self: *const Self) ?Allocation {
        return self.allocation;
    }

    /// 初始化 UDP 和 STUN
    fn setup(self: *Self) !void {
        if (self.udp == null) {
            self.udp = try nets.Udp.init(self.schedule);
            // 绑定到任意地址，让系统分配端口
            const bind_addr = try std.net.Address.parseIp4("0.0.0.0", 0);
            try self.udp.?.bind(bind_addr);
        }

        if (self.stun == null) {
            const stun_ptr = try self.allocator.create(Stun);
            stun_ptr.* = Stun.init(self.allocator, self.schedule);
            stun_ptr.udp = self.udp;
            self.stun = stun_ptr;
        }
    }

    /// 分配中继地址（Allocation）
    pub fn allocate(self: *Self) !Allocation {
        if (self.state != .idle and self.state != .error_state) {
            return error.InvalidState;
        }

        try self.setup();
        self.state = .allocating;

        const stun = self.stun.?;
        const transaction_id = try stun.generateTransactionId();

        // 创建 Allocate 请求
        var request = Stun.Message.init(self.allocator);
        errdefer request.deinit();

        // 设置消息类型（Allocate = 0x003）
        // TURN 方法不在 STUN 的 MessageMethod 枚举中，需要手动构建消息类型
        // 消息类型 = (class << 7) | method_encoded
        // Allocate = 0x003 = 0b000000000011
        // Request class = 0b00
        // 手动编码：class (2 bits) + reserved (1 bit) + method (12 bits)
        const allocate_method: u12 = 0x003;
        const class_val: u16 = @as(u16, 0b00) << 7; // Request class
        // STUN 方法编码：M0-M3 在 bits 3-6, M4-M8 在 bits 7-11, M9-M11 在 bits 12-15
        const method_val: u16 = ((allocate_method & 0x0f80) << 2) | ((allocate_method & 0x0070) << 1) | (allocate_method & 0x000f);
        const message_type = class_val | method_val;
        request.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = transaction_id,
        };

        // 添加 REQUESTED-TRANSPORT 属性（UDP = 17）
        var transport_value: [4]u8 = undefined;
        transport_value[0] = 0;
        transport_value[1] = 0;
        transport_value[2] = 0;
        transport_value[3] = 17; // UDP protocol number
        const transport_attr = Stun.Attribute{
            .type = @enumFromInt(0x0019), // REQUESTED-TRANSPORT
            .length = 4,
            .value = &transport_value,
        };
        try request.addAttribute(transport_attr);

        // 编码并发送请求
        const request_data = try request.encode(self.allocator);
        defer self.allocator.free(request_data);

        _ = try self.udp.?.sendTo(request_data, self.server_address);

        // 接收响应
        // 使用堆分配 buffer，避免栈溢出
        const buffer = try self.allocator.alloc(u8, 2048);
        defer self.allocator.free(buffer);
        const result = try self.udp.?.recvFrom(buffer);

        // 解析响应
        var response = try Stun.Message.parse(result.data, self.allocator);
        defer response.deinit();

        // 验证事务 ID
        if (!std.mem.eql(u8, &response.header.transaction_id, &transaction_id)) {
            self.state = .error_state;
            return error.InvalidTransactionId;
        }

        // 验证消息类型
        if (response.header.getClass() != .success_response) {
            self.state = .error_state;
            return error.TurnError;
        }

        // 提取 XOR-RELAYED-ADDRESS
        const xor_relayed_attr = response.findAttributeByValue(0x0016) orelse {
            self.state = .error_state;
            return error.MissingAttribute;
        };

        // 解析 XOR-RELAYED-ADDRESS（XOR-RELAYED-ADDRESS 使用 magic cookie，不需要 transaction_id）
        const xor_relayed = try parseXorRelayedAddress(xor_relayed_attr);
        const relayed_address = xor_relayed.address;

        // 提取 LIFETIME
        var lifetime: u32 = 3600; // 默认 1 小时
        if (response.findAttributeByValue(0x000D)) |lifetime_attr| {
            if (lifetime_attr.length == 4) {
                lifetime = std.mem.readInt(u32, lifetime_attr.value[0..4][0..4], std.builtin.Endian.big);
            }
        }

        // 创建 Allocation
        var allocation = Allocation{
            .relay_address = self.server_address, // TURN 服务器地址
            .relayed_address = relayed_address, // 实际中继地址
            .lifetime = lifetime,
        };

        // 提取 RESERVATION-TOKEN（如果有）
        if (response.findAttributeByValue(0x0022)) |token_attr| {
            if (token_attr.length > 0) {
                allocation.reservation_token = try self.allocator.dupe(u8, token_attr.value);
            }
        }

        self.allocation = allocation;
        self.state = .allocated;

        return allocation;
    }

    /// 刷新 Allocation
    pub fn refresh(self: *Self, lifetime: ?u32) !void {
        if (self.state != .allocated) {
            return error.InvalidState;
        }

        self.state = .refreshing;

        const stun = self.stun.?;
        const transaction_id = try stun.generateTransactionId();

        // 创建 Refresh 请求
        var request = Stun.Message.init(self.allocator);
        errdefer request.deinit();

        // Refresh = 0x004
        const refresh_method: u12 = 0x004;
        const class_val: u16 = @as(u16, 0b00) << 7; // Request class
        const method_val: u16 = ((refresh_method & 0x0f80) << 2) | ((refresh_method & 0x0070) << 1) | (refresh_method & 0x000f);
        const message_type = class_val | method_val;
        request.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = transaction_id,
        };

        // 添加 LIFETIME 属性
        if (lifetime) |lt| {
            var lifetime_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &lifetime_bytes, lt, std.builtin.Endian.big);
            const lifetime_attr = Stun.Attribute{
                .type = @enumFromInt(0x000D), // LIFETIME
                .length = 4,
                .value = &lifetime_bytes,
            };
            try request.addAttribute(lifetime_attr);
        }

        // 编码并发送
        const request_data = try request.encode(self.allocator);
        defer self.allocator.free(request_data);

        _ = try self.udp.?.sendTo(request_data, self.server_address);

        // 接收响应
        // 使用堆分配 buffer，避免栈溢出
        const buffer = try self.allocator.alloc(u8, 2048);
        defer self.allocator.free(buffer);
        const result = try self.udp.?.recvFrom(buffer);

        var response = try Stun.Message.parse(result.data, self.allocator);
        defer response.deinit();

        // 验证响应
        if (!std.mem.eql(u8, &response.header.transaction_id, &transaction_id)) {
            self.state = .error_state;
            return error.InvalidTransactionId;
        }

        if (response.header.getClass() != .success_response) {
            self.state = .error_state;
            return error.TurnError;
        }

        // 更新 lifetime
        if (response.findAttributeByValue(0x000D)) |lifetime_attr| {
            if (lifetime_attr.length == 4) {
                const new_lifetime = std.mem.readInt(u32, lifetime_attr.value[0..4][0..4], std.builtin.Endian.big);
                if (self.allocation) |*alloc| {
                    alloc.lifetime = new_lifetime;
                }
            }
        }

        self.state = .allocated;
    }

    /// 创建 Permission（允许对等端通过中继通信）
    pub fn createPermission(self: *Self, peer_address: std.net.Address) !void {
        if (self.state != .allocated) {
            return error.InvalidState;
        }

        const stun = self.stun.?;
        const transaction_id = try stun.generateTransactionId();

        // 创建 CreatePermission 请求
        var request = Stun.Message.init(self.allocator);
        errdefer request.deinit();

        // CreatePermission = 0x008
        const create_permission_method: u12 = 0x008;
        const class_val: u16 = @as(u16, 0b00) << 7; // Request class
        const method_val: u16 = ((create_permission_method & 0x0f80) << 2) | ((create_permission_method & 0x0070) << 1) | (create_permission_method & 0x000f);
        const message_type = class_val | method_val;
        request.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = transaction_id,
        };

        // 添加 XOR-PEER-ADDRESS 属性（XOR-PEER-ADDRESS 使用 magic cookie，不需要 transaction_id）
        const xor_peer_attr = try encodeXorPeerAddress(peer_address, self.allocator);
        errdefer self.allocator.free(xor_peer_attr.value);
        try request.addAttribute(xor_peer_attr);

        // 编码并发送
        const request_data = try request.encode(self.allocator);
        defer self.allocator.free(request_data);

        _ = try self.udp.?.sendTo(request_data, self.server_address);

        // 接收响应
        // 使用堆分配 buffer，避免栈溢出
        const buffer = try self.allocator.alloc(u8, 2048);
        defer self.allocator.free(buffer);
        const result = try self.udp.?.recvFrom(buffer);

        var response = try Stun.Message.parse(result.data, self.allocator);
        defer response.deinit();

        // 验证响应
        if (!std.mem.eql(u8, &response.header.transaction_id, &transaction_id)) {
            return error.InvalidTransactionId;
        }

        if (response.header.getClass() != .success_response) {
            return error.TurnError;
        }
    }

    /// 通过 TURN 发送数据（Send Indication）
    pub fn send(self: *Self, data: []const u8, peer_address: std.net.Address) !void {
        if (self.state != .allocated) {
            return error.InvalidState;
        }

        const stun = self.stun.?;
        const transaction_id = try stun.generateTransactionId();

        // 创建 Send Indication（Indication 不需要响应）
        var indication = Stun.Message.init(self.allocator);
        errdefer indication.deinit();

        // Send Indication = 0x006, Indication class = 0b01
        const send_method: u12 = 0x006;
        const class_val: u16 = @as(u16, 0b01) << 7; // Indication class
        const method_val: u16 = ((send_method & 0x0f80) << 2) | ((send_method & 0x0070) << 1) | (send_method & 0x000f);
        const message_type = class_val | method_val;
        indication.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = transaction_id,
        };

        // 添加 XOR-PEER-ADDRESS（XOR-PEER-ADDRESS 使用 magic cookie，不需要 transaction_id）
        const xor_peer_attr = try encodeXorPeerAddress(peer_address, self.allocator);
        errdefer self.allocator.free(xor_peer_attr.value);
        try indication.addAttribute(xor_peer_attr);

        // 添加 DATA 属性
        const data_attr = Stun.Attribute{
            .type = @enumFromInt(0x0013), // DATA
            .length = @as(u16, @intCast(data.len)),
            .value = data,
        };
        try indication.addAttribute(data_attr);

        // 编码并发送（Indication 不需要响应）
        const indication_data = try indication.encode(self.allocator);
        defer self.allocator.free(indication_data);

        _ = try self.udp.?.sendTo(indication_data, self.server_address);
    }

    /// 接收 Data Indication
    pub fn recv(self: *Self, buffer: []u8) !struct { data: []u8, peer: std.net.Address } {
        if (self.state != .allocated) {
            return error.InvalidState;
        }

        const result = try self.udp.?.recvFrom(buffer);

        // 尝试解析为 STUN Data Indication
        // 注意：也可能是 ChannelData（不是 STUN 消息）
        if (result.data.len < 20) {
            return error.InvalidMessage;
        }

        // 检查是否是 STUN 消息（前 2 字节的高 2 位应为 0b00 或 0b01）
        const first_two_bytes = std.mem.readInt(u16, result.data[0..2][0..2], std.builtin.Endian.big);
        const message_class = (first_two_bytes >> 7) & 0b11;

        if (message_class == 0b00 or message_class == 0b01) {
            // STUN Data Indication
            var indication = try Stun.Message.parse(result.data, self.allocator);
            defer indication.deinit();

            // 提取 XOR-PEER-ADDRESS
            const xor_peer_attr = indication.findAttributeByValue(0x0012) orelse {
                return error.MissingAttribute;
            };

            // XOR-PEER-ADDRESS 使用 magic cookie，不需要 transaction_id
            const xor_peer = try parseXorPeerAddress(xor_peer_attr);
            const peer_address = xor_peer.address;

            // 提取 DATA
            const data_attr = indication.findAttributeByValue(0x0013) orelse {
                return error.MissingAttribute;
            };

            if (data_attr.value.len > buffer.len) {
                return error.BufferTooSmall;
            }

            @memcpy(buffer[0..data_attr.value.len], data_attr.value);

            return .{
                .data = buffer[0..data_attr.value.len],
                .peer = peer_address,
            };
        } else {
            // ChannelData（简化处理，这里暂时返回错误）
            return error.UnsupportedChannelData;
        }
    }

    /// 解析 XOR-RELAYED-ADDRESS
    fn parseXorRelayedAddress(attr: Stun.Attribute) !struct { address: std.net.Address } {
        if (attr.length < 4) return error.InvalidAttribute;

        const family = attr.value[1];
        if (family != 1) return error.UnsupportedAddressFamily; // 只支持 IPv4

        // XOR 端口（前 2 字节）
        const xored_port = std.mem.readInt(u16, attr.value[2..4][0..2], std.builtin.Endian.big);
        const port = xored_port ^ 0x2112; // XOR with magic cookie high 16 bits

        // XOR 地址（4 字节）
        const magic_cookie: u32 = 0x2112A442;
        var addr_bytes: [4]u8 = undefined;
        addr_bytes[0] = attr.value[4] ^ @as(u8, ((magic_cookie >> 24) & 0xff));
        addr_bytes[1] = attr.value[5] ^ @as(u8, ((magic_cookie >> 16) & 0xff));
        addr_bytes[2] = attr.value[6] ^ @as(u8, ((magic_cookie >> 8) & 0xff));
        addr_bytes[3] = attr.value[7] ^ @as(u8, (magic_cookie & 0xff));

        const address = std.net.Address.initIp4(addr_bytes, port);
        return .{ .address = address };
    }

    /// 编码 XOR-PEER-ADDRESS
    fn encodeXorPeerAddress(address: std.net.Address, allocator: std.mem.Allocator) !Stun.Attribute {
        // 简化：只支持 IPv4
        // 使用 format 获取 IP 地址字符串，然后解析
        var addr_buf: [64]u8 = undefined;
        var fmt_buf = std.io.fixedBufferStream(&addr_buf);
        try address.format("", .{}, fmt_buf.writer());
        const addr_str = fmt_buf.getWritten();

        // 解析 IP 地址字符串（格式：xxx.xxx.xxx.xxx:port）
        var addr_bytes: [4]u8 = undefined;
        if (std.mem.indexOfScalar(u8, addr_str, ':')) |colon_pos| {
            const ip_str = addr_str[0..colon_pos];
            var parts = std.mem.splitScalar(u8, ip_str, '.');
            var i: usize = 0;
            while (parts.next()) |part| : (i += 1) {
                if (i >= 4) break;
                addr_bytes[i] = try std.fmt.parseInt(u8, part, 10);
            }
            if (i != 4) return error.InvalidAddress;
        } else {
            return error.InvalidAddress;
        }
        const port = address.getPort();
        const magic_cookie: u32 = 0x2112A442;

        var value = std.ArrayList(u8).init(allocator);
        errdefer value.deinit();

        // Family (1 byte) + Reserved (1 byte) + Port (2 bytes) + Address (4 bytes)
        try value.append(0); // Reserved
        try value.append(1); // IPv4

        // XOR 端口
        const xored_port = port ^ 0x2112;
        var port_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &port_bytes, xored_port, std.builtin.Endian.big);
        try value.appendSlice(&port_bytes);

        // XOR 地址
        try value.append(addr_bytes[0] ^ @as(u8, ((magic_cookie >> 24) & 0xff)));
        try value.append(addr_bytes[1] ^ @as(u8, ((magic_cookie >> 16) & 0xff)));
        try value.append(addr_bytes[2] ^ @as(u8, ((magic_cookie >> 8) & 0xff)));
        try value.append(addr_bytes[3] ^ @as(u8, (magic_cookie & 0xff)));

        const value_slice = try value.toOwnedSlice();
        return Stun.Attribute{
            .type = @enumFromInt(0x0012), // XOR-PEER-ADDRESS
            .length = @as(u16, @intCast(value_slice.len)),
            .value = value_slice,
        };
    }

    /// 解析 XOR-PEER-ADDRESS
    fn parseXorPeerAddress(attr: Stun.Attribute) !struct { address: std.net.Address } {
        if (attr.length < 4) return error.InvalidAttribute;

        const family = attr.value[1];
        if (family != 1) return error.UnsupportedAddressFamily;

        const xored_port = std.mem.readInt(u16, attr.value[2..4][0..2], std.builtin.Endian.big);
        const port = xored_port ^ 0x2112;

        const magic_cookie: u32 = 0x2112A442;
        var addr_bytes: [4]u8 = undefined;
        addr_bytes[0] = attr.value[4] ^ @as(u8, ((magic_cookie >> 24) & 0xff));
        addr_bytes[1] = attr.value[5] ^ @as(u8, ((magic_cookie >> 16) & 0xff));
        addr_bytes[2] = attr.value[6] ^ @as(u8, ((magic_cookie >> 8) & 0xff));
        addr_bytes[3] = attr.value[7] ^ @as(u8, (magic_cookie & 0xff));

        const address = std.net.Address.initIp4(addr_bytes, port);
        return .{ .address = address };
    }

    pub const Error = error{
        InvalidState,
        InvalidTransactionId,
        TurnError,
        MissingAttribute,
        InvalidAttribute,
        UnsupportedAddressFamily,
        InvalidMessage,
        BufferTooSmall,
        UnsupportedChannelData,
        InvalidAddress,
        OutOfMemory,
    };
};
