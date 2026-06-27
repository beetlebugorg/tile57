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

// Re-import the foundational packages (iso8211/s57/s100/mvt) into a consumer
// module (engine, libtile57.a, the baker). One place keeps the edge list in sync.
fn addPkgs(mod: *std.Build.Module, iso8211_mod: *std.Build.Module, s57_mod: *std.Build.Module, s100_mod: *std.Build.Module, mvt_mod: *std.Build.Module) void {
    mod.addImport("iso8211", iso8211_mod);
    mod.addImport("s57", s57_mod);
    mod.addImport("s100", s100_mod);
    mod.addImport("mvt", mvt_mod);
}

// Add a `zig build test` artifact for a standalone package module. A split
// module's `test {}` blocks do NOT run via the engine test binary (importing a
// module doesn't pull its tests in), so each package is tested through its own
// root with a concrete target. `imports` wire its dependency modules (the
// target-agnostic package objects, which inherit this target). Returns the test
// module so the caller can attach extra inputs (e.g. addCatalogueJson).
fn addPkgTest(
    b: *std.Build,
    step: *std.Build.Step,
    src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    const tm = b.createModule(.{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tm })).step);
    return tm;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Foundational packages, mirroring the Go oracle's pkg/iso8211, pkg/s57,
    // pkg/s100. Pure Zig (no libc/Lua) and target-agnostic: they omit target/
    // optimize so the same module objects compile under both the glibc test/lib
    // build and the static-musl baker build, inheriting each consumer's target.
    // DAG: iso8211 <- s57 <- s100. The embedded catalogue JSON rides on s100
    // (its only @embedFile user is s100/catalogue.zig). See specs/bundle-bake.md.
    const iso8211_mod = b.addModule("iso8211", .{
        .root_source_file = b.path("src/iso8211/iso8211.zig"),
    });
    const s57_mod = b.addModule("s57", .{
        .root_source_file = b.path("src/s57/s57.zig"),
        .imports = &.{.{ .name = "iso8211", .module = iso8211_mod }},
    });
    const s100_mod = b.addModule("s100", .{
        .root_source_file = b.path("src/s100/s100.zig"),
        .imports = &.{.{ .name = "s57", .module = s57_mod }},
    });
    addCatalogueJson(b, s100_mod);

    // MVT (Mapbox Vector Tile) encoder — pure, target-agnostic leaf, mirroring
    // the Go oracle's internal/engine/mvt. Used by tile/pmtiles/s57_mvt.
    const mvt_mod = b.addModule("mvt", .{
        .root_source_file = b.path("src/mvt/mvt.zig"),
    });

    // Asset/style generation for the chart bundle (colortables, manifest, …).
    // Pure + target-agnostic like the foundational packages, so it compiles
    // under both the glibc tests and the static-musl baker. See src/assets/.
    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("src/assets/assets.zig"),
    });

    // Pure-Zig public module (no libc). Used by the unit tests so that
    // Zig-linked test binary doesn't pull in the system crt.
    const mod = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPkgs(mod, iso8211_mod, s57_mod, s100_mod, mvt_mod);
    mod.addImport("assets", assets_mod); // engine re-exports it; tests cover it

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
    addPkgs(lib_mod, iso8211_mod, s57_mod, s100_mod, mvt_mod);
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
    addPkgs(bake_engine, iso8211_mod, s57_mod, s100_mod, mvt_mod);
    addLua(b, bake_engine);

    const bake = b.addExecutable(.{
        .name = "chartplotter-bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bake.zig"),
            .target = bake_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine", .module = bake_engine },
                .{ .name = "assets", .module = assets_mod },
            },
        }),
    });
    b.installArtifact(bake);

    const run_bake = b.addRunArtifact(bake);
    if (b.args) |args| run_bake.addArgs(args);
    b.step("run", "Run the bake CLI").dependOn(&run_bake.step);

    // Tests. The engine module (root.zig) covers its own files — the relative-
    // imported gzip/pmtiles/tile/s57_mvt/bake_enc + the MVT parity test. Each
    // standalone package is tested through its own root (addPkgTest), since a
    // module import does NOT pull another module's `test {}` blocks in.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    _ = addPkgTest(b, test_step, "src/iso8211/iso8211.zig", target, optimize, &.{});
    _ = addPkgTest(b, test_step, "src/s57/s57.zig", target, optimize, &.{
        .{ .name = "iso8211", .module = iso8211_mod },
    });
    const s100_test = addPkgTest(b, test_step, "src/s100/s100.zig", target, optimize, &.{
        .{ .name = "s57", .module = s57_mod },
    });
    addCatalogueJson(b, s100_test); // catalogue.zig @embedFile's the JSON
    _ = addPkgTest(b, test_step, "src/mvt/mvt.zig", target, optimize, &.{});
    _ = addPkgTest(b, test_step, "src/assets/assets.zig", target, optimize, &.{});
}
