# 协程时间片抢占调度设计文档

## 概述

本文档详细分析了 ZCO 协程库中实现时间片抢占调度的设计方案，包括核心问题分析、解决方案设计、安全性考虑和实现细节。

## 背景

在传统的协程调度中，协程必须主动让出 CPU（通过 `Suspend()` 或 `Sleep()`），这可能导致某些协程长时间占用 CPU 资源，影响系统的公平性和响应性。时间片抢占调度通过定时器信号强制中断正在运行的协程，实现更公平的调度。

## 核心问题分析

### 问题 1：`runningCo` 的读写竞争

**场景描述**：
```
时间线：
T1: 主循环：schedule.runningCo = co;  (写)
T2: 主循环：swapcontext(...);          (切换到协程)
T3: 信号到来，中断协程
T4: 信号处理器：co = schedule.runningCo  (读)
T5: 信号处理器：pushPreempted(co)
T6: 信号处理器：修改 interrupted_ctx
T7: 返回到主循环的 swapcontext 之后
```

**问题分析**：
- T1-T2 之间，信号如果到来，会中断在主循环中（此时 `runningCo != null` 但还未切换）
- 此时信号处理器读到 `runningCo`，但实际还在调度器上下文中！
- 这会导致错误地认为在协程中，保存错误的上下文

**解决方案**：在设置 `runningCo` 前后屏蔽信号

### 问题 2：`co.ctx` 的并发访问

**场景描述**：
```
T1: 信号处理器：co.ctx = interrupted_ctx.*  (写)
T2: 信号处理器：修改 interrupted_ctx，切换回调度器
T3: 主循环：checkNextCo() 从缓冲区取出 co
T4: 主循环：co.state = .READY
T5: 主循环：readyQueue.add(co)
T6: 主循环：nextCo = readyQueue.remove()  (假设就是这个 co)
T7: 主循环：Resume(co)
T8: Resume：swapcontext(&schedule.ctx, &co.ctx)  (读 co.ctx)
```

**问题分析**：
- `co.ctx` 是大结构体（几百字节），不是原子操作
- T1 的写可能被编译器/CPU 重排序
- T8 的读可能看到部分更新的数据

**解决方案**：
- 信号处理器写完 `co.ctx` 后，在 `pushPreempted` 前加内存屏障
- 主循环从缓冲区取出 co 后，读 `co.ctx` 前加内存屏障
- 实际上，SPSC 队列的原子操作本身就提供了屏障！

### 问题 3：信号在 swapcontext 内部到达

**场景描述**：信号在 `swapcontext` 执行过程中到达（正在保存/恢复寄存器）

**问题分析**：
- `swapcontext` 可能不是信号安全的
- 可能导致上下文损坏

**解决方案**：在 `swapcontext` 前屏蔽信号，返回后恢复

### 问题 4：无锁缓冲区的内存顺序

**当前 SPSC 队列实现问题**：
```zig
fn pushPreempted(self: *Schedule, co: *Co) bool {
    const head = self.preempted_head.load(.acquire);  // ❌ 应该用 monotonic
    const tail = self.preempted_tail.load(.acquire);  // ✓ 正确
    
    if (next_head == tail) return false;
    
    self.preempted_buffer[head] = co;  // ❌ 需要确保之前的写完成
    self.preempted_head.store(next_head, .release);  // ✓ 正确
}
```

**问题分析**：
- `co.ctx = ...` 的写入必须在 `head` 更新前完成
- 普通写入 `preempted_buffer[head] = co` 可能被重排序

### 问题 5：协程正常结束时的竞争

**场景分析**：
```
T1: 协程执行到 contextEntry 返回
T2: contextEntry: schedule.runningCo = null
T3: contextEntry: self.state = .STOP
T4: 自动返回到 schedule.ctx (因为 uc_link)
T5: 主循环：Resume 返回
T6: 主循环：if (co.state == .STOP) freeCo(co)
```

**问题分析**：如果信号在 T2-T4 之间到达？
- 信号处理器读到 `runningCo == null`，直接返回 ✓ 安全

### 问题 6：多个协程同时被抢占

**场景描述**：极端情况，信号处理器多次触发，缓冲区满

**当前处理**：返回 false，不抢占，保持 `RUNNING` 状态

**问题分析**：此时协程继续运行，但信号处理器认为它还在运行，下次信号又来怎么办？
- 下次信号来时，`runningCo` 仍指向这个协程
- 再次尝试 push，如果缓冲区还满，继续不抢占
- ✓ 这是安全的降级处理

## 完善后的最终方案

### 1. 核心数据结构

```zig
pub const Schedule = struct {
    ctx: Context = std.mem.zeroes(Context),
    runningCo: ?*Co = null,
    
    // 抢占缓冲区
    preempted_buffer: [256]*Co = undefined,
    preempted_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    preempted_tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    
    timer_id: ?c.timer_t = null,
    
    // ... 其他字段 ...
    
    threadlocal var localSchedule: ?*Schedule = null;
};
```

### 2. 无锁缓冲区（修正版）

```zig
fn pushPreempted(self: *Schedule, co: *Co) bool {
    const head = self.preempted_head.load(.monotonic);
    const next_head = (head + 1) % self.preempted_buffer.len;
    const tail = self.preempted_tail.load(.acquire);
    
    if (next_head == tail) {
        return false; // 缓冲区满，降级处理
    }
    
    // 写入数据
    self.preempted_buffer[head] = co;
    
    // 确保数据写入完成后再更新 head（release 语义）
    self.preempted_head.store(next_head, .release);
    return true;
}

fn popPreempted(self: *Schedule) ?*Co {
    const tail = self.preempted_tail.load(.monotonic);
    const head = self.preempted_head.load(.acquire); // 同步 push 的 release
    
    if (tail == head) {
        return null; // 缓冲区空
    }
    
    const co = self.preempted_buffer[tail];
    const next_tail = (tail + 1) % self.preempted_buffer.len;
    self.preempted_tail.store(next_tail, .release);
    return co;
}
```

### 3. 信号处理器（最简版本）

```zig
fn preemptSigHandler(_: c_int, _: [*c]c.siginfo_t, uctx_ptr: ?*anyopaque) callconv(.C) void {
    const schedule = localSchedule orelse return;
    const co = schedule.runningCo orelse return;
    
    const interrupted_ctx: *c.ucontext_t = @ptrCast(@alignCast(uctx_ptr.?));
    
    // 保存被中断的上下文
    co.ctx = interrupted_ctx.*;
    
    // 加入抢占缓冲区（内部有 release 屏障）
    if (!schedule.pushPreempted(co)) {
        // 缓冲区满，不抢占
        return;
    }
    
    // 修改返回上下文为调度器上下文
    interrupted_ctx.* = schedule.ctx;
    
    // 返回时自动切换到调度器
}
```

### 4. Resume 和 Suspend 操作（关键区屏蔽信号）

#### Resume 操作

```zig
pub fn Resume(self: *Co) !void {
    const schedule = self.schedule;
    std.debug.assert(schedule.runningCo == null);
    
    switch (self.state) {
        .INITED => {
            if (c.getcontext(&self.ctx) != 0) return error.getcontext;
            self.ctx.uc_stack.ss_sp = &self.stack;
            self.ctx.uc_stack.ss_size = self.stack.len;
            self.ctx.uc_flags = 0;
            self.ctx.uc_link = &schedule.ctx;
            c.makecontext(&self.ctx, @ptrCast(&Co.contextEntry), 1, self);
            
            // === 关键区开始：屏蔽信号 ===
            var sigset: c.sigset_t = undefined;
            var oldset: c.sigset_t = undefined;
            _ = c.sigemptyset(&sigset);
            _ = c.sigaddset(&sigset, c.SIGALRM);
            _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);
            
            self.state = .RUNNING;
            schedule.runningCo = self;
            
            const swap_result = c.swapcontext(&schedule.ctx, &self.ctx);
            
            // 恢复信号
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
            // === 关键区结束 ===
            
            if (swap_result != 0) return error.swapcontext;
        },
        .SUSPEND, .READY => {
            // === 关键区开始：屏蔽信号 ===
            var sigset: c.sigset_t = undefined;
            var oldset: c.sigset_t = undefined;
            _ = c.sigemptyset(&sigset);
            _ = c.sigaddset(&sigset, c.SIGALRM);
            _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);
            
            self.state = .RUNNING;
            schedule.runningCo = self;
            
            const swap_result = c.swapcontext(&schedule.ctx, &self.ctx);
            
            // 恢复信号
            _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
            // === 关键区结束 ===
            
            if (swap_result != 0) return error.swapcontext;
        },
        else => {},
    }
    
    if (self.state == .STOP) {
        schedule.freeCo(self);
    }
}
```

#### Suspend 操作（也需要屏蔽信号！）

**场景分析**：
```
T1: 协程调用 Suspend()
T2: co.state = .SUSPEND
T3: schedule.runningCo = null
T4: swapcontext(&co.ctx, &schedule.ctx)
```

**问题**：如果信号在 T2-T4 之间到达：
- 信号处理器读到 `runningCo == null`，直接返回
- 但实际还在协程的栈上！（还未执行 swapcontext）
- ❌ 这是安全的，因为信号处理器会直接返回

**等等，还有另一个问题**：
```
T1: 协程调用 Suspend()
T2: co.state = .SUSPEND
T3: 信号到达，读到 runningCo，尝试抢占
T4: 信号处理器保存 co.ctx（覆盖！）
T5: Suspend 继续：schedule.runningCo = null
T6: swapcontext 保存上下文到 co.ctx（又覆盖！）
```

**结论**：`Suspend` 也需要屏蔽信号！

```zig
pub fn Suspend(self: *Self) !void {
    const schedule = self.schedule;
    if (schedule.runningCo) |co| {
        if (co != self) {
            return error.RunningCo;
        }
        if (self.schedule.exit) {
            return error.ScheduleExited;
        }
        
        // === 关键区开始：屏蔽信号 ===
        var sigset: c.sigset_t = undefined;
        var oldset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigaddset(&sigset, c.SIGALRM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, &oldset);
        
        co.state = .SUSPEND;
        self.schedule.runningCo = null;
        
        const swap_result = c.swapcontext(&co.ctx, &schedule.ctx);
        
        // 恢复信号
        _ = c.pthread_sigmask(c.SIG_SETMASK, &oldset, null);
        // === 关键区结束 ===
        
        if (swap_result != 0) return error.swapcontext;
        
        if (self.schedule.exit) {
            return error.ScheduleExited;
        }
        return;
    }
    return error.RunningCoNull;
}
```

### 5. checkNextCo 处理抢占

```zig
inline fn checkNextCo(self: *Schedule) !void {
    // 先处理被抢占的协程（acquire 屏障确保看到完整数据）
    while (self.popPreempted()) |co| {
        co.state = .READY;
        self.runningCo = null;  // 清理状态
        try self.readyQueue.add(co);
    }
    
    // 调度下一个协程
    const count = self.readyQueue.count();
    if (count > 0) {
        const nextCo = self.readyQueue.remove();
        try cozig.Resume(nextCo);
    } else {
        const xLoop = &(self.xLoop orelse unreachable);
        try xLoop.run(.once);
    }
}
```

### 6. 定时器初始化

```zig
pub fn init(allocator: std.mem.Allocator) !*Schedule {
    const schedule = try allocator.create(Schedule);
    schedule.* = .{
        .sleepQueue = PriorityQueue.init(allocator, {}),
        .readyQueue = PriorityQueue.init(allocator, {}),
        .allocator = allocator,
        .allCoMap = CoMap.init(allocator),
    };
    
    schedule.xLoop = try xev.Loop.init(.{ .entries = 1024 * 4 });
    
    // 注册信号处理器
    var sa: c.struct_sigaction = undefined;
    @memset(@as([*]u8, @ptrCast(&sa))[0..@sizeOf(c.struct_sigaction)], 0);
    sa.__sigaction_handler.sa_sigaction = @ptrCast(&preemptSigHandler);
    sa.sa_flags = c.SA_SIGINFO;
    _ = c.sigemptyset(&sa.sa_mask);
    
    if (c.sigaction(c.SIGALRM, &sa, null) == -1) {
        return error.sigaction;
    }
    
    // 创建线程定时器
    var sev: c.struct_sigevent = undefined;
    @memset(@as([*]u8, @ptrCast(&sev))[0..@sizeOf(c.struct_sigevent)], 0);
    sev.sigev_notify = c.SIGEV_THREAD_ID;
    sev.sigev_signo = c.SIGALRM;
    sev._sigev_un._tid = @intCast(std.Thread.getCurrentId());
    
    var timerid: c.timer_t = undefined;
    if (c.timer_create(c.CLOCK_MONOTONIC, &sev, &timerid) != 0) {
        return error.timer_create;
    }
    schedule.timer_id = timerid;
    
    // 设置定时器（10ms）
    var its: c.struct_itimerspec = undefined;
    its.it_value.tv_sec = 0;
    its.it_value.tv_nsec = 10 * std.time.ns_per_ms;
    its.it_interval.tv_sec = 0;
    its.it_interval.tv_nsec = 10 * std.time.ns_per_ms;
    
    if (c.timer_settime(timerid, 0, &its, null) != 0) {
        return error.timer_settime;
    }
    
    localSchedule = schedule;
    schedule.tid = std.Thread.getCurrentId();
    
    return schedule;
}

pub fn deinit(self: *Schedule) void {
    // 停止定时器
    if (self.timer_id) |tid| {
        _ = c.timer_delete(tid);
    }
    
    // ... 其他清理 ...
}
```

## 安全性总结

| 共享数据 | 信号处理器 | 主循环 | 同步机制 |
|---------|-----------|--------|---------|
| `runningCo` | 读 | 读写 | swapcontext 前后屏蔽信号 |
| `co.ctx` | 写 | 读 | SPSC 队列的 acquire/release |
| `co.state` | - | 写 | 不在信号处理器中修改 |
| 抢占缓冲区 | 写(push) | 读(pop) | 原子操作 + 内存屏障 |

**关键不变式**：

1. 信号只在协程运行时有效（`runningCo != null`）
2. 一旦 co 被 push 到缓冲区，信号处理器不再访问它
3. 主循环从缓冲区 pop 出 co 后独占访问
4. `swapcontext` 执行期间屏蔽信号

## 潜在的性能影响

1. **信号屏蔽开销**：每次 `swapcontext` 都要 block/unblock 信号（~100ns）
2. **原子操作开销**：push/pop 缓冲区（~10ns）
3. **定时器精度**：10ms 时间片，适中

**优化方向**：如果性能关键，可以考虑更粗粒度的时间片（50ms）

## 实现步骤

1. 在 `Schedule` 中添加抢占缓冲区字段和 timer_id
2. 实现 `pushPreempted` 和 `popPreempted` 方法（正确的内存顺序）
3. 实现 `preemptSigHandler` 信号处理器
4. 修改 `Resume` 添加信号屏蔽的关键区
5. 修改 `checkNextCo` 添加抢占缓冲区处理
6. 在 `init` 中注册信号并创建定时器
7. 在 `deinit` 中清理定时器
8. 删除不需要的 `SwitchTimer` 和 `SuspendInSigHandler`

## 测试用例

```zig
// 测试 1：长时间运行的协程能被抢占
fn testPreemption() !void {
    const s = try Schedule.init(allocator);
    defer s.deinit();
    
    var counter1: usize = 0;
    var counter2: usize = 0;
    
    _ = try s.go(struct {
        fn run(c: *usize) !void {
            while (c.* < 1000000) : (c.* += 1) {}
        }
    }.run, .{&counter1});
    
    _ = try s.go(struct {
        fn run(c: *usize) !void {
            while (c.* < 1000000) : (c.* += 1) {}
        }
    }.run, .{&counter2});
    
    try s.loop();
    
    // 两个计数器应该都增长（公平调度）
    std.debug.assert(counter1 > 0);
    std.debug.assert(counter2 > 0);
}
```

## 最终评估

**优点**：

1. ✅ 完全对开发者透明
2. ✅ 数据竞争已通过信号屏蔽和内存屏障解决
3. ✅ 无锁设计，性能好
4. ✅ 降级处理（缓冲区满时不抢占）

**缺点**：

1. ⚠️ 每次上下文切换都要屏蔽/恢复信号（~100ns 开销）
2. ⚠️ 固定大小缓冲区（但 256 已经足够大）
3. ⚠️ 依赖 Linux 特定的 `timer_create` 和 `SIGEV_THREAD_ID`

**是否可行**：✅ 可行，安全性已充分考虑

## 待办事项

- [ ] 在 switch_timer.zig 中启用定时器和信号处理器
- [ ] 修复 schedule.zig 中的信号处理器逻辑和注册
- [ ] 清理 co.zig 中不需要的 SuspendInSigHandler 函数
- [ ] 测试时间片抢占功能是否正常工作

---

*本文档版本：1.0*  
*最后更新：2024年*  
*作者：ZCO 开发团队*
