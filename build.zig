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

    const basic_example = b.addExecutable(.{
        .name = "basic_example",
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    basic_example.root_module.addImport("zigzag", zigzag);
    const run_basic_example = b.addRunArtifact(basic_example);
    const basic_example_step = b.step("example.basic", "Run a basic example");
    basic_example_step.dependOn(&run_basic_example.step);

    const logging_example = b.addExecutable(.{
        .name = "logging_example",
        .root_source_file = b.path("examples/logging.zig"),
        .target = target,
        .optimize = optimize,
    });
    logging_example.root_module.addImport("zigzag", zigzag);
    const run_logging_example = b.addRunArtifact(logging_example);
    const logging_example_step = b.step("example.logging", "Run an example using hooks for call logs");
    logging_example_step.dependOn(&run_logging_example.step);
}
