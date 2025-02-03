const std = @import("std");
const xev = @import("xev");
const zco = @import("zco");
const io = @import("io");
pub fn main() !void {
    try testIo();
}
test "testio" {
    try testIo();
}
fn testIo() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    std.log.debug("main schedule inited", .{});
    defer {
        schedule.deinit();
    }
    const buildFile = try std.fs.cwd().createFile("./test.out", .{
        .read = true,
        .truncate = true,
    });
    defer {
        buildFile.close();
        std.fs.cwd().deleteFile("./test.out") catch unreachable;
    }
    const MyIo = struct {
        const Self = @This();
        schedule: *zco.Schedule,
        xobj: ?xev.File = null,
        pub usingnamespace io.CreateIo(Self);
    };
    var myio = MyIo{
        .schedule = schedule,
    };
    myio.xobj = try xev.File.init(buildFile);

    _ = try schedule.go(struct {
        fn run(s: *zco.Schedule, _myio: *MyIo) !void {
            std.log.debug("testIO schedule:{*} _myio:{*}", .{ s, _myio });
            _ = try s.go(struct {
                fn run(_io: *MyIo) !void {
                    var buf: [100]u8 = undefined;
                    const out = try std.fmt.bufPrint(&buf, "hello", .{});
                    _ = try _io.write(out);
                    const npread = try _io.pread(&buf, 0);
                    std.log.debug("testIo read:{s}", .{buf[0..npread]});
                    _io.schedule.stop();
                }
            }.run, .{_myio});
            // _co.schedule.stop();
        }
    }.run, .{ schedule, &myio });

    try schedule.loop();
}
