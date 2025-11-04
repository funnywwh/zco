const std = @import("std");
const testing = std.testing;
const codec = @import("./codec.zig");
const opus = @import("./codec/opus.zig");
const vp8 = @import("./codec/vp8.zig");

test "Opus encoder init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoder = try opus.OpusCodec.createEncoder(allocator, 48000, 2, 64000);
    defer encoder.deinit(allocator);

    const info = encoder.getInfo();
    try testing.expectEqualStrings("opus", info.name);
    try testing.expectEqualStrings("audio/opus", info.mime_type);
    try testing.expect(info.payload_type == 111);
    try testing.expect(info.clock_rate == 48000);
    try testing.expect(info.channels == 2);
    try testing.expect(info.type == .audio);
}

test "Opus decoder init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const decoder = try opus.OpusCodec.createDecoder(allocator, 48000, 2);
    defer decoder.deinit(allocator);

    const info = decoder.getInfo();
    try testing.expectEqualStrings("opus", info.name);
    try testing.expect(info.type == .audio);
}

test "Opus encode and decode (placeholder)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoder = try opus.OpusCodec.createEncoder(allocator, 48000, 2, 64000);
    defer encoder.deinit(allocator);

    const decoder = try opus.OpusCodec.createDecoder(allocator, 48000, 2);
    defer decoder.deinit(allocator);

    const input = "test audio data";
    const encoded = try encoder.encode(input, allocator);
    defer allocator.free(encoded);

    const decoded = try decoder.decode(encoded, allocator);
    defer allocator.free(decoded);

    // 占位符实现：输入和输出应该相同
    try testing.expect(std.mem.eql(u8, input, decoded));
}

test "VP8 encoder init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoder = try vp8.Vp8Codec.createEncoder(allocator, 640, 480, 30);
    defer encoder.deinit(allocator);

    const info = encoder.getInfo();
    try testing.expectEqualStrings("vp8", info.name);
    try testing.expectEqualStrings("video/vp8", info.mime_type);
    try testing.expect(info.payload_type == 96);
    try testing.expect(info.clock_rate == 90000);
    try testing.expect(info.channels == null);
    try testing.expect(info.type == .video);
}

test "VP8 decoder init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const decoder = try vp8.Vp8Codec.createDecoder(allocator, 640, 480);
    defer decoder.deinit(allocator);

    const info = decoder.getInfo();
    try testing.expectEqualStrings("vp8", info.name);
    try testing.expect(info.type == .video);
}

test "VP8 encode and decode (placeholder)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoder = try vp8.Vp8Codec.createEncoder(allocator, 640, 480, 30);
    defer encoder.deinit(allocator);

    const decoder = try vp8.Vp8Codec.createDecoder(allocator, 640, 480);
    defer decoder.deinit(allocator);

    const input = "test video data";
    const encoded = try encoder.encode(input, allocator);
    defer allocator.free(encoded);

    const decoded = try decoder.decode(encoded, allocator);
    defer allocator.free(decoded);

    // 占位符实现：输入和输出应该相同
    try testing.expect(std.mem.eql(u8, input, decoded));
}

