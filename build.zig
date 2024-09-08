const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const @"zig-dis-x86_64" = b.dependency("zig-dis-x86_64", .{ .target = target, .optimize = optimize });
    const dis_x86_64 = @"zig-dis-x86_64".module("dis_x86_64");

    const pmparse_dep = b.dependency("pmparse", .{ .target = target, .optimize = optimize });
    const pmparse = pmparse_dep.module("pmparse");

    const zigzag = b.addModule("zigzag", .{ .root_source_file = b.path("src/root.zig") });
    zigzag.addImport("dis_x86_64", dis_x86_64);
    zigzag.addImport("pmparse", pmparse);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/root.zig" } },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    addExample(b, "basic", "Basic example how to (un-)install a hook", zigzag, target, optimize);
    addExample(b, "logging", "Log calls to a function using hooks", zigzag, target, optimize);
}

fn addExample(b: *std.Build, comptime name: []const u8, comptime description: []const u8, zigzag: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const example = b.addExecutable(.{
        .name = name ++ "_example",
        .root_source_file = b.path("examples/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("zigzag", zigzag);

    const run_example = b.addRunArtifact(example);
    const run_example_step = b.step("example." ++ name, description ++ " (Build and run the example)");
    run_example_step.dependOn(&run_example.step);

    const build_example = b.addInstallArtifact(example, .{});
    const build_example_step = b.step("example." ++ name ++ ":install", description ++ " (Only install the artifact)");
    build_example_step.dependOn(&build_example.step);
}
