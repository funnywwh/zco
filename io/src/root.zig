const std = @import("std");
const xev = @import("xev");
const zco = @import("zco");

pub fn CreateIo(IOType: type) type {
    return struct {
        const Self = IOType;
        const SelfName = @typeName(IOType);
        pub fn read(self: *Self, buffer: []u8) anyerror!usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_read = xev.Completion{};
            const Result = struct {
                self: *Self,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .self = self,
            };
            xobj.read(&(self.co.schedule.xLoop.?), &c_read, .{ .slice = buffer }, Result, &result, (struct {
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
                    _result.self.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} read Resume error:{s}", .{ SelfName, @errorName(e) });
                        return .disarm;
                    };
                    return .disarm;
                }
            }).callback);
            try self.co.Suspend();
            return result.size;
        }
        pub fn write(self: *Self, buffer: []const u8) !usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_write = xev.Completion{};
            const Result = struct {
                self: *Self,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .self = self,
            };
            xobj.write(&self.co.schedule.xLoop.?, &c_write, .{ .slice = buffer }, Result, &result, (struct {
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
                    _result.self.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} write Resume error:{s}", .{ SelfName, @errorName(e) });
                    };
                    return .disarm;
                }
            }).callback);
            try self.co.Suspend();
            return result.size;
        }
        pub fn pread(self: *Self, buffer: []u8, offset: usize) anyerror!usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_read = xev.Completion{};
            const Result = struct {
                self: *Self,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .self = self,
            };
            xobj.pread(&(self.co.schedule.xLoop.?), &c_read, .{ .slice = buffer }, offset, Result, &result, (struct {
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
                    _result.self.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} read Resume error:{s}", .{ SelfName, @errorName(e) });
                        return .disarm;
                    };
                    return .disarm;
                }
            }).callback);
            try self.co.Suspend();
            return result.size;
        }
        pub fn pwrite(self: *Self, buffer: []const u8, offset: usize) !usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_write = xev.Completion{};
            const Result = struct {
                self: *Self,
                size: anyerror!usize = undefined,
            };
            var result: Result = .{
                .self = self,
            };
            xobj.pwrite(&self.co.schedule.xLoop.?, &c_write, .{ .slice = buffer }, offset, Result, &result, (struct {
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
                    _result.self.co.Resume() catch |e| {
                        _result.size = e;
                        std.log.err("io {s} write Resume error:{s}", .{ SelfName, @errorName(e) });
                    };
                    return .disarm;
                }
            }).callback);
            try self.co.Suspend();
            return result.size;
        }
    };
}
test "Type" {}
