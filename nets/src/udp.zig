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
    pub fn deinit(self: *Self) void {
        const allocator = self.schedule.allocator;
        allocator.destroy(self);
    }

    /// 绑定地址到 UDP socket
    pub fn bind(self: *Self, address: std.net.Address) !void {
        const xobj = try zco.xev.UDP.init(address);
        try xobj.bind(address);
        self.xobj = xobj;
    }

    /// 异步读取 UDP 数据（带地址信息）
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { data: []u8, addr: std.net.Address } {
        const xobj = self.xobj orelse return error.NotInit;
        
        std.log.debug("UDP.recvFrom: 开始接收，检查协程环境...", .{});
        
        // UDP State 需要初始化 op 字段，这里初始化为 recv 操作
        var state: zco.xev.UDP.State = undefined;
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
                    const _r = ud orelse unreachable;
                    _r.addr = addr;
                    _r.size = r;
                    std.log.debug("UDP.recvFrom callback: 收到数据，恢复协程", .{});
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
                    const _r = ud orelse unreachable;
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
            const loop = &(self.schedule.xLoop orelse unreachable);
            var c_close = zco.xev.Completion{};
            const co: *zco.Co = self.schedule.runningCo orelse unreachable;

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
                    const _r = ud orelse unreachable;
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
        }
    }
};
