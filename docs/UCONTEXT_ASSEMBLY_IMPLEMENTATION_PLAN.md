# 实现汇编版本 ucontext 编译开关

## 目标

- 创建 `src/ucontext_impl.zig` 实现汇编版本的 ucontext API
- 在 `build.zig` 中添加 `use_custom_ucontext` 编译选项（默认 false，使用系统实现）
- 修改 `src/c.zig` 根据编译选项选择使用系统实现或汇编实现
- 用户只需导入 `c.zig` 即可使用，无需关心底层实现

## 实现步骤

### 1. 创建汇编实现文件 `src/ucontext_impl.zig`

参考 libco 的汇编实现方式，实现以下函数（仅支持 x86_64 Linux）：

#### 核心函数

- **`getcontext(ctx: *c.ucontext_t) c_int`** - 保存当前执行上下文
  - 参考 libco：保存 RSP, RAX, RBX, RCX, RDX, RSI, RDI, RBP, R8-R15 到 ctx.uc_mcontext.gregs
  - 使用 `stmxcsr`/`fnstcw` 或 `fxsave` 保存浮点寄存器状态
  - 保存返回地址（RIP）

- **`setcontext(ctx: *const c.ucontext_t) c_int`** - 恢复上下文并跳转
  - 恢复所有寄存器（参考 libco 的恢复顺序）
  - 恢复浮点寄存器状态
  - 最后切换 RSP 并跳转到 RIP

- **`makecontext(ctx: *c.ucontext_t, func: anytype, argc: c_int, ...) void`** - 设置新上下文
  - 在栈上设置 MakecontextInfo 结构（函数指针、参数、uc_link）
  - 设置 RSP 指向准备好的栈位置（16字节对齐，预留 Red Zone）
  - 设置 RIP 指向 context_entry_wrapper

- **`swapcontext(old_ctx: *c.ucontext_t, new_ctx: *const c.ucontext_t) c_int`** - 保存并切换
  - 先调用 getcontext 保存，再调用 setcontext 切换

- **`context_entry_wrapper(info_ptr: usize) callconv(.C) noreturn`** - 协程入口包装函数

#### 关键实现要点（参考 libco）

- **寄存器保存顺序**：leaq 获取返回地址 → push 保存寄存器 → 保存浮点状态
- **栈操作**：直接操作 RSP，使用 `leaq 8(%rsp), %rax` 获取返回地址
- **浮点寄存器**：使用 `stmxcsr`/`fnstcw`（简单）或 `fxsave`/`fxrstor`（完整，推荐）
- **栈对齐**：确保 16 字节对齐，预留 128 字节 Red Zone
- **不处理信号掩码**（v0.6.0 架构，由调用者管理）

#### libco 参考实现

```asm
.globl coctx_swap
coctx_swap:
    // 保存当前协程上下文
    leaq 8(%rsp), %rax
    leaq 112(%rdi), %rsp
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq -8(%rax)  // ret func addr
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    
    // 保存浮点寄存器
    stmxcsr (%rsp)
    fnstcw 8(%rsp)
    
    // 切换到目标协程上下文
    movq %rsi, %rsp
    // 恢复目标协程的寄存器...
```

### 2. 修改 `build.zig`

在模块定义中添加编译选项：

```zig
const use_custom_ucontext = b.option(bool, "use_custom_ucontext", 
    "Use custom assembly ucontext implementation instead of system ucontext") orelse false;

// 创建选项对象
const ucontext_option = b.addOptions();
ucontext_option.addOption(bool, "use_custom_ucontext", use_custom_ucontext);

// 传递给 zco 模块
zco.root_module.addOptions("ucontext_opts", ucontext_option);
```

### 3. 修改 `src/c.zig`

根据编译选项条件编译：

```zig
const std = @import("std");
const builtin = @import("builtin");

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
const ucontext_opts = @import("root").ucontext_opts;
const use_custom = ucontext_opts.use_custom_ucontext and 
                   builtin.target.cpu.arch == .x86_64 and 
                   builtin.target.os.tag == .linux;

// 根据编译选项选择实现
if (use_custom) {
    // 导入并导出汇编实现
    const ucontext_impl = @import("./ucontext_impl.zig");
    pub const getcontext = ucontext_impl.getcontext;
    pub const setcontext = ucontext_impl.setcontext;
    pub const makecontext = ucontext_impl.makecontext;
    pub const swapcontext = ucontext_impl.swapcontext;
}
// else 使用系统实现（通过 @cImport）

pub usingnamespace c;
```

## 技术细节

- **x86_64 寄存器映射索引**：参考 Linux ucontext.h 的 gregset_t 定义
- **MakecontextInfo 结构**：存储函数指针、参数数组、argc、uc_link
- **栈对齐**：使用 `std.mem.alignDown` 和 `std.mem.alignForward` 确保 16 字节对齐
- **平台检查**：使用 `builtin.target.cpu.arch == .x86_64` 和 `os.tag == .linux`
- **编译选项访问**：在 `root.zig` 中添加 `pub const ucontext_opts = @import("builtin").root_module.ucontext_opts;`

## 测试验证

在 `src/ucontext_impl.zig` 中添加单元测试，确保汇编实现与系统实现行为一致：

### 测试用例

1. **基本功能测试**
   - `test "getcontext basic"` - 验证 getcontext 能正确保存上下文
   - `test "setcontext basic"` - 验证 setcontext 能正确恢复并跳转
   - `test "makecontext basic"` - 验证 makecontext 能正确设置新上下文
   - `test "swapcontext basic"` - 验证 swapcontext 能正确保存和切换

2. **寄存器保存/恢复测试**
   - `test "register preservation"` - 验证所有通用寄存器（R8-R15, RAX-RDI, RBP）正确保存和恢复
   - `test "floating point preservation"` - 验证浮点寄存器（XMM0-XMM15, FPU状态）正确保存和恢复
   - `test "stack pointer preservation"` - 验证栈指针正确保存和恢复

3. **函数调用测试**
   - `test "makecontext with arguments"` - 验证 makecontext 能正确处理参数传递（0-6个参数）
   - `test "context_entry_wrapper"` - 验证协程入口包装函数正确调用目标函数

4. **上下文链接测试**
   - `test "uc_link chain"` - 验证 uc_link 机制，协程返回后能正确切换到链接上下文

5. **栈对齐测试**
   - `test "stack alignment"` - 验证栈指针始终满足 16 字节对齐要求

6. **与系统实现对比测试**
   - `test "compatibility with system ucontext"` - 运行相同测试用例，对比两种实现的行为一致性
   - 使用编译开关切换实现，验证两种实现都能通过相同测试

### 测试结构

```zig
// 在 ucontext_impl.zig 末尾添加测试代码
const std = @import("std");
const testing = std.testing;
const c = @import("./c.zig");

test "getcontext basic" {
    var ctx: c.ucontext_t = undefined;
    try testing.expectEqual(0, c.getcontext(&ctx));
    // 验证上下文已保存
}

test "register preservation" {
    // 寄存器保存测试
}

// ... 其他测试
```

测试需要在两种编译选项下都能通过，确保实现正确性。

## 使用方式

### 默认使用系统实现

```bash
zig build
```

### 使用汇编实现

```bash
zig build -Duse_custom_ucontext=true
```

### 用户代码

用户只需导入 `c.zig`，无需关心底层实现：

```zig
const c = @import("zco").c;

var ctx: c.ucontext_t = undefined;
_ = c.getcontext(&ctx);
// ...
```

## 实现待办

- [ ] 创建 `src/ucontext_impl.zig`，实现 getcontext/setcontext/makecontext/swapcontext 的汇编版本
- [ ] 修改 `build.zig` 添加 `use_custom_ucontext` 编译选项并传递给模块
- [ ] 修改 `src/root.zig` 导出编译选项给 `c.zig` 使用
- [ ] 修改 `src/c.zig` 根据编译选项条件导入汇编实现或使用系统实现
- [ ] 添加完整的单元测试验证正确性

## 参考资源

- [libco 源码](https://github.com/Tencent/libco)
- [System V ABI - AMD64](https://www.uclibc.org/docs/psABI-x86_64.pdf)
- [FXSAVE/FXRSTOR Instruction](https://www.intel.com/content/www/us/en/develop/documentation/xed-user-guide/top/save-restore-x87-fpu-mmx-sse-state.html)
- [Linux ucontext Manual](https://man7.org/linux/man-pages/man3/getcontext.3.html)

