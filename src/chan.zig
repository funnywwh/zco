const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const Schedule = @import("./schedule.zig").Schedule;
const Co = @import("./co.zig").Co;

pub const Chan = CreateChan(*anyopaque);

pub fn CreateChan(DataType: type) type {
    return struct {
        const Self = @This();
        const Value = struct {
            value: DataType,
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

        pub fn init(s: *Schedule, bufCap: usize) !*Self {
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
            for (self.recvingQueue.items) |recvCo| {
                schedule.ResumeCo(recvCo) catch |e| {
                    std.log.err("Chan close coid:{d} ResumeCo error:{s}", .{ recvCo.id, @errorName(e) });
                };
            }
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.closed == true);
            self.valueQueue.clearAndFree();
            self.recvingQueue.clearAndFree();
            self.sendingQueue.clearAndFree();
            self.schedule.allocator.destroy(self);
        }

        fn removeInCoQueue(q: *CoQueue, co: *Co) void {
            // 要删除的 Co 指针
            const co_to_remove = co;

            // 删除所有等于 co_to_remove 的元素
            var i: usize = 0;
            while (i < q.items.len) : (i += 1) {
                if (q.items[i] == co_to_remove) {
                    // 删除当前元素，并将后续元素向前移动
                    _ = q.orderedRemove(i);
                    i -= 1; // 调整索引，因为后续元素向前移动了
                }
            }
        }
        pub fn isEmpty(self: *Self) bool {
            return self.valueQueue.items.len == 0;
        }
        pub fn send(self: *Self, data: DataType) !void {
            const schedule = self.schedule;
            const sendCo = try schedule.getCurrentCo();

            if (self.closed) {
                std.log.err("Chan send closed coid:{d}", .{sendCo.id});
                return error.sendClosed;
            }
            while (self.valueQueue.items.len >= self.bufferCap) {
                //缓冲区满等待空位
                try self.sendingQueue.append(sendCo);
                defer {
                    removeInCoQueue(&self.sendingQueue, sendCo);
                }
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
            if (self.bufferCap <= 0) {
                //非缓冲管道，发送方要阻塞
                //等待recver读完成
                try sendCo.Suspend();
            }
        }
        pub fn recv(self: *Self) !?DataType {
            const schedule = self.schedule;
            const recvCo = try schedule.getCurrentCo();

            while (self.valueQueue.items.len <= 0) {
                //没有数据可读
                try self.recvingQueue.append(recvCo);
                defer {
                    removeInCoQueue(&self.recvingQueue, recvCo);
                }
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
                if (self.bufferCap == 0) {
                    //非缓冲管道，发送方会阻塞，需要唤醒
                    try schedule.ResumeCo(val.co);
                }
                if (self.sendingQueue.items.len > 0) {
                    const sendCo = self.sendingQueue.orderedRemove(0);
                    try schedule.ResumeCo(sendCo);
                }
                return val.value;
            }
            return null;
        }
        pub fn len(self: *Chan) !usize {
            if (self.closed) return error.closed;
            return self.valueQueue.items.len;
        }
    };
}
