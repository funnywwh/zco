const std = @import("std");
const xev = @import("xev");
const zco = @import("zco");

pub fn CreateIo(IOType: type) type {
    return struct {
        schedule: *zco.Schedule,
        const Self = IOType;
        const SelfName = @typeName(IOType);

        pub fn close(self: *Self) void {
            if (self.xobj) |xobj| {
                const XObjType = @TypeOf(xobj);
                const s = self.schedule;
                const loop = &(s.xLoop orelse unreachable);
                var c_close = xev.Completion{};
                const co: *zco.Co = self.schedule.runningCo orelse unreachable;
                const Result = struct {
                    co: *zco.Co,
                    size: anyerror!usize = 0,
                };
                var result: Result = .{
                    .co = co,
                };
                xobj.close(loop, &c_close, Result, &result, struct {
                    fn callback(
                        ud: ?*Result,
                        _: *xev.Loop,
                        _: *xev.Completion,
                        _: XObjType,
                        r: xev.CloseError!void,
                    ) xev.CallbackAction {
                        _ = r catch unreachable;
                        const _result = ud orelse unreachable;
                        std.log.debug("io {s} closed", .{SelfName});
                        _result.co.Resume() catch |e| {
                            std.log.err("io {s} close ResumeCo error:{s}", .{ SelfName, @errorName(e) });
                        };
                        return .disarm;
                    }
                }.callback);
                co.Suspend() catch |e| {
                    std.log.err("io {s} close Suspend error:{s}", .{ SelfName, @errorName(e) });
                };
                self.xobj = null;
            }
        }
        pub fn read(self: *Self, buffer: []u8) anyerror!usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_read = xev.Completion{};
            const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
            const Result = struct {
                co: *zco.Co,
                size: anyerror!usize = 0,
            };
            var result: Result = .{
                .co = co,
            };
            xobj.read(&(self.schedule.xLoop.?), &c_read, .{ .slice = buffer }, Result, &result, (struct {
                fn callback(
                    ud: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: XObjType,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const _result = ud orelse unreachable;
                    _result.size = r;
                    _result.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} read Resume error:{s}", .{ SelfName, @errorName(e) });
                        return .disarm;
                    };
                    return .disarm;
                }
            }).callback);
            try co.Suspend();
            return result.size;
        }
        pub fn write(self: *Self, buffer: []const u8) !usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_write = xev.Completion{};
            const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
            const Result = struct {
                co: *zco.Co,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .co = co,
            };
            xobj.write(&self.schedule.xLoop.?, &c_write, .{ .slice = buffer }, Result, &result, (struct {
                fn callback(
                    ud: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: XObjType,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    const _result = ud orelse unreachable;
                    _result.size = r;
                    _result.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} write Resume error:{s}", .{ SelfName, @errorName(e) });
                    };
                    return .disarm;
                }
            }).callback);
            try co.Suspend();
            return result.size;
        }
        pub fn pread(self: *Self, buffer: []u8, offset: usize) anyerror!usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_read = xev.Completion{};
            const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
            const Result = struct {
                co: *zco.Co,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .co = co,
            };
            xobj.pread(&(self.schedule.xLoop.?), &c_read, .{ .slice = buffer }, offset, Result, &result, (struct {
                fn callback(
                    ud: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: XObjType,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const _result = ud orelse unreachable;
                    _result.size = r;
                    _result.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} read Resume error:{s}", .{ SelfName, @errorName(e) });
                        return .disarm;
                    };
                    return .disarm;
                }
            }).callback);
            try co.Suspend();
            return result.size;
        }
        pub fn pwrite(self: *Self, buffer: []const u8, offset: usize) !usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_write = xev.Completion{};
            const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;

            const Result = struct {
                co: *zco.Co,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .co = co,
            };
            xobj.pwrite(&self.schedule.xLoop.?, &c_write, .{ .slice = buffer }, offset, Result, &result, (struct {
                fn callback(
                    ud: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: XObjType,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    const _result = ud orelse unreachable;
                    _result.size = r;
                    _result.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} write Resume error:{s}", .{ SelfName, @errorName(e) });
                    };
                    return .disarm;
                }
            }).callback);
            try co.Suspend();
            return result.size;
        }
    };
}
test "Type" {}
