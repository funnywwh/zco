const std = @import("std");
const testing = std.testing;
// 通过 webrtc 模块访问子模块（test.zig 作为根文件时，相对路径导入可以工作）
const webrtc = @import("webrtc");

const Receiver = webrtc.peer.Receiver;
const Track = webrtc.media.Track;

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
    // 注意：track 由 receiver 拥有，receiver.deinit() 会负责释放，不需要手动 deinit

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
