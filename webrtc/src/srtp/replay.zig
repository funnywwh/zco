const std = @import("std");

/// SRTP 重放保护窗口（滑动窗口）
/// 遵循 RFC 3711 Section 3.3.2
pub const ReplayWindow = struct {
    const Self = @This();

    bitmap: u64 = 0, // 64-bit 滑动窗口位图
    last_sequence: u16 = 0, // 最后接收的序列号（16-bit）

    /// 检查序列号是否有效（不是重放）
    /// 返回 true 表示是重放，false 表示有效
    pub fn checkReplay(self: *Self, sequence: u16) bool {
        // 如果这是第一个包（last_sequence 为 0 且 sequence 也为 0）
        if (self.last_sequence == 0 and sequence == 0 and self.bitmap == 0) {
            self.update(sequence);
            return false;
        }

        // 计算序列号差（考虑回绕）
        var diff: i32 = @as(i32, sequence) -% @as(i32, self.last_sequence);

        // 处理序列号回绕（从最大值回到小值）
        if (diff < -32768) {
            diff += 65536; // 序列号回绕了
        }

        // 如果序列号比最后接收的序列号大，是正常的新包
        if (diff > 0) {
            if (diff > 64) {
                // 未来太远的包，可能是重放或乱序
                // 暂时接受并更新窗口
                self.update(sequence);
                return false;
            }
            // 正常的新包
            self.update(sequence);
            return false;
        }

        // 如果序列号比最后接收的序列号小，检查是否在窗口内
        if (diff < 0) {
            const abs_diff = @as(u16, @intCast(-diff));
            if (abs_diff > 64) {
                // 太旧的包，肯定是重放
                return true;
            }
            // 检查位图中是否已经设置
            const bit_index = @as(u6, @intCast(abs_diff - 1));
            if ((self.bitmap & (@as(u64, 1) << bit_index)) != 0) {
                // 位已设置，是重放
                return true;
            }
            // 在窗口内且未设置，更新窗口
            self.update(sequence);
            return false;
        }

        // 序列号相同（diff == 0），是重放
        return true;
    }

    /// 更新重放窗口
    pub fn update(self: *Self, sequence: u16) void {
        if (self.last_sequence == 0 and sequence == 0 and self.bitmap == 0) {
            // 第一个包
            self.last_sequence = sequence;
            self.bitmap = 1; // 设置位 0
            return;
        }

        // 计算序列号差（考虑回绕）
        var diff: i32 = @as(i32, sequence) -% @as(i32, self.last_sequence);

        // 处理序列号回绕
        if (diff < -32768) {
            diff += 65536;
        }

        if (diff > 0) {
            // 序列号增大，向右移动窗口
            if (@as(u32, @intCast(diff)) >= 64) {
                // 移动距离太大，清空窗口
                self.bitmap = 1; // 只设置当前位
                self.last_sequence = sequence;
            } else {
                // 正常移动窗口
                const shift = @as(u6, @intCast(diff));
                self.bitmap <<= shift;
                // 设置当前序列号的位（位 0）
                self.bitmap |= 1;
                self.last_sequence = sequence;
            }
        } else if (diff < 0) {
            // 序列号减小（乱序包），设置对应的位
            const abs_diff = @as(u16, @intCast(-diff));
            if (abs_diff <= 64) {
                const bit_index = @as(u6, @intCast(abs_diff - 1));
                self.bitmap |= @as(u64, 1) << bit_index;
            }
        }
        // diff == 0 的情况：序列号相同，不更新（在 checkReplay 中已处理）
    }

    /// 重置重放窗口
    pub fn reset(self: *Self) void {
        self.bitmap = 0;
        self.last_sequence = 0;
    }
};
