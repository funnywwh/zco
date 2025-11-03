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

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_sdp_tests.step);
    test_step.dependOn(&run_message_tests.step);
    test_step.dependOn(&run_stun_tests.step);
    test_step.dependOn(&run_candidate_tests.step);
    test_step.dependOn(&run_agent_tests.step);
    test_step.dependOn(&run_turn_tests.step);
}
