const root = @import("root");
const builtin = @import("builtin");

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
