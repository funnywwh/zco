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

    // 数据通道示例应用
    const datachannel_example = b.addExecutable(.{
        .name = "datachannel_example",
        .root_source_file = b.path("examples/datachannel_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    datachannel_example.root_module.addImport("zco", zco);
    datachannel_example.root_module.addImport("nets", nets);
    datachannel_example.root_module.addImport("websocket", websocket);
    datachannel_example.root_module.addImport("webrtc", webrtc);
    b.installArtifact(datachannel_example);

    const run_datachannel_example_cmd = b.addRunArtifact(datachannel_example);
    run_datachannel_example_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_datachannel_example_cmd.addArgs(args);
    }

    const run_datachannel_example_step = b.step("run-datachannel", "Run the datachannel example");
    run_datachannel_example_step.dependOn(&run_datachannel_example_cmd.step);

    // 数据通道 Echo 示例应用（真正的网络通信）
    const datachannel_echo = b.addExecutable(.{
        .name = "datachannel_echo",
        .root_source_file = b.path("examples/datachannel_echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    datachannel_echo.root_module.addImport("zco", zco);
    datachannel_echo.root_module.addImport("nets", nets);
    datachannel_echo.root_module.addImport("websocket", websocket);
    datachannel_echo.root_module.addImport("webrtc", webrtc);
    b.installArtifact(datachannel_echo);

    const run_datachannel_echo_cmd = b.addRunArtifact(datachannel_echo);
    run_datachannel_echo_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_datachannel_echo_cmd.addArgs(args);
    }

    const run_datachannel_echo_step = b.step("run-echo", "Run the datachannel echo example");
    run_datachannel_echo_step.dependOn(&run_datachannel_echo_cmd.step);

    // 信令服务器应用
    const signaling_server = b.addExecutable(.{
        .name = "signaling_server",
        .root_source_file = b.path("examples/signaling_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    signaling_server.root_module.addImport("zco", zco);
    signaling_server.root_module.addImport("nets", nets);
    signaling_server.root_module.addImport("websocket", websocket);
    signaling_server.root_module.addImport("webrtc", webrtc);
    b.installArtifact(signaling_server);

    const run_signaling_server_cmd = b.addRunArtifact(signaling_server);
    run_signaling_server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_signaling_server_cmd.addArgs(args);
    }

    const run_signaling_server_step = b.step("run-signaling", "Run the signaling server");
    run_signaling_server_step.dependOn(&run_signaling_server_cmd.step);

    // 信令客户端应用
    const signaling_client = b.addExecutable(.{
        .name = "signaling_client",
        .root_source_file = b.path("examples/signaling_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    signaling_client.root_module.addImport("zco", zco);
    signaling_client.root_module.addImport("nets", nets);
    signaling_client.root_module.addImport("websocket", websocket);
    signaling_client.root_module.addImport("webrtc", webrtc);
    b.installArtifact(signaling_client);

    const run_signaling_client_cmd = b.addRunArtifact(signaling_client);
    run_signaling_client_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_signaling_client_cmd.addArgs(args);
    }

    const run_signaling_client_step = b.step("run-client", "Run the signaling client (alice|bob room_id)");
    run_signaling_client_step.dependOn(&run_signaling_client_cmd.step);

    // UDP 测试应用
    const udp_test = b.addExecutable(.{
        .name = "udp_test",
        .root_source_file = b.path("examples/udp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    udp_test.root_module.addImport("zco", zco);
    udp_test.root_module.addImport("nets", nets);
    udp_test.root_module.addImport("websocket", websocket);
    udp_test.root_module.addImport("webrtc", webrtc);
    b.installArtifact(udp_test);

    const run_udp_test_cmd = b.addRunArtifact(udp_test);
    run_udp_test_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_udp_test_cmd.addArgs(args);
    }

    const run_udp_test_step = b.step("run-udp-test", "Run the UDP test");
    run_udp_test_step.dependOn(&run_udp_test_cmd.step);

    // 浏览器兼容性测试服务器
    const browser_compat_server = b.addExecutable(.{
        .name = "browser_compat_server",
        .root_source_file = b.path("examples/browser_compat_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_compat_server.root_module.addImport("zco", zco);
    browser_compat_server.root_module.addImport("nets", nets);
    browser_compat_server.root_module.addImport("websocket", websocket);
    browser_compat_server.root_module.addImport("webrtc", webrtc);
    b.installArtifact(browser_compat_server);

    const run_browser_compat_server_cmd = b.addRunArtifact(browser_compat_server);
    run_browser_compat_server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_browser_compat_server_cmd.addArgs(args);
    }

    const run_browser_compat_server_step = b.step("run-browser-compat-server", "Run the browser compatibility test server");
    run_browser_compat_server_step.dependOn(&run_browser_compat_server_cmd.step);

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

    // PeerConnection DataChannel 列表管理测试
    const datachannel_list_tests = b.addTest(.{
        .root_source_file = b.path("src/peer/connection_datachannel_list_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    datachannel_list_tests.root_module.addImport("zco", zco);
    datachannel_list_tests.root_module.addImport("nets", nets);
    datachannel_list_tests.root_module.addImport("websocket", websocket);
    const run_datachannel_list_tests = b.addRunArtifact(datachannel_list_tests);

    // PeerConnection SCTP 接收测试
    const sctp_receive_tests = b.addTest(.{
        .root_source_file = b.path("src/peer/connection_sctp_receive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sctp_receive_tests.root_module.addImport("zco", zco);
    sctp_receive_tests.root_module.addImport("nets", nets);
    sctp_receive_tests.root_module.addImport("websocket", websocket);
    const run_sctp_receive_tests = b.addRunArtifact(sctp_receive_tests);

    // SCTP DataChannel 发送/接收测试
    const datachannel_send_tests = b.addTest(.{
        .root_source_file = b.path("src/sctp/datachannel_send_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    datachannel_send_tests.root_module.addImport("zco", zco);
    datachannel_send_tests.root_module.addImport("nets", nets);
    const run_datachannel_send_tests = b.addRunArtifact(datachannel_send_tests);

    // SCTP DataChannel 事件测试
    const datachannel_events_tests = b.addTest(.{
        .root_source_file = b.path("src/sctp/datachannel_events_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    datachannel_events_tests.root_module.addImport("zco", zco);
    datachannel_events_tests.root_module.addImport("nets", nets);
    const run_datachannel_events_tests = b.addRunArtifact(datachannel_events_tests);

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
    test_step.dependOn(&run_datachannel_send_tests.step);
    test_step.dependOn(&run_datachannel_events_tests.step);
    test_step.dependOn(&run_datachannel_list_tests.step);
    test_step.dependOn(&run_sctp_receive_tests.step);
}
