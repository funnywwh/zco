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

pub usingnamespace c;
