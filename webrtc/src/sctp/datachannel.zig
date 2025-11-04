const std = @import("std");
const chunk = @import("./chunk.zig");
const stream = @import("./stream.zig");
const association = @import("./association.zig");

const Association = association.Association;

/// WebRTC 数据通道协议类型
/// 遵循 RFC 8832 Section 4
pub const DataChannelProtocol = enum(u16) {
    dcep = 50, // Data Channel Establishment Protocol
    _,
};

/// DCEP 消息类型
/// 遵循 RFC 8832 Section 5
pub const DcepMessageType = enum(u8) {
    data_channel_open = 0x03,
    data_channel_ack = 0x02,
    _,
};

/// DCEP Data Channel Open 消息
/// 遵循 RFC 8832 Section 5.1
pub const DcepOpen = struct {
    message_type: u8, // 0x03
    channel_type: u8, // 通道类型
    priority: u16, // 优先级（网络字节序）
    reliability_parameter: u32, // 可靠性参数（网络字节序）
    label_length: u16, // 标签长度（网络字节序）
    protocol_length: u16, // 协议长度（网络字节序）
    label: []u8, // 标签（UTF-8）
    protocol: []u8, // 协议（UTF-8）

    /// 解析 DCEP Open 消息
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !DcepOpen {
        if (data.len < 12) return error.InvalidDcepMessage;

        const message_type = data[0];
        if (message_type != 0x03) return error.InvalidDcepMessage;

        const channel_type = data[1];
        const priority = std.mem.readInt(u16, data[2..4][0..2], .big);
        const reliability_parameter = std.mem.readInt(u32, data[4..8][0..4], .big);
        const label_length = std.mem.readInt(u16, data[8..10][0..2], .big);
        const protocol_length = std.mem.readInt(u16, data[10..12][0..2], .big);

        var offset: usize = 12;

        if (data.len < offset + label_length + protocol_length) {
            return error.InvalidDcepMessage;
        }

        const label = try allocator.alloc(u8, label_length);
        errdefer allocator.free(label);
        if (label_length > 0) {
            @memcpy(label, data[offset .. offset + label_length]);
        }
        offset += label_length;

        const protocol = try allocator.alloc(u8, protocol_length);
        errdefer allocator.free(protocol);
        if (protocol_length > 0) {
            @memcpy(protocol, data[offset .. offset + protocol_length]);
        }

        return DcepOpen{
            .message_type = message_type,
            .channel_type = channel_type,
            .priority = priority,
            .reliability_parameter = reliability_parameter,
            .label_length = label_length,
            .protocol_length = protocol_length,
            .label = label,
            .protocol = protocol,
        };
    }

    /// 编码 DCEP Open 消息
    pub fn encode(self: *const DcepOpen, allocator: std.mem.Allocator) ![]u8 {
        const total_len = 12 + self.label.len + self.protocol.len;
        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        output[0] = self.message_type;
        output[1] = self.channel_type;
        std.mem.writeInt(u16, output[2..4][0..2], self.priority, .big);
        std.mem.writeInt(u32, output[4..8][0..4], self.reliability_parameter, .big);
        std.mem.writeInt(u16, output[8..10][0..2], self.label_length, .big);
        std.mem.writeInt(u16, output[10..12][0..2], self.protocol_length, .big);

        var offset: usize = 12;
        if (self.label.len > 0) {
            @memcpy(output[offset .. offset + self.label.len], self.label);
            offset += self.label.len;
        }
        if (self.protocol.len > 0) {
            @memcpy(output[offset .. offset + self.protocol.len], self.protocol);
        }

        return output;
    }

    /// 释放 DCEP Open 消息资源
    pub fn deinit(self: *DcepOpen, allocator: std.mem.Allocator) void {
        if (self.label.len > 0) {
            allocator.free(self.label);
        }
        if (self.protocol.len > 0) {
            allocator.free(self.protocol);
        }
    }

    pub const Error = error{
        InvalidDcepMessage,
        OutOfMemory,
        ChannelNotOpen,
        NotImplemented,
        NoData,
        StreamNotFound,
        NoAssociation,
    };
};

/// DCEP Data Channel ACK 消息
/// 遵循 RFC 8832 Section 5.2
pub const DcepAck = struct {
    message_type: u8, // 0x02

    /// 解析 DCEP ACK 消息
    pub fn parse(_: std.mem.Allocator, data: []const u8) !DcepAck {
        if (data.len < 1) return error.InvalidDcepMessage;
        if (data[0] != 0x02) return error.InvalidDcepMessage;

        return DcepAck{
            .message_type = 0x02,
        };
    }

    /// 编码 DCEP ACK 消息
    pub fn encode(_: *const DcepAck, allocator: std.mem.Allocator) ![]u8 {
        const output = try allocator.alloc(u8, 1);
        errdefer allocator.free(output);

        output[0] = 0x02;

        return output;
    }
};

/// 数据通道类型
pub const ChannelType = enum(u8) {
    reliable = 0x00,
    partial_reliable_rexmit = 0x01,
    partial_reliable_timed = 0x02,
    partial_reliable_buf = 0x03,
};

/// WebRTC 数据通道
/// 遵循 RFC 8832
pub const DataChannel = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    stream_id: u16, // SCTP 流 ID
    label: []u8, // 通道标签
    protocol: []u8, // 通道协议
    channel_type: ChannelType,
    priority: u16,
    reliability_parameter: u32,
    ordered: bool, // 是否有序传输
    state: DataChannelState,
    association: ?*Association = null, // 关联的 SCTP Association（可选）
    peer_connection: ?*anyopaque = null, // 关联的 PeerConnection（用于网络传输）

    // 事件回调
    onopen: ?*const fn (*Self) void = null,
    onclose: ?*const fn (*Self) void = null,
    onmessage: ?*const fn (*Self, []const u8) void = null,
    onerror: ?*const fn (*Self, anyerror) void = null,

    /// 初始化数据通道
    pub fn init(
        allocator: std.mem.Allocator,
        stream_id: u16,
        label: []const u8,
        protocol: []const u8,
        channel_type: ChannelType,
        priority: u16,
        reliability_parameter: u32,
        ordered: bool,
    ) !Self {
        const label_copy = try allocator.dupe(u8, label);
        errdefer allocator.free(label_copy);

        const protocol_copy = try allocator.dupe(u8, protocol);
        errdefer allocator.free(protocol_copy);

        return Self{
            .allocator = allocator,
            .stream_id = stream_id,
            .label = label_copy,
            .protocol = protocol_copy,
            .channel_type = channel_type,
            .priority = priority,
            .reliability_parameter = reliability_parameter,
            .ordered = ordered,
            .state = .connecting,
            .association = null,
            .peer_connection = null,
        };
    }

    /// 释放数据通道资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.label);
        self.allocator.free(self.protocol);
    }

    /// 创建 DCEP Open 消息
    pub fn createDcepOpen(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var dcep_open = DcepOpen{
            .message_type = 0x03,
            .channel_type = @intFromEnum(self.channel_type),
            .priority = self.priority,
            .reliability_parameter = self.reliability_parameter,
            .label_length = @as(u16, @intCast(self.label.len)),
            .protocol_length = @as(u16, @intCast(self.protocol.len)),
            .label = try allocator.dupe(u8, self.label),
            .protocol = try allocator.dupe(u8, self.protocol),
        };
        errdefer dcep_open.deinit(allocator);

        const encoded = try dcep_open.encode(allocator);
        dcep_open.deinit(allocator); // 释放临时分配的 label 和 protocol

        return encoded;
    }

    /// 处理接收到的 DCEP Open 消息
    pub fn processDcepOpen(self: *Self, allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var dcep_open = try DcepOpen.parse(allocator, data);
        defer dcep_open.deinit(allocator);

        // 更新通道参数
        self.channel_type = @as(ChannelType, @enumFromInt(dcep_open.channel_type));
        self.priority = dcep_open.priority;
        self.reliability_parameter = dcep_open.reliability_parameter;

        // 更新标签和协议（如果不同）
        // 注意：dcep_open.label 和 protocol 会在 defer 时释放，所以需要复制
        const label_new = try self.allocator.dupe(u8, dcep_open.label);
        const protocol_new = try self.allocator.dupe(u8, dcep_open.protocol);

        self.allocator.free(self.label);
        self.allocator.free(self.protocol);

        self.label = label_new;
        self.protocol = protocol_new;

        self.state = .open;

        // 创建并返回 DCEP ACK
        var dcep_ack = DcepAck{ .message_type = 0x02 };
        return try dcep_ack.encode(allocator);
    }

    /// 处理接收到的 DCEP ACK 消息
    pub fn processDcepAck(self: *Self, allocator: std.mem.Allocator, data: []const u8) !void {
        _ = try DcepAck.parse(allocator, data);
        self.state = .open;
    }

    /// 发送数据
    /// 将数据通过 SCTP Association 发送
    /// 如果 DataChannel 已关联 Association，可以省略 association 参数
    pub fn send(self: *Self, data: []const u8, association_opt: ?*Association) !void {
        const assoc = association_opt orelse self.association orelse return Error.NoAssociation;
        // 检查状态
        if (self.state != .open) {
            return Error.ChannelNotOpen;
        }

        // 通过 SCTP Association 发送数据
        // 1. 找到对应的 Stream（通过 stream_id）
        if (assoc.stream_manager.findStream(self.stream_id)) |sctp_stream| {
            // 2. 创建 Data Chunk
            // 使用 sendData 方法创建数据块
            // 获取当前 TSN（简化实现：使用递增的 TSN）
            const current_tsn = assoc.next_tsn;
            assoc.next_tsn +%= 1;
            var data_chunk = try self.sendData(
                sctp_stream,
                self.allocator,
                current_tsn,
                data,
            );
            // 3. 编码 Data Chunk
            const chunk_data = try data_chunk.encode(self.allocator);
            defer {
                self.allocator.free(chunk_data);
                data_chunk.deinit(self.allocator);
            }

            // 4. 构建 SCTP 包（CommonHeader + Data Chunk）
            const sctp_packet = try self.buildSctpPacket(assoc, chunk_data);
            defer self.allocator.free(sctp_packet);

            // 5. 通过网络发送（如果 PeerConnection 可用）
            if (self.peer_connection) |pc| {
                const PeerConnection = @import("../peer/connection.zig").PeerConnection;
                const pc_ptr: *PeerConnection = @ptrCast(@alignCast(pc));
                try pc_ptr.sendSctpData(sctp_packet);
            }
        } else {
            // Stream 不存在，需要创建
            // 创建 Stream（有序传输）
            const sctp_stream = try assoc.stream_manager.createStream(self.stream_id, self.ordered);
            errdefer _ = assoc.stream_manager.removeStream(self.stream_id) catch {};

            // 创建并发送数据块
            const current_tsn = assoc.next_tsn;
            assoc.next_tsn +%= 1;
            var data_chunk = try self.sendData(
                sctp_stream,
                self.allocator,
                current_tsn,
                data,
            );
            // 编码 Data Chunk
            const chunk_data = try data_chunk.encode(self.allocator);
            defer {
                self.allocator.free(chunk_data);
                data_chunk.deinit(self.allocator);
            }

            // 构建 SCTP 包（CommonHeader + Data Chunk）
            const sctp_packet = try self.buildSctpPacket(assoc, chunk_data);
            defer self.allocator.free(sctp_packet);

            // 通过网络发送（如果 PeerConnection 可用）
            if (self.peer_connection) |pc| {
                const PeerConnection = @import("../peer/connection.zig").PeerConnection;
                const pc_ptr: *PeerConnection = @ptrCast(@alignCast(pc));
                try pc_ptr.sendSctpData(sctp_packet);
            }
        }
    }

    /// 接收数据
    /// 从 SCTP Association 接收数据
    /// 如果 DataChannel 已关联 Association，可以省略 association 参数
    pub fn recv(self: *Self, association_opt: ?*Association, allocator: std.mem.Allocator) ![]u8 {
        const assoc = association_opt orelse self.association orelse return Error.NoAssociation;
        // 检查状态
        if (self.state != .open) {
            return Error.ChannelNotOpen;
        }

        // 从 SCTP Association 接收数据
        // 1. 找到对应的 Stream
        if (assoc.stream_manager.findStream(self.stream_id)) |sctp_stream| {
            // 2. 从 Stream 接收缓冲区读取数据
            if (sctp_stream.receive_buffer.items.len > 0) {
                // 复制数据并返回
                const data = try allocator.dupe(u8, sctp_stream.receive_buffer.items);

                // 清空接收缓冲区（简化实现）
                sctp_stream.receive_buffer.clearRetainingCapacity();

                // 触发 onmessage 事件
                if (self.onmessage) |callback| {
                    callback(self, data);
                }

                return data;
            } else {
                // 没有数据可接收
                return Error.NoData;
            }
        } else {
            // Stream 不存在
            return Error.StreamNotFound;
        }
    }

    /// 设置状态
    /// 状态变化时会触发相应的事件回调
    pub fn setState(self: *Self, new_state: DataChannelState) void {
        const old_state = self.state;
        self.state = new_state;

        // 触发状态变化事件
        switch (new_state) {
            .open => {
                if (old_state != .open and self.onopen) |callback| {
                    callback(self);
                }
            },
            .closed => {
                if (old_state != .closed and self.onclose) |callback| {
                    callback(self);
                }
            },
            else => {},
        }
    }

    /// 获取状态
    pub fn getState(self: *const Self) DataChannelState {
        return self.state;
    }

    /// 检查通道是否打开
    pub fn isOpen(self: *const Self) bool {
        return self.state == .open;
    }

    /// 设置关联的 SCTP Association
    pub fn setAssociation(self: *Self, assoc: *Association) void {
        self.association = assoc;
    }

    /// 获取关联的 SCTP Association
    pub fn getAssociation(self: *const Self) ?*Association {
        return self.association;
    }

    /// 设置 onopen 回调
    pub fn setOnOpen(self: *Self, callback: ?*const fn (*Self) void) void {
        self.onopen = callback;
    }

    /// 设置 onclose 回调
    pub fn setOnClose(self: *Self, callback: ?*const fn (*Self) void) void {
        self.onclose = callback;
    }

    /// 设置 onmessage 回调
    pub fn setOnMessage(self: *Self, callback: ?*const fn (*Self, []const u8) void) void {
        self.onmessage = callback;
    }

    /// 设置 onerror 回调
    pub fn setOnError(self: *Self, callback: ?*const fn (*Self, anyerror) void) void {
        self.onerror = callback;
    }

    /// 设置关联的 PeerConnection（用于网络传输）
    pub fn setPeerConnection(self: *Self, pc: anytype) void {
        self.peer_connection = @ptrCast(pc);
    }

    /// 发送用户数据
    /// 将用户数据封装为 SCTP DATA 块
    pub fn sendData(
        _: *Self,
        sctp_stream: *stream.Stream,
        allocator: std.mem.Allocator,
        tsn: u32,
        data: []const u8,
    ) !chunk.DataChunk {
        return try sctp_stream.createDataChunk(
            allocator,
            tsn,
            @intFromEnum(DataChannelProtocol.dcep),
            data,
            true, // beginning
            true, // ending
        );
    }

    /// 构建 SCTP 包
    /// 将 CommonHeader 和 Chunk 组合成完整的 SCTP 包
    fn buildSctpPacket(
        self: *Self,
        assoc: *Association,
        chunk_data: []const u8,
    ) ![]u8 {
        // 计算包总长度（CommonHeader: 12字节 + Chunk数据）
        const packet_len = 12 + chunk_data.len;
        const packet = try self.allocator.alloc(u8, packet_len);
        errdefer self.allocator.free(packet);

        // 构建 CommonHeader
        const common_header = chunk.CommonHeader{
            .source_port = assoc.local_port,
            .destination_port = assoc.remote_port,
            .verification_tag = assoc.local_verification_tag,
            .checksum = 0, // 简化：不计算校验和
        };

        // 编码 CommonHeader（前 12 字节）
        common_header.encode(packet[0..12]);

        // 复制 Chunk 数据（从第 12 字节开始）
        @memcpy(packet[12..], chunk_data);

        // 计算并写入校验和（简化实现：使用 CRC32）
        // 注意：RFC 4960 要求使用 Adler-32，这里简化使用 CRC32
        const checksum = self.calculateChecksum(packet);
        std.mem.writeInt(u32, packet[8..12][0..4], checksum, .big);

        return packet;
    }

    /// 计算 SCTP 校验和
    /// RFC 4960 要求使用 Adler-32，这里简化使用 CRC32
    fn calculateChecksum(self: *Self, data: []const u8) u32 {
        _ = self;
        // 简化实现：使用简单的校验和
        // 实际应该使用 Adler-32（RFC 4960 Appendix B）
        var sum: u32 = 0;
        for (data) |byte| {
            sum +%= byte;
        }
        return sum;
    }

    pub const Error = error{
        InvalidDcepMessage,
        OutOfMemory,
        ChannelNotOpen,
        NotImplemented,
        NoData,
        StreamNotFound,
        NoAssociation,
    };
};

/// 数据通道状态
pub const DataChannelState = enum {
    connecting, // 连接中（发送 DCEP Open）
    open, // 已打开
    closing, // 关闭中
    closed, // 已关闭
};
