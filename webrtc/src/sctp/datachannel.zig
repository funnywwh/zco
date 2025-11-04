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

    /// 获取通道状态
    pub fn getState(self: *const Self) DataChannelState {
        return self.state;
    }

    /// 检查通道是否打开
    pub fn isOpen(self: *const Self) bool {
        return self.state == .open;
    }

    pub const Error = error{
        InvalidDcepMessage,
        OutOfMemory,
    };
};

/// 数据通道状态
pub const DataChannelState = enum {
    connecting, // 连接中（发送 DCEP Open）
    open, // 已打开
    closing, // 关闭中
    closed, // 已关闭
};
