const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zco = b.dependency("zco", .{}).module("zco");
    const nets = b.dependency("nets", .{ .target = target, .optimize = optimize }).module("nets");
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize }).module("websocket");

    const lib = b.addStaticLibrary(.{
        .name = "webrtc",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("zco", zco);
    lib.root_module.addImport("nets", nets);
    lib.root_module.addImport("websocket", websocket);

    const webrtc = b.addModule("webrtc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc.addImport("zco", zco);
    webrtc.addImport("nets", nets);
    webrtc.addImport("websocket", websocket);

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "webrtc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zco", zco);
    exe.root_module.addImport("nets", nets);
    exe.root_module.addImport("websocket", websocket);
    exe.root_module.addImport("webrtc", webrtc);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the webrtc example");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("zco", zco);
    lib_unit_tests.root_module.addImport("nets", nets);
    lib_unit_tests.root_module.addImport("websocket", websocket);

    // SDP 测试
    const sdp_tests = b.addTest(.{
        .root_source_file = b.path("src/signaling/sdp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_sdp_tests = b.addRunArtifact(sdp_tests);

    // 消息测试
    const message_tests = b.addTest(.{
        .root_source_file = b.path("src/signaling/message_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    message_tests.root_module.addImport("zco", zco);
    message_tests.root_module.addImport("nets", nets);
    message_tests.root_module.addImport("websocket", websocket);
    const run_message_tests = b.addRunArtifact(message_tests);

    // STUN 测试
    const stun_tests = b.addTest(.{
        .root_source_file = b.path("src/ice/stun_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stun_tests.root_module.addImport("zco", zco);
    stun_tests.root_module.addImport("nets", nets);
    const run_stun_tests = b.addRunArtifact(stun_tests);

    // Candidate 测试
    const candidate_tests = b.addTest(.{
        .root_source_file = b.path("src/ice/candidate_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    candidate_tests.root_module.addImport("zco", zco);
    candidate_tests.root_module.addImport("nets", nets);
    const run_candidate_tests = b.addRunArtifact(candidate_tests);

    // ICE Agent 测试
    const agent_tests = b.addTest(.{
        .root_source_file = b.path("src/ice/agent_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tests.root_module.addImport("zco", zco);
    agent_tests.root_module.addImport("nets", nets);
    const run_agent_tests = b.addRunArtifact(agent_tests);

    // TURN 测试
    const turn_tests = b.addTest(.{
        .root_source_file = b.path("src/ice/turn_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    turn_tests.root_module.addImport("zco", zco);
    turn_tests.root_module.addImport("nets", nets);
    const run_turn_tests = b.addRunArtifact(turn_tests);

    // DTLS 记录层测试
    const record_tests = b.addTest(.{
        .root_source_file = b.path("src/dtls/record_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    record_tests.root_module.addImport("zco", zco);
    record_tests.root_module.addImport("nets", nets);
    const run_record_tests = b.addRunArtifact(record_tests);

    // DTLS 密钥派生测试
    const key_derivation_tests = b.addTest(.{
        .root_source_file = b.path("src/dtls/key_derivation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_key_derivation_tests = b.addRunArtifact(key_derivation_tests);

    // DTLS 握手协议测试
    const handshake_tests = b.addTest(.{
        .root_source_file = b.path("src/dtls/handshake_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    handshake_tests.root_module.addImport("zco", zco);
    handshake_tests.root_module.addImport("nets", nets);
    const run_handshake_tests = b.addRunArtifact(handshake_tests);

    // DTLS ECDHE 测试
    const ecdh_tests = b.addTest(.{
        .root_source_file = b.path("src/dtls/ecdh_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_ecdh_tests = b.addRunArtifact(ecdh_tests);

    // SRTP 测试
    const srtp_replay_tests = b.addTest(.{
        .root_source_file = b.path("src/srtp/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_srtp_replay_tests = b.addRunArtifact(srtp_replay_tests);

    const srtp_crypto_tests = b.addTest(.{
        .root_source_file = b.path("src/srtp/crypto_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_srtp_crypto_tests = b.addRunArtifact(srtp_crypto_tests);

    const srtp_context_tests = b.addTest(.{
        .root_source_file = b.path("src/srtp/context_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_srtp_context_tests = b.addRunArtifact(srtp_context_tests);

    const srtp_transform_tests = b.addTest(.{
        .root_source_file = b.path("src/srtp/transform_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_srtp_transform_tests = b.addRunArtifact(srtp_transform_tests);

    const rtp_packet_tests = b.addTest(.{
        .root_source_file = b.path("src/rtp/packet_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    rtp_packet_tests.root_module.addImport("zco", zco);
    const run_rtp_packet_tests = b.addRunArtifact(rtp_packet_tests);

    const rtp_ssrc_tests = b.addTest(.{
        .root_source_file = b.path("src/rtp/ssrc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    rtp_ssrc_tests.root_module.addImport("zco", zco);
    const run_rtp_ssrc_tests = b.addRunArtifact(rtp_ssrc_tests);

    const rtp_rtcp_tests = b.addTest(.{
        .root_source_file = b.path("src/rtp/rtcp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    rtp_rtcp_tests.root_module.addImport("zco", zco);
    const run_rtp_rtcp_tests = b.addRunArtifact(rtp_rtcp_tests);

    const sctp_chunk_tests = b.addTest(.{
        .root_source_file = b.path("src/sctp/chunk_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sctp_chunk_tests.root_module.addImport("zco", zco);
    const run_sctp_chunk_tests = b.addRunArtifact(sctp_chunk_tests);

    const sctp_association_tests = b.addTest(.{
        .root_source_file = b.path("src/sctp/association_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sctp_association_tests.root_module.addImport("zco", zco);
    const run_sctp_association_tests = b.addRunArtifact(sctp_association_tests);

    const sctp_stream_tests = b.addTest(.{
        .root_source_file = b.path("src/sctp/stream_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sctp_stream_tests.root_module.addImport("zco", zco);
    const run_sctp_stream_tests = b.addRunArtifact(sctp_stream_tests);

    const sctp_datachannel_tests = b.addTest(.{
        .root_source_file = b.path("src/sctp/datachannel_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sctp_datachannel_tests.root_module.addImport("zco", zco);
    const run_sctp_datachannel_tests = b.addRunArtifact(sctp_datachannel_tests);

    // Media Track 测试
    const media_track_tests = b.addTest(.{
        .root_source_file = b.path("src/media/track_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_media_track_tests = b.addRunArtifact(media_track_tests);

    // PeerConnection Sender 测试
    const sender_tests = b.addTest(.{
        .root_source_file = b.path("src/peer/sender_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sender_tests.root_module.addImport("zco", zco);
    sender_tests.root_module.addImport("nets", nets);
    sender_tests.root_module.addImport("websocket", websocket);
    const run_sender_tests = b.addRunArtifact(sender_tests);

    // PeerConnection Receiver 测试
    const receiver_tests = b.addTest(.{
        .root_source_file = b.path("src/peer/receiver_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    receiver_tests.root_module.addImport("zco", zco);
    receiver_tests.root_module.addImport("nets", nets);
    receiver_tests.root_module.addImport("websocket", websocket);
    const run_receiver_tests = b.addRunArtifact(receiver_tests);

    // Media Codec 测试
    const codec_tests = b.addTest(.{
        .root_source_file = b.path("src/media/codec_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_codec_tests = b.addRunArtifact(codec_tests);

    // PeerConnection DataChannel 测试
    const datachannel_tests = b.addTest(.{
        .root_source_file = b.path("src/peer/connection_datachannel_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    datachannel_tests.root_module.addImport("zco", zco);
    datachannel_tests.root_module.addImport("nets", nets);
    datachannel_tests.root_module.addImport("websocket", websocket);
    const run_datachannel_tests = b.addRunArtifact(datachannel_tests);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_sdp_tests.step);
    test_step.dependOn(&run_message_tests.step);
    test_step.dependOn(&run_stun_tests.step);
    test_step.dependOn(&run_candidate_tests.step);
    test_step.dependOn(&run_agent_tests.step);
    test_step.dependOn(&run_turn_tests.step);
    test_step.dependOn(&run_record_tests.step);
    test_step.dependOn(&run_key_derivation_tests.step);
    test_step.dependOn(&run_handshake_tests.step);
    test_step.dependOn(&run_ecdh_tests.step);
    test_step.dependOn(&run_srtp_replay_tests.step);
    test_step.dependOn(&run_srtp_crypto_tests.step);
    test_step.dependOn(&run_srtp_context_tests.step);
    test_step.dependOn(&run_srtp_transform_tests.step);
    test_step.dependOn(&run_rtp_packet_tests.step);
    test_step.dependOn(&run_rtp_ssrc_tests.step);
    test_step.dependOn(&run_rtp_rtcp_tests.step);
    test_step.dependOn(&run_sctp_chunk_tests.step);
    test_step.dependOn(&run_sctp_association_tests.step);
    test_step.dependOn(&run_sctp_stream_tests.step);
    test_step.dependOn(&run_sctp_datachannel_tests.step);
    test_step.dependOn(&run_media_track_tests.step);
    test_step.dependOn(&run_sender_tests.step);
    test_step.dependOn(&run_receiver_tests.step);
    test_step.dependOn(&run_codec_tests.step);
    test_step.dependOn(&run_datachannel_tests.step);
}
