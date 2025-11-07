const std = @import("std");
const testing = std.testing;
const webrtc = @import("webrtc");

const Sender = webrtc.peer.Sender;
const Track = webrtc.media.Track;

test "Sender init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const s = try Sender.init(allocator);
    defer s.deinit();

    try testing.expect(s.getTrack() == null);
    try testing.expect(s.getSsrc() == null);
    try testing.expect(s.getPayloadType() == null);
}

test "Sender set and get track" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const s = try Sender.init(allocator);
    defer s.deinit();

    const track = try Track.init(allocator, "track-1", .audio, "Audio");
    defer track.deinit();

    s.setTrack(track);
    try testing.expect(s.getTrack() == track);
}

test "Sender set and get SSRC" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const s = try Sender.init(allocator);
    defer s.deinit();

    const ssrc: u32 = 0x12345678;
    s.setSsrc(ssrc);
    try testing.expect(s.getSsrc() == ssrc);
}

test "Sender set and get payload type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const s = try Sender.init(allocator);
    defer s.deinit();

    const payload_type: u7 = 111; // Opus
    s.setPayloadType(payload_type);
    try testing.expect(s.getPayloadType() == payload_type);
}

test "Sender replace track" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const s = try Sender.init(allocator);
    defer s.deinit();

    const track1 = try Track.init(allocator, "track-1", .audio, "Audio 1");
    defer track1.deinit();
    const track2 = try Track.init(allocator, "track-2", .audio, "Audio 2");
    defer track2.deinit();

    s.setTrack(track1);
    try testing.expect(s.getTrack() == track1);

    try s.replaceTrack(track2);
    try testing.expect(s.getTrack() == track2);

    try s.replaceTrack(null);
    try testing.expect(s.getTrack() == null);
}
