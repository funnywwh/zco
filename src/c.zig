const c = @cImport({
    @cInclude("ucontext.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("sys/time.h");
    @cInclude("pthread.h");
    @cInclude("string.h");
    @cInclude("syscall.h");
});
pub usingnamespace c;