const std = @import("std");
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
                const loop = &(s.xLoop orelse {
                    std.log.err("io {s} close: xLoop is null", .{SelfName});
                    return;
                });
                var c_close = zco.xev.Completion{};
                const co = s.runningCo orelse {
                    std.log.err("io {s} close: not in coroutine context", .{SelfName});
                    return;
                };
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
                        _: *zco.xev.Loop,
                        _: *zco.xev.Completion,
                        _: XObjType,
                        r: zco.xev.CloseError!void,
                    ) zco.xev.CallbackAction {
                        _ = r catch unreachable;
                        const _result = ud orelse {
                            std.log.err("io {s} callback: userdata is null", .{SelfName});
                            return .disarm;
                        };
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
            var c_read = zco.xev.Completion{};
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
                    _: *zco.xev.Loop,
                    _: *zco.xev.Completion,
                    _: XObjType,
                    _: zco.xev.ReadBuffer,
                    r: zco.xev.ReadError!usize,
                ) zco.xev.CallbackAction {
                    const _result = ud orelse {
                        std.log.err("io {s} callback: userdata is null", .{SelfName});
                        return .disarm;
                    };
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
            // 注意：Suspend() 返回后，调用栈可能已经很深
            const size_value = result.size catch |e| {
                return e;
            };
            return size_value;
        }
        pub fn write(self: *Self, buffer: []const u8) !usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_write = zco.xev.Completion{};
            const co: *zco.Co = self.schedule.runningCo orelse return error.CallInSchedule;
            // 使用栈上的局部变量保存结果，避免堆分配
            // 注意：result 在栈上，但在 Suspend() 返回后访问时，栈可能已经很深
            var result: anyerror!usize = undefined;
            const Result = struct {
                co: *zco.Co,
                result_ptr: *anyerror!usize,
            };
            var result_wrapper = Result{
                .co = co,
                .result_ptr = &result,
            };
            xobj.write(&self.schedule.xLoop.?, &c_write, .{ .slice = buffer }, Result, &result_wrapper, (struct {
                fn callback(
                    ud: ?*Result,
                    _: *zco.xev.Loop,
                    _: *zco.xev.Completion,
                    _: XObjType,
                    _: zco.xev.WriteBuffer,
                    r: zco.xev.WriteError!usize,
                ) zco.xev.CallbackAction {
                    const _result = ud orelse {
                        std.log.err("io {s} callback: userdata is null", .{SelfName});
                        return .disarm;
                    };
                    // 直接在回调函数中设置结果到栈上的局部变量
                    _result.result_ptr.* = r;
                    _result.co.Resume() catch |e| {
                        _result.result_ptr.* = e;
                        std.log.err("io {s} write Resume error:{s}", .{ SelfName, @errorName(e) });
                    };
                    return .disarm;
                }
            }).callback);
            try co.Suspend();
            // 注意：Suspend() 返回后，调用栈可能已经很深
            // 先展开错误联合体，避免在 return 语句中触发栈探测
            const size_value = result catch |e| {
                return e;
            };
            return size_value;
        }
        pub fn pread(self: *Self, buffer: []u8, offset: usize) anyerror!usize {
            const xobj = self.xobj orelse return error.NotInit;
            const XObjType = @TypeOf(xobj);
            var c_read = zco.xev.Completion{};
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
                    _: *zco.xev.Loop,
                    _: *zco.xev.Completion,
                    _: XObjType,
                    _: zco.xev.ReadBuffer,
                    r: zco.xev.ReadError!usize,
                ) zco.xev.CallbackAction {
                    const _result = ud orelse {
                        std.log.err("io {s} callback: userdata is null", .{SelfName});
                        return .disarm;
                    };
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
            var c_write = zco.xev.Completion{};
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
                    _: *zco.xev.Loop,
                    _: *zco.xev.Completion,
                    _: XObjType,
                    _: zco.xev.WriteBuffer,
                    r: zco.xev.WriteError!usize,
                ) zco.xev.CallbackAction {
                    const _result = ud orelse {
                        std.log.err("io {s} callback: userdata is null", .{SelfName});
                        return .disarm;
                    };
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
