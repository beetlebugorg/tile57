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

// The distilled S-101 catalogue + S-57 numeric code tables, embedded. They live
// under vendor/, outside any module's src/ root, so they're added as named
// imports (catalogue.zig @embedFile's them) rather than relative @embedFile.
fn addCatalogueJson(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("catalogue_json", .{ .root_source_file = b.path("vendor/s101/catalogue.json") });
    mod.addAnonymousImport("s57codes_json", .{ .root_source_file = b.path("vendor/s101/s57codes.json") });
}

// Attach the embedded Lua 5.4 interpreter + the portrayal C shim to a module.
// Used for both libtile57.a (lib_root) and the bake CLI (bake_root); keeping it
// in one place stops the library and the baker drifting apart.
fn addLua(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/lua/src"));
    mod.addCSourceFile(.{ .file = b.path("csrc/lua_shim.c"), .flags = &.{"-DLUA_USE_POSIX"} });
    mod.addCSourceFiles(.{
        .root = b.path("vendor/lua/src"),
        .files = &lua_sources,
        .flags = &.{ "-std=gnu99", "-DLUA_USE_POSIX", "-O2" },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pure-Zig public module (no libc). Used by the unit tests so that
    // Zig-linked test binary doesn't pull in the system crt.
    const mod = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCatalogueJson(b, mod);

    // Static library (libtile57.a): C ABI + embedded Lua. Its own root so
    // the C sources / libc only land in the archive (linked by the C++ host),
    // never in a Zig-linked exe.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib_root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true, // links into a PIE C++ host
        .link_libc = true, // Lua needs the C runtime
    });
    addCatalogueJson(b, lib_mod);
    addLua(b, lib_mod);
    const lib = b.addLibrary(.{ .name = "tile57", .linkage = .static, .root_module = lib_mod });
    b.installArtifact(lib);

    // The offline baker / inspector CLI. It runs the embedded-Lua S-101 portrayal
    // so baked tiles get full S-101 styling (not the classify() fallback), so —
    // unlike the unit tests — its engine module is bake_root.zig (root.zig +
    // portray.zig) and it links libc + the vendored Lua / shim C sources, exactly
    // like libtile57.a. root.zig stays pure for the test build.
    // On a glibc Linux host, link the baker against Zig's own static musl rather
    // than the system libc. Zig's self-hosted ELF linker can't link a modern
    // glibc's crt1.o (it carries an .sframe section with R_X86_64_PC64
    // relocations the linker rejects), and forcing LLD segfaults the compiler.
    // musl ships with Zig and links cleanly into a self-contained static binary.
    // Other hosts (e.g. macOS Mach-O) keep the requested target; the library and
    // unit tests are unaffected (libtile57.a is linked by clang++ in the C++
    // host, and the tests are pure Zig with no libc).
    const bake_target = if (target.result.os.tag == .linux and target.result.abi != .musl)
        b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .linux, .abi = .musl })
    else
        target;

    const bake_engine = b.createModule(.{
        .root_source_file = b.path("src/bake_root.zig"),
        .target = bake_target,
        .optimize = optimize,
        .link_libc = true, // Lua needs the C runtime
    });
    addCatalogueJson(b, bake_engine);
    addLua(b, bake_engine);

    const bake = b.addExecutable(.{
        .name = "chartplotter-bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bake.zig"),
            .target = bake_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "engine", .module = bake_engine }},
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
