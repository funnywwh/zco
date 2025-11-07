const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 获取依赖
    const zco = b.dependency("zco", .{}).module("zco");
    const nets = b.dependency("nets", .{ .target = target, .optimize = optimize }).module("nets");

    // 创建可执行文件
    const exe = b.addExecutable(.{
        .name = "zig_server",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.root_module.addImport("zco", zco);
    exe.root_module.addImport("nets", nets);

    // 安装可执行文件
    b.installArtifact(exe);

    // 创建运行步骤
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);
}
