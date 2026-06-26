const std = @import("std");

// Lua 5.4 core sources (vendored from lua.org), minus the standalone mains.
const lua_sources = [_][]const u8{
    "lapi.c",    "lauxlib.c", "lbaselib.c", "lcode.c",   "lcorolib.c", "lctype.c",
    "ldblib.c",  "ldebug.c",  "ldo.c",      "ldump.c",   "lfunc.c",    "lgc.c",
    "linit.c",   "liolib.c",  "llex.c",     "lmathlib.c", "lmem.c",    "loadlib.c",
    "lobject.c", "lopcodes.c", "loslib.c",  "lparser.c", "lstate.c",   "lstring.c",
    "lstrlib.c", "ltable.c",  "ltablib.c",  "ltm.c",     "lundump.c",  "lutf8lib.c",
    "lvm.c",     "lzio.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pure-Zig public module (no libc). Used by the tests and the bake CLI so
    // those Zig-linked executables don't pull in the system crt.
    const mod = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The distilled S-101 catalogue + S-57 numeric code tables, embedded.
    mod.addAnonymousImport("catalogue_json", .{ .root_source_file = b.path("vendor/s101/catalogue.json") });
    mod.addAnonymousImport("s57codes_json", .{ .root_source_file = b.path("vendor/s101/s57codes.json") });

    // Static library (libchartplotter.a): C ABI + embedded Lua. Its own root so
    // the C sources / libc only land in the archive (linked by the C++ host),
    // never in a Zig-linked exe.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib_root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true, // links into a PIE C++ host
        .link_libc = true, // Lua needs the C runtime
    });
    lib_mod.addAnonymousImport("catalogue_json", .{ .root_source_file = b.path("vendor/s101/catalogue.json") });
    lib_mod.addAnonymousImport("s57codes_json", .{ .root_source_file = b.path("vendor/s101/s57codes.json") });
    lib_mod.addIncludePath(b.path("vendor/lua/src"));
    lib_mod.addCSourceFile(.{ .file = b.path("csrc/lua_shim.c"), .flags = &.{"-DLUA_USE_POSIX"} });
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/lua/src"),
        .files = &lua_sources,
        .flags = &.{ "-std=gnu99", "-DLUA_USE_POSIX", "-O2" },
    });
    const lib = b.addLibrary(.{ .name = "chartplotter", .linkage = .static, .root_module = lib_mod });
    b.installArtifact(lib);

    // The offline baker / inspector CLI (pure Zig).
    const bake = b.addExecutable(.{
        .name = "bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bake.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "engine", .module = mod }},
        }),
    });
    b.installArtifact(bake);

    const run_bake = b.addRunArtifact(bake);
    if (b.args) |args| run_bake.addArgs(args);
    b.step("run", "Run the bake CLI").dependOn(&run_bake.step);

    // Tests (pure Zig).
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    b.step("test", "Run unit tests").dependOn(&run_mod_tests.step);
}
