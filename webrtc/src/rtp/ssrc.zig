const std = @import("std");
const crypto = std.crypto;

/// SSRC (Synchronization Source Identifier) 管理
/// 遵循 RFC 3550 Section 5.1
pub const SsrcManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    ssrcs: std.HashMap(u32, void, SsrcContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .ssrcs = std.HashMap(u32, void, SsrcContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.ssrcs.deinit();
    }

    /// 生成新的 SSRC（32 位随机数）
    /// 遵循 RFC 3550 Section 8.1
    pub fn generateSsrc() u32 {
        // 生成 32 位随机数作为 SSRC
        // 注意：0 不是有效的 SSRC 值
        var random_bytes: [4]u8 = undefined;
        crypto.random.bytes(&random_bytes);
        var ssrc = std.mem.readInt(u32, &random_bytes, .little);

        // 确保不是 0
        if (ssrc == 0) {
            ssrc = 1;
        }

        return ssrc;
    }

    /// 添加 SSRC（用于跟踪已使用的 SSRC）
    pub fn addSsrc(self: *Self, ssrc: u32) !void {
        try self.ssrcs.put(ssrc, {});
    }

    /// 检查 SSRC 是否已存在
    pub fn containsSsrc(self: *const Self, ssrc: u32) bool {
        return self.ssrcs.contains(ssrc);
    }

    /// 移除 SSRC
    pub fn removeSsrc(self: *Self, ssrc: u32) bool {
        return self.ssrcs.remove(ssrc);
    }

    /// 生成并添加新的 SSRC（确保不冲突）
    /// 如果生成的 SSRC 已存在，会重新生成（最多尝试 10 次）
    pub fn generateAndAddSsrc(self: *Self) !u32 {
        var attempts: u8 = 0;
        while (attempts < 10) {
            const ssrc = Self.generateSsrc();
            if (!self.containsSsrc(ssrc)) {
                try self.addSsrc(ssrc);
                return ssrc;
            }
            attempts += 1;
        }
        return error.FailedToGenerateSsrc;
    }

    /// 获取所有 SSRC 列表
    pub fn getAllSsrcs(self: *const Self, allocator: std.mem.Allocator) ![]u32 {
        const count = self.ssrcs.count();
        const result = try allocator.alloc(u32, count);
        var index: usize = 0;
        var iterator = self.ssrcs.iterator();
        while (iterator.next()) |entry| {
            result[index] = entry.key_ptr.*;
            index += 1;
        }
        return result;
    }

    pub const Error = error{
        OutOfMemory,
        FailedToGenerateSsrc,
    };
};

/// SSRC HashMap 上下文
const SsrcContext = struct {
    pub fn hash(_: SsrcContext, ssrc: u32) u64 {
        return @as(u64, ssrc);
    }

    pub fn eql(_: SsrcContext, a: u32, b: u32) bool {
        return a == b;
    }
};

/// 生成新的 SSRC（独立函数，不依赖管理器）
pub fn generateSsrc() u32 {
    return SsrcManager.generateSsrc();
}

/// 验证 SSRC 是否有效（非零）
pub fn isValidSsrc(ssrc: u32) bool {
    return ssrc != 0;
}
