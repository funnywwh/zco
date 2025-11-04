const std = @import("std");

/// 媒体轨道类型
pub const TrackKind = enum {
    audio,
    video,
};

/// 媒体轨道状态
pub const TrackState = enum {
    live, // 活动状态，正在生成媒体
    ended, // 已结束，不再生成媒体
};

/// MediaStreamTrack
/// 表示单个媒体轨道（音频或视频）
/// 遵循 W3C Media Capture and Streams 规范
pub const Track = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    id: []const u8, // 轨道 ID
    kind: TrackKind, // 轨道类型（音频或视频）
    label: []const u8, // 标签（用户友好的名称）
    enabled: bool = true, // 是否启用
    state: TrackState = .live, // 轨道状态

    /// 初始化媒体轨道
    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        kind: TrackKind,
        label: []const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .kind = kind,
            .label = try allocator.dupe(u8, label),
            .enabled = true,
            .state = .live,
        };

        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.id);
        self.allocator.free(self.label);
        self.allocator.destroy(self);
    }

    /// 获取轨道 ID
    pub fn getId(self: *const Self) []const u8 {
        return self.id;
    }

    /// 获取轨道类型
    pub fn getKind(self: *const Self) TrackKind {
        return self.kind;
    }

    /// 获取轨道标签
    pub fn getLabel(self: *const Self) []const u8 {
        return self.label;
    }

    /// 检查轨道是否启用
    pub fn isEnabled(self: *const Self) bool {
        return self.enabled;
    }

    /// 启用/禁用轨道
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    /// 获取轨道状态
    pub fn getState(self: *const Self) TrackState {
        return self.state;
    }

    /// 结束轨道
    pub fn stop(self: *Self) void {
        self.state = .ended;
    }
};

