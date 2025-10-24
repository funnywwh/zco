const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize }).module("xev");

    const zco = b.addModule("zco", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("./src/root.zig"),
    });
    zco.link_libc = true;
    zco.addImport("xev", xev);

    const lib = b.addStaticLibrary(.{
        .name = "zco",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("zco", zco);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zco",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    // exe.linkSystemLibrary("rt");
    exe.root_module.addImport("zco", zco);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // lib_unit_tests.linkSystemLibrary("rt");
    lib_unit_tests.root_module.addImport("zco", zco);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // exe_unit_tests.linkSystemLibrary("rt");
    exe_unit_tests.root_module.addImport("zco", zco);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    // 添加抢占演示程序
    const demo_exe = b.addExecutable(.{
        .name = "example_preemption",
        .root_source_file = b.path("example_preemption.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_exe.linkLibC();
    demo_exe.root_module.addImport("zco", zco);
    demo_exe.root_module.addImport("xev", xev);
    b.installArtifact(demo_exe);

    const demo_run_cmd = b.addRunArtifact(demo_exe);
    demo_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        demo_run_cmd.addArgs(args);
    }
    b.step("demo", "Run the preemption demo").dependOn(&demo_run_cmd.step);
}
