const std = @import("std");
const zco = @import("zco");
const io = @import("io");

pub const File = struct {
    const Self = @This();
    const XFile = zco.xev.File;
    pub const Error = anyerror;

    xobj: ?XFile = null,
    schedule: *zco.Schedule,

    pub fn init(schedule: *zco.Schedule) !File {
        return .{
            .schedule = schedule,
        };
    }
    pub fn deinit(self: *Self) void {
        if (self.xobj) |xobj| {
            _ = xobj; // autofix
        }
    }
    pub fn open(self: *Self, file: std.fs.File) !void {
        const xobj = try zco.xev.File.init(file);
        self.xobj = xobj;
    }

    pub usingnamespace io.CreateIo(File);
};
