const std = @import("std");
const testing = std.testing;
const track = @import("./track.zig");

const Track = track.Track;
const TrackKind = track.TrackKind;
const TrackState = track.TrackState;

test "Track init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const t = try Track.init(allocator, "track-1", .audio, "Audio Track");
    defer t.deinit();

    try testing.expectEqualStrings("track-1", t.getId());
    try testing.expect(t.getKind() == .audio);
    try testing.expectEqualStrings("Audio Track", t.getLabel());
    try testing.expect(t.isEnabled());
    try testing.expect(t.getState() == .live);
}

test "Track enable and disable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const t = try Track.init(allocator, "track-1", .video, "Video Track");
    defer t.deinit();

    try testing.expect(t.isEnabled());
    t.setEnabled(false);
    try testing.expect(!t.isEnabled());
    t.setEnabled(true);
    try testing.expect(t.isEnabled());
}

test "Track stop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const t = try Track.init(allocator, "track-1", .audio, "Audio Track");
    defer t.deinit();

    try testing.expect(t.getState() == .live);
    t.stop();
    try testing.expect(t.getState() == .ended);
}

test "Track video kind" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const t = try Track.init(allocator, "video-track", .video, "Camera");
    defer t.deinit();

    try testing.expect(t.getKind() == .video);
    try testing.expectEqualStrings("video-track", t.getId());
    try testing.expectEqualStrings("Camera", t.getLabel());
}

