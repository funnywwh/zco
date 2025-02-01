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
        co: *zco.Co = undefined,
        xobj: ?xev.File = null,
        pub usingnamespace io.CreateIo(Self);
    };
    var myio = MyIo{};
    myio.xobj = try xev.File.init(buildFile);

    _ = try schedule.go(struct {
        fn run(_co: *zco.Co, _myio: *MyIo) !void {
            std.log.debug("testIO schedule:{*} _myio:{*}", .{ _co.schedule, _myio });
            try _co.schedule.iogo(_myio, struct {
                fn run(_io: *MyIo) !void {
                    var buf: [100]u8 = undefined;
                    const out = try std.fmt.bufPrint(&buf, "hello", .{});
                    _ = try _io.write(out);
                    const npread = try _io.pread(&buf, 0);
                    std.log.debug("testIo read:{s}", .{buf[0..npread]});
                    _io.co.schedule.stop();
                }
            }.run, null);
            // _co.schedule.stop();
        }
    }.run, &myio);

    try schedule.loop();
}
