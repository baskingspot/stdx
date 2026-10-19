const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The only exported module. Everything below is developer-only: returning
    // early for a consumer keeps testingx and the docs steps out of its fetch
    // graph.
    const mod = b.addModule("stdx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner and the bench engine. It is lazy
    // because only the root build uses it; a consumer never fetches it. On the
    // first configure pass it is not fetched yet, `lazyDependency` returns
    // null, and the build runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = test_runner,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    // Only the module suite takes runner flags: a filter that matches none of
    // the examples' tests would fail that binary.
    if (b.args) |args| run_mod_tests.addArgs(args);

    const test_step = b.step("test", "Run stdx tests");
    test_step.dependOn(&run_mod_tests.step);

    // The guide's examples (docs/examples) are real programs against the
    // public module, tested with everything else.
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("docs/examples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stdx", .module = mod }},
    });
    const example_tests = b.addTest(.{
        .root_module = examples_mod,
        .test_runner = test_runner,
    });
    const run_example_tests = b.addRunArtifact(example_tests);
    run_example_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    test_step.dependOn(&run_example_tests.step);

    // Fuzzing needs the built-in runner: testingx's main rejects fuzz mode
    // because the fuzzer speaks a private protocol. `just fuzz` drives this.
    const fuzz_tests = b.addTest(.{ .root_module = mod });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.has_side_effects = true;
    const fuzz_step = b.step("fuzz", "Fuzz the module (built-in test runner)");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    const mod_docs = b.addObject(.{
        .name = "stdx",
        .root_module = mod,
    });
    // The site serves the API reference under /api/, and Zola copies
    // docs/static as is, so the reference installs there. `zig-out` is not the
    // destination because Zola owns the site output directory.
    const docs_install = b.addInstallDirectory(.{
        .source_dir = mod_docs.getEmittedDocs(),
        .install_dir = .{ .custom = "../docs/static/api" },
        .install_subdir = "",
    });
    const docs_step = b.step("docs", "Generate API docs into docs/static/api");
    docs_step.dependOn(&docs_install.step);

    if (b.lazyImport(@This(), "testingx")) |testingx| {
        const testingx_dependency = testingx_dep orelse unreachable;
        const run_bench = testingx.addBench(b, .{
            .module = testingx_dependency.module("testingx"),
            .root_source_file = b.path("src/bench.zig"),
            .imports = &.{.{ .name = "stdx", .module = mod }},
            .target = target,
        });
        if (b.args) |args| run_bench.addArgs(args);

        const bench_step = b.step("bench", "Run stdx benchmarks");
        bench_step.dependOn(&run_bench.step);
    }
}
