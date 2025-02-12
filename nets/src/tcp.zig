const std = @import("std");
const zco = @import("zco");
const xev = @import("xev");
const io = @import("io");

pub const Tcp = struct {
    const Self = @This();

    xobj: ?xev.TCP = null,
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
        const allocator = self.schedule.allocator;
        allocator.destroy(self);
    }
    pub fn bind(self: *Self, address: std.net.Address) !void {
        const xobj = try xev.TCP.init(address);
        try xobj.bind(address);
        self.xobj = xobj;
    }
    pub fn accept(self: *Self) !*Tcp {
        const xobj = self.xobj orelse return error.NotInit;
        var c_accept = xev.Completion{};
        const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
        const Result = struct {
            co: *zco.Co,
            clientConn: xev.AcceptError!xev.TCP = undefined,
        };

        var result: Result = .{
            .co = co,
        };
        xobj.accept(&(self.schedule.xLoop.?), &c_accept, Result, &result, (struct {
            fn callback(
                ud: ?*Result,
                _: *xev.Loop,
                _: *xev.Completion,
                r: xev.AcceptError!xev.TCP,
            ) xev.CallbackAction {
                const _r = ud orelse unreachable;
                _r.clientConn = r;
                std.log.debug("tcp accept callback", .{});
                _r.co.Resume() catch |e| {
                    std.log.err("nets tcp accept ResumeCo error:{s}", .{@errorName(e)});
                };
                return .disarm;
            }
        }).callback);
        try co.Suspend();
        const clientConn = try result.clientConn;
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

    pub usingnamespace io.CreateIo(Tcp);
};
