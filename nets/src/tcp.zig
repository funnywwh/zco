const std = @import("std");
const zco = @import("zco");
const io = @import("io");
const posix = std.posix;

pub const Tcp = struct {
    const Self = @This();

    xobj: ?zco.xev.TCP = null,
    schedule: *zco.Schedule,

    pub const Error = anyerror;

    pub fn init(schedule: *zco.Schedule) !*Tcp {
        const tcp = try schedule.allocator.create(Tcp);
        tcp.* = .{
            .schedule = schedule,
        };
        return tcp;
    }
    pub fn deinit(self: *Self) void {
        // 注意：如果 xobj 存在，应该在调用 deinit 之前先调用 close()
        // 这里只负责销毁对象本身
        const allocator = self.schedule.allocator;
        allocator.destroy(self);
    }
    pub fn bind(self: *Self, address: std.net.Address) !void {
        const xobj = try zco.xev.TCP.init(address);
        try xobj.bind(address);
        self.xobj = xobj;
    }
    pub fn accept(self: *Self) !*Tcp {
        const xobj = self.xobj orelse return error.NotInit;
        var c_accept = zco.xev.Completion{};
        const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
        const Result = struct {
            co: *zco.Co,
            clientConn: zco.xev.AcceptError!zco.xev.TCP = undefined,
        };

        var result: Result = .{
            .co = co,
        };
        xobj.accept(&(self.schedule.xLoop.?), &c_accept, Result, &result, (struct {
            fn callback(
                ud: ?*Result,
                _: *zco.xev.Loop,
                _: *zco.xev.Completion,
                r: zco.xev.AcceptError!zco.xev.TCP,
            ) zco.xev.CallbackAction {
                const _r = ud orelse {
                    std.log.err("nets tcp accept callback: userdata is null", .{});
                    return .disarm;
                };
                _r.clientConn = r;
                _r.co.Resume() catch |e| {
                    std.log.err("nets tcp accept ResumeCo error:{s}", .{@errorName(e)});
                };
                return .disarm;
            }
        }).callback);
        try co.Suspend();
        const clientConn = try result.clientConn;

        // 设置TCP_NODELAY，禁用Nagle算法以降低延迟
        const nodelay: posix.socket_t = 1;
        const fd = if (@import("builtin").os.tag == .windows)
            @as(std.os.windows.ws2_32.SOCKET, @ptrCast(clientConn.fd))
        else
            clientConn.fd;

        // 设置TCP_NODELAY，性能优化
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(nodelay)) catch |e| {
            std.log.warn("Failed to set TCP_NODELAY: {s}", .{@errorName(e)});
        };

        const retTcp = try self.schedule.allocator.create(Tcp);
        retTcp.* = .{
            .xobj = clientConn,
            .schedule = co.schedule,
        };
        return retTcp;
    }
    pub fn listen(self: *Self, backlog: u31) !void {
        const xobj = self.xobj orelse return error.NotInit;
        return xobj.listen(backlog);
    }

    /// 连接到服务器（客户端连接）
    pub fn connect(self: *Self, address: std.net.Address) !void {
        // 如果已经有 xobj，先关闭
        if (self.xobj) |_| {
            self.close();
        }

        // 创建新的 TCP socket
        const xobj = try zco.xev.TCP.init(address);

        var c_connect = zco.xev.Completion{};
        const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
        const Result = struct {
            co: *zco.Co,
            result: zco.xev.TCP.ConnectError!void = undefined,
        };

        var result: Result = .{
            .co = co,
        };

        const xloop_ptr = if (self.schedule.xLoop) |*xloop| xloop else return error.NoEventLoop;
        xobj.connect(xloop_ptr, &c_connect, address, Result, &result, (struct {
            fn callback(
                ud: ?*Result,
                _: *zco.xev.Loop,
                _: *zco.xev.Completion,
                _: zco.xev.TCP,
                r: zco.xev.TCP.ConnectError!void,
            ) zco.xev.CallbackAction {
                const _r = ud orelse {
                    std.log.err("nets tcp connect callback: userdata is null", .{});
                    return .disarm;
                };
                _r.result = r;
                _r.co.Resume() catch |e| {
                    std.log.err("nets tcp connect ResumeCo error:{s}", .{@errorName(e)});
                };
                return .disarm;
            }
        }).callback);

        try co.Suspend();
        try result.result;

        // 设置 TCP_NODELAY，禁用 Nagle 算法以降低延迟
        const nodelay: posix.socket_t = 1;
        const fd = if (@import("builtin").os.tag == .windows)
            @as(std.os.windows.ws2_32.SOCKET, @ptrCast(xobj.fd))
        else
            xobj.fd;

        // 设置 TCP_NODELAY，性能优化
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(nodelay)) catch |e| {
            std.log.warn("Failed to set TCP_NODELAY: {s}", .{@errorName(e)});
        };

        self.xobj = xobj;
    }

    pub usingnamespace io.CreateIo(Tcp);
};
