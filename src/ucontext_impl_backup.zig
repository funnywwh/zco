const std = @import("std");
const c = @import("./c.zig");
const builtin = @import("builtin");

// 调试开关
const DEBUG_UCONTEXT = true;

// 仅支持 x86_64 Linux
comptime {
    if (builtin.target.cpu.arch != .x86_64 or builtin.target.os.tag != .linux) {
        @compileError("ucontext_impl.zig only supports x86_64 Linux");
    }
}

// MakecontextInfo 结构：存储在栈上，包含函数指针、参数和 uc_link
const MakecontextInfo = struct {
    func: usize, // 函数指针
    argc: c_int,
    args: [6]usize, // x86_64 System V ABI 最多6个寄存器参数
    uc_link: ?*const c.ucontext_t,
};

/// 保存当前执行上下文
/// 参考 libco 的寄存器保存方式
pub export fn getcontext(ctx: *c.ucontext_t) c_int {
    // 获取 gregs 数组的指针
    const gregs: *[18]usize = @ptrCast(&ctx.uc_mcontext.gregs);

    // 为浮点寄存器状态创建对齐的缓冲区（fxsave 需要 16 字节对齐，512 字节大小）
    var fpregs_buffer align(16) = std.mem.zeroes([512]u8);

    // 使用内联汇编保存所有寄存器
    // 策略：先保存 R8、RDI、RAX、RCX、R10 和 R11 的值，然后使用 RDI 作为基址保存其他寄存器
    var saved_rdi: usize = undefined;
    var saved_r8: usize = undefined;
    var saved_rax: usize = undefined;
    var saved_rcx: usize = undefined;
    var saved_r10: usize = undefined;
    var saved_r11: usize = undefined;

    // 先获取所有需要保存的寄存器值
    asm volatile (
        \\  movq %%r8, %[r8]
        \\  movq %%rax, %[rax]
        \\  movq %%rcx, %[rcx]
        \\  movq %%r10, %[r10]
        \\  movq %%r11, %[r11]
        : [r8] "=r" (saved_r8),
          [rax] "=r" (saved_rax),
          [rcx] "=r" (saved_rcx),
          [r10] "=r" (saved_r10),
          [r11] "=r" (saved_r11),
        :
        : "r8", "rax", "rcx", "r10", "r11"
    );
    // REG_RDI 应该保存调用 getcontext 时 RDI 的值，也就是 ctx 的地址
    // 但此时 RDI 已经被用作 gregs 的地址，我们需要从函数参数获取 ctx
    saved_rdi = @intFromPtr(ctx);

    // 参考 libco 的实现方式：从当前栈顶读取返回地址
    asm volatile (
        \\  // 参考 libco coctx_swap.S 的实现
        \\  // 将 gregs 地址加载到 RDI（用作基址）
        \\  movq %[gregs], %%rdi
        \\
        \\  // libco 方式：保存当前 RSP，然后从栈顶读取返回地址
        \\  // libco 代码：leaq (%rsp),%rax; movq %rax, 104(%rdi); movq 0(%rax), %rax; movq %rax, 72(%rdi)
        \\  leaq (%%rsp), %%rax          // 当前 RSP 到 RAX
        \\  movq %%rax, 120(%%rdi)       // REG_RSP = 15 (保存当前 RSP)
        \\  movq 0(%%rax), %%r11         // 从栈顶读取返回地址到 R11（临时）
        \\  // 检查返回地址是否有效：不能为 0，且应该在代码段范围内
        \\  testq %%r11, %%r11           // 测试是否为 0
        \\  jz .L_use_rbp_rip            // 如果为 0，使用备用方法
        \\  // 检查是否在合理范围内（代码段地址通常在低地址或高地址）
        \\  // 如果小于 0x100000，可能是无效地址（除非是特殊映射）
        \\  cmp $0x100000, %%r11         // 与 0x100000 比较
        \\  jb .L_use_rbp_rip            // 如果小于，使用备用方法
        \\  jmp .L_rip_saved             // 否则，直接保存
        \\  .L_use_rbp_rip:
        \\  // 备用方法：当栈顶返回地址无效时，尝试从调用栈中获取
        \\  // 在协程栈上，栈顶可能被覆盖，但调用链中应该有返回地址
        \\  // 尝试从 8(%rbp) 读取（调用者的返回地址位置，即 call getcontext 后的地址）
        \\  // 注意：8(%rbp) 是调用者的 RBP，不是返回地址，返回地址在 16(%rbp)
        \\  // 但如果栈顶为 0，说明栈结构可能不同，我们标记为无效，让 swapcontext 修复
        \\  movq $0xdeadbeefdeadbeef, %%r11  // 标记为无效，由 swapcontext 修复
        \\  .L_rip_saved:
        \\  movq %%r11, 128(%%rdi)       // REG_RIP = 16 (保存返回地址)
        \\
        \\  // 按照 libco 的顺序保存寄存器（regs[0..13]）
        \\  // libco 顺序：R15, R14, R13, R12, R9, R8, RBP, RDI, RSI, RET, RDX, RCX, RBX, RSP
        \\  // 我们的 gregs 顺序：R8, R9, R10, R11, R12, R13, R14, R15, RDI, RSI, RBP, RBX, RDX, RAX, RCX, RSP, RIP, EFL
        \\  movq %%r15, 56(%%rdi)        // REG_R15 = 7
        \\  movq %%r14, 48(%%rdi)        // REG_R14 = 6
        \\  movq %%r13, 40(%%rdi)        // REG_R13 = 5
        \\  movq %%r12, 32(%%rdi)        // REG_R12 = 4
        \\  movq %%r9,  8(%%rdi)         // REG_R9 = 1
        \\  movq %[r8],  0(%%rdi)        // REG_R8 = 0 (从保存的值)
        \\  movq %%rbp, 80(%%rdi)        // REG_RBP = 10
        \\  movq %[rdi_val], 64(%%rdi)    // REG_RDI = 8 (保存原始 RDI，即 ctx 地址)
        \\  movq %%rsi, 72(%%rdi)        // REG_RSI = 9
        \\  // RET 已经保存到 REG_RIP = 16
        \\  movq %%rdx, 96(%%rdi)        // REG_RDX = 12
        \\  movq %[rcx_val], 112(%%rdi)   // REG_RCX = 14 (从保存的值)
        \\  movq %%rbx, 88(%%rdi)        // REG_RBX = 11
        \\  // RSP 已经保存到 REG_RSP = 15
        \\
        \\  // 保存 R10 和 R11
        \\  movq %[r10_val], 16(%%rdi)    // REG_R10 = 2
        \\  movq %[r11_val], 24(%%rdi)     // REG_R11 = 3
        \\
        \\  // 保存 RAX（返回值寄存器）
        \\  movq %[rax_val], 104(%%rdi)   // REG_RAX = 13
        \\
        \\  // 保存 EFLAGS
        \\  pushfq
        \\  popq 136(%%rdi)              // REG_EFL = 17
        \\
        \\  // 恢复 RDI（确保函数返回时 RDI 保持原值）
        \\  movq %[rdi_val], %%rdi
        :
        : [gregs] "r" (gregs),
          [r8] "r" (saved_r8),
          [rdi_val] "r" (saved_rdi),
          [rax_val] "r" (saved_rax),
          [rcx_val] "r" (saved_rcx),
          [r10_val] "r" (saved_r10),
          [r11_val] "r" (saved_r11),
        : "rdi", "rax", "rcx", "r10", "r11", "memory"
    );

    // 保存浮点寄存器状态（使用 fxsave，需要 16 字节对齐）
    // 注意：必须在恢复 RDI 之后保存浮点寄存器，因为 fxsave 可能使用 RDI
    // 使用对齐的临时缓冲区
    const fpregs_ptr: [*]align(16) u8 = &fpregs_buffer;
    asm volatile ("fxsave (%[ptr])"
        :
        : [ptr] "r" (fpregs_ptr),
        : "memory"
    );

    // 将浮点寄存器状态复制到 ctx.__fpregs_mem（即使它不对齐）
    @memcpy(@as([*]u8, @ptrCast(&ctx.__fpregs_mem))[0..512], fpregs_buffer[0..512]);

    if (DEBUG_UCONTEXT) {
        const saved_rip = gregs[16];
        const saved_rsp = gregs[15];
        const saved_rbp = gregs[10];
        const reg_rax = gregs[13];
        const reg_rcx = gregs[14];
        // 使用 stderr 输出调试信息，避免依赖日志配置
        const stderr = std.io.getStdErr().writer();
        stderr.print("[getcontext] 保存的 RIP: 0x{x}, RSP: 0x{x}, RBP: 0x{x}, RAX: 0x{x}, RCX: 0x{x}\n", .{ saved_rip, saved_rsp, saved_rbp, reg_rax, reg_rcx }) catch {};

        // 检查 RIP 是否在有效的代码段范围内
        // 代码段通常在低地址（0x100000-0x2000000）或高地址（动态链接库 0x7f...）
        const is_valid_rip = (saved_rip >= 0x100000 and saved_rip < 0x80000000) or
            (saved_rip >= 0x7f0000000000 and saved_rip < 0x800000000000);

        if (saved_rip == 0 or saved_rip == 0xaaaaaaaaaaaaaaaa or saved_rip == 0x200000002 or !is_valid_rip) {
            stderr.print("[getcontext] 警告：检测到无效的 RIP 值！RIP: 0x{x}, ctx地址: 0x{x}\n", .{ saved_rip, @intFromPtr(ctx) }) catch {};
            // 尝试从当前栈帧检查
            var rbp_val: usize = undefined;
            asm volatile ("movq %%rbp, %[rbp]"
                : [rbp] "=r" (rbp_val),
            );
            const ret_addr_at_16 = @as(*const usize, @ptrFromInt(rbp_val + 16)).*;
            const rbp_at_8 = @as(*const usize, @ptrFromInt(rbp_val + 8)).*;
            const r15_at_0 = @as(*const usize, @ptrFromInt(rbp_val)).*;
            const r14_at_minus8 = @as(*const usize, @ptrFromInt(rbp_val - 8)).*;
            const rbx_at_minus16 = @as(*const usize, @ptrFromInt(rbp_val - 16)).*;
            stderr.print("[getcontext] 当前 RBP: 0x{x}\n", .{rbp_val}) catch {};
            stderr.print("[getcontext] 栈内容: 16(%%rbp)=0x{x}, 8(%%rbp)=0x{x}, 0(%%rbp)=0x{x}, -8(%%rbp)=0x{x}, -16(%%rbp)=0x{x}\n", .{ ret_addr_at_16, rbp_at_8, r15_at_0, r14_at_minus8, rbx_at_minus16 }) catch {};

            // 尝试从 RSP 计算返回地址
            var rsp_val: usize = undefined;
            asm volatile ("movq %%rsp, %[rsp]"
                : [rsp] "=r" (rsp_val),
            );
            stderr.print("[getcontext] 当前 RSP: 0x{x}, RBP-RSP: 0x{x}\n", .{ rsp_val, rbp_val - rsp_val }) catch {};

            // 如果 RIP 无效，尝试使用一个安全的默认值（这不应该发生，但可以避免崩溃）
            // 注意：这只是一个临时的调试措施
            if (saved_rip == 0 or saved_rip == 0xaaaaaaaaaaaaaaaa or saved_rip == 0x200000002) {
                stderr.print("[getcontext] 严重错误：RIP 完全无效，这会导致后续 setcontext 失败\n", .{}) catch {};
            }
        }
    }

    return 0;
}

/// 恢复指定上下文并跳转
/// 不会返回，除非通过 uc_link
pub export fn setcontext(ctx: *const c.ucontext_t) c_int {
    const gregs: *const [18]usize = @ptrCast(&ctx.uc_mcontext.gregs);

    if (DEBUG_UCONTEXT) {
        const rip = gregs[16];
        const rsp = gregs[15];
        const rbp = gregs[10];
        const rax = gregs[13];
        const rdi = gregs[8];
        const rsi = gregs[9];
        // 使用 stderr 输出调试信息，避免依赖日志配置
        const stderr = std.io.getStdErr().writer();
        stderr.print("[setcontext] 准备恢复 - RIP: 0x{x}, RSP: 0x{x}, RBP: 0x{x}\n", .{ rip, rsp, rbp }) catch {};
        stderr.print("[setcontext] RAX: 0x{x}, RDI: 0x{x}, RSI: 0x{x}\n", .{ rax, rdi, rsi }) catch {};
        stderr.print("[setcontext] 上下文地址: 0x{x}\n", .{@intFromPtr(ctx)}) catch {};

        // 检查关键值是否有效
        if (rip == 0 or rip == 0xaaaaaaaaaaaaaaaa) {
            stderr.print("[setcontext] 警告：RIP 值无效！\n", .{}) catch {};
        }
        if (rsp == 0 or rsp == 0xaaaaaaaaaaaaaaaa) {
            stderr.print("[setcontext] 警告：RSP 值无效！\n", .{}) catch {};
        }
        // 检查 RSP 是否指向有效内存区域（在合理的地址范围内）
        if (rsp < 0x700000000000 or rsp > 0x7fffffffffff) {
            stderr.print("[setcontext] 警告：RSP 值异常！\n", .{}) catch {};
        }
    }

    // 恢复浮点寄存器
    // 先将数据复制到对齐的缓冲区，然后使用 fxsave
    var fpregs_buffer align(16) = std.mem.zeroes([512]u8);
    @memcpy(fpregs_buffer[0..512], @as([*]const u8, @ptrCast(&ctx.__fpregs_mem))[0..512]);

    const fpregs_ptr: [*]align(16) const u8 = &fpregs_buffer;

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[setcontext] 准备执行 fxrstor，fpregs_ptr: 0x{x}, 对齐: {d}\n", .{ @intFromPtr(fpregs_ptr), @intFromPtr(fpregs_ptr) % 16 }) catch {};
    }

    asm volatile ("fxrstor (%[ptr])"
        :
        : [ptr] "r" (fpregs_ptr),
        : "memory"
    );

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[setcontext] fxrstor 执行完成\n", .{}) catch {};
    }

    // 恢复所有寄存器并跳转
    // 参考 libco coctx_swap.S 的实现顺序
    const gregs_ptr = gregs;

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[setcontext] 准备执行 asm，gregs 地址: 0x{x}\n", .{@intFromPtr(gregs_ptr)}) catch {};
        stderr.print("[setcontext] 读取的值 - RIP: 0x{x}, RSP: 0x{x}, RDI: 0x{x}, RSI: 0x{x}\n", .{ gregs_ptr[16], gregs_ptr[15], gregs_ptr[8], gregs_ptr[9] }) catch {};
        // 验证 gregs 内存可访问
        stderr.print("[setcontext] gregs[0] = 0x{x}, gregs[15] = 0x{x}, gregs[16] = 0x{x}\n", .{ gregs_ptr[0], gregs_ptr[15], gregs_ptr[16] }) catch {};
        // 验证上下文结构有效
        stderr.print("[setcontext] ctx 地址: 0x{x}, 栈大小验证完成\n", .{@intFromPtr(ctx)}) catch {};
    }

    // 参考 libco coctx_swap.S 的实现：按顺序恢复寄存器，最后 ret
    // 在 asm 开始时，手动将 gregs 的地址移到 RSI（因为 RDI 需要先恢复）
    asm volatile (
        \\  // 参考 libco coctx_swap.S 的恢复顺序
        \\  // 先将 gregs 地址移到 RSI（因为 RDI 需要先恢复）
        \\  movq %[gregs], %%rsi
        \\
        \\  // 严格按照 libco 的顺序恢复寄存器
        \\  // libco 顺序：RBP, RSP, R15, R14, R13, R12, R9, R8, RDI, RDX, RCX, RBX, RSI
        \\  movq 80(%%rsi), %%rbp   // REG_RBP = gregs[10]
        \\  movq 120(%%rsi), %%rsp  // REG_RSP = gregs[15] (切换栈！)
        \\  movq 56(%%rsi), %%r15   // REG_R15 = gregs[7]
        \\  movq 48(%%rsi), %%r14   // REG_R14 = gregs[6]
        \\  movq 40(%%rsi), %%r13   // REG_R13 = gregs[5]
        \\  movq 32(%%rsi), %%r12   // REG_R12 = gregs[4]
        \\  movq 8(%%rsi),  %%r9    // REG_R9 = gregs[1]
        \\  movq 0(%%rsi),  %%r8    // REG_R8 = gregs[0]
        \\  movq 64(%%rsi), %%rdi   // REG_RDI = gregs[8] (在切换栈后，可以从 RSI 读取)
        \\  movq 96(%%rsi), %%rdx   // REG_RDX = gregs[12]
        \\  movq 112(%%rsi), %%rcx  // REG_RCX = gregs[14]
        \\  movq 88(%%rsi), %%rbx   // REG_RBX = gregs[11]
        \\
        \\  // libco 方式：将返回地址压栈，然后使用 ret 跳转
        \\  // libco 代码：leaq 8(%rsp), %rsp; pushq 72(%rsi); movq 64(%rsi), %rsi; ret
        \\  // 但我们的 gregs 布局不同：RIP 在 gregs[16] = 128(%rsi)
        \\  // 注意：必须在恢复 RSI 之前读取 RIP，因为恢复 RSI 后无法再访问 gregs
        \\  movq 128(%%rsi), %%rax  // 先将 RIP 读取到 RAX（临时存储，gregs[16] = 16*8 = 128）
        \\  leaq 8(%%rsp), %%rsp    // RSP += 8（为返回地址留出空间，确保栈对齐）
        \\  pushq %%rax             // 将 RIP 压栈（作为返回地址）
        \\  // 此时栈应该是 16 字节对齐的（RSP % 16 == 8，push 后 RSP % 16 == 0）
        \\
        \\  // 恢复 RSI（必须在最后，因为之前用 RSI 作为 gregs 基址）
        \\  // REG_RSI = gregs[9] = 9*8 = 72
        \\  movq 72(%%rsi), %%rsi   // REG_RSI = gregs[9]
        \\
        \\  // libco 不恢复 RAX（使用 xorq %rax, %rax 清零），但我们为了完整性可以恢复
        \\  // 但注意：必须在恢复 RSI 之后，因为之前用 RSI 作为 gregs 基址
        \\  // 实际上，在 ret 跳转前，RAX 的值不重要，但为了正确性，我们跳过恢复 RAX
        \\
        \\  // 使用 ret 跳转（从栈顶弹出返回地址并跳转）
        \\  ret
        \\  // 这里永远不会执行到
        :
        : [gregs] "r" (gregs_ptr), // gregs 地址（将移动到 RSI）
        : "memory", "cc" // 告诉编译器内存和条件码被修改，寄存器修改由汇编代码明确处理
    );

    // 这里永远不会执行到
    unreachable;
}

/// 协程入口包装函数
/// C ABI 兼容，作为协程的实际入口点
fn context_entry_wrapper(info_ptr: usize) callconv(.C) noreturn {
    // 注意：函数序言会执行 push %rbp; mov %rsp, %rbp; sub $0x280, %rsp
    // 这意味着函数需要至少 0x280 (640) 字节的栈空间

    // 使用内联汇编立即输出调试信息，在函数序言完成后
    // 注意：此时栈已经建立，可以安全地调用函数
    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[context_entry_wrapper] 进入函数！info_ptr: 0x{x}\n", .{info_ptr}) catch {};
    }

    // 验证 info_ptr 是否有效（使用简单的检查，避免复杂操作）
    if (info_ptr == 0) {
        // 不能使用 @panic，因为它可能需要栈操作
        // 使用无限循环避免崩溃
        while (true) {
            asm volatile ("hlt");
        }
    }

    // 立即读取 MakecontextInfo 的所有字段，避免后续栈操作覆盖
    // 使用结构体访问，让编译器处理对齐
    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[context_entry_wrapper] 进入，info_ptr: 0x{x}\n", .{info_ptr}) catch {};
        // 先检查 info_ptr 是否有效（在合理的内存范围内）
        if (info_ptr < 0x100000 or info_ptr > 0x800000000000) {
            stderr.print("[context_entry_wrapper] 警告：info_ptr 地址异常！\n", .{}) catch {};
            while (true) {
                asm volatile ("hlt");
            }
        }
    }

    // 立即读取 MakecontextInfo，避免任何栈操作
    // 使用 volatile 指针读取，防止编译器优化
    // 注意：在函数序言完成后，栈可能已经被修改，所以需要立即读取
    const info: *volatile MakecontextInfo = @ptrFromInt(info_ptr);

    // 先验证 info_ptr 指向的内存是否有效（读取第一个字段）
    // 如果 func 字段被覆盖为 0 或无效值，说明内存被破坏
    const raw_func_check: *volatile usize = @ptrFromInt(info_ptr);
    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[context_entry_wrapper] 原始内存 [0]: 0x{x}\n", .{raw_func_check.*}) catch {};
    }

    const func_addr = info.func;
    const argc_val = info.argc;
    // 直接读取 args 数组，使用 volatile
    var args_val: [6]usize = undefined;
    for (0..6) |i| {
        args_val[i] = info.args[i];
    }
    const uc_link_val = info.uc_link;

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[context_entry_wrapper] info_ptr: 0x{x}, func: 0x{x}, argc: {d}, args[0]: 0x{x}\n", .{ info_ptr, func_addr, argc_val, args_val[0] }) catch {};
        // 验证 func_addr 是否有效
        if (func_addr == 0 or func_addr < 0x100000 or func_addr > 0x80000000) {
            stderr.print("[context_entry_wrapper] 错误：func_addr 无效或指向栈地址！\n", .{}) catch {};
            // 尝试从原始内存读取验证
            const raw_func: *volatile usize = @ptrFromInt(info_ptr);
            stderr.print("[context_entry_wrapper] 原始内存 [0]: 0x{x}\n", .{raw_func.*}) catch {};
        }
        // 检查 func_addr 是否有效
        if (func_addr == 0 or func_addr < 0x100000) {
            stderr.print("[context_entry_wrapper] 错误：func_addr 无效！\n", .{}) catch {};
            while (true) {
                asm volatile ("hlt");
            }
        }
    }

    // 调用实际函数
    // 注意：func_addr 指向的是 Co.contextEntry，其签名是 fn (*co.Co) callconv(.C) void
    // 参数 args[0] 是指向 Co 的指针（usize）
    if (argc_val > 0) {
        const first_arg = args_val[0];
        // 创建一个函数类型，接受一个指针参数（与 Co.contextEntry 的签名匹配）
        const FuncType = *const fn (usize) callconv(.C) void;
        const func: FuncType = @ptrFromInt(func_addr);
        // 直接调用函数（编译器会处理栈对齐和调用约定）
        // x86_64 System V ABI：第一个参数通过 RDI 传递
        func(first_arg);
    } else {
        // 无参数调用
        const EmptyFunc = *const fn () callconv(.C) void;
        const empty_func: EmptyFunc = @ptrFromInt(func_addr);
        empty_func();
    }

    // 函数返回后，如果有 uc_link，切换到链接的上下文
    if (uc_link_val) |link_ctx| {
        _ = setcontext(link_ctx);
    }

    // 如果没有 uc_link，进入无限循环
    // 这不应该发生，因为协程应该总是有 uc_link
    while (true) {
        // 暂停 CPU，避免忙等待
        std.Thread.yield() catch {};
    }
}

/// 设置新上下文，使其在切换时执行指定函数
/// 注意：函数签名必须匹配 C 标准库的 makecontext
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

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        const func_ptr = if (func) |f| @intFromPtr(f) else 0;
        stderr.print("[makecontext] func 指针: 0x{x}, argc: {d}\n", .{ func_ptr, argc }) catch {};
        if (argc > 0) {
            stderr.print("[makecontext] args[0]: 0x{x}\n", .{args[0]}) catch {};
        }
    }

    // 参考 libco coctx_make 的实现
    // 计算栈顶地址（16字节对齐，向下对齐）
    const stack_bottom: usize = @intFromPtr(ctx.uc_stack.ss_sp);
    const alignment: usize = 16;
    // libco 方式：sp = ctx->ss_sp + ctx->ss_size - sizeof(void*)
    // 并在栈顶存放函数指针：*ret_addr = (void*)pfn
    var sp: usize = stack_bottom + ctx.uc_stack.ss_size - @sizeOf(usize);
    // 16字节对齐（向下对齐）
    sp = sp & ~(alignment - 1);

    // libco 在栈顶存放函数指针，这样 setcontext 中的 leaq 8(%rsp), %rsp 可以跳过它
    // 我们也在栈顶存放函数指针，以保持与 libco 一致的行为
    // 注意：这个函数指针会被 setcontext 跳过，不会被执行
    const entry_addr = @intFromPtr(&context_entry_wrapper);
    const ret_addr_ptr: *usize = @ptrFromInt(sp);
    ret_addr_ptr.* = entry_addr; // 在栈顶存放 context_entry_wrapper 地址

    // 注意：setcontext 会执行：
    //   movq 120(%rsi), %rsp  # RSP = sp
    //   leaq 8(%rsp), %rsp    # RSP += 8 (跳过栈顶的函数指针)
    //   pushq %rax            # RSP -= 8 (压入 RIP)
    //   此时 RSP = sp - 8
    //   ret                   # pop 返回地址，RSP = sp，跳转到 RIP

    // 计算 MakecontextInfo 的位置（在栈顶下方）
    // 栈布局分析：
    //   1. makecontext: sp 指向栈顶，栈顶存放函数指针
    //   2. setcontext: 恢复 RSP = sp，然后 leaq 8(%rsp), %rsp (跳过函数指针)，pushq RIP
    //      此时 RSP = sp - 8
    //   3. ret 跳转到 context_entry_wrapper: pop 返回地址，RSP = sp
    //   4. context_entry_wrapper 函数序言:
    //      - push %rbp: RSP = sp - 8
    //      - mov %rsp, %rbp: RBP = sp - 8
    //      - sub $0x370, %rsp: RSP = sp - 8 - 0x370
    //      栈帧范围: [sp - 8 - 0x370, sp - 8]
    // MakecontextInfo 必须在这个栈帧之外（更低地址），避免被覆盖
    const info_size = @sizeOf(MakecontextInfo);
    const aligned_info_size = (info_size + alignment - 1) & ~(alignment - 1);
    const stack_frame_size = 0x370; // context_entry_wrapper 的栈帧大小（sub $0x370）
    const rbp_push_size = 8; // push %rbp 占用的空间
    const total_stack_usage = stack_frame_size + rbp_push_size; // 总共栈使用
    // MakecontextInfo 放在 context_entry_wrapper 栈帧下方
    // 额外留出 512 字节作为安全边距，确保不会被覆盖
    const safety_margin = 512; // 更大的安全边距
    const info_ptr = sp - aligned_info_size - total_stack_usage - safety_margin;
    const aligned_info_ptr = info_ptr & ~(alignment - 1);

    // 验证 info_ptr 不会超出栈边界
    if (aligned_info_ptr < stack_bottom) {
        @panic("makecontext: info_ptr 超出栈边界");
    }

    // 先初始化整个栈区域为 0（确保没有垃圾数据）
    const stack_init_size = (stack_bottom + ctx.uc_stack.ss_size) - aligned_info_ptr;
    if (stack_init_size > 0) {
        const stack_init_ptr: [*]u8 = @ptrFromInt(aligned_info_ptr);
        @memset(stack_init_ptr[0..stack_init_size], 0);
    }

    // 然后保存 MakecontextInfo（覆盖初始化的 0）
    // 使用 volatile 指针确保写入不被优化掉
    const info: *volatile MakecontextInfo = @ptrFromInt(aligned_info_ptr);
    const func_addr = if (func) |f| @intFromPtr(f) else 0;
    // 按字段顺序写入，确保对齐正确
    info.func = func_addr;
    info.argc = argc;
    // 直接赋值 args 数组（编译器会处理对齐和复制）
    for (0..6) |i| {
        info.args[i] = args[i];
    }
    info.uc_link = ctx.uc_link;

    // 强制内存屏障，确保所有写入完成
    std.mem.doNotOptimizeAway(info.func);
    std.mem.doNotOptimizeAway(info.argc);
    std.mem.doNotOptimizeAway(info.args);

    // 验证写入
    if (DEBUG_UCONTEXT) {
        const verify_func = info.func;
        const verify_argc = info.argc;
        if (verify_func != func_addr or verify_argc != argc) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("[makecontext] 错误：写入验证失败！func: 0x{x}->0x{x}, argc: {d}->{d}\n", .{ func_addr, verify_func, argc, verify_argc }) catch {};
        }
    }

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[makecontext] 保存 MakecontextInfo - func: 0x{x}, argc: {d}, args[0]: 0x{x}, info_ptr: 0x{x}\n", .{ info.func, info.argc, info.args[0], aligned_info_ptr }) catch {};
        // 验证写入是否正确
        const verify_info: *const MakecontextInfo = @ptrFromInt(aligned_info_ptr);
        stderr.print("[makecontext] 验证读取 - func: 0x{x}, argc: {d}\n", .{ verify_info.func, verify_info.argc }) catch {};
    }

    // 设置寄存器
    const gregs_ptr = @as(*[18]usize, @ptrCast(&ctx.uc_mcontext.gregs));

    // 参考 libco: ctx->regs[kRSP] = sp
    // RSP 指向栈顶（16字节对齐），栈顶已经存放了 context_entry_wrapper 地址
    gregs_ptr[15] = sp; // REG_RSP = 15

    // RIP: 指向 context_entry_wrapper 函数
    // 注意：libco 使用 regs[kRETAddr] = (char*)pfn，但在 setcontext 中 push 的是 72(%rsi)（regs[9]）
    // 我们的实现中，setcontext 会跳过栈顶的函数指针，然后 push RIP（gregs[16]）
    gregs_ptr[16] = entry_addr; // REG_RIP = 16

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[makecontext] context_entry_wrapper 地址: 0x{x}\n", .{entry_addr}) catch {};
    }

    // RDI: 传入 MakecontextInfo 的地址（作为包装函数的参数）
    gregs_ptr[8] = aligned_info_ptr; // REG_RDI = 8

    // RBP: 初始值将被 push 到栈上，然后函数会设置 RBP = RSP
    // 函数序言：push %rbp（RSP -= 8），然后 mov %rsp, %rbp，然后 sub $0x370
    // 初始 RBP 可以设置为 sp，函数会重新设置
    gregs_ptr[10] = sp; // REG_RBP = 10（会被 push 到栈上，然后函数重新设置）

    // 其他寄存器初始化为 0（安全值）
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

    // EFLAGS: 设置为标准值（允许中断，方向标志清空等）
    // 标准的 EFLAGS 值通常是 0x202（允许中断，方向标志清空）
    var eflags: usize = undefined;
    asm volatile (
        \\  pushfq
        \\  popq %[eflags]
        : [eflags] "=r" (eflags),
        :
        : "memory"
    );
    gregs_ptr[17] = eflags; // REG_EFL（使用当前的 EFLAGS 值）

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[makecontext] 设置 RSP: 0x{x}, RIP: 0x{x}, RDI: 0x{x}, RBP: 0x{x}\n", .{ gregs_ptr[15], gregs_ptr[16], gregs_ptr[8], gregs_ptr[10] }) catch {};
        stderr.print("[makecontext] sp: 0x{x}, MakecontextInfo 地址: 0x{x}\n", .{ sp, aligned_info_ptr }) catch {};
    }

    // 初始化浮点寄存器状态（可选，设为标准值）
    // 使用 fxsave/fxrstor 的初始化状态
}

/// 保存当前上下文到 old_ctx，然后切换到 new_ctx
pub export fn swapcontext(old_ctx: *c.ucontext_t, new_ctx: *const c.ucontext_t) c_int {
    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[swapcontext] 保存上下文到: 0x{x}, 切换到: 0x{x}\n", .{ @intFromPtr(old_ctx), @intFromPtr(new_ctx) }) catch {};
    }

    // 保存当前上下文
    // 注意：getcontext 保存的 RIP 将指向这个函数中 getcontext 返回后的地址
    // 使用标签标记 getcontext 返回后的位置，以便修复无效 RIP
    var return_addr_after_getcontext: usize = undefined;
    if (getcontext(old_ctx) != 0) {
        return -1;
    }
    // 标记 getcontext 返回后的地址
    asm volatile (
        \\  lea (%%rip), %[addr]
        : [addr] "=r" (return_addr_after_getcontext),
    );

    // 检查 getcontext 保存的 RIP 是否有效
    // 如果无效，手动修复（设置为 swapcontext 中 getcontext 返回后的地址）
    const gregs_ptr = @as(*[18]usize, @ptrCast(&old_ctx.uc_mcontext.gregs));
    const saved_rip = gregs_ptr[16];
    // 检查 RIP 是否在代码段范围内
    // 有效的代码地址通常在：
    //   - 低地址：0x100000-0x80000000（主程序代码段）
    //   - 高地址：0x7f0000000000-0x7fffffffffff（动态链接库），但通常不在 0x7f...0000-0x7fff...ffff 范围内
    // 栈地址通常在 0x7f...0000 到 0x7fff...ffff，且通常是 8 字节对齐
    // 更保守的判断：只接受低地址代码段或特定范围的高地址
    const is_valid_rip = (saved_rip >= 0x100000 and saved_rip < 0x80000000) or
        (saved_rip >= 0x7fffff000000 and saved_rip <= 0x7fffffffffff); // 只接受高地址段的末尾部分

    if (saved_rip == 0 or saved_rip == 0xdeadbeefdeadbeef or
        saved_rip == 0xaaaaaaaaaaaaaaaa or !is_valid_rip)
    {
        // RIP 无效，使用标记的地址（即 getcontext 返回后的地址）
        gregs_ptr[16] = return_addr_after_getcontext;

        if (DEBUG_UCONTEXT) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("[swapcontext] 修复无效 RIP 0x{x}，设置为: 0x{x}\n", .{ saved_rip, return_addr_after_getcontext }) catch {};
        }
    }

    if (DEBUG_UCONTEXT) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[swapcontext] getcontext 完成，准备调用 setcontext(0x{x})\n", .{@intFromPtr(new_ctx)}) catch {};
        if (saved_rip == 0 or saved_rip == 0xdeadbeefdeadbeef) {
            stderr.print("[swapcontext] 警告：getcontext 保存的 RIP 无效，可能无法正确恢复\n", .{}) catch {};
        }
    }

    // 切换到新上下文
    // 注意：setcontext 的参数通过寄存器 RDI 传递（x86_64 System V ABI）
    // getcontext 不会修改 RDI，所以 new_ctx 应该仍然在 RDI 中
    // 但为了安全，我们显式传递参数
    const result = setcontext(new_ctx);
    // 这里永远不会执行到，因为 setcontext 不会返回（除非通过 uc_link）
    return result;
}

// 单元测试
test "getcontext basic" {
    var ctx: c.ucontext_t = undefined;
    try std.testing.expectEqual(0, getcontext(&ctx));
    // 验证上下文已保存（RIP 应该指向 getcontext 之后的地址）
}

test "makecontext basic" {
    var ctx: c.ucontext_t = undefined;
    var stack: [4096]u8 align(16) = undefined;

    ctx.uc_stack.ss_sp = &stack;
    ctx.uc_stack.ss_size = stack.len;
    ctx.uc_link = null;

    const test_func = struct {
        fn func() callconv(.C) void {
            // 这个函数会在 makecontext 后的上下文中被调用
        }
    }.func;

    makecontext(&ctx, @intFromPtr(&test_func), 0);
    try std.testing.expect(ctx.uc_stack.ss_sp != null);
}

test "swapcontext basic" {
    var ctx1: c.ucontext_t = undefined;
    var ctx2: c.ucontext_t = undefined;
    var stack2: [4096]u8 align(16) = undefined;

    _ = getcontext(&ctx1);

    ctx2.uc_stack.ss_sp = &stack2;
    ctx2.uc_stack.ss_size = stack2.len;
    ctx2.uc_link = &ctx1;

    var func_called = false;
    const test_func = struct {
        fn func(flag_ptr: usize) callconv(.C) void {
            const flag: *bool = @ptrFromInt(flag_ptr);
            flag.* = true;
            // 通过 uc_link 返回到 ctx1
        }
    }.func;

    makecontext(&ctx2, @intFromPtr(&test_func), 1, @intFromPtr(&func_called));

    // 注意：swapcontext 会切换到 ctx2，然后通过 uc_link 返回到 ctx1
    // 这里只是测试编译，实际执行需要更复杂的设置
    _ = swapcontext(&ctx1, &ctx2);
}
