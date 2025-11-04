const std = @import("std");
const testing = std.testing;
const receiver = @import("./receiver.zig");
const media = @import("../media/root.zig");

const Receiver = receiver.Receiver;
const Track = media.Track;

test "Receiver init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const r = try Receiver.init(allocator);
    defer r.deinit();

    try testing.expect(r.getTrack() == null);
    try testing.expect(r.getSsrc() == null);
    try testing.expect(r.getPayloadType() == null);
}

test "Receiver set and get track" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const r = try Receiver.init(allocator);
    defer r.deinit();

    const track = try Track.init(allocator, "track-1", .video, "Video");
    defer track.deinit();

    r.setTrack(track);
    try testing.expect(r.getTrack() == track);
}

test "Receiver set and get SSRC" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const r = try Receiver.init(allocator);
    defer r.deinit();

    const ssrc: u32 = 0x87654321;
    r.setSsrc(ssrc);
    try testing.expect(r.getSsrc() == ssrc);
}

test "Receiver set and get payload type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const r = try Receiver.init(allocator);
    defer r.deinit();

    const payload_type: u7 = 96; // VP8
    r.setPayloadType(payload_type);
    try testing.expect(r.getPayloadType() == payload_type);
}

