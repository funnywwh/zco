const std = @import("std");
const c = @import("./c.zig");
const Context = c.ucontext_t;
const Schedule = @import("./schedule.zig").Schedule;

pub const SwitchTimer = struct{
    const Self = @This();
    const List = std.ArrayList(*Schedule);
    pub const SIGNO = c.SIGUSR1;

    const CO_SWITCH_TIME = 10*std.time.us_per_ms;

    listSchedule:List,
    mtx:std.Thread.Mutex = .{},

    var localSwitchTimer:?*SwitchTimer = null;

    extern fn syscall(id:usize,pid:i32,tid:usize,sig:u32) callconv(.C) void;

    fn timerHandler(_:c_int, siginfo:[*c]c.siginfo_t, _:*void) callconv(.C) void{
        _ = siginfo; // autofix
        const switchTimer = localSwitchTimer orelse return;
        // switchTimer.mtx.lock();
        // defer switchTimer.mtx.unlock();

        std.log.debug("SwitchTimer timerHandler [[",.{});
        defer std.log.debug("SwitchTimer timerHandler ]]",.{});
        for(switchTimer.listSchedule.items)|schedule|{
            std.log.debug("SwitchTimer timerHandler syscall tid:{d} schedule:{*}",.{schedule.tid,schedule});
            _ = syscall(c.SYS_tgkill,std.os.linux.getpid(),schedule.tid,SIGNO);
        }
    }

    pub fn init(allocator:std.mem.Allocator)!void{
        const self:Self = .{
            .listSchedule = List.init(allocator),
        };


        var sa = c.struct_sigaction{};
        sa.__sigaction_handler.sa_sigaction = @ptrCast(&timerHandler);
        sa.sa_flags = 0;
        _ = c.sigemptyset(&sa.sa_mask);
            _ = c.sigaddset(&sa.sa_mask,c.SIGALRM);

        if(c.sigaction(c.SIGALRM,&sa,null) == -1){
            return error.sigaction;
        }

        var set = c.sigset_t{};
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set,SIGNO);
        _ = c.pthread_sigmask(c.SIG_BLOCK,&set,null);

        var timer = c.itimerval{};
        timer.it_value.tv_sec = 1;
        timer.it_value.tv_usec = CO_SWITCH_TIME;
        timer.it_interval.tv_sec = 0;
        timer.it_interval.tv_usec = CO_SWITCH_TIME;

        // _ = c.setitimer(c.ITIMER_REAL,&timer,null);

        const switchTimer = try allocator.create(SwitchTimer);
        switchTimer.* = self;
        localSwitchTimer = switchTimer;

        return ;
    }
    pub fn deinit()void{
        if(localSwitchTimer)|switchTimer|{
            switchTimer.listSchedule.clearAndFree();
        }
    }
    pub fn addSchedule(s:*Schedule)!void{
        const self = localSwitchTimer orelse return error.uninit ;
        self.mtx.lock();
        defer self.mtx.unlock();
        try self.listSchedule.append(s);
        std.log.debug("SwitchTimer addSchedule tid:{d} schedule schedule:{*}",.{s.tid,s});
    }
};
