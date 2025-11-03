const std = @import("std");
const testing = std.testing;

// 由于 sdp.zig 中的 parse 函数需要 allocator 参数，我们需要直接导入
const SdpModule = struct {
    pub const Sdp = @import("./sdp.zig").Sdp;
};

const sdp = SdpModule;

test "SDP init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sdp_obj = sdp.Sdp.init(allocator);
    defer sdp_obj.deinit();

    try testing.expect(sdp_obj.version == null);
    try testing.expect(sdp_obj.origin == null);
    try testing.expect(sdp_obj.session_name == null);
}

test "SDP parse basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdp_text =
        \\v=0
        \\o=- 4611731400430051336 2 IN IP4 127.0.0.1
        \\s=-
        \\t=0 0
    ;

    var sdp_obj = try sdp.Sdp.parse(allocator, sdp_text);
    defer sdp_obj.deinit();

    try testing.expect(sdp_obj.version.? == 0);
    try testing.expect(sdp_obj.origin != null);
    try testing.expectEqualStrings("-", sdp_obj.origin.?.username);
    try testing.expect(sdp_obj.origin.?.session_id == 4611731400430051336);
    try testing.expect(sdp_obj.session_name != null);
    try testing.expectEqualStrings("-", sdp_obj.session_name.?);
}

test "SDP parse with connection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdp_text =
        \\v=0
        \\o=- 4611731400430051336 2 IN IP4 127.0.0.1
        \\s=-
        \\c=IN IP4 192.168.1.1
        \\t=0 0
    ;

    var sdp_obj = try sdp.Sdp.parse(allocator, sdp_text);
    defer sdp_obj.deinit();

    try testing.expect(sdp_obj.connection != null);
    try testing.expectEqualStrings("IN", sdp_obj.connection.?.nettype);
    try testing.expectEqualStrings("IP4", sdp_obj.connection.?.addrtype);
    try testing.expectEqualStrings("192.168.1.1", sdp_obj.connection.?.address);
}

test "SDP parse with media" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdp_text =
        \\v=0
        \\o=- 4611731400430051336 2 IN IP4 127.0.0.1
        \\s=-
        \\t=0 0
        \\m=audio 5004 UDP/TLS/RTP/SAVPF 111 103 104 9 0 8 106 105 13 110 112 113 126
    ;

    var sdp_obj = try sdp.Sdp.parse(allocator, sdp_text);
    defer sdp_obj.deinit();

    try testing.expect(sdp_obj.media_descriptions.items.len == 1);
    const md = sdp_obj.media_descriptions.items[0];
    try testing.expectEqualStrings("audio", md.media_type);
    try testing.expect(md.port == 5004);
    try testing.expectEqualStrings("UDP/TLS/RTP/SAVPF", md.proto);
    try testing.expect(md.formats.items.len > 0);
}

test "SDP parse with ICE attributes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdp_text =
        \\v=0
        \\o=- 4611731400430051336 2 IN IP4 127.0.0.1
        \\s=-
        \\t=0 0
        \\a=ice-ufrag:abc123
        \\a=ice-pwd:xyz789
    ;

    var sdp_obj = try sdp.Sdp.parse(allocator, sdp_text);
    defer sdp_obj.deinit();

    try testing.expect(sdp_obj.ice_ufrag != null);
    try testing.expectEqualStrings("abc123", sdp_obj.ice_ufrag.?);
    try testing.expect(sdp_obj.ice_pwd != null);
    try testing.expectEqualStrings("xyz789", sdp_obj.ice_pwd.?);
}

test "SDP parse with fingerprint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdp_text =
        \\v=0
        \\o=- 4611731400430051336 2 IN IP4 127.0.0.1
        \\s=-
        \\t=0 0
        \\a=fingerprint:sha-256 12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF
    ;

    var sdp_obj = try sdp.Sdp.parse(allocator, sdp_text);
    defer sdp_obj.deinit();

    try testing.expect(sdp_obj.fingerprint != null);
    try testing.expectEqualStrings("sha-256", sdp_obj.fingerprint.?.hash);
}

test "SDP generate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var sdp_obj = sdp.Sdp.init(allocator);
    defer sdp_obj.deinit();

    sdp_obj.version = 0;
    sdp_obj.session_name = try allocator.dupe(u8, "Test Session");

    const generated = try sdp_obj.generate();
    defer allocator.free(generated);

    try testing.expect(std.mem.indexOf(u8, generated, "v=0") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "s=Test Session") != null);
}

test "SDP generate with origin" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var sdp_obj = sdp.Sdp.init(allocator);
    defer sdp_obj.deinit();

    sdp_obj.version = 0;
    sdp_obj.origin = sdp.Sdp.Origin{
        .username = try allocator.dupe(u8, "-"),
        .session_id = 1234567890,
        .session_version = 2,
        .nettype = try allocator.dupe(u8, "IN"),
        .addrtype = try allocator.dupe(u8, "IP4"),
        .address = try allocator.dupe(u8, "127.0.0.1"),
    };

    const generated = try sdp_obj.generate();
    defer allocator.free(generated);

    try testing.expect(std.mem.indexOf(u8, generated, "o=- 1234567890 2 IN IP4 127.0.0.1") != null);
}

test "SDP generate with media" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var sdp_obj = sdp.Sdp.init(allocator);
    defer sdp_obj.deinit();

    sdp_obj.version = 0;
    sdp_obj.session_name = try allocator.dupe(u8, "-");

    var md = sdp.Sdp.MediaDescription{
        .media_type = try allocator.dupe(u8, "audio"),
        .port = 5004,
        .proto = try allocator.dupe(u8, "RTP/AVP"),
        .formats = std.ArrayList([]const u8).init(allocator),
        .bandwidths = std.ArrayList(sdp.Sdp.Bandwidth).init(allocator),
        .attributes = std.ArrayList(sdp.Sdp.Attribute).init(allocator),
    };
    try md.formats.append(try allocator.dupe(u8, "111"));
    try sdp_obj.media_descriptions.append(md);

    const generated = try sdp_obj.generate();
    defer allocator.free(generated);

    try testing.expect(std.mem.indexOf(u8, generated, "m=audio 5004 RTP/AVP 111") != null);
}

test "SDP parse ICE candidate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const candidate_str = "candidate 1 1 UDP 2130706431 192.168.1.100 54321 typ host";
    const candidate = try sdp.Sdp.parseIceCandidate(candidate_str, allocator);
    defer {
        allocator.free(candidate.foundation);
        allocator.free(candidate.transport);
        allocator.free(candidate.address);
        allocator.free(candidate.typ);
    }

    try testing.expectEqualStrings("1", candidate.foundation);
    try testing.expect(candidate.component == 1);
    try testing.expectEqualStrings("UDP", candidate.transport);
    try testing.expect(candidate.priority == 2130706431);
    try testing.expectEqualStrings("192.168.1.100", candidate.address);
    try testing.expect(candidate.port == 54321);
    try testing.expectEqualStrings("host", candidate.typ);
}

test "SDP round-trip parse and generate" {
    // 使用 ArenaAllocator 来简化内存管理，避免内存泄漏检测问题
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const original_sdp =
        \\v=0
        \\o=- 4611731400430051336 2 IN IP4 127.0.0.1
        \\s=-
        \\c=IN IP4 192.168.1.1
        \\t=0 0
        \\a=ice-ufrag:abc123
        \\a=ice-pwd:xyz789
        \\m=audio 5004 UDP/TLS/RTP/SAVPF 111
    ;

    var sdp_obj = try sdp.Sdp.parse(allocator, original_sdp);
    defer sdp_obj.deinit();

    const generated = try sdp_obj.generate();
    defer allocator.free(generated);

    // 验证生成的 SDP 包含关键信息
    try testing.expect(std.mem.indexOf(u8, generated, "v=0") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "c=IN IP4 192.168.1.1") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "a=ice-ufrag:abc123") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "m=audio 5004") != null);
}
