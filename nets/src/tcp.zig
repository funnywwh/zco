const std = @import("std");
const zco = @import("zco");
const xev = @import("xev");

pub const Tcp = struct {
    const Self = @This();

    xtcp: ?xev.TCP = null,
    co: *zco.Co,
    allocator: std.mem.Allocator,

    pub const Error = error{
        NoError,
        NotInit,
        swapcontext,
        getcontext,
    } || xev.ReadError;
    pub fn init(allocator: std.mem.Allocator, co: *zco.Co) !Tcp {
        return .{
            .co = co,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        _ = self; // autofix
    }
    pub fn close(self: *Self) void {
        if (self.xtcp) |xtcp| {
            const s = self.co.schedule;
            const loop = &(s.xLoop orelse unreachable);
            var c_close = xev.Completion{};
            xtcp.close(loop, &c_close, Self, self, struct {
                fn callback(
                    ud: ?*Self,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: xev.TCP,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    const owner = ud orelse unreachable;
                    std.log.debug("Tcp closed", .{});
                    owner.co.Resume() catch |e| {
                        std.log.err("nets tcp close ResumeCo error:{s}", .{@errorName(e)});
                    };
                    return .disarm;
                }
            }.callback);
            self.co.Suspend() catch |e| {
                std.log.err("nets tcp close Suspend error:{s}", .{@errorName(e)});
            };
        }
    }
    pub fn bind(self: *Self, address: std.net.Address) !void {
        const xtcp = try xev.TCP.init(address);
        try xtcp.bind(address);
        self.xtcp = xtcp;
    }
    pub fn accept(self: *Self) !*Tcp {
        const xtcp = self.xtcp orelse return error.NotInit;
        var c_accept = xev.Completion{};
        const Result = struct {
            self: *Self,
            clientConn: xev.AcceptError!xev.TCP = undefined,
        };
        var result: Result = .{
            .self = self,
        };
        xtcp.accept(&(self.co.schedule.xLoop.?), &c_accept, Result, &result, (struct {
            fn callback(
                ud: ?*Result,
                _: *xev.Loop,
                _: *xev.Completion,
                r: xev.AcceptError!xev.TCP,
            ) xev.CallbackAction {
                const _r = ud orelse unreachable;
                _r.clientConn = r;
                _r.self.co.Resume() catch |e| {
                    std.log.err("nets tcp accept ResumeCo error:{s}", .{@errorName(e)});
                };
                return .disarm;
            }
        }).callback);
        try self.co.Suspend();
        const clientConn = try result.clientConn;
        const retTcp = try self.allocator.create(Tcp);
        retTcp.* = .{
            .xtcp = clientConn,
            .co = self.co,
            .allocator = self.allocator,
        };
        return retTcp;
    }
    pub fn listen(self: *Self, backlog: u31) !void {
        const xtcp = self.xtcp orelse return error.NotInit;
        return xtcp.listen(backlog);
    }

    pub fn read(self: *Self, buffer: []u8) Error!usize {
        const xtcp = self.xtcp orelse return error.NotInit;
        var c_read = xev.Completion{};
        const Result = struct {
            self: *Self,
            size: Error!usize = undefined,
        };
        var result: Result = .{
            .self = self,
        };
        xtcp.read(&(self.co.schedule.xLoop.?), &c_read, .{ .slice = buffer }, Result, &result, (struct {
            fn callback(
                ud: ?*Result,
                _: *xev.Loop,
                _: *xev.Completion,
                _: xev.TCP,
                _: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction {
                const _result = ud orelse unreachable;
                _result.size = r;
                _result.self.co.Resume() catch |e| {
                    _result.size = e;
                    std.log.err("nets Tcp read Resume error:{s}", .{@errorName(e)});
                    return .disarm;
                };
                return .disarm;
            }
        }).callback);
        try self.co.Suspend();
        return result.size;
    }
    pub fn write(self: *Self, buffer: []const u8) !usize {
        const xtcp = self.xtcp orelse return error.NotInit;
        var c_write = xev.Completion{};
        const Result = struct {
            self: *Self,
            size: anyerror!usize = undefined,
        };
        var result: Result = .{
            .self = self,
        };
        xtcp.write(&self.co.schedule.xLoop.?, &c_write, .{ .slice = buffer }, Result, &result, (struct {
            fn callback(
                ud: ?*Result,
                _: *xev.Loop,
                _: *xev.Completion,
                _: xev.TCP,
                _: xev.WriteBuffer,
                r: xev.WriteError!usize,
            ) xev.CallbackAction {
                const _result = ud orelse unreachable;
                _result.size = r;
                _result.self.co.Resume() catch |e| {
                    _result.size = e;
                    std.log.err("nets Tcp write Resume error:{s}", .{@errorName(e)});
                };
                return .disarm;
            }
        }).callback);
        try self.co.Suspend();
        return result.size;
    }
};
