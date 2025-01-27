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
    state:State = .READY,
    priority:usize = 0,
    schedule:*Schedule,
    stack:[DEFAULT_STACK_SZIE]u8 = std.mem.zeroes([DEFAULT_STACK_SZIE]u8),
    wakeupTimestampNs:usize = 0,//纳秒
    
    const State = enum{
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
            if(c.swapcontext(&co.ctx,&schedule.ctx) != 0){
                return error.swapcontext;
            }
        }
    }
    pub fn Resume(self:*Self)!void{
        const schedule = self.schedule;
        switch(self.state){
            .READY =>{
                std.log.debug("Co Resume state:{any}",.{self.state});
                if(c.getcontext(&self.ctx) != 0){
                    return error.getcontext;
                }
                self.ctx.uc_stack.ss_sp = &self.stack;
                self.ctx.uc_stack.ss_size = self.stack.len;
                self.ctx.uc_flags = 0;
                self.ctx.uc_link = &schedule.ctx;
                std.log.debug("Co Resume makecontext",.{});
                c.makecontext(&self.ctx,@ptrCast(&contextEntry),1,self);
                self.state = .RUNNING;
                schedule.runningCo = self;
                if(c.swapcontext(&schedule.ctx,&self.ctx) != 0 ){
                    return error.swapcontext;
                }
            },
            .SUSPEND => {
                self.state = .RUNNING;
                schedule.runningCo = self;
                if(c.swapcontext(&schedule.ctx,&self.ctx) != 0 ){
                    return error.swapcontext;
                }
            },
            else =>{

            }
        } 
    }
    pub fn Sleep(self:*Self,ns:usize)!void{
        _ = ns; // autofix
        const schedule = self.schedule;
        try schedule.readyQueue.add(self);
        try self.Suspend();
    }
    fn contextEntry(self:*Self) callconv(.C) void{
        std.log.debug("Co contextEntry coid:{d}",.{self.id});
        defer std.log.debug("Co contextEntry coid:{d} exited",.{self.id});
        const schedule = self.schedule;
        self.func(self,self.arg)  catch |e|{
            std.log.err("contextEntry error:{s}",.{@errorName(e)});
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

    const PriorityQueue = std.PriorityQueue(*Co,void,Schedule.queueCompare);

    pub fn init(allocator:std.mem.Allocator)Schedule{
        const mg = Schedule{
            .sleepQueue = PriorityQueue.init(allocator,{}),
            .readyQueue = PriorityQueue.init(allocator,{}),
            .allocator = allocator,
        };
        return mg;
    }
    pub fn deinit()void{

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
        try self.addReadyCo(co);
        return co;
    }
    fn queueCompare(_: void, a: *Co, b: *Co)std.math.Order{
        return std.math.order(a.priority,b.priority);
    }
    fn addSleepCo(self:*Schedule,co:*Co)!void{
        try self.sleepQueue.add(co);
    }
    fn addReadyCo(self:*Schedule,co:*Co)!void{
        std.log.debug("addReadyCo id:{d}",.{co.id});
        try self.readyQueue.add(co);   
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
        // var iter = self.readyQueue.iterator();
        // while(iter.next())|_co|{
        //     std.log.debug("checkNextCo cid:{d}",.{_co.id});
        // }
        if(count > 0 ){
            const nextCo = self.readyQueue.remove();
            // std.log.debug("coid:{d} will running readyQueue.count:{d}",.{nextCo.id,self.readyQueue.count()});
            try nextCo.Resume();
        }else{
            // std.log.debug("Schedule no co",.{});
        }
    }
};
