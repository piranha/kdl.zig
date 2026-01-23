const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module for external use
    const kdl_module = b.addModule("kdl", .{
        .root_source_file = b.path("src/kdl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = kdl_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Test runner for official KDL test suite
    const test_runner_module = b.addModule("test_runner", .{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_runner_module.addImport("kdl", kdl_module);

    const test_runner = b.addExecutable(.{
        .name = "test_runner",
        .root_module = test_runner_module,
    });

    const run_test_runner = b.addRunArtifact(test_runner);
    run_test_runner.addArg("tests/test_cases");

    const suite_step = b.step("test-suite", "Run official KDL test suite");
    suite_step.dependOn(&run_test_runner.step);
}
