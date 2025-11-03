const std = @import("std");

/// SCTP 公共头
/// 遵循 RFC 4960 Section 3.1
pub const CommonHeader = struct {
    source_port: u16,
    destination_port: u16,
    verification_tag: u32,
    checksum: u32,

    /// 解析 SCTP 公共头
    pub fn parse(data: []const u8) !CommonHeader {
        if (data.len < 12) return error.InvalidSctpHeader;

        const source_port = std.mem.readInt(u16, data[0..2][0..2], .big);
        const destination_port = std.mem.readInt(u16, data[2..4][0..2], .big);
        const verification_tag = std.mem.readInt(u32, data[4..8][0..4], .big);
        const checksum = std.mem.readInt(u32, data[8..12][0..4], .big);

        return CommonHeader{
            .source_port = source_port,
            .destination_port = destination_port,
            .verification_tag = verification_tag,
            .checksum = checksum,
        };
    }

    /// 编码 SCTP 公共头
    pub fn encode(self: *const CommonHeader, output: []u8) void {
        std.debug.assert(output.len >= 12);

        std.mem.writeInt(u16, output[0..2][0..2], self.source_port, .big);
        std.mem.writeInt(u16, output[2..4][0..2], self.destination_port, .big);
        std.mem.writeInt(u32, output[4..8][0..4], self.verification_tag, .big);
        std.mem.writeInt(u32, output[8..12][0..4], self.checksum, .big);
    }
};

/// SCTP 块类型
/// 遵循 RFC 4960 Section 3.2
pub const ChunkType = enum(u8) {
    data = 0,
    init = 1,
    init_ack = 2,
    sack = 3,
    heartbeat = 4,
    heartbeat_ack = 5,
    abort = 6,
    shutdown = 7,
    shutdown_ack = 8,
    error_chunk = 9,
    cookie_echo = 10,
    cookie_ack = 11,
    ecne = 12,
    cwr = 13,
    shutdown_complete = 14,
    _,
};

/// SCTP 块公共头
/// 遵循 RFC 4960 Section 3.2
pub const ChunkHeader = struct {
    chunk_type: ChunkType,
    flags: u8,
    length: u16,

    /// 解析块头
    pub fn parse(data: []const u8) !ChunkHeader {
        if (data.len < 4) return error.InvalidChunkHeader;

        const chunk_type_value = data[0];
        const chunk_type = @as(ChunkType, @enumFromInt(chunk_type_value));
        const flags = data[1];
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);

        return ChunkHeader{
            .chunk_type = chunk_type,
            .flags = flags,
            .length = length,
        };
    }

    /// 编码块头
    pub fn encode(self: *const ChunkHeader, output: []u8) void {
        std.debug.assert(output.len >= 4);

        output[0] = @intFromEnum(self.chunk_type);
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);
    }
};

/// DATA 块
/// 遵循 RFC 4960 Section 3.3.1
pub const DataChunk = struct {
    flags: u8, // U (Unordered), B (Beginning), E (Ending)
    length: u16,
    tsn: u32, // Transmission Sequence Number
    stream_id: u16,
    stream_sequence: u16,
    payload_protocol_id: u32,
    user_data: []u8, // 动态分配

    /// 解析 DATA 块
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !DataChunk {
        if (data.len < 16) return error.InvalidDataChunk;

        const flags = data[1]; // Flags 在第二个字节
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);
        if (data.len < length) return error.InvalidDataChunk;

        const tsn = std.mem.readInt(u32, data[4..8][0..4], .big);
        const stream_id = std.mem.readInt(u16, data[8..10][0..2], .big);
        const stream_sequence = std.mem.readInt(u16, data[10..12][0..2], .big);
        const payload_protocol_id = std.mem.readInt(u32, data[12..16][0..4], .big);

        const user_data_len = length - 16;
        const user_data = try allocator.alloc(u8, user_data_len);
        @memcpy(user_data, data[16 .. 16 + user_data_len]);

        return DataChunk{
            .flags = flags,
            .length = length,
            .tsn = tsn,
            .stream_id = stream_id,
            .stream_sequence = stream_sequence,
            .payload_protocol_id = payload_protocol_id,
            .user_data = user_data,
        };
    }

    /// 编码 DATA 块
    pub fn encode(self: *const DataChunk, allocator: std.mem.Allocator) ![]u8 {
        const total_len = self.length;
        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        // 块类型
        output[0] = 0; // DATA
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);

        std.mem.writeInt(u32, output[4..8][0..4], self.tsn, .big);
        std.mem.writeInt(u16, output[8..10][0..2], self.stream_id, .big);
        std.mem.writeInt(u16, output[10..12][0..2], self.stream_sequence, .big);
        std.mem.writeInt(u32, output[12..16][0..4], self.payload_protocol_id, .big);

        @memcpy(output[16..], self.user_data);

        return output;
    }

    /// 释放 DATA 块资源
    pub fn deinit(self: *DataChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.user_data);
    }
};

/// INIT 块
/// 遵循 RFC 4960 Section 3.3.2
pub const InitChunk = struct {
    allocator: std.mem.Allocator,
    flags: u8,
    length: u16,
    initiate_tag: u32,
    a_rwnd: u32, // Advertised Receiver Window Credit
    outbound_streams: u16,
    inbound_streams: u16,
    initial_tsn: u32,
    parameters: []u8, // 可选参数（动态分配）

    /// 解析 INIT 块
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !InitChunk {
        if (data.len < 20) return error.InvalidInitChunk;

        const flags = data[1]; // Flags 在第二个字节
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);
        if (data.len < length) return error.InvalidInitChunk;

        const initiate_tag = std.mem.readInt(u32, data[4..8][0..4], .big);
        const a_rwnd = std.mem.readInt(u32, data[8..12][0..4], .big);
        const outbound_streams = std.mem.readInt(u16, data[12..14][0..2], .big);
        const inbound_streams = std.mem.readInt(u16, data[14..16][0..2], .big);
        const initial_tsn = std.mem.readInt(u32, data[16..20][0..4], .big);

        const params_len = length - 20;
        const parameters = if (params_len > 0)
            try allocator.alloc(u8, params_len)
        else
            try allocator.alloc(u8, 0);
        if (params_len > 0) {
            @memcpy(parameters, data[20 .. 20 + params_len]);
        }

        return InitChunk{
            .allocator = allocator,
            .flags = flags,
            .length = length,
            .initiate_tag = initiate_tag,
            .a_rwnd = a_rwnd,
            .outbound_streams = outbound_streams,
            .inbound_streams = inbound_streams,
            .initial_tsn = initial_tsn,
            .parameters = parameters,
        };
    }

    /// 编码 INIT 块
    pub fn encode(self: *const InitChunk, allocator: std.mem.Allocator) ![]u8 {
        const total_len = self.length;
        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        output[0] = 1; // INIT
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);

        std.mem.writeInt(u32, output[4..8][0..4], self.initiate_tag, .big);
        std.mem.writeInt(u32, output[8..12][0..4], self.a_rwnd, .big);
        std.mem.writeInt(u16, output[12..14][0..2], self.outbound_streams, .big);
        std.mem.writeInt(u16, output[14..16][0..2], self.inbound_streams, .big);
        std.mem.writeInt(u32, output[16..20][0..4], self.initial_tsn, .big);

        if (self.parameters.len > 0) {
            @memcpy(output[20..], self.parameters);
        }

        return output;
    }

    /// 释放 INIT 块资源
    pub fn deinit(self: *InitChunk) void {
        if (self.parameters.len > 0) {
            self.allocator.free(self.parameters);
        }
    }
};

/// SACK 块
/// 遵循 RFC 4960 Section 3.3.4
pub const SackChunk = struct {
    flags: u8,
    length: u16,
    cum_tsn_ack: u32, // Cumulative TSN Acknowledgment
    a_rwnd: u32, // Advertised Receiver Window Credit
    gap_blocks: []GapBlock, // 动态分配
    duplicate_tsns: []u32, // 动态分配

    /// Gap Block（间隔块）
    pub const GapBlock = struct {
        start: u16,
        end: u16,
    };

    /// 解析 SACK 块
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !SackChunk {
        if (data.len < 16) return error.InvalidSackChunk;

        const flags = data[1]; // Flags 在第二个字节
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);
        if (data.len < length) return error.InvalidSackChunk;

        const cum_tsn_ack = std.mem.readInt(u32, data[4..8][0..4], .big);
        const a_rwnd = std.mem.readInt(u32, data[8..12][0..4], .big);
        const num_gap_blocks = std.mem.readInt(u16, data[12..14][0..2], .big);
        const num_dup_tsns = std.mem.readInt(u16, data[14..16][0..2], .big);

        var offset: usize = 16;

        // 解析 Gap Blocks
        const gap_blocks = try allocator.alloc(GapBlock, num_gap_blocks);
        for (0..num_gap_blocks) |i| {
            if (offset + 4 > data.len) return error.InvalidSackChunk;
            const start = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            const end = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            gap_blocks[i] = GapBlock{ .start = start, .end = end };
        }

        // 解析 Duplicate TSNs
        const duplicate_tsns = try allocator.alloc(u32, num_dup_tsns);
        for (0..num_dup_tsns) |i| {
            if (offset + 4 > data.len) return error.InvalidSackChunk;
            duplicate_tsns[i] = std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += 4;
        }

        return SackChunk{
            .flags = flags,
            .length = length,
            .cum_tsn_ack = cum_tsn_ack,
            .a_rwnd = a_rwnd,
            .gap_blocks = gap_blocks,
            .duplicate_tsns = duplicate_tsns,
        };
    }

    /// 编码 SACK 块
    pub fn encode(self: *const SackChunk, allocator: std.mem.Allocator) ![]u8 {
        const base_len: usize = 16;
        const gap_blocks_len = self.gap_blocks.len * 4;
        const dup_tsns_len = self.duplicate_tsns.len * 4;
        const total_len = base_len + gap_blocks_len + dup_tsns_len;

        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        output[0] = 3; // SACK
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], @as(u16, @intCast(total_len)), .big);

        std.mem.writeInt(u32, output[4..8][0..4], self.cum_tsn_ack, .big);
        std.mem.writeInt(u32, output[8..12][0..4], self.a_rwnd, .big);
        std.mem.writeInt(u16, output[12..14][0..2], @as(u16, @intCast(self.gap_blocks.len)), .big);
        std.mem.writeInt(u16, output[14..16][0..2], @as(u16, @intCast(self.duplicate_tsns.len)), .big);

        var offset: usize = 16;

        // 编码 Gap Blocks
        for (self.gap_blocks) |block| {
            std.mem.writeInt(u16, output[offset..][0..2], block.start, .big);
            offset += 2;
            std.mem.writeInt(u16, output[offset..][0..2], block.end, .big);
            offset += 2;
        }

        // 编码 Duplicate TSNs
        for (self.duplicate_tsns) |tsn| {
            std.mem.writeInt(u32, output[offset..][0..4], tsn, .big);
            offset += 4;
        }

        return output;
    }

    /// 释放 SACK 块资源
    pub fn deinit(self: *SackChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.gap_blocks);
        allocator.free(self.duplicate_tsns);
    }
};

/// HEARTBEAT 块
/// 遵循 RFC 4960 Section 3.3.5
pub const HeartbeatChunk = struct {
    flags: u8,
    length: u16,
    heartbeat_info: []u8, // 动态分配

    /// 解析 HEARTBEAT 块
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !HeartbeatChunk {
        if (data.len < 4) return error.InvalidHeartbeatChunk;

        const flags = data[1]; // Flags 在第二个字节
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);
        if (data.len < length) return error.InvalidHeartbeatChunk;

        const info_len = length - 4;
        const heartbeat_info = try allocator.alloc(u8, info_len);
        if (info_len > 0) {
            @memcpy(heartbeat_info, data[4 .. 4 + info_len]);
        }

        return HeartbeatChunk{
            .flags = flags,
            .length = length,
            .heartbeat_info = heartbeat_info,
        };
    }

    /// 编码 HEARTBEAT 块
    pub fn encode(self: *const HeartbeatChunk, allocator: std.mem.Allocator) ![]u8 {
        const total_len = self.length;
        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        output[0] = 4; // HEARTBEAT
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);

        if (self.heartbeat_info.len > 0) {
            @memcpy(output[4..], self.heartbeat_info);
        }

        return output;
    }

    /// 释放 HEARTBEAT 块资源
    pub fn deinit(self: *HeartbeatChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.heartbeat_info);
    }
};

/// COOKIE-ECHO 块
/// 遵循 RFC 4960 Section 3.3.11
pub const CookieEchoChunk = struct {
    flags: u8,
    length: u16,
    cookie: []u8, // 动态分配

    /// 解析 COOKIE-ECHO 块
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !CookieEchoChunk {
        if (data.len < 4) return error.InvalidCookieEchoChunk;

        const flags = data[1]; // Flags 在第二个字节
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);
        if (data.len < length) return error.InvalidCookieEchoChunk;

        const cookie_len = length - 4;
        const cookie = try allocator.alloc(u8, cookie_len);
        if (cookie_len > 0) {
            @memcpy(cookie, data[4 .. 4 + cookie_len]);
        }

        return CookieEchoChunk{
            .flags = flags,
            .length = length,
            .cookie = cookie,
        };
    }

    /// 编码 COOKIE-ECHO 块
    pub fn encode(self: *const CookieEchoChunk, allocator: std.mem.Allocator) ![]u8 {
        const total_len = self.length;
        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        output[0] = 10; // COOKIE-ECHO
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);

        if (self.cookie.len > 0) {
            @memcpy(output[4..], self.cookie);
        }

        return output;
    }

    /// 释放 COOKIE-ECHO 块资源
    pub fn deinit(self: *CookieEchoChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.cookie);
    }
};

/// COOKIE-ACK 块
/// 遵循 RFC 4960 Section 3.3.12
pub const CookieAckChunk = struct {
    flags: u8,
    length: u16, // 固定为 4

    /// 解析 COOKIE-ACK 块
    pub fn parse(_: std.mem.Allocator, data: []const u8) !CookieAckChunk {
        if (data.len < 4) return error.InvalidCookieAckChunk;

        const flags = data[1]; // Flags 在第二个字节
        const length = std.mem.readInt(u16, data[2..4][0..2], .big);
        if (length != 4) return error.InvalidCookieAckChunk;

        return CookieAckChunk{
            .flags = flags,
            .length = length,
        };
    }

    /// 编码 COOKIE-ACK 块
    pub fn encode(self: *const CookieAckChunk, allocator: std.mem.Allocator) ![]u8 {
        const output = try allocator.alloc(u8, 4);
        errdefer allocator.free(output);

        output[0] = 11; // COOKIE-ACK
        output[1] = self.flags;
        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);

        return output;
    }
};

pub const Error = error{
    InvalidSctpHeader,
    InvalidChunkHeader,
    InvalidDataChunk,
    InvalidInitChunk,
    InvalidSackChunk,
    InvalidHeartbeatChunk,
    InvalidCookieEchoChunk,
    InvalidCookieAckChunk,
    OutOfMemory,
};
