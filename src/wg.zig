const std = @import("std");
const schedule_mod = @import("./schedule.zig");
const chan_mod = @import("./chan.zig");
const Co = @import("./co.zig").Co;
const Schedule = schedule_mod.Schedule;
const Chan = chan_mod.CreateChan(bool);

pub const WaitGroup = struct {
    const Self = @This();

    count: usize = 0,
    waitChn: *Chan,

    pub fn init(s: *Schedule) !Self {
        return .{
            .waitChn = try Chan.init(s, 1),
        };
    }
    pub fn deinit(self: *Self) void {
        self.waitChn.deinit();
    }
    pub fn add(self: *Self, count: usize) !void {
        self.count +|= count;
    }
    pub fn done(self: *Self) void {
        std.debug.assert(self.count > 0);
        self.count -|= 1;
        if (self.count == 0) {
            // 所有协程都完成了，接收 wait() 发送的信号，唤醒 wait()
            // 如果 wait() 先执行，send() 会阻塞等待，这里 recv() 会唤醒它
            // 如果 done() 先执行，recv() 会阻塞等待，直到 wait() 发送信号
            _ = self.waitChn.recv() catch |e| {
                // 如果调度器已退出或 channel 已关闭，忽略错误
                if (e != error.ScheduleExited and e != error.recvClosed) {
                    std.log.err("wg recv error: {any}", .{e});
                }
            };
        }
    }

    pub fn wait(self: *Self) void {
        // 总是发送信号，无论 count 的值
        // 如果 wait() 先执行，send() 会阻塞等待，直到 done() 调用 recv()
        // 如果 done() 先执行，recv() 会阻塞等待，这里 send() 会唤醒它
        // 如果 count == 0，done() 已经执行完，recv() 在等待，这里 send() 会立即唤醒它
        _ = self.waitChn.send(true) catch |e| {
            // 如果调度器已退出或 channel 已关闭，忽略错误
            if (e != error.ScheduleExited and e != error.sendClosed) {
                std.log.err("wg send error: {any}", .{e});
            }
        };
    }
};
