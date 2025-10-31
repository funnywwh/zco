const std = @import("std");
const c = @import("./c.zig");
const builtin = @import("builtin");

// 调试开关
const DEBUG_UCONTEXT = false;

// 仅支持 x86_64 Linux
comptime {
    if (builtin.target.cpu.arch != .x86_64 or builtin.target.os.tag != .linux) {
        @compileError("ucontext_impl.zig only supports x86_64 Linux");
    }
}

// MakecontextInfo 结构：存储在栈上，包含函数指针、参数和 uc_link
// 参考 musl 的实现方式
const MakecontextInfo = struct {
    func: usize, // 函数指针
    argc: c_int,
    args: [6]usize, // x86_64 System V ABI 最多6个寄存器参数
    uc_link: ?*const c.ucontext_t,
};

/// 保存当前执行上下文
/// 参考 musl 的实现方式：使用汇编直接保存所有寄存器
pub export fn getcontext(ctx: *c.ucontext_t) c_int {
    const gregs: *[18]usize = @ptrCast(&ctx.uc_mcontext.gregs);

    // musl 方式的实现：直接使用汇编保存所有寄存器
    // musl 使用 movq 指令将寄存器保存到 gregs 数组的相应位置
    // 标准 ucontext_t gregs 索引：
    // REG_R8=0, REG_R9=1, REG_R10=2, REG_R11=3, REG_R12=4, REG_R13=5, REG_R14=6, REG_R15=7,
    // REG_RDI=8, REG_RSI=9, REG_RBP=10, REG_RBX=11, REG_RDX=12, REG_RAX=13, REG_RCX=14, REG_RSP=15, REG_RIP=16, REG_EFL=17

    var saved_rdi: usize = undefined;
    var saved_rax: usize = undefined;

    // 先保存会被用作临时寄存器的值
    asm volatile (
        \\  movq %%rdi, %[rdi]
        \\  movq %%rax, %[rax]
        : [rdi] "=r" (saved_rdi),
          [rax] "=r" (saved_rax),
        :
        : "rdi", "rax"
    );

    // musl 方式：从栈顶读取返回地址并保存
    asm volatile (
        \\  // 使用 RDI 作为 gregs 基址
        \\  movq %[gregs], %%rdi
        \\
        \\  // 保存 RSP
        \\  leaq (%%rsp), %%rax
        \\  movq %%rax, 120(%%rdi)       // REG_RSP = 15 (offset 15*8 = 120)
        \\
        \\  // 从栈顶读取返回地址
        \\  movq (%%rsp), %%rax
        \\  movq %%rax, 128(%%rdi)       // REG_RIP = 16 (offset 16*8 = 128)
        \\
        \\  // 保存所有通用寄存器（按照标准 gregs 顺序）
        \\  movq %%r8,  0(%%rdi)         // REG_R8 = 0
        \\  movq %%r9,  8(%%rdi)         // REG_R9 = 1
        \\  movq %%r10, 16(%%rdi)        // REG_R10 = 2
        \\  movq %%r11, 24(%%rdi)        // REG_R11 = 3
        \\  movq %%r12, 32(%%rdi)        // REG_R12 = 4
        \\  movq %%r13, 40(%%rdi)        // REG_R13 = 5
        \\  movq %%r14, 48(%%rdi)        // REG_R14 = 6
        \\  movq %%r15, 56(%%rdi)        // REG_R15 = 7
        \\  movq %[rdi_saved], 64(%%rdi) // REG_RDI = 8 (保存的原始 RDI)
        \\  movq %%rsi, 72(%%rdi)        // REG_RSI = 9
        \\  movq %%rbp, 80(%%rdi)        // REG_RBP = 10
        \\  movq %%rbx, 88(%%rdi)        // REG_RBX = 11
        \\  movq %%rdx, 96(%%rdi)        // REG_RDX = 12
        \\  movq %[rax_saved], 104(%%rdi) // REG_RAX = 13 (保存的原始 RAX)
        \\  movq %%rcx, 112(%%rdi)       // REG_RCX = 14
        \\
        \\  // 保存 EFLAGS
        \\  pushfq
        \\  popq 136(%%rdi)              // REG_EFL = 17 (offset 17*8 = 136)
        \\
        \\  // 恢复 RDI 和 RAX
        \\  movq %[rdi_saved], %%rdi
        \\  movq %[rax_saved], %%rax
        :
        : [gregs] "r" (gregs),
          [rdi_saved] "r" (saved_rdi),
          [rax_saved] "r" (saved_rax),
        : "rdi", "rax", "memory", "cc"
    );

    // 保存浮点寄存器状态（musl 使用 fxsave）
    var fpregs_buffer align(16) = std.mem.zeroes([512]u8);
    const fpregs_ptr: [*]align(16) u8 = &fpregs_buffer;
    asm volatile ("fxsave (%[ptr])"
        :
        : [ptr] "r" (fpregs_ptr),
        : "memory"
    );

    // 复制到 ctx.__fpregs_mem
    @memcpy(@as([*]u8, @ptrCast(&ctx.__fpregs_mem))[0..512], fpregs_buffer[0..512]);

    return 0;
}

/// 恢复上下文并跳转
/// 参考 musl 的实现方式：恢复所有寄存器，最后切换栈和跳转
pub export fn setcontext(ctx: *const c.ucontext_t) c_int {
    const gregs: *const [18]usize = @ptrCast(&ctx.uc_mcontext.gregs);

    // 恢复浮点寄存器状态（musl 使用 fxrstor）
    var fpregs_buffer align(16) = std.mem.zeroes([512]u8);
    @memcpy(fpregs_buffer[0..512], @as([*]const u8, @ptrCast(&ctx.__fpregs_mem))[0..512]);
    const fpregs_ptr: [*]align(16) const u8 = &fpregs_buffer;

    asm volatile ("fxrstor (%[ptr])"
        :
        : [ptr] "r" (fpregs_ptr),
        : "memory"
    );

    // musl 方式：恢复所有寄存器，最后切换栈和跳转
    // 关键策略：先恢复 R8-R15，因为它们不会被用作临时存储
    // 然后恢复 RDI、RSI 等，最后恢复 RSP 和 RIP
    asm volatile (
        \\  // 将 gregs 地址移到 RSI（作为基址）
        \\  movq %[gregs], %%rsi
        \\
        \\  // 第一步：恢复 R8-R15（这些寄存器不会被用作临时存储）
        \\  movq 0(%%rsi),  %%r8         // REG_R8
        \\  movq 8(%%rsi),  %%r9         // REG_R9
        \\  movq 16(%%rsi), %%r10        // REG_R10
        \\  movq 24(%%rsi), %%r11        // REG_R11
        \\  movq 32(%%rsi), %%r12        // REG_R12
        \\  movq 40(%%rsi), %%r13        // REG_R13
        \\  movq 48(%%rsi), %%r14        // REG_R14
        \\  movq 56(%%rsi), %%r15        // REG_R15
        \\
        \\  // 第二步：先读取所有还需要从 gregs 读取的值（在恢复任何寄存器之前）
        \\  // 使用栈暂存：RCX, RAX, RSI, RIP, RSP, EFL
        \\  movq 112(%%rsi), %%rax        // REG_RCX（临时）
        \\  pushq %%rax                  // 压栈（REG_RCX）
        \\  movq 104(%%rsi), %%rax        // REG_RAX（临时）
        \\  pushq %%rax                  // 压栈（REG_RAX）
        \\  movq 72(%%rsi), %%rax         // REG_RSI（临时）
        \\  pushq %%rax                  // 压栈（REG_RSI）
        \\  movq 128(%%rsi), %%rax        // REG_RIP（临时）
        \\  pushq %%rax                  // 压栈（REG_RIP）
        \\  movq 120(%%rsi), %%rax        // REG_RSP（临时）
        \\  pushq %%rax                  // 压栈（REG_RSP）
        \\  movq 136(%%rsi), %%rax        // REG_EFL（临时）
        \\  pushq %%rax                  // 压栈（REG_EFL）
        \\
        \\  // 第三步：恢复其他寄存器（RDI、RBP、RBX、RDX 可以直接恢复）
        \\  movq 64(%%rsi), %%rdi        // REG_RDI
        \\  movq 80(%%rsi), %%rbp        // REG_RBP
        \\  movq 88(%%rsi), %%rbx        // REG_RBX
        \\  movq 96(%%rsi), %%rdx        // REG_RDX
        \\
        \\  // 第四步：恢复 EFLAGS（从栈顶弹出）
        \\  popq %%rax                   // REG_EFL
        \\  pushq %%rax                  // 压回
        \\  popfq                        // 恢复 EFLAGS
        \\
        \\  // 第五步：恢复 RSI、RAX、RCX（从栈弹出）
        \\  popq %%rax                   // REG_EFL（丢弃，已经恢复）
        \\  popq %%r11                   // REG_RSP（临时存储到 R11，R11 已恢复但可以覆盖）
        \\  popq %%r12                   // REG_RIP（临时存储到 R12，R12 已恢复但可以覆盖）
        \\  popq %%rsi                   // REG_RSI
        \\  popq %%rax                   // REG_RAX
        \\  popq %%rcx                   // REG_RCX
        \\
        \\  // 最后：恢复栈指针和跳转
        \\  movq %%r11, %%rsp            // REG_RSP（切换栈！）
        \\  movq %%r12, %%rax            // REG_RIP
        \\  jmpq *%%rax                  // 跳转到 RIP
        :
        : [gregs] "r" (gregs),
        : "memory", "cc"
    );

    unreachable;
}

/// 设置新上下文
/// 参考 musl 的实现方式：在栈上设置参数，设置 RSP 和 RIP
pub export fn makecontext(ctx: *c.ucontext_t, func: ?*const fn () callconv(.C) void, argc: c_int, ...) void {
    // 验证栈已设置
    if (ctx.uc_stack.ss_sp == null or ctx.uc_stack.ss_size == 0) {
        @panic("makecontext: uc_stack must be set");
    }

    if (argc < 0 or argc > 6) {
        @panic("makecontext: argc must be between 0 and 6");
    }

    // 获取可变参数
    var args: [6]usize = undefined;
    if (argc > 0) {
        var va = @cVaStart();
        defer @cVaEnd(&va);
        var i: c_int = 0;
        while (i < argc) : (i += 1) {
            args[@intCast(i)] = @cVaArg(&va, usize);
        }
    }

    const stack_bottom: usize = @intFromPtr(ctx.uc_stack.ss_sp);
    const alignment: usize = 16;

    // musl 方式：计算栈顶，16字节对齐
    // 栈顶 = ss_sp + ss_size，向下对齐到16字节
    // 但 musl 实际使用 ss_sp + ss_size - sizeof(void*) 作为栈顶
    var sp: usize = stack_bottom + ctx.uc_stack.ss_size - @sizeOf(usize);
    sp = sp & ~(alignment - 1);

    // 在栈上分配 MakecontextInfo（放在栈顶下方）
    // musl 的方式：直接在栈上放置参数，不需要额外的结构体
    // 但为了兼容性，我们仍然使用 MakecontextInfo
    const info_size = @sizeOf(MakecontextInfo);
    const aligned_info_size = (info_size + alignment - 1) & ~(alignment - 1);

    // 计算 MakecontextInfo 的位置（在栈顶下方）
    // musl 不预留额外的栈帧空间，因为 makecontext 的函数会在新栈上运行
    // 但我们需要确保 MakecontextInfo 不会被 context_entry_wrapper 的栈帧覆盖
    // context_entry_wrapper 的函数序言：push %rbp (8字节) + sub $0x370 (880字节)
    // 所以栈帧范围是 [sp - 8 - 0x370, sp - 8]
    // MakecontextInfo 应该在这个范围之外
    const stack_frame_size = 0x370 + 8; // 栈帧大小 + push %rbp
    const info_ptr = sp - aligned_info_size - stack_frame_size;
    const aligned_info_ptr = info_ptr & ~(alignment - 1);

    // 初始化栈内存
    const stack_init_size = (stack_bottom + ctx.uc_stack.ss_size) - aligned_info_ptr;
    if (stack_init_size > 0) {
        const stack_init_ptr: [*]u8 = @ptrFromInt(aligned_info_ptr);
        @memset(stack_init_ptr[0..stack_init_size], 0);
    }

    // 保存 MakecontextInfo
    const info: *MakecontextInfo = @ptrFromInt(aligned_info_ptr);
    const func_addr = if (func) |f| @intFromPtr(f) else 0;
    info.func = func_addr;
    info.argc = argc;
    info.args = args;
    info.uc_link = ctx.uc_link;

    // 设置寄存器
    const gregs_ptr = @as(*[18]usize, @ptrCast(&ctx.uc_mcontext.gregs));

    // musl 方式：RSP 指向栈顶（对齐后的位置）
    gregs_ptr[15] = sp; // REG_RSP

    // RIP 指向 context_entry_wrapper
    const entry_addr = @intFromPtr(&context_entry_wrapper);
    gregs_ptr[16] = entry_addr; // REG_RIP

    // RDI 传入 MakecontextInfo 的地址
    gregs_ptr[8] = aligned_info_ptr; // REG_RDI

    // RBP 初始值
    gregs_ptr[10] = sp; // REG_RBP

    // 其他寄存器初始化为 0
    gregs_ptr[0] = 0; // REG_R8
    gregs_ptr[1] = 0; // REG_R9
    gregs_ptr[2] = 0; // REG_R10
    gregs_ptr[3] = 0; // REG_R11
    gregs_ptr[4] = 0; // REG_R12
    gregs_ptr[5] = 0; // REG_R13
    gregs_ptr[6] = 0; // REG_R14
    gregs_ptr[7] = 0; // REG_R15
    gregs_ptr[9] = 0; // REG_RSI
    gregs_ptr[11] = 0; // REG_RBX
    gregs_ptr[12] = 0; // REG_RDX
    gregs_ptr[13] = 0; // REG_RAX
    gregs_ptr[14] = 0; // REG_RCX

    // EFLAGS: 设置为标准值
    gregs_ptr[17] = 0x202; // REG_EFL（允许中断，方向标志清空）
}

/// 协程入口包装函数
fn context_entry_wrapper(info_ptr: usize) callconv(.C) noreturn {
    // 立即读取 MakecontextInfo（在函数序言完成后）
    const info: *MakecontextInfo = @ptrFromInt(info_ptr);
    const func_addr = info.func;
    const argc_val = info.argc;
    var args_val: [6]usize = undefined;
    for (0..6) |i| {
        args_val[i] = info.args[i];
    }
    const uc_link_val = info.uc_link;

    // 调用实际函数
    if (argc_val > 0) {
        const first_arg = args_val[0];
        const FuncType = *const fn (usize) callconv(.C) void;
        const func: FuncType = @ptrFromInt(func_addr);
        func(first_arg);
    } else {
        const EmptyFunc = *const fn () callconv(.C) void;
        const empty_func: EmptyFunc = @ptrFromInt(func_addr);
        empty_func();
    }

    // 函数返回后，如果有 uc_link，切换到链接的上下文
    if (uc_link_val) |link_ctx| {
        _ = setcontext(link_ctx);
    }

    // 如果没有 uc_link，进入无限循环
    while (true) {
        std.Thread.yield() catch {};
    }
}

/// 保存当前上下文并切换
pub export fn swapcontext(old_ctx: *c.ucontext_t, new_ctx: *const c.ucontext_t) c_int {
    if (getcontext(old_ctx) != 0) {
        return -1;
    }
    return setcontext(new_ctx);
}
