const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module (the library's public API).
    const mod = b.addModule("tilegen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true, // libtilegen.a links into a PIE C++ host
    });

    // Static library (libtilegen.a) — the C ABI surface (src/capi.zig) and the
    // CMake host will link this for live in-process tile generation (M5).
    const lib = b.addLibrary(.{
        .name = "tilegen",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // The offline baker CLI.
    const bake = b.addExecutable(.{
        .name = "bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bake.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tilegen", .module = mod }},
        }),
    });
    b.installArtifact(bake);

    const run_bake = b.addRunArtifact(bake);
    if (b.args) |args| run_bake.addArgs(args);
    b.step("run", "Run the bake CLI").dependOn(&run_bake.step);

    // Tests.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    b.step("test", "Run unit tests").dependOn(&run_mod_tests.step);
}
