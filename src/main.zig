const std = @import("std");
const zco = @import("zco");

pub const ZCO_STACK_SIZE = 1024 * 12;

pub fn main() !void {}
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//     try zco.init(allocator);
//     defer zco.deinit();
//     const t1 = try std.Thread.spawn(.{}, coRun, .{1});
//     defer t1.join();

//     const t2 = try std.Thread.spawn(.{}, coRun1, .{2});
//     defer t2.join();

//     const t3 = try std.Thread.spawn(.{}, ctxSwithBench, .{});
//     defer t3.join();

//     const t4 = try std.Thread.spawn(.{}, coNest, .{});
//     defer t4.join();
// }

// pub fn coNest() !void {
//     var schedule = try zco.newSchedule();
//     defer {
//         schedule.deinit();
//     }

//     _ = try schedule.go(struct {
//         fn run(_co: *zco.Co, _s: ?*zco.Schedule) !void {
//             const s = _s orelse unreachable; // autofix
//             _ = try s.go(struct {
//                 fn run(_co1: *zco.Co, _: ?*zco.Schedule) !void {
//                     std.log.debug("coNest co2 will Suspend", .{});
//                     try _co1.Suspend();
//                 }
//             }.run, s);
//             try _co.Suspend();
//         }
//     }.run, schedule);
//     try schedule.loop();
// }
// pub fn ctxSwithBench() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     var schedule = try zco.Schedule.init(allocator);
//     defer {
//         schedule.deinit();
//         allocator.destroy(schedule);
//     }

//     _ = try schedule.go(struct {
//         const num_bounces = 1_000_000;
//         fn run(_co: *zco.Co, _s: ?*zco.Schedule) !void {
//             const s = _s orelse unreachable;
//             const start = std.time.nanoTimestamp();
//             for (0..num_bounces) |_| {
//                 try _co.Sleep(1);
//             }
//             const end = std.time.nanoTimestamp();
//             const duration = end - start;
//             const ns_per_bounce = @divFloor(duration, num_bounces * 2);
//             std.log.err("coid:{d} switch ns:{d}", .{ _co.id, ns_per_bounce });
//             s.exit = true;
//         }
//     }.run, schedule);
//     try schedule.loop();
// }
// pub fn coRun(baseIdx: u32) !void {
//     _ = baseIdx; // autofix
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     var schedule = try zco.Schedule.init(allocator);
//     defer {
//         schedule.deinit();
//         allocator.destroy(schedule);
//     }

//     const CoArg = struct {
//         baseIdx: usize,
//     };
//     for (0..1_000) |i| {
//         var arg1 = try allocator.create(CoArg);
//         arg1.baseIdx = i;

//         _ = try schedule.go(struct {
//             fn run(_co: *zco.Co, _args: ?*CoArg) !void {
//                 const args = _args orelse return error.noArg;
//                 defer _co.schedule.allocator.destroy(args);
//                 const idx = args.baseIdx;
//                 var v: usize = idx;
//                 var maxSleep: usize = 0;
//                 while (true) {
//                     std.log.debug("co{d} running v:{d}", .{ _co.id, v });
//                     const start = try std.time.Instant.now();
//                     try _co.Sleep(10);
//                     const end = try std.time.Instant.now();
//                     v +%= 1;
//                     const d = end.since(start) / std.time.ns_per_ms;
//                     if (d > maxSleep) {
//                         maxSleep = d;
//                         std.log.err("coid:{d} sleeped max ms:{d}", .{ _co.id, maxSleep });
//                     }
//                 }
//             }
//         }.run, arg1);
//     }
//     try schedule.loop();
// }
// pub fn coRun1(baseIdx: u32) !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     var schedule = try zco.Schedule.init(allocator);
//     defer {
//         schedule.deinit();
//     }
//     var chn1 = zco.Chan.init(schedule, 10);
//     defer chn1.deinit();

//     const CoArg = struct {
//         chn: *zco.Chan,
//         baseIdx: u32,
//     };
//     var arg1 = CoArg{ .chn = &chn1, .baseIdx = baseIdx };

//     _ = try schedule.go(struct {
//         fn run(_co: *zco.Co, _args: ?*CoArg) !void {
//             var v: usize = 0;
//             const args = _args orelse return error.noArg;
//             const _ch: *zco.Chan = @alignCast(@ptrCast(args.chn));
//             const idx = args.baseIdx;
//             while (true) {
//                 std.log.debug("co{d} sending", .{idx});
//                 // try c.Sleep(10);
//                 v +%= 1;
//                 try _ch.send(&v);
//                 if (v == 1000) {
//                     break;
//                 }
//                 std.log.debug("co{d} sent", .{idx});
//             }
//             _ch.close();
//             _co.schedule.stop();
//         }
//     }.run, &arg1);

//     _ = try schedule.go(struct {
//         fn run(_: *zco.Co, _args: ?*CoArg) !void {
//             var v: usize = 100;
//             const args = _args orelse return error.noArg;
//             const _ch: *zco.Chan = @alignCast(@ptrCast(args.chn));
//             const idx = args.baseIdx + 1;
//             while (true) {
//                 std.log.debug("co{d} sending", .{idx});
//                 // try c.Sleep(10);
//                 v +%= 1;
//                 try _ch.send(&v);
//                 std.log.debug("co{d} sent", .{idx});
//             }
//         }
//     }.run, &arg1);
//     _ = try schedule.go(struct {
//         fn run(_: *zco.Co, _arg: ?*CoArg) !void {
//             const args = _arg orelse return error.noArg;
//             const _ch: *zco.Chan = @alignCast(@ptrCast(args.chn));
//             const idx = args.baseIdx + 2;
//             while (true) {
//                 std.log.debug("co{d} recving", .{idx});
//                 const d: *usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
//                 std.log.debug("co{d} recv:{d}", .{ idx, d.* });
//             }
//         }
//     }.run, &arg1);
//     _ = try schedule.go(struct {
//         fn run(_: *zco.Co, _arg: ?*CoArg) !void {
//             const args = _arg orelse return error.noArg;
//             const _ch: *zco.Chan = @alignCast(@ptrCast(args.chn));
//             const idx = args.baseIdx + 3;
//             while (true) {
//                 std.log.debug("co{d} recving", .{idx});
//                 const d: *usize = @alignCast(@ptrCast(try _ch.recv() orelse break));
//                 std.log.debug("co{d} recv:{d}", .{ idx, d.* });
//             }
//         }
//     }.run, &arg1);
//     try schedule.loop();
// }

test "simple test" {}
