const std = @import("std");
const builtin = @import("builtin");
const root = @import("./root.zig");

// 导入系统头文件获取类型定义（始终需要）
const c = @cImport({
    @cInclude("ucontext.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("sys/time.h");
    @cInclude("pthread.h");
    @cInclude("string.h");
    @cInclude("syscall.h");
    @cInclude("unistd.h");
    @cInclude("sys/ucontext.h");
});

// x86_64 寄存器索引常量
pub const REG_RIP = 16; // 程序计数器
pub const REG_RSP = 19; // 栈指针

// 检查是否使用自定义实现
// 从配置模块读取选项值
// 可以通过手动修改 src/ucontext_config.zig 文件来启用/禁用自定义实现
const ucontext_config = @import("./ucontext_config.zig");
const use_custom = ucontext_config.use_custom_ucontext and
    builtin.target.cpu.arch == .x86_64 and
    builtin.target.os.tag == .linux;

// 根据编译选项选择实现
// 如果使用自定义实现，ucontext_impl.zig 中的函数已经用 pub export 声明
// 它们会自动覆盖系统函数（链接器会选择我们的符号）
// 这里只需要确保模块被导入，让链接器能找到这些函数
comptime {
    if (use_custom) {
        _ = @import("./ucontext_impl.zig");
    }
}

pub usingnamespace c;
