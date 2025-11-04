const std = @import("std");

/// 媒体模块导出
pub const track = @import("./track.zig");

// 导出常用类型
pub const Track = track.Track;
pub const TrackKind = track.TrackKind;
pub const TrackState = track.TrackState;
