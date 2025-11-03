const std = @import("std");

/// RTCP 包类型
/// 遵循 RFC 3550 Section 6
pub const PacketType = enum(u8) {
    sr = 200, // Sender Report
    rr = 201, // Receiver Report
    sdes = 202, // Source Description
    bye = 203, // Goodbye
    app = 204, // Application-defined
    _,
};

/// RTCP 包通用头
/// 遵循 RFC 3550 Section 6.1
pub const Header = struct {
    version: u2 = 2, // RTCP 版本，固定为 2
    padding: bool = false, // 填充标志
    rc: u5, // Reception Report Count
    packet_type: PacketType, // 包类型
    length: u16, // 包长度（以 32 位字为单位，不包括此头）

    /// 解析 RTCP 头
    pub fn parse(data: []const u8) !Header {
        if (data.len < 4) return error.InvalidRtcpHeader;

        const first_byte = data[0];
        const version = @as(u2, @truncate(first_byte >> 6));
        if (version != 2) return error.InvalidRtcpVersion;

        const padding = (first_byte & 0x20) != 0;
        const rc = @as(u5, @truncate(first_byte & 0x1F));

        const packet_type = @as(PacketType, @enumFromInt(data[1]));

        const length = std.mem.readInt(u16, data[2..4][0..2], .big);

        return Header{
            .version = version,
            .padding = padding,
            .rc = rc,
            .packet_type = packet_type,
            .length = length,
        };
    }

    /// 编码 RTCP 头
    pub fn encode(self: *const Header, output: []u8) void {
        std.debug.assert(output.len >= 4);

        var first_byte: u8 = @as(u8, self.version) << 6;
        if (self.padding) first_byte |= 0x20;
        first_byte |= @as(u8, self.rc) & 0x1F;
        output[0] = first_byte;

        output[1] = @intFromEnum(self.packet_type);

        std.mem.writeInt(u16, output[2..4][0..2], self.length, .big);
    }
};

/// 接收报告块
/// 遵循 RFC 3550 Section 6.4.1
pub const ReceptionReport = struct {
    ssrc: u32, // 接收报告的 SSRC
    fraction_lost: u8, // 丢失比例（0-255）
    cumulative_packets_lost: u24, // 累计丢包数（24 位有符号整数）
    extended_highest_sequence: u32, // 扩展最高序列号
    interarrival_jitter: u32, // 到达间隔抖动
    last_sr_timestamp: u32, // 最后一个 SR 的时间戳（NTP 时间戳的中间 32 位）
    delay_since_last_sr: u32, // 距离最后一个 SR 的延迟（以 1/65536 秒为单位）

    /// 解析接收报告块
    pub fn parse(data: []const u8) !ReceptionReport {
        if (data.len < 24) return error.InvalidReceptionReport;

        const ssrc = std.mem.readInt(u32, data[0..4][0..4], .big);
        const fraction_lost = data[4];

        // Cumulative Packets Lost 是 24 位有符号整数
        // 提取 24 位值（字节 5-7）
        var cumulative_bytes: [4]u8 = undefined;
        cumulative_bytes[0] = if (data[5] & 0x80 != 0) 0xFF else 0x00; // 符号扩展
        @memcpy(cumulative_bytes[1..4], data[5..8]);
        const cumulative_packets_lost_i32 = std.mem.readInt(i32, &cumulative_bytes, .big);
        // 转换为 u24（只取低 24 位）
        const cumulative_packets_lost = @as(u24, @truncate(@as(u32, @bitCast(cumulative_packets_lost_i32))));

        const extended_highest_sequence = std.mem.readInt(u32, data[8..12][0..4], .big);
        const interarrival_jitter = std.mem.readInt(u32, data[12..16][0..4], .big);
        const last_sr_timestamp = std.mem.readInt(u32, data[16..20][0..4], .big);
        const delay_since_last_sr = std.mem.readInt(u32, data[20..24][0..4], .big);

        return ReceptionReport{
            .ssrc = ssrc,
            .fraction_lost = fraction_lost,
            .cumulative_packets_lost = cumulative_packets_lost,
            .extended_highest_sequence = extended_highest_sequence,
            .interarrival_jitter = interarrival_jitter,
            .last_sr_timestamp = last_sr_timestamp,
            .delay_since_last_sr = delay_since_last_sr,
        };
    }

    /// 编码接收报告块
    pub fn encode(self: *const ReceptionReport, output: []u8) void {
        std.debug.assert(output.len >= 24);

        std.mem.writeInt(u32, output[0..4][0..4], self.ssrc, .big);
        output[4] = self.fraction_lost;

        // 编码 Cumulative Packets Lost（24 位有符号整数）
        // 将 u24 视为有符号 24 位：如果最高位是 1，则是负数
        const cumulative_value: u24 = self.cumulative_packets_lost;
        // 检查符号位（第 23 位）
        const is_negative = (cumulative_value & 0x800000) != 0;

        var cumulative_bytes: [4]u8 = undefined;
        if (is_negative) {
            // 符号扩展：最高字节为 0xFF
            cumulative_bytes[0] = 0xFF;
        } else {
            cumulative_bytes[0] = 0x00;
        }
        // 写入 24 位值（字节 1-3）- 手动写入，因为 writeInt 不支持 u24
        cumulative_bytes[1] = @as(u8, @truncate(cumulative_value >> 16));
        cumulative_bytes[2] = @as(u8, @truncate(cumulative_value >> 8));
        cumulative_bytes[3] = @as(u8, @truncate(cumulative_value));
        @memcpy(output[5..8], cumulative_bytes[1..4]);

        std.mem.writeInt(u32, output[8..12][0..4], self.extended_highest_sequence, .big);
        std.mem.writeInt(u32, output[12..16][0..4], self.interarrival_jitter, .big);
        std.mem.writeInt(u32, output[16..20][0..4], self.last_sr_timestamp, .big);
        std.mem.writeInt(u32, output[20..24][0..4], self.delay_since_last_sr, .big);
    }
};

/// 发送端报告（SR）
/// 遵循 RFC 3550 Section 6.4.1
pub const SenderReport = struct {
    allocator: std.mem.Allocator,
    ssrc: u32, // 发送端的 SSRC
    ntp_timestamp_msb: u32, // NTP 时间戳高 32 位
    ntp_timestamp_lsb: u32, // NTP 时间戳低 32 位
    rtp_timestamp: u32, // RTP 时间戳
    sender_packet_count: u32, // 发送包计数
    sender_octet_count: u32, // 发送字节计数
    reports: std.ArrayList(ReceptionReport), // 接收报告块列表

    /// 解析 SR 包
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !SenderReport {
        if (data.len < 28) return error.InvalidSenderReport;

        var sr = SenderReport{
            .allocator = allocator,
            .ssrc = undefined,
            .ntp_timestamp_msb = undefined,
            .ntp_timestamp_lsb = undefined,
            .rtp_timestamp = undefined,
            .sender_packet_count = undefined,
            .sender_octet_count = undefined,
            .reports = std.ArrayList(ReceptionReport).init(allocator),
        };
        errdefer sr.reports.deinit();

        // 跳过 RTCP 头（4 字节）
        var offset: usize = 4;

        // 解析 SSRC
        sr.ssrc = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析 NTP 时间戳（64 位）
        sr.ntp_timestamp_msb = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        sr.ntp_timestamp_lsb = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析 RTP 时间戳
        sr.rtp_timestamp = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析发送者包计数
        sr.sender_packet_count = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析发送者字节计数
        sr.sender_octet_count = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析接收报告块（RC 字段在头中指定数量）
        // 需要从 RTCP 头获取 RC 值，这里简化处理，解析所有可用的报告块
        while (offset + 24 <= data.len) {
            const report = try ReceptionReport.parse(data[offset..]);
            try sr.reports.append(report);
            offset += 24;
        }

        return sr;
    }

    /// 编码 SR 包
    pub fn encode(self: *const SenderReport, allocator: std.mem.Allocator) ![]u8 {
        const header_size = 4; // RTCP 头
        const sr_body_size = 24; // SSRC (4) + NTP MSB (4) + NTP LSB (4) + RTP timestamp (4) + Packet count (4) + Octet count (4) = 24 字节
        const report_size = 24; // 每个接收报告块 24 字节
        const total_size = header_size + sr_body_size + self.reports.items.len * report_size;

        const output = try allocator.alloc(u8, total_size);
        errdefer allocator.free(output);

        // 编码 RTCP 头
        var header = Header{
            .version = 2,
            .padding = false,
            .rc = @as(u5, @intCast(self.reports.items.len)),
            .packet_type = .sr,
            .length = @as(u16, @intCast((total_size / 4) - 1)), // 以 32 位字为单位，不包括头
        };
        header.encode(output[0..4]);

        var offset: usize = 4;

        // 编码 SSRC
        std.mem.writeInt(u32, output[offset..][0..4], self.ssrc, .big);
        offset += 4;

        // 编码 NTP 时间戳
        std.mem.writeInt(u32, output[offset..][0..4], self.ntp_timestamp_msb, .big);
        offset += 4;
        std.mem.writeInt(u32, output[offset..][0..4], self.ntp_timestamp_lsb, .big);
        offset += 4;

        // 编码 RTP 时间戳
        std.mem.writeInt(u32, output[offset..][0..4], self.rtp_timestamp, .big);
        offset += 4;

        // 编码发送者包计数
        std.mem.writeInt(u32, output[offset..][0..4], self.sender_packet_count, .big);
        offset += 4;

        // 编码发送者字节计数
        std.mem.writeInt(u32, output[offset..][0..4], self.sender_octet_count, .big);
        offset += 4;

        // 编码接收报告块
        for (self.reports.items) |report| {
            report.encode(output[offset..]);
            offset += 24;
        }

        return output;
    }

    /// 释放 SR 包资源
    pub fn deinit(self: *SenderReport) void {
        self.reports.deinit();
    }
};

/// 接收端报告（RR）
/// 遵循 RFC 3550 Section 6.4.2
pub const ReceiverReport = struct {
    allocator: std.mem.Allocator,
    ssrc: u32, // 接收端的 SSRC
    reports: std.ArrayList(ReceptionReport), // 接收报告块列表

    /// 解析 RR 包
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !ReceiverReport {
        if (data.len < 8) return error.InvalidReceiverReport;

        var rr = ReceiverReport{
            .allocator = allocator,
            .ssrc = undefined,
            .reports = std.ArrayList(ReceptionReport).init(allocator),
        };
        errdefer rr.reports.deinit();

        // 跳过 RTCP 头（4 字节）
        var offset: usize = 4;

        // 解析 SSRC
        rr.ssrc = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析接收报告块
        while (offset + 24 <= data.len) {
            const report = try ReceptionReport.parse(data[offset..]);
            try rr.reports.append(report);
            offset += 24;
        }

        return rr;
    }

    /// 编码 RR 包
    pub fn encode(self: *const ReceiverReport, allocator: std.mem.Allocator) ![]u8 {
        const header_size = 4; // RTCP 头
        const rr_body_size = 4; // SSRC (4 字节)
        const report_size = 24; // 每个接收报告块 24 字节
        const total_size = header_size + rr_body_size + self.reports.items.len * report_size;

        const output = try allocator.alloc(u8, total_size);
        errdefer allocator.free(output);

        // 编码 RTCP 头
        var header = Header{
            .version = 2,
            .padding = false,
            .rc = @as(u5, @intCast(self.reports.items.len)),
            .packet_type = .rr,
            .length = @as(u16, @intCast((total_size / 4) - 1)),
        };
        header.encode(output[0..4]);

        var offset: usize = 4;

        // 编码 SSRC
        std.mem.writeInt(u32, output[offset..][0..4], self.ssrc, .big);
        offset += 4;

        // 编码接收报告块
        for (self.reports.items) |report| {
            report.encode(output[offset..]);
            offset += 24;
        }

        return output;
    }

    /// 释放 RR 包资源
    pub fn deinit(self: *ReceiverReport) void {
        self.reports.deinit();
    }
};

/// SDES 项类型
/// 遵循 RFC 3550 Section 6.5
pub const SdesType = enum(u8) {
    end = 0,
    cname = 1,
    name = 2,
    email = 3,
    phone = 4,
    loc = 5,
    tool = 6,
    note = 7,
    priv = 8,
    _,
};

/// SDES 项
pub const SdesItem = struct {
    allocator: std.mem.Allocator,
    item_type: SdesType,
    text: []u8, // 文本数据（动态分配）

    /// 解析 SDES 项
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !SdesItem {
        if (data.len < 2) return error.InvalidSdesItem;

        const item_type = @as(SdesType, @enumFromInt(data[0]));
        const length = data[1];

        if (data.len < 2 + length) return error.InvalidSdesItem;

        const text = try allocator.alloc(u8, length);
        @memcpy(text, data[2 .. 2 + length]);

        return SdesItem{
            .allocator = allocator,
            .item_type = item_type,
            .text = text,
        };
    }

    /// 编码 SDES 项
    pub fn encode(self: *const SdesItem, output: []u8) !usize {
        const needed = 2 + self.text.len;
        if (output.len < needed) return error.BufferTooSmall;

        output[0] = @intFromEnum(self.item_type);
        output[1] = @as(u8, @intCast(self.text.len));
        @memcpy(output[2 .. 2 + self.text.len], self.text);

        // SDES 项需要 32 位对齐（填充到 4 字节边界）
        const aligned_len = (needed + 3) & ~@as(usize, 3);
        if (aligned_len > needed) {
            @memset(output[needed..aligned_len], 0);
            return aligned_len;
        }

        return needed;
    }

    /// 释放 SDES 项资源
    pub fn deinit(self: *SdesItem) void {
        self.allocator.free(self.text);
    }
};

/// 源描述（SDES）
/// 遵循 RFC 3550 Section 6.5
pub const SourceDescription = struct {
    allocator: std.mem.Allocator,
    ssrc: u32, // 源的 SSRC
    items: std.ArrayList(SdesItem), // SDES 项列表

    /// 解析 SDES 包
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !SourceDescription {
        if (data.len < 8) return error.InvalidSourceDescription;

        var sdes = SourceDescription{
            .allocator = allocator,
            .ssrc = undefined,
            .items = std.ArrayList(SdesItem).init(allocator),
        };
        errdefer {
            for (sdes.items.items) |*item| {
                item.deinit();
            }
            sdes.items.deinit();
        }

        // 跳过 RTCP 头（4 字节）
        var offset: usize = 4;

        // 解析 SSRC
        sdes.ssrc = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // 解析 SDES 项
        while (offset < data.len) {
            if (data[offset] == 0) {
                // END 项，可能还有填充
                offset += 1;
                // 对齐到 32 位边界
                offset = (@as(usize, @intCast(offset)) + 3) & ~@as(usize, 3);
                break;
            }

            var item = try SdesItem.parse(allocator, data[offset..]);
            errdefer item.deinit();
            try sdes.items.append(item);

            // 计算对齐后的项长度
            const item_base_len = 2 + item.text.len;
            const item_aligned_len = (item_base_len + 3) & ~@as(usize, 3);
            offset += item_aligned_len;
        }

        return sdes;
    }

    /// 编码 SDES 包
    pub fn encode(self: *const SourceDescription, allocator: std.mem.Allocator) ![]u8 {
        // 计算总长度
        var total_len: usize = 4; // RTCP 头
        total_len += 4; // SSRC
        for (self.items.items) |item| {
            const item_len = 2 + item.text.len;
            total_len += (item_len + 3) & ~@as(usize, 3); // 对齐到 4 字节
        }
        total_len += 4; // END 项 + 对齐

        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        // 编码 RTCP 头
        var header = Header{
            .version = 2,
            .padding = false,
            .rc = 1, // SDES 通常每个包一个源
            .packet_type = .sdes,
            .length = @as(u16, @intCast((total_len / 4) - 1)),
        };
        header.encode(output[0..4]);

        var offset: usize = 4;

        // 编码 SSRC
        std.mem.writeInt(u32, output[offset..][0..4], self.ssrc, .big);
        offset += 4;

        // 编码 SDES 项
        for (self.items.items) |item| {
            const written = try item.encode(output[offset..]);
            offset += written;
        }

        // 添加 END 项
        output[offset] = 0;
        offset += 1;

        // 对齐到 32 位边界
        while (offset % 4 != 0) {
            output[offset] = 0;
            offset += 1;
        }

        return output;
    }

    /// 释放 SDES 包资源
    pub fn deinit(self: *SourceDescription) void {
        for (self.items.items) |item| {
            var mutable_item = item;
            mutable_item.deinit();
        }
        self.items.deinit();
    }
};

/// BYE 包
/// 遵循 RFC 3550 Section 6.6
pub const Bye = struct {
    allocator: std.mem.Allocator,
    ssrcs: std.ArrayList(u32), // 离开的 SSRC 列表
    reason: ?[]u8 = null, // 可选原因字符串

    /// 解析 BYE 包
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Bye {
        if (data.len < 8) return error.InvalidBye;

        var bye = Bye{
            .allocator = allocator,
            .ssrcs = std.ArrayList(u32).init(allocator),
            .reason = null,
        };
        errdefer bye.ssrcs.deinit();

        // 跳过 RTCP 头（4 字节）
        var offset: usize = 4;

        // 解析 SSRC 列表（RC 字段指定数量）
        const header = try Header.parse(data);
        var i: u5 = 0;
        while (i < header.rc and offset + 4 <= data.len) : (i += 1) {
            const ssrc = std.mem.readInt(u32, data[offset..][0..4], .big);
            try bye.ssrcs.append(ssrc);
            offset += 4;
        }

        // 解析可选的原因字符串
        if (offset < data.len) {
            const reason_length = data[offset];
            offset += 1;
            if (reason_length > 0 and offset + reason_length <= data.len) {
                const reason = try allocator.alloc(u8, reason_length);
                @memcpy(reason, data[offset .. offset + reason_length]);
                bye.reason = reason;
                offset += reason_length;
                // 对齐到 32 位边界
                const aligned_offset = (offset + 3) & ~@as(usize, 3);
                offset = aligned_offset;
            }
        }

        return bye;
    }

    /// 编码 BYE 包
    pub fn encode(self: *const Bye, allocator: std.mem.Allocator) ![]u8 {
        var total_len: usize = 4; // RTCP 头
        total_len += self.ssrcs.items.len * 4; // SSRC 列表
        if (self.reason) |reason| {
            if (reason.len > 0) {
                total_len += 1 + reason.len; // 长度 + 原因
                total_len = (total_len + 3) & ~@as(usize, 3); // 对齐
            }
        }

        const output = try allocator.alloc(u8, total_len);
        errdefer allocator.free(output);

        // 编码 RTCP 头
        var header = Header{
            .version = 2,
            .padding = false,
            .rc = @as(u5, @intCast(self.ssrcs.items.len)),
            .packet_type = .bye,
            .length = @as(u16, @intCast((total_len / 4) - 1)),
        };
        header.encode(output[0..4]);

        var offset: usize = 4;

        // 编码 SSRC 列表
        for (self.ssrcs.items) |ssrc| {
            std.mem.writeInt(u32, output[offset..][0..4], ssrc, .big);
            offset += 4;
        }

        // 编码可选原因
        if (self.reason) |reason| {
            if (reason.len > 0) {
                output[offset] = @as(u8, @intCast(reason.len));
                offset += 1;
                @memcpy(output[offset .. offset + reason.len], reason);
                offset += reason.len;
                // 对齐
                while (offset % 4 != 0) {
                    output[offset] = 0;
                    offset += 1;
                }
            }
        }

        return output;
    }

    /// 释放 BYE 包资源
    pub fn deinit(self: *Bye) void {
        self.ssrcs.deinit();
        if (self.reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

pub const Error = error{
    InvalidRtcpHeader,
    InvalidRtcpVersion,
    InvalidSenderReport,
    InvalidReceiverReport,
    InvalidReceptionReport,
    InvalidSourceDescription,
    InvalidSdesItem,
    InvalidBye,
    BufferTooSmall,
    OutOfMemory,
};
