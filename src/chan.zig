const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const Schedule = @import("./schedule.zig").Schedule;
const Co = @import("./co.zig").Co;


pub const Chan = struct{
    const Self = @This();
    const Value = struct{
        value:*anyopaque,
        co:*Co,
    };
    const ValQueue = std.ArrayList(Value);
    const CoQueue = std.ArrayList(*Co);
    schedule:*Schedule,
    sendingQueue:CoQueue,
    recvingQueue:CoQueue,
    valueQueue:ValQueue,
    bufferCap:usize = 1,
    closed:bool = false,

    sendCount:usize = 0,
    recvCount:usize = 0,

    pub fn init(s:*Schedule,bufCap:usize)Self{
        std.debug.assert(bufCap > 0);
        return .{
            .schedule = s,
            .sendingQueue = CoQueue.init(s.allocator),
            .recvingQueue = CoQueue.init(s.allocator),
            .valueQueue = ValQueue.init(s.allocator),
            .bufferCap = bufCap,
        };
    }
    pub fn close(self:*Self)void{
        const schedule = self.schedule;
        self.closed = true;
        //唤醒所有sender和recver
        for(self.sendingQueue.items)|sendCo|{
            schedule.ResumeCo(sendCo) catch |e|{
                std.log.err("Chan close coid:{d} ResumeCo error:{s}",.{sendCo.id,@errorName(e)});
            };
        }
        self.sendingQueue.clearAndFree();
        for(self.recvingQueue.items)|recvCo|{
            schedule.ResumeCo(recvCo) catch |e|{
                std.log.err("Chan close coid:{d} ResumeCo error:{s}",.{recvCo.id,@errorName(e)});
            };
        }
        self.recvingQueue.clearAndFree();
    }
    pub fn deinit(self:*Self)void{
        std.debug.assert(self.closed);
        std.debug.assert(self.isEmpty());
        self.valueQueue.clearAndFree();
    }
    pub fn isEmpty(self:*Self)bool{
        return self.valueQueue.items.len == 0;
    }
    pub fn send(self:*Self,data:*anyopaque)!void{
        const schedule = self.schedule;
        const sendCo = schedule.runningCo orelse unreachable;
        self.sendCount += 1;
        std.log.debug("Chan send_ coid:{d}",.{sendCo.id});

        if(self.closed){
            std.log.err("Chan send closed",.{});
            return error.sendClosed;
        }
        while(self.valueQueue.items.len  >= self.bufferCap)
        {
            //缓冲区满等待空位
            try self.sendingQueue.append(sendCo);
            std.log.debug("Chan send buffer full",.{});
            try sendCo.Suspend();
            if(self.closed){
                return error.sendClosed;
            }
        }
        try self.valueQueue.append(.{
            .value = data,
            .co = sendCo,
        });
        std.log.debug("Chan send appendValue",.{});
        if(self.recvingQueue.items.len > 0 ){
            const recvCo = self.recvingQueue.orderedRemove(0);
            std.log.debug("Chan send wakeup recv coid:{d}",.{recvCo.id});
            try schedule.ResumeCo(recvCo);            
        }
        std.log.debug("Chan send waiting recv",.{});
        //等待recver读完成
        try sendCo.Suspend();
    }
    pub fn recv(self:*Self)!?*anyopaque{
        const schedule = self.schedule;
        const recvCo = schedule.runningCo orelse unreachable;

        std.log.debug("Chan recv_ coid:{d}",.{recvCo.id});
        while(self.valueQueue.items.len <= 0 ){
            //没有数据可读
            try self.recvingQueue.append(recvCo);
            std.log.debug("Chan recv waiting data recvCo id:{d}",.{recvCo.id});
            try recvCo.Suspend();
            //唤醒后要检测有没有可读数据
            //有可能已经被其它recver处理完了
            std.log.debug("Chan recv nodata recvCo id:{d}",.{recvCo.id});
            if(self.closed){
                std.log.debug("Chan recv closed",.{});
                break;
            }
            std.log.debug("Chan recv wakeup recvCo id:{d}",.{recvCo.id});
        }
        if(self.valueQueue.items.len > 0 ){
            std.log.debug("Chan send removeValue",.{});
            const val = self.valueQueue.orderedRemove(0);
            try schedule.ResumeCo(val.co);
            if(self.sendingQueue.items.len > 0){
                const sendCo = self.sendingQueue.orderedRemove(0);
                try schedule.ResumeCo(sendCo);
            }
            return val.value;
        }
        return null;
    }
};