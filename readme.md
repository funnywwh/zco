***

# Zco: Zig 协程，带时间片，优先级

[![GitHub](https://img.shields.io/github/stars/funnywwh/zco.svg?style=social)](https://github.com/funnywwh/zco)
[![License](https://img.shields.io/github/license/funnywwh/zco)](https://github.com/funnywwh/zco/blob/main/LICENSE)
[![GitHub Issues](https://img.shields.io/github/issues/funnywwh/zco)](https://github.com/funnywwh/zco/issues)

## 项目简介

`zco` 是一个用 Zig 编写的协程库，支持时间片调度和优先级机制。它旨在提供高效、灵活的协程管理功能，适用于需要高并发处理的应用场景。

## 特性

*   **时间片调度**：支持时间片调度机制，确保协程之间的公平调度。(未实现)
*   **优先级支持**：协程可以根据优先级进行调度，高优先级的协程会优先执行。
*   **轻量级**：协程的创建和切换开销极小，适合高并发场景。
*   **灵活的 API**：提供简单易用的 API，方便开发者快速上手。

## 安装

### 依赖

*   [Zig](https://ziglang.org/)：确保已安装最新版本的 Zig 编译器。

### 获取代码

```bash
git clone https://github.com/funnywwh/zco.git
cd zco
```

### 构建

```bash
zig build
```

### 在项目中使用

*   在build.zig.zon中添加依赖zco,libxev
```zig
.{
    .dependencies = .{
        .zco = .{
            .path = "../",
        },
        .io = .{
            .path = "../io",
        },
        .libxev = .{
            .path = "../vendor/libxev",//使用vendor中的libxev
        },
    },
}
```

*   在build.zig倒入包zco，xev
```zig
    const zco = b.dependency("zco", .{}).module("zco");
    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize }).module("xev");
    const io = b.dependency("io", .{ .target = target, .optimize = optimize }).module("io");

```
## 使用方法

### 简单的示例

```zig
const std = @import("std");
const zco = @import("zco");
pub fn main() !void {
    _ = try zco.loop(struct {
        fn run() !void {
            const s = try zco.getSchedule();
			std.log.debug("helloword!",.{});
            s.stop();
        }
    }.run, .{});
}
```

### 复杂点的示例代码

以下是一个简单的示例，展示如何使用 `zco` 创建和运行协程：

```zig
const std = @import("std");
const zco = @import("zco");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    _ = try schedule.go(struct {
        fn run(schedule: *zco.Schedule) !void {
			const co = try schedule.getCurrentCo();
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                std.log.info("Coroutine running: {}", .{i});
                try co.sleep(1000); // Sleep for 1 second
            }
        }
    }.run, .{schedule});

    try schedule.loop();
}
```

### Chan通道实例

```zig
const std = @import("std");
const zco = @import("zco");

pub fn main() !void {
    _ = try zco.loop(struct {
        fn run() !void {
            const s = try zco.getSchedule();
            const DataType = struct {
                name: []const u8,
                id: u32,
                age: u32,
            };
            const Chan = zco.CreateChan(DataType);
            const exitCh = try Chan.init(try zco.getSchedule(), 1);
            defer {
                exitCh.close();
                exitCh.deinit();
            }
            _ = try s.go(struct {
                fn run(ch: *Chan) !void {
                    const v = try ch.recv();
                    std.log.debug("recved:{any}", .{v});
                }
            }.run, .{exitCh});
            try exitCh.send(.{
                .name = "test",
                .age = 45,
                .id = 1,
            });
            s.stop();
        }
    }.run, .{});
}
```

### 构建和运行示例

```bash
zig build run
```

## API 文档

### `zco.newSchedule()`

创建一个新的协程调度器。

### `schedule.go(func, args)`

启动一个新的协程。

*   `func`：协程的入口函数。
*   `args`：传递给协程的参数。



### `schedule.loop()`

启动调度器的事件循环，开始处理协程。

## 贡献

欢迎贡献代码！请遵循以下步骤：

1.  **Fork** 项目到你的 GitHub 账号。
2.  创建一个新的分支：`git checkout -b feature/your-feature-name`
3.  提交你的更改：`git commit -m "Add some feature"`
4.  推送到你的分支：`git push origin feature/your-feature-name`
5.  创建一个新的 **Pull Request**

## 许可证

`zco` 采用 [MIT License](https://github.com/funnywwh/zco/blob/main/LICENSE)。

## 联系方式

*   GitHub: <https://github.com/funnywwh/zco>
*   Email: <your-email@example.com>

***

希望这份 `README.md` 能够满足你的需求！如果需要进一步调整或补充内容，请随时告诉我。
