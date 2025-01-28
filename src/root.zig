const std = @import("std");
const testing = std.testing;
const c = @cImport({
    @cInclude("ucontext.h");
});
const Context = c.ucontext_t;



pub const Co = struct{
    const Self = @This();
    id:usize = 0,
    ctx:Context = std.mem.zeroes(Context),
    func:Func,
    arg:?*anyopaque = null,
    state:State = .INITED,
    priority:usize = 0,
    schedule:*Schedule,
    stack:[DEFAULT_STACK_SZIE]u8 = std.mem.zeroes([DEFAULT_STACK_SZIE]u8),
    wakeupTimestampNs:usize = 0,//纳秒
    const State = enum{
        INITED,
        SUSPEND,
        READY,
        RUNNING,
        STOP,
    };
    const DEFAULT_STACK_SZIE = 1024*100;

    var nextId:usize = 0;
    
    const Func =*const fn (self:*Co,args:?*anyopaque)anyerror!void;


    pub fn Suspend(self:*Self)!void{
        const schedule = self.schedule;
        if(schedule.runningCo)|co|{
            if(co != self){
                unreachable;
            }
            co.state = .SUSPEND;
            self.schedule.runningCo = null;
            if(c.swapcontext(&co.ctx,&schedule.ctx) != 0){
                return error.swapcontext;
            }
            return ;
        }
        unreachable;
    }
    pub fn Resume(self:*Self)!void{
        const schedule = self.schedule;
        std.debug.assert(schedule.runningCo == null);
        std.log.debug("coid:{d} Resume state:{any}",.{self.id,self.state});
        switch(self.state){
            .INITED =>{
                if(c.getcontext(&self.ctx) != 0){
                    return error.getcontext;
                }
                self.ctx.uc_stack.ss_sp = &self.stack;
                self.ctx.uc_stack.ss_size = self.stack.len;
                self.ctx.uc_flags = 0;
                self.ctx.uc_link = &schedule.ctx;
                std.log.debug("coid:{d} Resume makecontext",.{self.id});
                c.makecontext(&self.ctx,@ptrCast(&contextEntry),1,self);
                std.log.debug("coid:{d} Resume swapcontext state:{any}",.{self.id,self.state});
                self.state = .RUNNING;
                schedule.runningCo = self;
                if(c.swapcontext(&schedule.ctx,&self.ctx) != 0 ){
                    return error.swapcontext;
                }
            },
            .SUSPEND,.READY => {
                std.log.debug("coid:{d} Resume swapcontext state:{any}",.{self.id,self.state});
                self.state = .RUNNING;
                schedule.runningCo = self;
                if(c.swapcontext(&schedule.ctx,&self.ctx) != 0 ){
                    return error.swapcontext;
                }
            },
            else =>{

            }
        }
        if(self.state == .STOP){
            schedule.freeCo(self);
        }
    }
    pub fn Sleep(self:*Self,ns:usize)!void{
        _ = ns; // autofix
        const schedule = self.schedule;
        try schedule.readyQueue.add(self);
        _ = try self.Suspend();
    }
    fn contextEntry(self:*Self) callconv(.C) void{
        std.log.debug("Co contextEntry coid:{d}",.{self.id});
        defer std.log.debug("Co contextEntry coid:{d} exited",.{self.id});
        const schedule = self.schedule;
        self.func(self,self.arg)  catch |e|{
            std.log.err("contextEntry coid:{d} error:{s}",.{self.id,@errorName(e)});
        };
        schedule.runningCo = null;
        self.state = .STOP;
    }
};
pub const Schedule = struct{
    ctx:Context = std.mem.zeroes(Context),
    runningCo:?*Co = null,
    sleepQueue:PriorityQueue,
    readyQueue:PriorityQueue,
    allocator:std.mem.Allocator,
    sendCo:?*Co = null,
    recvCo:?*Co = null,

    allCoMap:CoMap,

    const CoMap = std.AutoArrayHashMap(*Co,*Co);
    const PriorityQueue = std.PriorityQueue(*Co,void,Schedule.queueCompare);

    pub fn init(allocator:std.mem.Allocator)Schedule{
        const mg = Schedule{
            .sleepQueue = PriorityQueue.init(allocator,{}),
            .readyQueue = PriorityQueue.init(allocator,{}),
            .allocator = allocator,
            .allCoMap = CoMap.init(allocator),
        };
        return mg;
    }
    pub fn deinit(self:*Schedule)void{
        self.sleepQueue.deinit();
        self.readyQueue.deinit();
        while(self.allCoMap.popOrNull())|co|{
            self.allocator.destroy(co);
        }
        self.allCoMap.deinit();
    }
    pub fn go(self:*Schedule,func:Co.Func,args:?*anyopaque)!*Co{
        const co = try self.allocator.create(Co);
        co.* = Co{
            .arg = args,
            .func = @ptrCast(func),
            .id =  Co.nextId,
            .schedule = self,
        };
        Co.nextId +%= 1;
        try self.ResumeCo(co);
        return co;
    }
    fn queueCompare(_: void, a: *Co, b: *Co)std.math.Order{
        return std.math.order(a.priority,b.priority);
    }
    fn sleepCo(self:*Schedule,co:*Co)!void{
        try self.sleepQueue.add(co);
    }
    fn ResumeCo(self:*Schedule,co:*Co)!void{
        std.log.debug("ResumeCo id:{d}",.{co.id});
        try self.readyQueue.add(co);   
    }
    fn freeCo(self:*Schedule,co:*Co)void{
        if(co.state == .STOP){
            return;
        }
        for(self.sleepQueue.items,0..)|_co,i|{
            if(_co == co){
                _ = self.sleepQueue.removeIndex(i);
            }
        }
        for(self.readyQueue.items,0..)|_co,i|{
            if(_co == co){
                _ = self.readyQueue.removeIndex(i);
            }
        }
        if(self.allCoMap.get(co))|_|{
            self.allocator.destroy(co);
        }
    }
    pub fn loop(self:*Schedule,exit:*bool)!void{
        while(!exit.*){
            self.checkNextCo()  catch |e|{
                std.log.err("Schedule loop checkNextCo error:{s}",.{@errorName(e)});
            };
        }
    }
    fn checkNextCo(self:*Schedule)!void{
        const count = self.readyQueue.count();
        var iter = self.readyQueue.iterator();
        std.log.debug("checkNextCo begin",.{});
        while(iter.next())|_co|{
            std.log.debug("checkNextCo cid:{d}",.{_co.id});
        }
        if(count > 0 ){
            const nextCo = self.readyQueue.remove();
            std.log.debug("coid:{d} will running readyQueue.count:{d}",.{nextCo.id,self.readyQueue.count()});
            try nextCo.Resume();
        }else{
            // std.log.debug("Schedule no co",.{});
        }
    }
};


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
    pub fn close(self:*Self)!void{
        const schedule = self.schedule;
        self.closed = true;
        //唤醒所有sender和recver
        for(self.sendingQueue.items)|sendCo|{
            schedule.ResumeCo(sendCo) catch |e|{
                std.log.err("Chan close coid:{d} ResumeCo error:{s}",.{sendCo.id,@errorName(e)});
            };
        }
        for(self.recvingQueue.items)|recvCo|{
            schedule.ResumeCo(recvCo) catch |e|{
                std.log.err("Chan close coid:{d} ResumeCo error:{s}",.{recvCo.id,@errorName(e)});
            };
        }
    }
    pub fn isEmpty(self:*Self)bool{
        return self.valueQueue.items.len == 0;
    }
    pub fn send(self:*Self,data:*anyopaque)!void{
        if(self.closed){
            std.log.err("Chan send closed",.{});
            return error.sendClosed;
        }
        const schedule = self.schedule;
        const sendCo = schedule.runningCo orelse unreachable;
        if(self.valueQueue.items.len  >= self.bufferCap)
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
        if(self.recvingQueue.items.len > 0 ){
            std.log.debug("Chan send recvingQueue len:{d}",.{self.recvingQueue.items.len});
            const recvCo = self.recvingQueue.orderedRemove(0);
            try schedule.ResumeCo(recvCo);            
        }
        std.log.debug("Chan send waiting recv",.{});
        //等待recver读完成
        try sendCo.Suspend();
    }
    pub fn recv(self:*Self)!?*anyopaque{
        const schedule = self.schedule;
        const recvCo = schedule.runningCo orelse unreachable;
        if(self.valueQueue.items.len <= 0 ){
            //没有数据可读
            while(true){
                if(self.closed){
                    std.log.debug("Chan recv closed",.{});
                    return null;
                }
                try self.recvingQueue.append(recvCo);
                std.log.debug("Chan recv waiting data recvCo id:{d}",.{recvCo.id});
                try recvCo.Suspend();
                //唤醒后要检测有没有可读数据
                //有可能已经被其它recver处理完了
                if(self.valueQueue.items.len <= 0){
                    std.log.debug("Chan recv nodata recvCo id:{d}",.{recvCo.id});
                }else{
                    break;
                }
            }
            std.log.debug("Chan recv wakeup recvCo id:{d}",.{recvCo.id});
        }
        const val = self.valueQueue.orderedRemove(0);
        try schedule.ResumeCo(val.co);
        if(self.sendingQueue.items.len > 0){
            const sendCo = self.sendingQueue.orderedRemove(0);
            try schedule.ResumeCo(sendCo);
        }

        return val.value;
    }
};