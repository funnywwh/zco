# ucontext API 自实现文档

## 概述

ZCO v0.5.0 使用 Zig 内联汇编重新实现了标准的 `ucontext` API，完全替代了系统库的 `ucontext` 实现。这个实现提供了与标准 `ucontext` API 完全兼容的接口，同时包含浮点数寄存器（XMM 寄存器）的完整保存和恢复功能。

## 实现背景

### 为什么需要重新实现？

1. **平台兼容性**: 系统 `ucontext` 在一些平台上已被标记为废弃（deprecated），未来可能不再支持
2. **完整控制**: 自实现可以完全控制上下文切换的细节，便于优化和调试
3. **浮点支持**: 确保浮点寄存器的完整保存和恢复，这对于需要浮点计算的协程至关重要
4. **依赖减少**: 减少对系统库的依赖，提高可移植性

### 实现方式

我们没有使用 `setjmp`/`longjmp`（因为无法直接访问其内部结构），而是使用**内联汇编直接保存和恢复所有寄存器**，包括：

- 通用寄存器（R8-R15, RAX, RBX, RCX, RDX, RSI, RDI, RBP, RSP, RIP, EFLAGS）
- 浮点寄存器（XMM0-XMM15, FPU 状态）

## 架构设计

### 文件结构

```
src/
├── c.zig              # C 头文件导入，导入 ucontext_impl
└── ucontext_impl.zig  # ucontext API 的完整实现
```

### 核心函数

#### 1. `getcontext(ctx: *ucontext_t) c_int`

**功能**: 保存当前执行上下文到 `ctx`

**实现要点**:
- 使用 `pthread_sigmask` 保存信号掩码
- 使用内联汇编直接保存所有通用寄存器到 `ctx.uc_mcontext.gregs`
- 使用 `fxsave` 指令保存所有浮点寄存器到 `ctx.__fpregs_mem`
- 保存 RIP（返回地址）用于后续恢复

**寄存器映射**:
```zig
// x86_64 gregset_t 数组索引映射
REG_R8=0, REG_R9=1, REG_R10=2, REG_R11=3, REG_R12=4, REG_R13=5,
REG_R14=6, REG_R15=7, REG_RDI=8, REG_RSI=9, REG_RBP=10, REG_RBX=11,
REG_RDX=12, REG_RAX=13, REG_RCX=14, REG_RSP=15, REG_RIP=16, REG_EFL=17
```

#### 2. `makecontext(ctx: *ucontext_t, func: fn() void, argc: c_int, ...) void`

**功能**: 设置新上下文，使其在切换时执行指定函数

**实现要点**:
- 验证栈已设置（`uc_stack` 不能为空）
- 处理可变参数（最多6个，对应 x86_64 System V ABI 的寄存器参数）
- 计算栈顶地址（16字节对齐）
- 在栈上分配 `MakecontextInfo` 结构（包含函数指针、参数、`uc_link`）
- 设置寄存器：
  - `RSP`: 指向准备好的栈位置
  - `RIP`: 指向 `context_entry_wrapper` 函数
  - `RDI`: 传入 `MakecontextInfo` 的地址（作为包装函数的参数）
- 初始化浮点寄存器状态

**栈布局**:
```
高地址
  ┌─────────────────┐
  │  MakecontextInfo │  <- info_ptr (传给包装函数)
  ├─────────────────┤
  │   Red Zone       │  (128字节，x86_64 ABI 要求)
  ├─────────────────┤
  │                  │
  │   协程栈空间      │
  │                  │
  └─────────────────┘
低地址
```

#### 3. `swapcontext(old_ctx: *ucontext_t, new_ctx: *const ucontext_t) c_int`

**功能**: 保存当前上下文到 `old_ctx`，然后切换到 `new_ctx`

**实现**:
```zig
pub export fn swapcontext(oucp: *c.ucontext_t, ucp: *const c.ucontext_t) c_int {
    // 保存当前上下文
    if (getcontext(oucp) != 0) {
        return -1;
    }
    // 切换到新上下文
    return setcontext(ucp);
}
```

#### 4. `setcontext(ctx: *const c.ucontext_t) c_int`

**功能**: 恢复指定上下文（不返回，除非通过 `uc_link`）

**实现要点**:
- 恢复信号掩码
- 使用 `fxrstor` 恢复浮点寄存器
- 使用内联汇编恢复所有通用寄存器
- 最后恢复 RSP 和 RIP，完成跳转

**寄存器恢复顺序**:
1. 先恢复所有通用寄存器（除 RSP、RIP 外）
2. 恢复 EFLAGS
3. 恢复 RSP（必须在跳转前设置）
4. 恢复 RIP 并跳转（`jmp *%rax`）

### 协程入口包装

`context_entry_wrapper` 是一个 C ABI 兼容的函数，作为协程的实际入口点：

```zig
fn context_entry_wrapper(info_ptr: usize) callconv(.C) noreturn {
    const info: *MakecontextInfo = @ptrFromInt(info_ptr);
    
    // 调用实际函数（第一个参数是 info.args[0]）
    if (info.argc > 0) {
        info.func(@ptrFromInt(info.args[0]));
    } else {
        // 如果没有参数，传递一个空指针
        const EmptyFn = *const fn () callconv(.C) void;
        const empty_func: EmptyFn = @ptrCast(info.func);
        empty_func();
    }

    // 函数返回后，如果有 uc_link，切换到链接的上下文
    if (info.uc_link) |link_ctx| {
        _ = setcontext(link_ctx);
    }
    
    // 如果没有 uc_link，进入等待循环
    while (true) {
        std.Thread.Futex.wait(null, 0, null);
    }
}
```

**作用**:
- 从栈上的 `MakecontextInfo` 提取函数指针和参数
- 调用实际的协程函数
- 处理协程返回后的清理（通过 `uc_link`）

## 技术细节

### 浮点寄存器保存/恢复

我们使用 `fxsave`/`fxrstor` 指令来保存和恢复浮点寄存器：

**fxsave 保存内容**:
- FPU 控制字、状态字、标签字
- 8个 FPU 寄存器（80位 each）
- 16个 XMM 寄存器（128位 each，XMM0-XMM15）
- MXCSR（SSE 控制/状态寄存器）
- FPU 指令/数据指针

**内存对齐要求**:
- `fxsave`/`fxrstor` 需要 16 字节对齐的内存区域
- `ucontext_t.__fpregs_mem` 在结构体中自然对齐

### 栈对齐和 ABI 兼容

**x86_64 System V ABI 要求**:
- 栈必须 16 字节对齐
- 函数调用前，栈指针必须对齐到 16 字节边界
- Red Zone: 前 128 字节保留给函数使用

**我们的实现**:
```zig
// 计算栈顶地址（16字节对齐，向下对齐）
const stack_top = std.mem.alignDown(stack_bottom + ctx.uc_stack.ss_size, 16);

// 分配 MakecontextInfo（16字节对齐）
const aligned_info_size = std.mem.alignForward(usize, info_size, 16);
var stack_ptr: usize = stack_top - aligned_info_size;

// 预留 Red Zone
stack_ptr -= 128;
stack_ptr = std.mem.alignDown(stack_ptr, 16);
```

### 信号掩码保存

`getcontext` 会保存当前的信号掩码：

```zig
if (c.pthread_sigmask(c.SIG_BLOCK, null, &ctx.uc_sigmask) != 0) {
    return -1;
}
```

`setcontext` 会恢复信号掩码：

```zig
if (c.pthread_sigmask(c.SIG_SETMASK, &ctx.uc_sigmask, null) != 0) {
    return -1;
}
```

这确保了上下文切换时信号处理的一致性。

## 平台支持

### 当前支持

- **架构**: x86_64
- **操作系统**: Linux
- **编译检查**: 使用 `comptime` 在编译时验证目标平台

### 未来扩展

可以扩展到其他平台：

1. **ARM64**: 需要适配寄存器映射和浮点寄存器保存方式
2. **macOS/iOS**: 需要适配 Mach 系统的信号处理
3. **Windows**: 需要适配 Windows 的纤程（Fiber）API

## 性能考虑

### 上下文切换开销

**寄存器保存/恢复**:
- 通用寄存器: ~20 个寄存器 × 8 字节 = 160 字节
- 浮点寄存器: ~512 字节（fxsave 格式）
- 总内存访问: ~672 字节

**指令开销**:
- `fxsave`: ~50-100 个 CPU 周期
- `fxrstor`: ~50-100 个 CPU 周期
- 寄存器保存/恢复: ~100-200 个 CPU 周期
- **总开销**: ~200-400 个 CPU 周期

这比系统 `ucontext` 实现略慢（因为保存了更多状态），但提供了更好的兼容性和控制。

### 优化建议

1. **浮点寄存器延迟保存**: 如果协程不使用浮点运算，可以延迟保存浮点寄存器
2. **寄存器缓存**: 对于频繁切换的协程，可以缓存部分寄存器状态
3. **SIMD 优化**: 使用 SIMD 指令批量保存/恢复寄存器

## 测试验证

### 基本功能测试

```zig
test "getcontext/makecontext/swapcontext" {
    var ctx: c.ucontext_t = undefined;
    var ctx2: c.ucontext_t = undefined;
    
    // 测试 getcontext
    try std.testing.expectEqual(0, c.getcontext(&ctx));
    
    // 测试 makecontext
    ctx.uc_stack.ss_sp = &stack;
    ctx.uc_stack.ss_size = stack.len;
    c.makecontext(&ctx, test_func, 0);
    
    // 测试 swapcontext
    try std.testing.expectEqual(0, c.swapcontext(&ctx2, &ctx));
}
```

### 浮点数测试

确保上下文切换后浮点数寄存器正确性：

```zig
test "float register preservation" {
    const x: f64 = 3.14159;
    const y: f64 = 2.71828;
    
    // 在协程中计算
    var ctx: c.ucontext_t = undefined;
    // ... 设置上下文并切换
    
    // 验证浮点数结果正确
    try std.testing.expectApproxEqAbs(result, expected, 1e-10);
}
```

### 与系统 ucontext 对比测试

确保行为完全一致：

```zig
test "compatibility with system ucontext" {
    // 运行相同的测试用例
    // 验证结果一致
}
```

## 已知限制

1. **平台特定**: 目前仅支持 x86_64 Linux
2. **性能开销**: 比系统实现略慢（因为保存了更完整的状态）
3. **调试难度**: 内联汇编调试较困难
4. **信号处理器兼容**: 某些信号处理器可能需要特殊处理

## 使用指南

### 基本用法

```zig
const c = @import("zco").c;

// 创建上下文
var ctx: c.ucontext_t = undefined;
var stack: [4096]u8 align(16) = undefined;

// 设置栈
ctx.uc_stack.ss_sp = &stack;
ctx.uc_stack.ss_size = stack.len;

// 获取当前上下文
_ = c.getcontext(&ctx);

// 设置新上下文
c.makecontext(&ctx, my_function, 1, @intFromPtr(&some_data));

// 切换到新上下文
var old_ctx: c.ucontext_t = undefined;
_ = c.swapcontext(&old_ctx, &ctx);
```

### 与 ZCO 集成

ZCO 的协程系统自动使用这个实现，无需额外配置：

```zig
const zco = @import("zco");

// 正常使用 ZCO API
_ = try schedule.go(my_coroutine, .{});
```

实现会自动被链接并替换系统库的 `ucontext` 函数。

## 参考资源

- [System V ABI - AMD64](https://www.uclibc.org/docs/psABI-x86_64.pdf)
- [FXSAVE/FXRSTOR Instruction](https://www.intel.com/content/www/us/en/develop/documentation/xed-user-guide/top/save-restore-x87-fpu-mmx-sse-state.html)
- [Linux ucontext Manual](https://man7.org/linux/man-pages/man3/getcontext.3.html)

## 维护说明

### 修改注意事项

1. **寄存器映射**: 修改寄存器映射时需要同步更新所有相关代码
2. **ABI 兼容**: 确保栈布局符合 x86_64 System V ABI
3. **浮点状态**: 修改浮点寄存器处理时需要测试浮点运算的正确性
4. **信号处理**: 确保信号掩码的正确保存和恢复

### 调试技巧

1. **使用 GDB**: 在关键位置设置断点，检查寄存器值
2. **打印寄存器**: 在保存/恢复前后打印寄存器值，验证正确性
3. **栈跟踪**: 使用 `backtrace` 检查栈布局是否正确
4. **浮点测试**: 运行包含浮点运算的测试，确保精度正确

---

**版本**: v0.6.0  
**最后更新**: 2024-12  
**维护者**: ZCO 开发团队

## 版本历史

### v0.6.0
- 移除信号掩码处理，由调用者统一管理
- 性能优化，减少系统调用
- 架构改进，职责更清晰

### v0.5.0
- 初始实现，使用内联汇编完成所有功能
- 完整支持浮点寄存器保存/恢复

