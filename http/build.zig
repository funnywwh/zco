const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zco = b.dependency("zco", .{}).module("zco");
    const nets = b.dependency("nets", .{ .target = target, .optimize = optimize }).module("nets");
    const io = b.dependency("io", .{ .target = target, .optimize = optimize }).module("io");
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize }).module("websocket");

    const lib = b.addStaticLibrary(.{
        .name = "http",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("zco", zco);
    lib.root_module.addImport("nets", nets);
    lib.root_module.addImport("io", io);
    lib.root_module.addImport("websocket", websocket);

    b.installArtifact(lib);

    const http = b.addModule("http", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    http.addImport("zco", zco);
    http.addImport("nets", nets);
    http.addImport("io", io);
    http.addImport("websocket", websocket);

    const exe = b.addExecutable(.{
        .name = "http",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addImport("zco", zco);
    exe.root_module.addImport("nets", nets);
    exe.root_module.addImport("io", io);
    exe.root_module.addImport("websocket", websocket);
    exe.root_module.addImport("http", http);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the http server");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("zco", zco);
    lib_unit_tests.root_module.addImport("nets", nets);
    lib_unit_tests.root_module.addImport("io", io);
    lib_unit_tests.root_module.addImport("websocket", websocket);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

