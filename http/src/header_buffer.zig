const std = @import("std");

/// 仅用于 HTTP 头部阶段的固定缓冲区
/// - 采用固定容量（默认 4KB），避免在头部解析期间发生堆分配
/// - 提供零拷贝切片，以便解析器记录字段位置并直接引用
pub const HeaderBuffer = struct {
    const Self = @This();

    /// 默认头部缓冲区大小（字节）
    pub const DEFAULT_CAPACITY: usize = 4096;

    data: [DEFAULT_CAPACITY]u8 = undefined,
    len: usize = 0,

    /// 初始化头部缓冲区
    pub fn init() Self {
        return .{};
    }

    /// 追加数据到头部缓冲区（仅在头部阶段调用）
    /// 错误：当追加数据将导致超过容量时返回 error.HeaderTooLarge
    pub fn append(self: *Self, chunk: []const u8) !void {
        if (self.len + chunk.len > self.data.len) {
            return error.HeaderTooLarge;
        }
        @memcpy(self.data[self.len .. self.len + chunk.len], chunk);
        self.len += chunk.len;
    }

    /// 获取当前有效的只读切片
    pub fn slice(self: *const Self) []const u8 {
        return self.data[0..self.len];
    }

    /// 清空缓冲区（处理完一条消息后调用）
    pub fn reset(self: *Self) void {
        self.len = 0;
    }
};


