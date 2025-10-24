const std = @import("std");
const file = @import("file");
const zco = @import("zco");

const File = file.File;
pub fn main() !void {
    try testFile();
}

fn testFile() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try zco.init(allocator);
    defer zco.deinit();

    const s = try zco.newSchedule();
    defer {
        s.deinit();
    }
    _ = try s.go(struct {
        fn run(_s: *zco.Schedule) !void {
            const co = _s.runningCo orelse undefined;
            var testfile = try File.init(_s);
            defer {
                testfile.deinit();
            }
            const path = "1.test";
            try testfile.open(try std.fs.cwd().createFile(path, .{
                .read = true,
                .truncate = true,
            }));
            const data: []const u8 = "helloworld";
            _ = try testfile.write(data);
            var buf: [1024]u8 = undefined;
            const n = try testfile.pread(&buf, 0);
            testfile.close();
            try std.fs.cwd().deleteFile(path);

            co.schedule.stop();
        }
    }.run, .{s});
    try s.loop();
}
test "simple test" {}
