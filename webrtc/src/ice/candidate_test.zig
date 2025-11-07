const std = @import("std");
const testing = std.testing;
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const candidate = webrtc.ice.candidate;

test "Candidate init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("192.168.1.100", 54321);
    var cand = try candidate.Candidate.init(
        allocator,
        "foundation1",
        1,
        "udp",
        address,
        .host,
    );
    defer cand.deinit();

    try testing.expectEqualStrings("foundation1", cand.foundation);
    try testing.expect(cand.component_id == 1);
    try testing.expectEqualStrings("udp", cand.transport);
    try testing.expect(cand.typ == .host);
    try testing.expect(cand.address.getPort() == 54321);
}

test "Candidate calculatePriority" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("192.168.1.100", 54321);
    var cand = try candidate.Candidate.init(
        allocator,
        "foundation1",
        1,
        "udp",
        address,
        .host,
    );
    defer cand.deinit();

    const type_pref = candidate.Candidate.getTypePreference(.host);
    cand.calculatePriority(type_pref, 65534);

    // 验证优先级计算：priority = (2^24)*(type_pref) + (2^8)*(local_pref) + component
    // 126 << 24 | 65534 << 8 | 1
    const expected: u32 = (@as(u32, 126) << 24) | (@as(u32, 65534) << 8) | 1;
    try testing.expect(cand.priority == expected);
}

test "Candidate getTypePreference" {
    try testing.expect(candidate.Candidate.getTypePreference(.host) == 126);
    try testing.expect(candidate.Candidate.getTypePreference(.peer_reflexive) == 110);
    try testing.expect(candidate.Candidate.getTypePreference(.server_reflexive) == 100);
    try testing.expect(candidate.Candidate.getTypePreference(.relayed) == 0);
}

test "Candidate toSdpCandidate host" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("192.168.1.100", 54321);
    var cand = try candidate.Candidate.init(
        allocator,
        "foundation1",
        1,
        "udp",
        address,
        .host,
    );
    defer cand.deinit();

    const type_pref = candidate.Candidate.getTypePreference(.host);
    cand.calculatePriority(type_pref, 65534);

    const sdp_str = try cand.toSdpCandidate(allocator);
    defer allocator.free(sdp_str);

    // 注意：toSdpCandidate() 返回的格式不包含 "candidate" 前缀
    // 格式：foundation component transport priority address port typ type
    try testing.expect(std.mem.indexOf(u8, sdp_str, "foundation1") != null);
    try testing.expect(std.mem.indexOf(u8, sdp_str, "typ host") != null);
    try testing.expect(std.mem.indexOf(u8, sdp_str, "192.168.1.100") != null);
    try testing.expect(std.mem.indexOf(u8, sdp_str, "54321") != null);
}

test "Candidate toSdpCandidate with related address" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("192.168.1.100", 54321);
    var cand = try candidate.Candidate.init(
        allocator,
        "foundation1",
        1,
        "udp",
        address,
        .server_reflexive,
    );
    defer cand.deinit();

    cand.related_address = try std.net.Address.parseIp4("10.0.0.1", 12345);
    cand.related_port = 12345;

    const sdp_str = try cand.toSdpCandidate(allocator);
    defer allocator.free(sdp_str);

    try testing.expect(std.mem.indexOf(u8, sdp_str, "raddr 10.0.0.1") != null);
    try testing.expect(std.mem.indexOf(u8, sdp_str, "rport 12345") != null);
}

test "Candidate fromSdpCandidate host" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const candidate_str = "candidate 1 1 UDP 2130706431 192.168.1.100 54321 typ host";
    var cand = try candidate.Candidate.fromSdpCandidate(allocator, candidate_str);
    defer cand.deinit();

    try testing.expectEqualStrings("1", cand.foundation);
    try testing.expect(cand.component_id == 1);
    try testing.expectEqualStrings("UDP", cand.transport);
    try testing.expect(cand.priority == 2130706431);
    try testing.expect(cand.address.getPort() == 54321);
    try testing.expect(cand.typ == .host);
}

test "Candidate fromSdpCandidate server_reflexive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const candidate_str = "candidate 2 1 UDP 1694498815 203.0.113.1 54321 typ srflx raddr 192.168.1.100 rport 54320";
    var cand = try candidate.Candidate.fromSdpCandidate(allocator, candidate_str);
    defer cand.deinit();

    try testing.expect(cand.typ == .server_reflexive);
    try testing.expect(cand.related_address != null);
    try testing.expect(cand.related_port == 54320);
}

test "Candidate fromSdpCandidate invalid format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const invalid_str = "invalid candidate string";
    const result = candidate.Candidate.fromSdpCandidate(allocator, invalid_str);
    try testing.expectError(error.InvalidCandidate, result);
}

test "Candidate fromSdpCandidate invalid type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const invalid_str = "candidate 1 1 UDP 2130706431 192.168.1.100 54321 typ invalid";
    const result = candidate.Candidate.fromSdpCandidate(allocator, invalid_str);
    try testing.expectError(error.InvalidCandidateType, result);
}
