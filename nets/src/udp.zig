const std = @import("std");
const zco = @import("zco");
const io = @import("io");
const posix = std.posix;

/// UDP socket 实现，基于 libxev 异步 IO
pub const Udp = struct {
    const Self = @This();

    xobj: ?zco.xev.UDP = null,
    schedule: *zco.Schedule,

    pub const Error = anyerror;

    /// 创建新的 UDP socket
    pub fn init(schedule: *zco.Schedule) !*Udp {
        const udp = try schedule.allocator.create(Udp);
        udp.* = .{
            .schedule = schedule,
        };
        return udp;
    }

    /// 清理 UDP 资源
    /// 注意：此方法会销毁 UDP 对象本身，调用者需要确保不再使用此对象
    pub fn deinit(self: *Self) void {
        // 先关闭 socket（如果已绑定）
        if (self.xobj) |_| {
            self.close();
        }
        // 保存 allocator 引用（因为 self 即将被销毁）
        const allocator = self.schedule.allocator;
        allocator.destroy(self);
    }

    /// 绑定地址到 UDP socket
    pub fn bind(self: *Self, address: std.net.Address) !void {
        // 如果已经绑定，不允许重新绑定
        if (self.xobj != null) {
            std.log.warn("UDP.bind: Socket 已经绑定 (fd: {})，跳过重新绑定到 {}", .{ self.xobj.?.fd, address });
            return;
        }
        const xobj = try zco.xev.UDP.init(address);
        try xobj.bind(address);
        self.xobj = xobj;
        std.log.debug("UDP.bind: Socket 已绑定到 {} (fd: {})", .{ address, xobj.fd });
    }

    /// 获取实际绑定的地址和端口
    /// 使用 getsockname 系统调用获取 socket 的实际绑定地址
    pub fn getBoundAddress(self: *Self) !std.net.Address {
        const xobj = self.xobj orelse return error.NotInit;

        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        try posix.getsockname(xobj.fd, &addr, &addr_len);

        // 使用 initPosix 从 posix.sockaddr 创建 Address
        return std.net.Address.initPosix(@alignCast(&addr));
    }

    /// 异步读取 UDP 数据（带地址信息）
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { data: []u8, addr: std.net.Address } {
        const xobj = self.xobj orelse {
            std.log.err("UDP.recvFrom: xobj 为 null (socket 未初始化)", .{});
            return error.NotInit;
        };

        std.log.debug("UDP.recvFrom: 开始接收，检查协程环境... (socket fd: {})", .{xobj.fd});

        // UDP State 需要初始化 op 字段，这里初始化为 recv 操作
        // 注意：必须先设置 op = .{ .recv = undefined }，然后再设置完整结构
        var state: zco.xev.UDP.State = undefined;
        state.op = .{ .recv = undefined };
        state.userdata = null;
        state.op = .{
            .recv = .{
                .buf = .{ .slice = buffer },
                .addr_buffer = undefined,
                .msghdr = undefined,
                .iov = undefined,
            },
        };

        var c_read = zco.xev.Completion{};
        const co: *zco.Co = self.schedule.runningCo orelse {
            std.log.err("UDP.recvFrom: 不在协程环境中（runningCo 为 null）", .{});
            return error.CallInSchedule;
        };

        std.log.debug("UDP.recvFrom: 协程环境正常，开始异步接收...", .{});

        const Result = struct {
            co: *zco.Co,
            size: anyerror!usize = 0,
            addr: std.net.Address = undefined,
        };

        var result: Result = .{
            .co = co,
        };

        const xloop_ptr = if (self.schedule.xLoop) |*xloop| xloop else {
            std.log.err("UDP.recvFrom: xLoop 为 null", .{});
            return error.NoEventLoop;
        };

        std.log.debug("UDP.recvFrom: 调用 xobj.read", .{});

        xobj.read(
            xloop_ptr,
            &c_read,
            &state,
            .{ .slice = buffer },
            Result,
            &result,
            struct {
                fn callback(
                    ud: ?*Result,
                    _: *zco.xev.Loop,
                    _: *zco.xev.Completion,
                    _: *zco.xev.UDP.State,
                    addr: std.net.Address,
                    _: zco.xev.UDP,
                    _: zco.xev.ReadBuffer,
                    r: zco.xev.ReadError!usize,
                ) zco.xev.CallbackAction {
                    std.log.info("UDP.recvFrom callback: 回调被触发！地址: {}, 结果: {!}", .{ addr, r });
                    const _r = ud orelse {
                        std.log.err("UDP.recvFrom callback: userdata 为 null", .{});
                        return .disarm;
                    };
                    _r.addr = addr;
                    _r.size = r;

                    if (r) |size| {
                        std.log.info("UDP.recvFrom callback: 收到 {} 字节数据，恢复协程", .{size});
                    } else |err| {
                        std.log.err("UDP.recvFrom callback: 接收错误: {}", .{err});
                    }

                    _r.co.Resume() catch |e| {
                        std.log.err("nets udp recvFrom ResumeCo error:{s}", .{@errorName(e)});
                    };
                    return .disarm;
                }
            }.callback,
        );

        std.log.debug("UDP.recvFrom: 已注册到事件循环，准备挂起协程", .{});

        std.log.debug("UDP.recvFrom: 挂起协程，等待数据到达...", .{});
        try co.Suspend();
        const size = try result.size;

        std.log.debug("UDP.recvFrom: 收到数据，恢复协程 ({} 字节来自 {})", .{ size, result.addr });

        return .{
            .data = buffer[0..size],
            .addr = result.addr,
        };
    }

    /// 异步发送 UDP 数据到指定地址
    pub fn sendTo(self: *Self, buffer: []const u8, address: std.net.Address) !usize {
        // 验证地址有效性：端口不能为 0
        if (address.getPort() == 0) {
            std.log.err("UDP.sendTo: 无效的地址，端口为 0: {}", .{address});
            return error.InvalidAddress;
        }
        std.log.debug("UDP.sendTo: 发送 {} 字节到 {}", .{ buffer.len, address });
        const xobj = self.xobj orelse return error.NotInit;
        // UDP State 需要初始化 op 字段，这里初始化为 send 操作
        var state: zco.xev.UDP.State = undefined;
        state.userdata = null;
        state.op = .{
            .send = .{
                .buf = .{ .slice = buffer },
                .addr = address,
                .msghdr = undefined,
                .iov = undefined,
            },
        };

        var c_write = zco.xev.Completion{};
        const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;

        const Result = struct {
            co: *zco.Co,
            size: anyerror!usize = undefined,
        };

        var result: Result = .{
            .co = co,
        };

        xobj.write(
            &(self.schedule.xLoop.?),
            &c_write,
            &state,
            address,
            .{ .slice = buffer },
            Result,
            &result,
            struct {
                fn callback(
                    ud: ?*Result,
                    _: *zco.xev.Loop,
                    _: *zco.xev.Completion,
                    _: *zco.xev.UDP.State,
                    _: zco.xev.UDP,
                    _: zco.xev.WriteBuffer,
                    r: zco.xev.WriteError!usize,
                ) zco.xev.CallbackAction {
                    const _r = ud orelse {
                        std.log.err("nets udp sendTo callback: userdata is null", .{});
                        return .disarm;
                    };
                    _r.size = r;
                    _r.co.Resume() catch |e| {
                        std.log.err("nets udp sendTo ResumeCo error:{s}", .{@errorName(e)});
                    };
                    return .disarm;
                }
            }.callback,
        );

        try co.Suspend();
        const sent = try result.size;
        std.log.debug("UDP.sendTo: 已发送 {} 字节到 {}", .{ sent, address });
        return sent;
    }

    /// 关闭 UDP socket
    pub fn close(self: *Self) void {
        if (self.xobj) |xobj| {
            if (self.schedule.xLoop) |*loop| {
                var c_close = zco.xev.Completion{};
                const co = self.schedule.runningCo orelse {
                    std.log.err("nets udp close: not in coroutine context", .{});
                    return;
                };

                const Result = struct {
                    co: *zco.Co,
                    done: bool = false,
                };

                var result: Result = .{
                    .co = co,
                };

                xobj.close(loop, &c_close, Result, &result, struct {
                    fn callback(
                        ud: ?*Result,
                        _: *zco.xev.Loop,
                        _: *zco.xev.Completion,
                        _: zco.xev.UDP,
                        _: zco.xev.CloseError!void,
                    ) zco.xev.CallbackAction {
                        const _r = ud orelse {
                            std.log.err("nets udp close callback: userdata is null", .{});
                            return .disarm;
                        };
                        _r.done = true;
                        _r.co.Resume() catch |e| {
                            std.log.err("nets udp close ResumeCo error:{s}", .{@errorName(e)});
                        };
                        return .disarm;
                    }
                }.callback);

                co.Suspend() catch |e| {
                    std.log.err("nets udp close Suspend error:{s}", .{@errorName(e)});
                };

                self.xobj = null;
            } else {
                std.log.err("nets udp close: xLoop is null", .{});
            }
        }
    }
};
