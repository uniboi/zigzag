const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const @"zig-dis-x86_64" = b.dependency("zig-dis-x86_64", .{ .target = target, .optimize = optimize });
    const dis_x86_64 = @"zig-dis-x86_64".module("dis_x86_64");

    const pmparse_dep = b.dependency("pmparse", .{ .target = target, .optimize = optimize });
    const pmparse = pmparse_dep.module("pmparse");

    const lib = b.addStaticLibrary(.{
        .name = "zigzag",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/root.zig" } },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zigzag",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("dis_x86_64", dis_x86_64);
    exe.root_module.addImport("pmparse", pmparse);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    const exampleLib = b.addSharedLibrary(.{ .name = "cExampleLib", .target = target, .optimize = optimize });
    exampleLib.addCSourceFile(.{ .file = .{ .src_path = .{ .owner = b, .sub_path = "csrc/add.c" } }, .flags = &.{} });
    exampleLib.linkLibC();

    b.installArtifact(exampleLib);

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
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/root.zig" } },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
