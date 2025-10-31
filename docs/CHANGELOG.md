# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2024-12-31

### Changed
- **ucontext 实现优化**: 移除 `getcontext` 和 `setcontext` 函数中的信号屏蔽处理
- **架构改进**: 信号掩码处理由调用者（调度器）统一管理，职责更清晰
- **性能优化**: 减少不必要的 `pthread_sigmask` 系统调用，提升上下文切换效率

### Technical Details
- `getcontext`: 仅清零 `uc_sigmask` 字段，不再调用 `pthread_sigmask`
- `setcontext`: 移除信号掩码恢复逻辑，由调用者在适当时机处理
- 调度器层已有完善的信号屏蔽机制（`blockPreemptSignals`/`restoreSignals`）
- 避免了重复的信号掩码操作，减少系统调用开销

### Documentation
- 完善了 `docs/UCONTEXT_IMPLEMENTATION.md` 实现文档
- 更新了 README 中的版本信息和特性说明

### Performance
- 上下文切换开销进一步降低（减少系统调用）
- 更清晰的代码架构，便于后续优化

## [0.3.1] - 2024-12-19

### Added
- 协程级定时器生命周期管理
- `stopTimer()` 方法用于停止定时器
- 定时器与协程运行状态完全绑定

### Changed
- 定时器启动逻辑从调度器级别改为协程级别
- 协程运行时启动定时器并重置计时
- 协程挂起时立即停止定时器
- 空闲时不运行定时器，节省CPU资源

### Performance
- 网络服务器性能提升 16-41%
- 低并发场景 RPS 提升 41% (25,970 → 36,593)
- 高并发场景 RPS 提升 16% (24,596 → 28,462)
- 响应时间全面改善 14-29%

### Technical Details
- 移除了 `timer_started` 全局状态标志
- 每个协程获得完整时间片（从0开始计时）
- 优化了信号处理开销
- 提高了CPU缓存局部性

## [0.2.2] - 2024-12-18

### Added
- 时间片抢占调度功能
- 基于 SIGALRM 信号的协程抢占机制
- 性能统计和监控功能

### Changed
- 协程调度器支持强制抢占
- 时间片设置为 10ms，平衡性能和公平性
- 优化了协程切换性能

## [0.2.1] - 2024-12-17

### Added
- 异步 I/O 支持
- 网络模块 (TCP 服务器/客户端)
- 文件 I/O 模块

### Changed
- 基于 libxev 的异步事件循环
- 协程与异步 I/O 集成

## [0.2.0] - 2024-12-16

### Added
- 通道 (Channel) 支持
- 等待组 (WaitGroup) 支持
- 协程睡眠功能

### Changed
- 完整的协程调度器实现
- 优先级队列调度

## [0.1.0] - 2024-12-15

### Added
- 基础协程实现
- 上下文切换机制
- 协程调度器
- 基本的协程生命周期管理
