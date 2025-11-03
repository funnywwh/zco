const std = @import("std");

/// RTP 包结构
/// 遵循 RFC 3550 Section 5.1
pub const Packet = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    // RTP 头字段
    version: u2 = 2, // RTP 版本，固定为 2
    padding: bool = false, // 填充标志
    extension: bool = false, // 扩展头标志
    csrc_count: u4 = 0, // CSRC 计数（0-15）
    marker: bool = false, // 标记位（用于视频关键帧等）
    payload_type: u7, // 载荷类型（0-127）
    sequence_number: u16, // 序列号（16 位，会回绕）
    timestamp: u32, // 时间戳（32 位）
    ssrc: u32, // 同步源标识符（32 位）

    // CSRC 列表（0-15 个 SSRC）
    csrc_list: std.ArrayList(u32) = undefined,

    // 扩展头（可选）
    extension_profile: ?u16 = null, // Profile-Specific Extension Header ID
    extension_data: []u8 = undefined, // Extension Data（动态分配）

    // 载荷数据
    payload: []u8, // RTP 载荷（动态分配，由调用者管理生命周期）

    /// 解析 RTP 包
    /// 遵循 RFC 3550 Section 5.1
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 12) return error.InvalidRtpPacket; // 最小 RTP 头是 12 字节

        // 解析第一个字节
        const first_byte = data[0];
        const version = @as(u2, @truncate(first_byte >> 6));
        if (version != 2) return error.InvalidRtpVersion;

        const padding = (first_byte & 0x20) != 0;
        const extension = (first_byte & 0x10) != 0;
        const csrc_count = @as(u4, @truncate(first_byte & 0x0F));

        // 解析第二个字节
        const second_byte = data[1];
        const marker = (second_byte & 0x80) != 0;
        const payload_type = @as(u7, @truncate(second_byte & 0x7F));

        // 解析序列号（字节 2-3，大端序）
        const sequence_number = std.mem.readInt(u16, data[2..4][0..2], .big);

        // 解析时间戳（字节 4-7，大端序）
        const timestamp = std.mem.readInt(u32, data[4..8][0..4], .big);

        // 解析 SSRC（字节 8-11，大端序）
        const ssrc = std.mem.readInt(u32, data[8..12][0..4], .big);

        var packet = Self{
            .allocator = allocator,
            .version = version,
            .padding = padding,
            .extension = extension,
            .csrc_count = csrc_count,
            .marker = marker,
            .payload_type = payload_type,
            .sequence_number = sequence_number,
            .timestamp = timestamp,
            .ssrc = ssrc,
            .csrc_list = std.ArrayList(u32).init(allocator),
            .extension_profile = null,
            .extension_data = undefined,
            .payload = undefined,
        };
        errdefer packet.csrc_list.deinit();

        var offset: usize = 12; // 基本头固定 12 字节

        // 解析 CSRC 列表（每个 CSRC 4 字节）
        if (csrc_count > 0) {
            if (data.len < offset + csrc_count * 4) return error.InvalidRtpPacket;
            for (0..csrc_count) |_| {
                const csrc = std.mem.readInt(u32, data[offset..][0..4], .big);
                try packet.csrc_list.append(csrc);
                offset += 4;
            }
        }

        // 解析扩展头（可选）
        if (extension) {
            if (data.len < offset + 4) return error.InvalidRtpPacket;

            // Profile-Specific Extension Header ID (2 字节)
            packet.extension_profile = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;

            // Extension Length (2 字节，以 32 位字为单位)
            const extension_length = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;

            // Extension Data (extension_length * 4 字节)
            const extension_data_len = extension_length * 4;
            if (data.len < offset + extension_data_len) return error.InvalidRtpPacket;

            packet.extension_data = try allocator.alloc(u8, extension_data_len);
            @memcpy(packet.extension_data, data[offset .. offset + extension_data_len]);
            offset += extension_data_len;
        }

        // 剩余部分是载荷
        // 如果设置了 padding，需要去掉填充字节
        var payload_len = data.len - offset;
        if (padding) {
            if (payload_len == 0) return error.InvalidRtpPacket;
            const padding_len = data[data.len - 1];
            if (padding_len > payload_len) return error.InvalidRtpPacket;
            payload_len -= padding_len;
        }

        // 复制载荷数据（注意：这里分配了内存，调用者需要负责释放）
        packet.payload = try allocator.alloc(u8, payload_len);
        @memcpy(packet.payload, data[offset .. offset + payload_len]);

        return packet;
    }

    /// 编码 RTP 包
    /// 返回编码后的字节数组（调用者负责释放）
    pub fn encode(self: *const Self) ![]u8 {
        // 计算总长度
        const csrc_len = self.csrc_count * 4;
        const extension_len = if (self.extension)
            if (self.extension_data.len > 0)
                4 + self.extension_data.len // Profile ID + Length + Data
            else
                4 // 至少 4 字节（Profile ID + Length，即使长度为 0）
        else
            0;

        const total_len = 12 + csrc_len + extension_len + self.payload.len;
        const output = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(output);

        var offset: usize = 0;

        // 编码第一个字节
        var first_byte: u8 = @as(u8, self.version) << 6;
        if (self.padding) first_byte |= 0x20;
        if (self.extension) first_byte |= 0x10;
        first_byte |= @as(u8, self.csrc_count) & 0x0F;
        output[offset] = first_byte;
        offset += 1;

        // 编码第二个字节
        var second_byte: u8 = if (self.marker) 0x80 else 0;
        second_byte |= @as(u8, self.payload_type) & 0x7F;
        output[offset] = second_byte;
        offset += 1;

        // 编码序列号（字节 2-3，大端序）
        std.mem.writeInt(u16, output[offset..][0..2], self.sequence_number, .big);
        offset += 2;

        // 编码时间戳（字节 4-7，大端序）
        std.mem.writeInt(u32, output[offset..][0..4], self.timestamp, .big);
        offset += 4;

        // 编码 SSRC（字节 8-11，大端序）
        std.mem.writeInt(u32, output[offset..][0..4], self.ssrc, .big);
        offset += 4;

        // 编码 CSRC 列表
        for (self.csrc_list.items) |csrc| {
            std.mem.writeInt(u32, output[offset..][0..4], csrc, .big);
            offset += 4;
        }

        // 编码扩展头
        if (self.extension) {
            if (self.extension_profile) |profile| {
                // Profile-Specific Extension Header ID
                std.mem.writeInt(u16, output[offset..][0..2], profile, .big);
                offset += 2;

                // Extension Length（以 32 位字为单位）
                const ext_len_words = @as(u16, @intCast((self.extension_data.len + 3) / 4)); // 向上取整到 4 字节
                std.mem.writeInt(u16, output[offset..][0..2], ext_len_words, .big);
                offset += 2;

                // Extension Data
                @memcpy(output[offset .. offset + self.extension_data.len], self.extension_data);
                offset += self.extension_data.len;

                // 填充到 32 位对齐（如果需要）
                const padding_bytes = ext_len_words * 4 - self.extension_data.len;
                @memset(output[offset .. offset + padding_bytes], 0);
                offset += padding_bytes;
            } else {
                // 即使 extension 为 true，如果没有 profile，也写入 4 字节零
                @memset(output[offset .. offset + 4], 0);
                offset += 4;
            }
        }

        // 编码载荷
        @memcpy(output[offset..], self.payload);

        return output;
    }

    /// 释放 RTP 包资源
    pub fn deinit(self: *Self) void {
        self.csrc_list.deinit();
        if (self.extension and self.extension_data.len > 0) {
            self.allocator.free(self.extension_data);
        }
        // 注意：payload 的生命周期由调用者管理，这里不释放
    }

    /// 获取下一个序列号（处理 16 位回绕）
    pub fn nextSequenceNumber(self: *const Self) u16 {
        // 16 位序列号回绕：0xFFFF -> 0x0000
        if (self.sequence_number == 0xFFFF) {
            return 0;
        }
        return self.sequence_number + 1;
    }

    /// 计算序列号差（考虑回绕）
    pub fn sequenceDifference(self: *const Self, other: u16) i32 {
        const diff = @as(i32, self.sequence_number) -% @as(i32, other);
        // 处理回绕：如果差大于 32767，说明回绕了
        if (diff > 32767) {
            return diff - 65536;
        }
        if (diff < -32768) {
            return diff + 65536;
        }
        return diff;
    }

    /// 标准 Payload Type 常量
    pub const PayloadType = struct {
        pub const PCMU: u7 = 0; // G.711 μ-law
        pub const PCMA: u7 = 8; // G.711 A-law
        pub const G722: u7 = 9; // G.722
        pub const G729: u7 = 18; // G.729
        // 96-127 为动态载荷类型，通过 SDP 协商
    };

    pub const Error = error{
        InvalidRtpPacket,
        InvalidRtpVersion,
        OutOfMemory,
    };
};
