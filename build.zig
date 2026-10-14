const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("stdx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run stdx tests");
    test_step.dependOn(&run_mod_tests.step);

    const mod_docs = b.addObject(.{
        .name = "stdx",
        .root_module = mod,
    });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = mod_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "zig-docs",
    });
    const docs_step = b.step("docs", "Generate API docs");
    docs_step.dependOn(&docs_install.step);
}
