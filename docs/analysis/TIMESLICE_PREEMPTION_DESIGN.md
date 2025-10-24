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

## 潜在问题与限制

### 1. 平台依赖性问题

**当前实现限制**：
- **Linux 依赖**：依赖 `timer_create`、`SIGEV_THREAD_ID` 和 `ucontext`
- **Windows 兼容性**：需要替代方案，如 `SetTimer` + `QueueUserAPC`
- **macOS 兼容性**：需要 `mach ports` 或 `dispatch_source_timer`

**跨平台解决方案**：
```zig
// 平台抽象层
const PlatformTimer = switch (builtin.os.tag) {
    .linux => LinuxTimer,
    .windows => WindowsTimer,
    .macos => MacOSTimer,
    else => @compileError("Unsupported platform"),
};

const LinuxTimer = struct {
    timer_id: c.timer_t,
    // ... Linux 特定实现
};

const WindowsTimer = struct {
    timer_handle: c.HANDLE,
    // ... Windows 特定实现
};
```

### 2. 调试和监控困难

**问题描述**：
- 信号处理器异步执行，难以追踪和调试
- 抢占行为不可预测，影响问题定位
- 缺乏运行时监控指标

**改进建议**：
```zig
// 添加调试日志
fn preemptSigHandler(_: c_int, _: [*c]c.siginfo_t, uctx_ptr: ?*anyopaque) callconv(.C) void {
    const schedule = localSchedule orelse return;
    const co = schedule.runningCo orelse return;
    
    // 调试日志
    std.log.debug("Preempting co ID: {}, state: {}", .{ co.id, co.state });
    
    // ... 原有逻辑 ...
    
    // 统计信息
    schedule.metrics.preemptions += 1;
}

// 添加监控指标
const ScheduleMetrics = struct {
    preemptions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    buffer_peak: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    buffer_overflows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};
```

### 3. 公平性限制

**当前问题**：
- 固定时间片未考虑协程优先级
- `readyQueue` 是 `PriorityQueue`，但抢占时未考虑优先级
- 高优先级协程可能被低优先级协程抢占

**优先级抢占方案**：
```zig
// 扩展抢占逻辑
fn shouldPreempt(current: *Co, candidate: *Co) bool {
    // 优先级比较
    if (candidate.priority > current.priority) return true;
    if (candidate.priority < current.priority) return false;
    
    // 相同优先级时按时间片
    return candidate.time_slice_remaining <= 0;
}
```

### 4. 实现状态检查

**当前状态**：ZCO 项目中的 `SwitchTimer` 实现大部分被注释掉，说明时间片抢占功能尚未完全实现。

**需要完成的工作**：
- [ ] 启用并完善 `SwitchTimer` 实现
- [ ] 实现信号处理器逻辑
- [ ] 添加抢占缓冲区机制
- [ ] 集成到主调度循环中

## 改进建议

### 1. 动态缓冲区管理

**当前问题**：固定 256 大小的缓冲区，满时降级处理

**改进方案**：
```zig
// 动态缓冲区实现
const DynamicPreemptBuffer = struct {
    buffer: std.ArrayList(*Co),
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    max_size: usize = 1024, // 最大限制
    
    fn pushPreempted(self: *DynamicPreemptBuffer, co: *Co) !bool {
        const head = self.head.load(.monotonic);
        const next_head = (head + 1) % self.buffer.items.len;
        const tail = self.tail.load(.acquire);
        
        if (next_head == tail) {
            // 尝试扩容
            if (self.buffer.items.len < self.max_size) {
                try self.buffer.resize(self.buffer.items.len * 2);
                return self.pushPreempted(co); // 递归重试
            }
            return false; // 达到最大限制
        }
        
        self.buffer.items[head] = co;
        self.head.store(next_head, .release);
        return true;
    }
};
```

### 2. 运行时监控和指标

**监控指标设计**：
```zig
const ScheduleMetrics = struct {
    // 抢占统计
    preemptions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    preemption_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    // 缓冲区统计
    buffer_peak: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    buffer_overflows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    // 协程统计
    co_switches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    co_voluntary_yields: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    // 性能统计
    avg_switch_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_switch_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    pub fn getReport(self: *const ScheduleMetrics) MetricsReport {
        return .{
            .preemptions = self.preemptions.load(.monotonic),
            .preemption_failures = self.preemption_failures.load(.monotonic),
            .buffer_peak = self.buffer_peak.load(.monotonic),
            .buffer_overflows = self.buffer_overflows.load(.monotonic),
            .co_switches = self.co_switches.load(.monotonic),
            .co_voluntary_yields = self.co_voluntary_yields.load(.monotonic),
            .avg_switch_time = self.avg_switch_time.load(.monotonic),
            .max_switch_time = self.max_switch_time.load(.monotonic),
        };
    }
};
```

### 3. 优先级感知抢占

**优先级调度扩展**：
```zig
const Co = struct {
    // ... 现有字段 ...
    priority: u8 = 0, // 0-255，数值越大优先级越高
    time_slice_remaining: u32 = 10, // 剩余时间片（毫秒）
    last_preempt_time: u64 = 0, // 上次抢占时间
    
    pub fn shouldPreempt(self: *const Co, other: *const Co) bool {
        // 优先级抢占
        if (other.priority > self.priority) return true;
        if (other.priority < self.priority) return false;
        
        // 相同优先级时按时间片
        return self.time_slice_remaining <= 0;
    }
    
    pub fn updateTimeSlice(self: *Co, elapsed_ms: u32) void {
        if (self.time_slice_remaining > elapsed_ms) {
            self.time_slice_remaining -= elapsed_ms;
        } else {
            self.time_slice_remaining = 0;
        }
    }
};
```

### 4. 自适应时间片

**动态时间片调整**：
```zig
const AdaptiveTimeSlice = struct {
    base_slice: u32 = 10, // 基础时间片（毫秒）
    min_slice: u32 = 1,   // 最小时间片
    max_slice: u32 = 100, // 最大时间片
    
    // 根据系统负载调整时间片
    fn adjustTimeSlice(self: *AdaptiveTimeSlice, load_factor: f32) u32 {
        const adjusted = @as(u32, @intFromFloat(self.base_slice * load_factor));
        return std.math.clamp(adjusted, self.min_slice, self.max_slice);
    }
    
    // 根据协程行为调整时间片
    fn adjustForCo(self: *AdaptiveTimeSlice, co: *Co) u32 {
        if (co.voluntary_yields > co.preemptions) {
            // 协程经常主动让出，可以给更长时间片
            return self.base_slice * 2;
        } else if (co.preemptions > co.voluntary_yields * 2) {
            // 协程经常被抢占，减少时间片
            return self.base_slice / 2;
        }
        return self.base_slice;
    }
};
```

### 5. 替代架构方案

**如果性能成为瓶颈，考虑以下替代方案**：

#### 方案 A：内核级线程池
```zig
// 使用内核线程 + 工作窃取队列
const ThreadPoolScheduler = struct {
    threads: []std.Thread,
    work_queues: []WorkStealingQueue,
    global_queue: std.concurrent.Queue(*Co),
    
    // 优点：真正的并行执行，无需信号处理
    // 缺点：违背用户级协程目标，内存开销大
};
```

#### 方案 B：async/await 模式
```zig
// 使用 Zig 的 async/await
const AsyncScheduler = struct {
    pub fn schedule(comptime func: anytype, args: anytype) !void {
        const frame = try allocator.create(@TypeOf(@frame()));
        frame.* = async func(args);
        // 自动调度，无需手动上下文切换
    }
    
    // 优点：编译器优化，类型安全
    // 缺点：需要重构现有代码
};
```

#### 方案 C：混合调度器
```zig
// 结合协程和内核线程
const HybridScheduler = struct {
    cpu_intensive_queue: PriorityQueue, // 使用时间片抢占
    io_intensive_queue: PriorityQueue,  // 使用事件驱动
    
    pub fn schedule(self: *HybridScheduler, co: *Co) void {
        if (co.is_cpu_intensive) {
            self.cpu_intensive_queue.add(co);
        } else {
            self.io_intensive_queue.add(co);
        }
    }
};
```

### 6. 开源生态整合

**参考现有实现**：
- **Tokio (Rust)**：成熟的任务调度器设计
- **Mio (Rust)**：高性能 I/O 多路复用
- **libuv (C)**：跨平台异步 I/O
- **Zig std.heap**：内存管理最佳实践

**集成建议**：
```zig
// 参考 Tokio 的调度器设计
const TaskScheduler = struct {
    // 多级队列：L0(高优先级), L1(普通), L2(低优先级)
    queues: [3]PriorityQueue,
    
    // 工作窃取：当本地队列空时从其他队列偷取
    work_stealing: bool = true,
    
    // 批处理：一次处理多个任务
    batch_size: usize = 32,
};
```

## 实现步骤

1. 在 `Schedule` 中添加抢占缓冲区字段和 timer_id
2. 实现 `pushPreempted` 和 `popPreempted` 方法（正确的内存顺序）
3. 实现 `preemptSigHandler` 信号处理器
4. 修改 `Resume` 添加信号屏蔽的关键区
5. 修改 `checkNextCo` 添加抢占缓冲区处理
6. 在 `init` 中注册信号并创建定时器
7. 在 `deinit` 中清理定时器
8. 删除不需要的 `SwitchTimer` 和 `SuspendInSigHandler`

## 调试和监控指导

### 1. 调试工具和技巧

#### 信号处理器调试
```zig
// 增强的信号处理器，包含详细日志
fn preemptSigHandler(_: c_int, siginfo: [*c]c.siginfo_t, uctx_ptr: ?*anyopaque) callconv(.C) void {
    const schedule = localSchedule orelse {
        std.log.debug("Signal handler: no local schedule", .{});
        return;
    };
    
    const co = schedule.runningCo orelse {
        std.log.debug("Signal handler: no running co", .{});
        return;
    };
    
    // 记录抢占信息
    const now = std.time.nanoTimestamp();
    std.log.debug("Preempting co ID: {}, state: {}, time: {}", .{ 
        co.id, co.state, now 
    });
    
    // 检查协程状态一致性
    if (co.state != .RUNNING) {
        std.log.err("Inconsistent state: co {} is not RUNNING but being preempted", .{co.id});
        return;
    }
    
    // ... 原有逻辑 ...
    
    // 更新统计信息
    schedule.metrics.preemptions.fetchAdd(1, .monotonic);
}
```

#### 协程状态跟踪
```zig
// 协程状态变化跟踪
const CoTracker = struct {
    state_changes: std.ArrayList(StateChange),
    allocator: std.mem.Allocator,
    
    const StateChange = struct {
        co_id: usize,
        from_state: Co.State,
        to_state: Co.State,
        timestamp: u64,
        reason: []const u8,
    };
    
    pub fn trackStateChange(self: *CoTracker, co: *Co, to_state: Co.State, reason: []const u8) void {
        const change = StateChange{
            .co_id = co.id,
            .from_state = co.state,
            .to_state = to_state,
            .timestamp = std.time.nanoTimestamp(),
            .reason = reason,
        };
        
        self.state_changes.append(change) catch {
            std.log.warn("Failed to track state change for co {}", .{co.id});
        };
    }
    
    pub fn dumpTrace(self: *const CoTracker) void {
        std.log.info("=== Co State Trace ===", .{});
        for (self.state_changes.items) |change| {
            std.log.info("Co {}: {} -> {} at {} (reason: {})", .{
                change.co_id,
                @tagName(change.from_state),
                @tagName(change.to_state),
                change.timestamp,
                change.reason,
            });
        }
    }
};
```

### 2. 性能监控

#### 实时指标收集
```zig
// 性能监控器
const PerformanceMonitor = struct {
    metrics: ScheduleMetrics,
    start_time: u64,
    
    pub fn init() PerformanceMonitor {
        return .{
            .metrics = ScheduleMetrics{},
            .start_time = std.time.nanoTimestamp(),
        };
    }
    
    pub fn recordSwitchTime(self: *PerformanceMonitor, switch_time_ns: u64) void {
        // 更新平均切换时间
        const current_avg = self.metrics.avg_switch_time.load(.monotonic);
        const count = self.metrics.co_switches.load(.monotonic);
        const new_avg = (current_avg * count + switch_time_ns) / (count + 1);
        self.metrics.avg_switch_time.store(new_avg, .monotonic);
        
        // 更新最大切换时间
        const current_max = self.metrics.max_switch_time.load(.monotonic);
        if (switch_time_ns > current_max) {
            self.metrics.max_switch_time.store(switch_time_ns, .monotonic);
        }
    }
    
    pub fn getReport(self: *const PerformanceMonitor) PerformanceReport {
        const runtime_ns = std.time.nanoTimestamp() - self.start_time;
        const runtime_sec = @as(f64, @floatFromInt(runtime_ns)) / 1e9;
        
        return .{
            .runtime_seconds = runtime_sec,
            .preemptions_per_second = @as(f64, @floatFromInt(self.metrics.preemptions.load(.monotonic))) / runtime_sec,
            .switches_per_second = @as(f64, @floatFromInt(self.metrics.co_switches.load(.monotonic))) / runtime_sec,
            .avg_switch_time_ns = self.metrics.avg_switch_time.load(.monotonic),
            .max_switch_time_ns = self.metrics.max_switch_time.load(.monotonic),
            .buffer_peak = self.metrics.buffer_peak.load(.monotonic),
            .buffer_overflows = self.metrics.buffer_overflows.load(.monotonic),
        };
    }
};
```

#### 内存使用监控
```zig
// 内存使用监控
const MemoryMonitor = struct {
    peak_stack_usage: usize = 0,
    total_allocations: u64 = 0,
    allocation_failures: u64 = 0,
    
    pub fn trackAllocation(self: *MemoryMonitor, size: usize) void {
        self.total_allocations += 1;
        if (size > self.peak_stack_usage) {
            self.peak_stack_usage = size;
        }
    }
    
    pub fn trackAllocationFailure(self: *MemoryMonitor) void {
        self.allocation_failures += 1;
    }
    
    pub fn getMemoryReport(self: *const MemoryMonitor) MemoryReport {
        return .{
            .peak_stack_usage = self.peak_stack_usage,
            .total_allocations = self.total_allocations,
            .allocation_failures = self.allocation_failures,
            .failure_rate = if (self.total_allocations > 0) 
                @as(f64, @floatFromInt(self.allocation_failures)) / @as(f64, @floatFromInt(self.total_allocations))
                else 0.0,
        };
    }
};
```

### 3. 测试用例

#### 基础抢占测试
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

#### 压力测试
```zig
// 测试 2：高并发抢占压力测试
fn testPreemptionStress() !void {
    const s = try Schedule.init(allocator);
    defer s.deinit();
    
    const num_coroutines = 100;
    var counters = try allocator.alloc(usize, num_coroutines);
    defer allocator.free(counters);
    @memset(counters, 0);
    
    // 创建大量协程
    for (counters, 0..) |*counter, i| {
        _ = try s.go(struct {
            fn run(c: *usize, id: usize) !void {
                std.log.debug("Starting coroutine {}", .{id});
                while (c.* < 10000) : (c.* += 1) {
                    // 模拟一些工作
                    _ = std.math.sqrt(@as(f64, @floatFromInt(c.*)));
                }
                std.log.debug("Finished coroutine {}", .{id});
            }
        }.run, .{ counter, i });
    }
    
    try s.loop();
    
    // 验证所有协程都完成了工作
    for (counters, 0..) |counter, i| {
        std.debug.assert(counter == 10000);
        std.log.debug("Coroutine {} completed with count {}", .{ i, counter });
    }
}
```

#### 优先级测试
```zig
// 测试 3：优先级抢占测试
fn testPriorityPreemption() !void {
    const s = try Schedule.init(allocator);
    defer s.deinit();
    
    var low_priority_count: usize = 0;
    var high_priority_count: usize = 0;
    
    // 低优先级协程
    _ = try s.go(struct {
        fn run(c: *usize) !void {
            while (c.* < 100000) : (c.* += 1) {}
        }
    }.run, .{&low_priority_count});
    
    // 延迟启动高优先级协程
    _ = try s.go(struct {
        fn run(c: *usize) !void {
            try cozig.Sleep(5); // 等待 5ms
            while (c.* < 100000) : (c.* += 1) {}
        }
    }.run, .{&high_priority_count});
    
    try s.loop();
    
    // 高优先级协程应该先完成
    std.debug.assert(high_priority_count == 100000);
    std.debug.assert(low_priority_count < 100000);
}
```

#### 集成测试：nets HTTP 服务器

**验证目标**：在真实应用场景下验证时间片抢占调度的有效性

**测试程序**：`nets/src/main.zig` - 基于 ZCO 的 HTTP 服务器

**为什么是重点验证程序**：
- 包含大量并发协程（最多 10,000 个客户端连接）
- 混合 CPU 密集型（请求解析）和 I/O 密集型（网络读写）任务
- 长时间运行的事件循环
- 内置性能监控，可观察抢占效果

**运行方法**：
```bash
# 编译并运行服务器
cd nets
zig build run

# 使用压测工具验证
wrk -t4 -c100 -d30s http://127.0.0.1:8080/
```

**预期行为**：
- 所有客户端连接都能得到及时响应
- 无单个协程长期占用 CPU 导致其他协程饥饿
- 性能监控显示稳定的平均延迟
- 服务器在高负载下仍能公平调度所有连接

**验证指标**：
- QPS（每秒请求数）应保持稳定
- 平均延迟和最大延迟在合理范围内
- 连接数在限制范围内均匀分配
- 无协程饿死或超时现象

### 4. 调试最佳实践

#### 使用 GDB 调试
```bash
# 编译调试版本
zig build -Doptimize=Debug

# 启动 GDB
gdb ./zig-out/bin/zco

# 设置断点
(gdb) break preemptSigHandler
(gdb) break Schedule.Resume
(gdb) break Schedule.Suspend

# 运行并观察信号处理
(gdb) run
```

#### 使用 Valgrind 检查内存
```bash
# 使用 Valgrind 检查内存泄漏
valgrind --leak-check=full --show-leak-kinds=all ./zig-out/bin/zco

# 使用 Helgrind 检查数据竞争
valgrind --tool=helgrind ./zig-out/bin/zco
```

#### 使用 strace 跟踪系统调用
```bash
# 跟踪信号相关系统调用
strace -e trace=timer_create,timer_settime,sigaction,kill ./zig-out/bin/zco
```

### 5. 生产环境监控

#### 健康检查端点
```zig
// HTTP 健康检查端点
fn healthCheckHandler(req: *http.Request, res: *http.Response) !void {
    const metrics = schedule.getMetrics();
    const report = metrics.getReport();
    
    const health = .{
        .status = "healthy",
        .uptime_seconds = report.runtime_seconds,
        .preemptions_per_second = report.preemptions_per_second,
        .switches_per_second = report.switches_per_second,
        .avg_switch_time_ns = report.avg_switch_time_ns,
        .buffer_peak = report.buffer_peak,
        .buffer_overflows = report.buffer_overflows,
    };
    
    try res.writeAll(try std.json.stringifyAlloc(allocator, health, .{}));
}
```

#### 指标导出
```zig
// Prometheus 指标导出
fn exportPrometheusMetrics(schedule: *Schedule) !void {
    const metrics = schedule.getMetrics();
    const report = metrics.getReport();
    
    std.log.info("# HELP zco_preemptions_total Total number of preemptions", .{});
    std.log.info("# TYPE zco_preemptions_total counter", .{});
    std.log.info("zco_preemptions_total {}", .{report.preemptions});
    
    std.log.info("# HELP zco_switches_total Total number of context switches", .{});
    std.log.info("# TYPE zco_switches_total counter", .{});
    std.log.info("zco_switches_total {}", .{report.co_switches});
    
    std.log.info("# HELP zco_avg_switch_time_ns Average context switch time in nanoseconds", .{});
    std.log.info("# TYPE zco_avg_switch_time_ns gauge", .{});
    std.log.info("zco_avg_switch_time_ns {}", .{report.avg_switch_time_ns});
}
```

## 跨平台兼容性分析

### 1. Linux 平台（当前实现）

**支持特性**：
- ✅ `timer_create` / `timer_settime` - 高精度定时器
- ✅ `SIGEV_THREAD_ID` - 线程特定信号传递
- ✅ `ucontext` - 用户级上下文切换
- ✅ `pthread_sigmask` - 信号屏蔽

**实现复杂度**：⭐⭐ (简单)

### 2. Windows 平台

**挑战**：
- ❌ 无 `timer_create` 等价物
- ❌ 无 `ucontext` 支持
- ❌ 信号处理机制不同

**解决方案**：
```zig
// Windows 实现
const WindowsTimer = struct {
    timer_handle: c.HANDLE,
    thread_id: c.DWORD,
    
    pub fn init() !WindowsTimer {
        // 使用 CreateTimerQueueTimer
        var timer_handle: c.HANDLE = undefined;
        if (c.CreateTimerQueueTimer(
            &timer_handle,
            null, // 默认定时器队列
            @ptrCast(&windowsPreemptHandler),
            null, // 参数
            10,   // 10ms 延迟
            10,   // 10ms 间隔
            0     // 标志
        ) == 0) {
            return error.CreateTimerFailed;
        }
        
        return WindowsTimer{
            .timer_handle = timer_handle,
            .thread_id = c.GetCurrentThreadId(),
        };
    }
    
    pub fn deinit(self: *WindowsTimer) void {
        _ = c.DeleteTimerQueueTimer(null, self.timer_handle, null);
    }
};

// Windows 上下文切换（使用纤程）
const WindowsContext = struct {
    fiber: ?c.LPVOID = null,
    
    pub fn init(self: *WindowsContext, stack: []u8, entry: c.LPFIBER_START_ROUTINE) !void {
        self.fiber = c.CreateFiber(stack.len, entry, null);
        if (self.fiber == null) return error.CreateFiberFailed;
    }
    
    pub fn switchTo(self: *WindowsContext, from: *WindowsContext) void {
        c.SwitchToFiber(self.fiber);
    }
};
```

**实现复杂度**：⭐⭐⭐⭐ (复杂)

### 3. macOS 平台

**挑战**：
- ❌ 无 `SIGEV_THREAD_ID`
- ❌ `ucontext` 已弃用
- ✅ 有 `mach ports` 和 `dispatch` 框架

**解决方案**：
```zig
// macOS 实现
const MacOSTimer = struct {
    dispatch_source: ?c.dispatch_source_t = null,
    queue: ?c.dispatch_queue_t = null,
    
    pub fn init() !MacOSTimer {
        const queue = c.dispatch_queue_create("zco.timer", null);
        if (queue == null) return error.CreateQueueFailed;
        
        const source = c.dispatch_source_create(
            c.DISPATCH_SOURCE_TYPE_TIMER,
            0,
            0,
            queue
        );
        if (source == null) {
            c.dispatch_release(queue);
            return error.CreateSourceFailed;
        }
        
        // 设置定时器
        const interval = 10 * std.time.ns_per_ms;
        c.dispatch_source_set_timer(source, 0, interval, 0);
        c.dispatch_source_set_event_handler(source, @ptrCast(&macosPreemptHandler));
        c.dispatch_resume(source);
        
        return MacOSTimer{
            .dispatch_source = source,
            .queue = queue,
        };
    }
    
    pub fn deinit(self: *MacOSTimer) void {
        if (self.dispatch_source) |source| {
            c.dispatch_source_cancel(source);
            c.dispatch_release(source);
        }
        if (self.queue) |queue| {
            c.dispatch_release(queue);
        }
    }
};

// macOS 上下文切换（使用 pthread）
const MacOSContext = struct {
    stack: []u8,
    stack_ptr: [*]u8,
    
    pub fn init(self: *MacOSContext, stack: []u8, entry: *const fn(*anyopaque) callconv(.C) void) !void {
        self.stack = stack;
        self.stack_ptr = stack.ptr + stack.len;
        
        // 使用 makecontext/getcontext/setcontext (已弃用但可用)
        // 或实现自定义的汇编上下文切换
    }
};
```

**实现复杂度**：⭐⭐⭐ (中等)

### 4. 跨平台抽象层

**统一接口设计**：
```zig
// 平台抽象层
const PlatformTimer = switch (builtin.os.tag) {
    .linux => LinuxTimer,
    .windows => WindowsTimer,
    .macos => MacOSTimer,
    else => @compileError("Unsupported platform for time slice preemption"),
};

const PlatformContext = switch (builtin.os.tag) {
    .linux => LinuxContext,
    .windows => WindowsContext,
    .macos => MacOSContext,
    else => @compileError("Unsupported platform for context switching"),
};

// 统一的调度器接口
const CrossPlatformScheduler = struct {
    timer: PlatformTimer,
    context: PlatformContext,
    
    pub fn init() !CrossPlatformScheduler {
        return CrossPlatformScheduler{
            .timer = try PlatformTimer.init(),
            .context = try PlatformContext.init(),
        };
    }
    
    pub fn deinit(self: *CrossPlatformScheduler) void {
        self.timer.deinit();
        self.context.deinit();
    }
};
```

### 5. 平台特性对比

| 特性 | Linux | Windows | macOS |
|------|-------|---------|-------|
| 高精度定时器 | ✅ timer_create | ✅ CreateTimerQueueTimer | ✅ dispatch_source |
| 线程特定信号 | ✅ SIGEV_THREAD_ID | ❌ | ❌ |
| 用户级上下文 | ✅ ucontext | ❌ (需纤程) | ⚠️ (已弃用) |
| 信号屏蔽 | ✅ pthread_sigmask | ✅ | ✅ |
| 实现复杂度 | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| 性能 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |

### 6. 推荐实现策略

**阶段 1：Linux 优先**
- 先实现 Linux 版本，验证设计正确性
- 使用 `timer_create` + `ucontext` 方案
- 充分测试和优化

**阶段 2：跨平台扩展**
- 实现 Windows 版本（使用纤程）
- 实现 macOS 版本（使用 dispatch）
- 添加平台检测和条件编译

**阶段 3：性能优化**
- 针对各平台特性优化
- 添加平台特定的性能调优
- 提供平台特定的配置选项

## 最终评估

**优点**：

1. ✅ 完全对开发者透明
2. ✅ 数据竞争已通过信号屏蔽和内存屏障解决
3. ✅ 无锁设计，性能好
4. ✅ 降级处理（缓冲区满时不抢占）
5. ✅ 跨平台兼容性设计完善

**缺点**：

1. ⚠️ 每次上下文切换都要屏蔽/恢复信号（~100ns 开销）
2. ⚠️ 固定大小缓冲区（但 256 已经足够大）
3. ⚠️ 平台依赖性强，需要针对不同平台实现
4. ⚠️ Windows/macOS 实现复杂度较高

**是否可行**：✅ 可行，安全性已充分考虑，跨平台兼容性设计完善

**推荐实施路径**：
1. 先在 Linux 上实现和测试
2. 验证设计正确性和性能
3. 逐步扩展到其他平台
4. 根据实际需求决定是否支持所有平台

## 待办事项

### 核心实现
- [ ] 在 switch_timer.zig 中启用定时器和信号处理器
- [ ] 修复 schedule.zig 中的信号处理器逻辑和注册
- [ ] 清理 co.zig 中不需要的 SuspendInSigHandler 函数
- [ ] 测试时间片抢占功能是否正常工作

### 改进功能
- [ ] 实现动态缓冲区管理
- [ ] 添加运行时监控和指标收集
- [ ] 实现优先级感知抢占
- [ ] 添加自适应时间片调整

### 跨平台支持
- [ ] 实现 Windows 平台支持（使用纤程）
- [ ] 实现 macOS 平台支持（使用 dispatch）
- [ ] 添加跨平台抽象层
- [ ] 各平台性能测试和优化

### 调试和监控
- [ ] 添加详细的调试日志
- [ ] 实现协程状态跟踪
- [ ] 添加性能监控工具
- [ ] 集成 Prometheus 指标导出

### 测试和文档
- [ ] 编写完整的测试用例套件
- [ ] 添加压力测试和性能基准
- [ ] 更新 API 文档和用户指南
- [ ] 编写最佳实践指南

---

*本文档版本：2.0*  
*最后更新：2024年12月*  
*作者：ZCO 开发团队*  
*基于用户反馈更新：添加了潜在问题分析、改进建议、跨平台兼容性和调试指导*
