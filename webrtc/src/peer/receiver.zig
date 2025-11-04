const std = @import("std");
const zco = @import("zco");
const media = @import("../media/root.zig");
const rtp = @import("../rtp/root.zig");

/// RTCRtpReceiver
/// 负责接收远程对等端的媒体轨道
/// 遵循 W3C WebRTC 1.0 规范
pub const Receiver = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    track: ?*media.Track = null, // 接收到的媒体轨道（由接收器创建）
    ssrc: ?u32 = null, // SSRC（用于标识接收源）
    payload_type: ?u7 = null, // 载荷类型（RTP payload type）

    /// 初始化 RTP 接收器
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .track = null,
            .ssrc = null,
            .payload_type = null,
        };
        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        if (self.track) |track| {
            track.deinit();
        }
        self.allocator.destroy(self);
    }

    /// 设置媒体轨道
    pub fn setTrack(self: *Self, track: *media.Track) void {
        self.track = track;
    }

    /// 获取媒体轨道
    pub fn getTrack(self: *const Self) ?*media.Track {
        return self.track;
    }

    /// 设置 SSRC
    pub fn setSsrc(self: *Self, ssrc: u32) void {
        self.ssrc = ssrc;
    }

    /// 获取 SSRC
    pub fn getSsrc(self: *const Self) ?u32 {
        return self.ssrc;
    }

    /// 设置载荷类型
    pub fn setPayloadType(self: *Self, payload_type: u7) void {
        self.payload_type = payload_type;
    }

    /// 获取载荷类型
    pub fn getPayloadType(self: *const Self) ?u7 {
        return self.payload_type;
    }
};

