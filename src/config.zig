const root = @import("root");
const builtin = @import("builtin");

// 环形缓冲区+优先级位图配置
pub const RING_BUFFER_SIZE = 2048;  // 可配置的环形缓冲区大小
pub const MAX_PRIORITY_LEVELS = 32;  // 支持32个优先级级别

pub const DEFAULT_ZCO_STACK_SZIE = blk: {
    if (@hasDecl(root, "DEFAULT_ZCO_STACK_SZIE")) {
        if (builtin.mode == .Debug) {
            if (root.DEFAULT_ZCO_STACK_SZIE < 1024 * 32) {
                @compileError("root.DEFAULT_ZCO_STACK_SZIE < 1024*12");
            }
        } else {
            if (root.DEFAULT_ZCO_STACK_SZIE < 1024 * 4) {
                @compileError("root.DEFAULT_ZCO_STACK_SZIE < 1024*4");
            }
        }
        break :blk root.DEFAULT_ZCO_STACK_SZIE;
    } else {
        if (builtin.mode == .Debug) {
            break :blk 1024 * 64; // 增加到64KB
        } else {
            break :blk 1024 * 16; // 增加到16KB
        }
    }
};
