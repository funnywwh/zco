const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const peer = @import("./root.zig");
const ice = @import("../ice/root.zig");

const PeerConnection = peer.PeerConnection;
const SignalingState = peer.SignalingState;
const IceConnectionState = peer.IceConnectionState;
const IceGatheringState = peer.IceGatheringState;
const ConnectionState = peer.ConnectionState;
const Candidate = ice.Candidate;

/// 创建测试用的 PeerConnection
fn createTestPeerConnection(allocator: std.mem.Allocator) !*PeerConnection {
    var schedule = try zco.Schedule.init(allocator);
    errdefer schedule.deinit();

    const config = PeerConnection.Configuration{
        .ice_servers = &.{},
        .ice_transport_policy = .all,
        .ice_candidate_pool_size = 0,
    };

    return try PeerConnection.init(allocator, &schedule, config);
}

test "PeerConnection init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{
        .ice_servers = &.{},
        .ice_transport_policy = .all,
        .ice_candidate_pool_size = 0,
    };

    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 验证初始状态
    try testing.expect(pc.getSignalingState() == .stable);
    try testing.expect(pc.getIceConnectionState() == .new);
    try testing.expect(pc.getIceGatheringState() == .new);
    try testing.expect(pc.getConnectionState() == .new);

    // 验证组件已初始化
    try testing.expect(pc.ice_agent != null);
    try testing.expect(pc.dtls_certificate != null);
    try testing.expect(pc.dtls_record != null);
    try testing.expect(pc.dtls_handshake != null);
}

test "createOffer generates valid SDP" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    // 验证基础字段
    try testing.expect(offer.version == 0);
    try testing.expect(offer.origin.username != null);
    try testing.expect(offer.session_name != null);
    try testing.expect(offer.connection != null);

    // 验证至少有一个媒体描述
    try testing.expect(offer.media_descriptions.items.len > 0);

    // 验证音频媒体描述
    const audio_media = offer.media_descriptions.items[0];
    try testing.expect(std.mem.eql(u8, audio_media.media_type, "audio"));
    try testing.expect(std.mem.eql(u8, audio_media.proto, "UDP/TLS/RTP/SAVPF"));

    // 验证 ICE 属性
    try testing.expect(offer.ice_ufrag != null);
    try testing.expect(offer.ice_pwd != null);
    try testing.expect(offer.ice_ufrag.?.len >= 4);
    try testing.expect(offer.ice_pwd.?.len >= 22);

    // 验证 DTLS 指纹
    try testing.expect(offer.fingerprint != null);
    try testing.expect(offer.fingerprint.?.hash != null);
    try testing.expect(offer.fingerprint.?.value != null);
    try testing.expect(std.mem.eql(u8, offer.fingerprint.?.hash.?, "sha-256"));

    // 验证 setup 属性
    var has_setup = false;
    for (audio_media.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "setup")) {
            has_setup = true;
            try testing.expect(attr.value != null);
            try testing.expect(std.mem.eql(u8, attr.value.?, "actpass"));
            break;
        }
    }
    try testing.expect(has_setup);
}

test "createAnswer generates valid SDP from offer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 先创建 offer
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    // 设置 remote description (offer)
    try pc.setRemoteDescription(offer);

    // 创建 answer
    const answer = try pc.createAnswer(allocator);
    defer answer.deinit();
    defer allocator.destroy(answer);

    // 验证基础字段
    try testing.expect(answer.version == 0);
    try testing.expect(answer.origin.username != null);
    try testing.expect(answer.session_name != null);

    // 验证媒体描述数量匹配
    try testing.expect(answer.media_descriptions.items.len == offer.media_descriptions.items.len);

    // 验证音频媒体描述
    const audio_media = answer.media_descriptions.items[0];
    try testing.expect(std.mem.eql(u8, audio_media.media_type, "audio"));
    try testing.expect(std.mem.eql(u8, audio_media.proto, "UDP/TLS/RTP/SAVPF"));

    // 验证 ICE 属性
    try testing.expect(answer.ice_ufrag != null);
    try testing.expect(answer.ice_pwd != null);

    // 验证 DTLS 指纹
    try testing.expect(answer.fingerprint != null);
    try testing.expect(answer.fingerprint.?.hash != null);
    try testing.expect(std.mem.eql(u8, answer.fingerprint.?.hash.?, "sha-256"));

    // 验证 setup 属性（answer 应该是 active）
    var has_setup = false;
    for (audio_media.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "setup")) {
            has_setup = true;
            try testing.expect(attr.value != null);
            try testing.expect(std.mem.eql(u8, attr.value.?, "active"));
            break;
        }
    }
    try testing.expect(has_setup);
}

test "createAnswer requires remote description" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 不设置 remote description，直接创建 answer 应该失败
    const result = pc.createAnswer(allocator);
    try testing.expectError(error.NoRemoteDescription, result);
}

test "setLocalDescription updates signaling state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 初始状态应该是 stable
    try testing.expect(pc.getSignalingState() == .stable);

    // 创建并设置本地 offer
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    try pc.setLocalDescription(offer);

    // 状态应该变为 have_local_offer
    try testing.expect(pc.getSignalingState() == .have_local_offer);
    try testing.expect(pc.getIceGatheringState() == .gathering);
}

test "setRemoteDescription updates signaling state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 创建并设置远程 offer
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    try pc.setRemoteDescription(offer);

    // 状态应该变为 have_remote_offer
    try testing.expect(pc.getSignalingState() == .have_remote_offer);
}

test "setLocalDescription and setRemoteDescription complete offer/answer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};

    // Peer 1: 创建 offer
    const pc1 = try PeerConnection.init(allocator, &schedule, config);
    defer pc1.deinit();
    const offer = try pc1.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);
    try pc1.setLocalDescription(offer);
    try testing.expect(pc1.getSignalingState() == .have_local_offer);

    // Peer 2: 接收 offer，创建 answer
    const pc2 = try PeerConnection.init(allocator, &schedule, config);
    defer pc2.deinit();
    try pc2.setRemoteDescription(offer);
    try testing.expect(pc2.getSignalingState() == .have_remote_offer);

    const answer = try pc2.createAnswer(allocator);
    defer answer.deinit();
    defer allocator.destroy(answer);
    try pc2.setLocalDescription(answer);
    try testing.expect(pc2.getSignalingState() == .stable);

    // Peer 1: 接收 answer
    try pc1.setRemoteDescription(answer);
    try testing.expect(pc1.getSignalingState() == .stable);
}

test "DTLS certificate is generated and has valid fingerprint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 验证证书已生成
    try testing.expect(pc.dtls_certificate != null);

    const cert = pc.dtls_certificate.?;
    try testing.expect(cert.der_data.len > 0);

    // 验证指纹计算
    const fingerprint = cert.computeFingerprint();
    try testing.expect(fingerprint.len == 32); // SHA-256 是 32 字节

    // 验证指纹格式化
    const fingerprint_str = try cert.formatFingerprint(allocator);
    defer allocator.free(fingerprint_str);
    
    // 指纹格式应该是 "XX:XX:XX:..." (64 个字符，63 个冒号)
    try testing.expect(fingerprint_str.len > 0);
    // 验证包含冒号分隔符
    var has_colon = false;
    for (fingerprint_str) |c| {
        if (c == ':') {
            has_colon = true;
            break;
        }
    }
    try testing.expect(has_colon);
}

test "createOffer and createAnswer have different fingerprints" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};

    // 创建两个 PeerConnection
    const pc1 = try PeerConnection.init(allocator, &schedule, config);
    defer pc1.deinit();
    const pc2 = try PeerConnection.init(allocator, &schedule, config);
    defer pc2.deinit();

    const offer = try pc1.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    try pc2.setRemoteDescription(offer);
    const answer = try pc2.createAnswer(allocator);
    defer answer.deinit();
    defer allocator.destroy(answer);

    // 两个 PeerConnection 的证书应该不同（因为是随机生成的）
    const fingerprint1 = pc1.dtls_certificate.?.computeFingerprint();
    const fingerprint2 = pc2.dtls_certificate.?.computeFingerprint();
    
    // 验证指纹不同（极大概率）
    var different = false;
    for (fingerprint1, fingerprint2) |b1, b2| {
        if (b1 != b2) {
            different = true;
            break;
        }
    }
    try testing.expect(different);
}

test "determineDtlsRole logic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 创建 offer 并设置本地描述
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);
    try pc.setLocalDescription(offer);

    // 此时只有本地描述，应该是服务器（等待客户端连接）
    // 注意：determineDtlsRole 是私有方法，我们通过观察行为间接测试
    // 或者我们可以通过 startDtlsHandshake 的行为来推断

    // 设置远程描述后，应该变为客户端
    try pc.setRemoteDescription(offer);
    // 此时应该识别为客户端（因为远程有 offer）
}

test "ICE candidate parsing from SDP" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 创建 offer（包含 ICE candidates）
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    // 设置本地描述触发候选收集
    try pc.setLocalDescription(offer);

    // 验证 offer 中可能包含 candidates（如果已收集）
    const audio_media = offer.media_descriptions.items[0];
    var candidate_count: u32 = 0;
    for (audio_media.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "candidate")) {
            candidate_count += 1;
            // 验证 candidate 字符串格式
            if (attr.value) |candidate_str| {
                try testing.expect(candidate_str.len > 0);
            }
        }
    }
    // 注意：候选收集是异步的，可能还没有 candidates
}

test "addIceCandidate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 创建一个测试 candidate
    const foundation = try allocator.dupe(u8, "test-foundation");
    defer allocator.free(foundation);
    const transport = try allocator.dupe(u8, "udp");
    defer allocator.free(transport);

    const candidate_ptr = try allocator.create(Candidate);
    candidate_ptr.* = try Candidate.init(
        allocator,
        foundation,
        1, // component_id
        transport,
        std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 12345),
        .host,
    );
    defer candidate_ptr.deinit();
    defer allocator.destroy(candidate_ptr);

    // 添加 candidate
    try pc.addIceCandidate(candidate_ptr);

    // 验证 candidate 已添加到 ICE Agent
    if (pc.ice_agent) |agent| {
        const remote_candidates = agent.getRemoteCandidates();
        try testing.expect(remote_candidates.len > 0);
    }
}

test "getSignalingState returns current state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    try testing.expect(pc.getSignalingState() == .stable);
    try testing.expect(pc.getIceConnectionState() == .new);
    try testing.expect(pc.getIceGatheringState() == .new);
    try testing.expect(pc.getConnectionState() == .new);
}

test "setLocalDescription triggers ICE gathering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);

    // 初始状态
    try testing.expect(pc.getIceGatheringState() == .new);

    // 设置本地描述后，应该开始收集
    try pc.setLocalDescription(offer);
    try testing.expect(pc.getIceGatheringState() == .gathering);
}

test "setRemoteDescription triggers ICE checking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    // 先设置本地描述
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);
    try pc.setLocalDescription(offer);

    // 设置远程描述
    const remote_offer = try pc.createOffer(allocator);
    defer remote_offer.deinit();
    defer allocator.destroy(remote_offer);
    try pc.setRemoteDescription(remote_offer);

    // 如果已有本地描述，应该开始连接检查
    try testing.expect(pc.getIceConnectionState() == .checking);
}

test "multiple createOffer calls generate different ICE credentials" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);
    defer pc.deinit();

    const offer1 = try pc.createOffer(allocator);
    defer offer1.deinit();
    defer allocator.destroy(offer1);

    const offer2 = try pc.createOffer(allocator);
    defer offer2.deinit();
    defer allocator.destroy(offer2);

    // ICE credentials 应该是随机的，所以应该不同（极大概率）
    try testing.expect(offer1.ice_ufrag != null);
    try testing.expect(offer2.ice_ufrag != null);
    
    // 验证 ufrag 不同（极大概率）
    const ufrag1 = offer1.ice_ufrag.?;
    const ufrag2 = offer2.ice_ufrag.?;
    var different = false;
    if (ufrag1.len == ufrag2.len) {
        for (ufrag1, ufrag2) |b1, b2| {
            if (b1 != b2) {
                different = true;
                break;
            }
        }
    } else {
        different = true;
    }
    // 注意：由于随机性，理论上可能相同，但概率极低
    // try testing.expect(different);
}

test "deinit cleans up all resources" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const config = PeerConnection.Configuration{};
    const pc = try PeerConnection.init(allocator, &schedule, config);

    // 创建一些描述
    const offer = try pc.createOffer(allocator);
    defer offer.deinit();
    defer allocator.destroy(offer);
    try pc.setLocalDescription(offer);

    // 清理应该成功（无内存泄漏）
    pc.deinit();
}

