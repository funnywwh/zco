const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const Schedule = @import("./schedule.zig").Schedule;
const Co = @import("./co.zig").Co;

pub const Chan = struct {
    const Self = @This();
    const Value = struct {
        value: *anyopaque,
        co: *Co,
    };
    const ValQueue = std.ArrayList(Value);
    const CoQueue = std.ArrayList(*Co);
    schedule: *Schedule,
    sendingQueue: CoQueue,
    recvingQueue: CoQueue,
    valueQueue: ValQueue,
    bufferCap: usize = 1,
    closed: bool = false,

    sendCount: usize = 0,
    recvCount: usize = 0,

    pub fn init(s: *Schedule, bufCap: usize) !*Self {
        std.debug.assert(bufCap > 0);
        const allocator = s.allocator;
        const self: *Self = try allocator.create(Self);
        self.* = .{
            .schedule = s,
            .sendingQueue = CoQueue.init(s.allocator),
            .recvingQueue = CoQueue.init(s.allocator),
            .valueQueue = ValQueue.init(s.allocator),
            .bufferCap = bufCap,
        };
        return self;
    }
    pub fn close(self: *Self) void {
        if (self.closed) return;
        const schedule = self.schedule;
        self.closed = true;
        //唤醒所有sender和recver
        for (self.sendingQueue.items) |sendCo| {
            schedule.ResumeCo(sendCo) catch |e| {
                std.log.err("Chan close coid:{d} ResumeCo error:{s}", .{ sendCo.id, @errorName(e) });
            };
        }
        self.sendingQueue.clearAndFree();
        for (self.recvingQueue.items) |recvCo| {
            schedule.ResumeCo(recvCo) catch |e| {
                std.log.err("Chan close coid:{d} ResumeCo error:{s}", .{ recvCo.id, @errorName(e) });
            };
        }
        self.recvingQueue.clearAndFree();
    }
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.closed);
        std.debug.assert(self.isEmpty());
        self.valueQueue.clearAndFree();
        self.schedule.allocator.destroy(self);
    }
    pub fn isEmpty(self: *Self) bool {
        return self.valueQueue.items.len == 0;
    }
    pub fn send(self: *Self, data: *anyopaque) !void {
        const schedule = self.schedule;
        const sendCo = try schedule.getCurrentCo();
        self.sendCount += 1;

        if (self.closed) {
            std.log.err("Chan send closed coid:{d}", .{sendCo.id});
            return error.sendClosed;
        }
        while (self.valueQueue.items.len >= self.bufferCap) {
            //缓冲区满等待空位
            try self.sendingQueue.append(sendCo);
            try sendCo.Suspend();
            if (self.closed) {
                return error.sendClosed;
            }
        }
        try self.valueQueue.append(.{
            .value = data,
            .co = sendCo,
        });
        if (self.recvingQueue.items.len > 0) {
            const recvCo = self.recvingQueue.orderedRemove(0);
            std.log.err("Chan send wakeup recv coid:{d}", .{recvCo.id});
            try schedule.ResumeCo(recvCo);
        }
        //等待recver读完成
        try sendCo.Suspend();
    }
    pub fn recv(self: *Self) !?*anyopaque {
        const schedule = self.schedule;
        const recvCo = schedule.runningCo orelse unreachable;

        while (self.valueQueue.items.len <= 0) {
            //没有数据可读
            try self.recvingQueue.append(recvCo);
            try recvCo.Suspend();
            //唤醒后要检测有没有可读数据
            //有可能已经被其它recver处理完了
            if (self.closed) {
                std.log.debug("Chan recv closed", .{});
                break;
            }
        }
        if (self.valueQueue.items.len > 0) {
            const val = self.valueQueue.orderedRemove(0);
            try schedule.ResumeCo(val.co);
            if (self.sendingQueue.items.len > 0) {
                const sendCo = self.sendingQueue.orderedRemove(0);
                try schedule.ResumeCo(sendCo);
            }
            return val.value;
        }
        return error.recvClosed;
    }
    pub fn len(self: *Chan) !usize {
        if (self.closed) return error.closed;
        return self.valueQueue.items.len;
    }
};

pub fn CreateChan(DataType: type) type {
    return struct {
        const Self = @This();
        chan: ?*Chan = null,
        pub fn init(s: *Schedule, bufCap: usize) !*Self {
            const allocator = s.allocator;
            const ch = try Chan.init(s, bufCap);
            errdefer ch.deinit();
            const o = try allocator.create(Self);
            o.* = .{
                .chan = ch,
            };
            return o;
        }
        pub fn deinit(self: *Self) void {
            const ch = self.chan orelse {
                std.log.err("chan not init", .{});
                return;
            };
            const allocator = ch.schedule.allocator;
            ch.deinit();
            allocator.destroy(self);
        }
        pub fn close(self: *Self) void {
            const chan = self.chan orelse {
                std.log.err("chan closed", .{});
                return;
            };
            chan.close();
        }
        pub fn send(self: *Self, data: DataType) !void {
            const ch = self.chan orelse return error.NotInit;
            try ch.send(@constCast(@ptrCast(&data)));
        }
        pub fn recv(self: *Self) !DataType {
            const ch = self.chan orelse return error.NotInit;
            const d = try ch.recv();
            const data: *DataType = @alignCast(@ptrCast(d));
            return data.*;
        }
        pub fn len(self: *Self) !usize {
            return self.len();
        }
    };
}
