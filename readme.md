***

# zco: Zig 协程库

类golang的channel

时间片和优先级尚未实现

[![GitHub](https://img.shields.io/github/stars/funnywwh/zco.svg?style=social)](https://github.com/funnywwh/zco)
[![License](https://img.shields.io/github/license/funnywwh/zco)](https://github.com/funnywwh/zco/blob/main/LICENSE)
[![GitHub Issues](https://img.shields.io/github/issues/funnywwh/zco)](https://github.com/funnywwh/zco/issues)

## 项目简介

`zco` 是一个用 Zig 编写的协程库，支持时间片调度和优先级机制。它旨在提供高效、灵活的协程管理功能，适用于需要高并发处理的应用场景。

## 📚 文档

详细的文档和性能测试报告请查看 [docs/](./docs/) 目录：

- **[性能对比报告](./docs/PERFORMANCE_COMPARISON_REPORT.md)** - ZCO vs Go HTTP服务器性能对比
- **[性能优化指南](./docs/PERFORMANCE_OPTIMIZATION_GUIDE.md)** - 详细的优化指南
- **[测试脚本](./docs/)** - 各种性能测试脚本

## 🚀 性能亮点

- **QPS**: 37,000 - 46,000 请求/秒
- **延迟**: 1.3 - 11.5 毫秒  
- **内存优化**: 协程栈大小仅8KB
- **零GC压力**: 无垃圾回收暂停
- **高并发稳定**: 支持500+并发连接，0%失败率

## 特性

*   **时间片调度**：支持时间片调度机制，确保协程之间的公平调度。(未实现)
*   **优先级支持**：协程可以根据优先级进行调度，高优先级的协程会优先执行。
*   **轻量级**：协程的创建和切换开销极小，适合高并发场景。
*   **灵活的 API**：提供简单易用的 API，方便开发者快速上手。


## 协程切换引擎
* ucontext

## 安装

### zig version

0.14.0-dev.3028+cdc9d65b0

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
                try co.Sleep(1*std.time.ns_per_s); // Sleep for 1 second
            }
        }
    }.run, .{schedule});

    try schedule.loop();
}
```

### 构建和运行示例

```bash
zig build run
```
### 自定义堆栈大小
在root包下定义
```zig
pub const DEFAULT_ZCO_STACK_SZIE = 1024 * 32;
```
## API 文档
###  zco

#### `fn loop(f: anytype, args: anytype) !void`

单协程模式简单创建一个主协程循环.

*   `func`：协程的入口函数。
*   `args`：传递给协程的参数。

#### `fn init(_allocator: std.mem.Allocator) !void`

初始化zco

#### `fn deinit() void`

退出前销毁zco数据


#### `fn newSchedule() !*Schedule`

创建一个新的协程调度器。

#### `fn getSchedule() !*Schedule`

获取主调度器

### Schedule

#### `fn init(allocator: std.mem.Allocator) !*Schedule`

调度器初始化


#### `fn go(self: *Schedule, comptime func: anytype, args: anytype) !*Co`

启动一个新的协程。

*   `func`：协程的入口函数。
*   `args`：传递给协程的参数。

#### `fn loop(self: *Schedule) !void `

启动调度器的事件循环，开始处理协程。

#### `fn stop(self: *Schedule) void`

退出调度器

#### `fn getCurrentCo(self: *Schedule) !*Co`

获取当前调度器下的当前协程

### Co 协程对象
#### `fn Suspend(self: *Self) !void`

睡眠主动让出cpu，只有外面才能唤醒

#### `fn Resume(self: *Co) !void`

其它协程中唤醒指定的协程,被唤醒的协程不是立即执行，只有放入调度器的就绪队列

当前协程Suspend后才可能被执行

#### `fn Sleep(self: *Self, ns: usize) !void`

休眠多少纳秒后被放入调度器的就绪队列

* `ns`: 休眠的纳秒数


### Chan

用于协程间通讯

支持多读多写

Chan关闭后 send,recv 回收到异常

send 只有等recv的协程成接受并休眠后，send 才会返回,因此可以发送局部变量

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
#### `fn CreateChan(DataType: type) type`

创建指定类型DataType的通道类型

#### `fn init(s: *Schedule, bufCap: usize) !*Self`

初始化化通道

* `bufCap`: 通道缓冲区大小，缓冲区满时send阻塞，空时recv阻塞
* `s`: 关联的调度器,不要混用

#### `fn deinit(self: *Self) void`

销毁通道,销毁前要close

#### `fn close(self: *Self) void `

关闭通道

send,recv，会返回异常,阻塞的协程会被唤醒

#### `fn send(self: *Self, data: DataType) !void`

发送数据,直到数据被接受协程处理完并Suspend

没有接收协程时，阻塞


* `data` 要发送的数据

#### `fn recv(self: *Self) !DataType`

接收数据，没有数据时阻塞


#### `fn len(self: *Self) !usize`

返回通道缓冲区数据长度(DataType的个数)


### io 

异步io，只能在协程里用

#### `fn CreateIo(IOType: type) type`

创建异步io的通用方法

*   `type`：io类

```zig
    const MyIo = struct {
        const Self = @This();
        schedule: *zco.Schedule,
        xobj: ?xev.File = null,
        pub usingnamespace io.CreateIo(Self);
    };
```

io的子类里必须要有的字段

* `xobj` 的libxev异步对象
* `schedule` 关联的调度器

#### `fn close(self: *Self) void`
关闭io

#### `fn read(self: *Self, buffer: []u8) anyerror!usize`

读取数据

* `buffer`: 数据缓冲区

* 返回读到的数据长度


#### `fn write(self: *Self, buffer: []const u8) !usize`

写数据
* `buffer`: 数据缓冲区
* 返回写成功的数据长度

#### `fn pread(self: *Self, buffer: []u8, offset: usize) anyerror!usize`

从offset开始读写，可以seek的io,如File
* `buffer`: 数据缓冲区
* `offset`：从0开始的偏移量
* 返回读到的长度

#### `fn pwrite(self: *Self, buffer: []const u8, offset: usize) !usize`

从指定位置开始写

* `buffer`: 数据缓冲区
* `offset`：从0开始的偏移量
* 返回写成功的长度

### Tcp

异步Tcp，继承CreateIo的方法

示例参考nets/src/main.zig

#### `fn bind(self: *Self, address: std.net.Address) !void`

绑定指定的ip,port

#### `fn listen(self: *Self, backlog: u31) !void`

开始监听链接

#### `fn accept(self: *Self) !*Tcp`

接收链接

### File 

异步文件，继承CreateIo的方法

示例参考nets/src/main.zig

#### `pub fn init(schedule: *zco.Schedule) !File`

初始化

#### `fn deinit(self: *Self) void`

销毁

#### `fn open(self: *Self, file: std.fs.File) !void`

打开文件

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
*   Email: <funnywwh@qq.com>

## 感谢
*   Libxev: <https://github.com/mitchellh/libxev>

***

希望这份 `README.md` 能够满足你的需求！如果需要进一步调整或补充内容，请随时告诉我。
