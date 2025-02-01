const std = @import("std");
const zco = @import("zco");
const xev = @import("xev");
const io = @import("io");

pub const File = struct {
    const Self = @This();

    pub const Error = anyerror;

    xobj: ?xev.File = null,
    co: *zco.Co,

    pub fn init(co: *zco.Co) !File {
        return .{
            .co = co,
        };
    }
    pub fn deinit(self: *Self) void {
        _ = self; // autofix
    }
    pub fn open(self: *Self, file: *std.fs.File) !void {
        self.xobj = try xev.File.init(file.*);
    }
    pub fn close(self: *Self) void {
        _ = self; // autofix
    }

    pub usingnamespace io.CreateIo(File);
};

test "File" {
    try zco.init(std.testing.allocator);
    defer zco.deinit();

    const s = try zco.newSchedule();
    defer {
        s.deinit();
    }
    _ = try s.go(struct {
        fn run(co: *zco.Co) !void {
            var file = try File.init(co);
            defer file.deinit();
            co.schedule.stop();
        }
    }.run, null);
    try s.loop();
}
