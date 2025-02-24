const std = @import("std");
const zco = @import("zco");
const xev = @import("xev");
const io = @import("io");

pub const File = struct {
    const Self = @This();
    const XFile = xev.File;
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
        const xobj = try xev.File.init(file);
        self.xobj = xobj;
    }

    pub usingnamespace io.CreateIo(File);
};
