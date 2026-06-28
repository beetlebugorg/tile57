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
// Attached to the `portray` module — which both libtile57.a and the baker import
// — so the Lua runtime is defined once and can't drift between them.
fn addLua(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/lua/src"));
    mod.addCSourceFile(.{ .file = b.path("src/portray/lua_shim.c"), .flags = &.{"-DLUA_USE_POSIX"} });
    mod.addCSourceFiles(.{
        .root = b.path("vendor/lua/src"),
        .files = &lua_sources,
        .flags = &.{ "-std=gnu99", "-DLUA_USE_POSIX", "-O2" },
    });
}

// Attach the vendored SVG rasterizer (nanosvg) + PNG encoder (stb_image_write)
// behind svgraster.c to a module. Used by the `sprite` module (sprite/pattern
// atlas generation in the bake tool). Single-header C libs; need libc.
fn addSvgRaster(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/nanosvg"));
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{ .file = b.path("src/sprite/svgraster.c"), .flags = &.{ "-std=gnu99", "-O2" } });
}

// Re-import the pure packages into a consumer module (engine, libtile57.a, the
// baker). One list keeps the edge set in sync across all three.
fn addPkgs(mod: *std.Build.Module, pkgs: []const std.Build.Module.Import) void {
    for (pkgs) |p| mod.addImport(p.name, p.module);
}

// The shared MVT round-trip fixture (used by pmtiles + the mvt parity test). It
// lives under src/testdata/, outside any single module root, so it rides as an
// anonymous import rather than a relative @embedFile.
fn addMvtFixture(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("mvt_fixture", .{ .root_source_file = b.path("src/testdata/annapolis_z14.mvt") });
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

    // Tile-encoding packages (mirror the Go oracle's internal/engine/{mvt,tile,
    // pmtiles}), pure + target-agnostic. DAG: gzip, mvt (leaves) <- tile, pmtiles.
    const mvt_mod = b.addModule("mvt", .{
        .root_source_file = b.path("src/mvt/mvt.zig"),
    });
    const gzip_mod = b.addModule("gzip", .{
        .root_source_file = b.path("src/gzip/gzip.zig"),
    });
    const tile_mod = b.addModule("tile", .{
        .root_source_file = b.path("src/tile/tile.zig"),
        .imports = &.{.{ .name = "mvt", .module = mvt_mod }},
    });
    const pmtiles_mod = b.addModule("pmtiles", .{
        .root_source_file = b.path("src/pmtiles/pmtiles.zig"),
        .imports = &.{ .{ .name = "gzip", .module = gzip_mod }, .{ .name = "mvt", .module = mvt_mod } },
    });

    // S-57 -> MVT tile generation (s57_mvt) + the banded ENC_ROOT baker (bake_enc,
    // mirrors the Go oracle's internal/engine/baker). Pure; s57_mvt <- bake_enc.
    const s57_mvt_mod = b.addModule("s57_mvt", .{
        .root_source_file = b.path("src/s57_mvt/s57_mvt.zig"),
        .imports = &.{
            .{ .name = "s57", .module = s57_mod },
            .{ .name = "s100", .module = s100_mod },
            .{ .name = "mvt", .module = mvt_mod },
            .{ .name = "tile", .module = tile_mod },
        },
    });
    const bake_enc_mod = b.addModule("bake_enc", .{
        .root_source_file = b.path("src/bake_enc/bake_enc.zig"),
        .imports = &.{
            .{ .name = "s57", .module = s57_mod },
            .{ .name = "s57_mvt", .module = s57_mvt_mod },
            .{ .name = "pmtiles", .module = pmtiles_mod },
            .{ .name = "tile", .module = tile_mod },
        },
    });

    // S-101 portrayal runner: drives the embedded Lua rule engine over a cell's
    // adapted features (mirrors Go's internal/engine/portrayal). Owns the Lua
    // attachment (the C shim + vendored Lua) so libc/Lua is encapsulated here,
    // not spread across the lib + baker modules. pic so the same code links into
    // both the PIE C++ host (libtile57.a) and the static baker. The pure engine
    // module does NOT import it, so `zig build test` stays libc-free.
    const portray_mod = b.addModule("portray", .{
        .root_source_file = b.path("src/portray/portray.zig"),
        .link_libc = true,
        .pic = true,
        .imports = &.{
            .{ .name = "s57", .module = s57_mod },
            .{ .name = "s100", .module = s100_mod },
        },
    });
    addLua(b, portray_mod);

    // Asset/style generation for the chart bundle (colortables, manifest, …).
    // Pure + target-agnostic like the foundational packages, so it compiles
    // under both the glibc tests and the static-musl baker. See src/assets/.
    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("src/assets/assets.zig"),
    });

    // Chart-style generation: patch a MapLibre style template per the mariner's
    // S-52 display options (a 1:1 Zig port of the C++ chartstyle/ module). Pure +
    // target-agnostic; consumed by the C ABI (capi.zig) so tile57 ships tile +
    // style generation together. See src/chartstyle/.
    const chartstyle_mod = b.addModule("chartstyle", .{
        .root_source_file = b.path("src/chartstyle/chartstyle.zig"),
    });

    // S-101 sprite/pattern atlas builder (nanosvg + stb PNG). libc (the C libs),
    // target-less so it inherits the consumer's target (only the bake tool, which
    // already links libc for Lua). Not in pure_pkgs — the tests stay libc-free.
    const sprite_mod = b.addModule("sprite", .{
        .root_source_file = b.path("src/sprite/sprite.zig"),
        .link_libc = true,
    });
    addSvgRaster(b, sprite_mod);

    // All pure packages, imported by name into engine / libtile57.a / the baker.
    // (portray is libc, wired separately into the lib + baker only.)
    const pure_pkgs = [_]std.Build.Module.Import{
        .{ .name = "iso8211", .module = iso8211_mod },
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "s100", .module = s100_mod },
        .{ .name = "gzip", .module = gzip_mod },
        .{ .name = "mvt", .module = mvt_mod },
        .{ .name = "tile", .module = tile_mod },
        .{ .name = "pmtiles", .module = pmtiles_mod },
        .{ .name = "s57_mvt", .module = s57_mvt_mod },
        .{ .name = "bake_enc", .module = bake_enc_mod },
        .{ .name = "assets", .module = assets_mod },
        .{ .name = "chartstyle", .module = chartstyle_mod },
    };

    // Pure-Zig public module (no libc). Used by the unit tests so that
    // Zig-linked test binary doesn't pull in the system crt.
    const mod = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPkgs(mod, &pure_pkgs);
    addMvtFixture(b, mod); // mvt_parity_test (in the engine module) embeds it

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
    addPkgs(lib_mod, &pure_pkgs);
    lib_mod.addImport("portray", portray_mod);
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
    addPkgs(bake_engine, &pure_pkgs);
    bake_engine.addImport("portray", portray_mod);

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
                .{ .name = "sprite", .module = sprite_mod },
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
    _ = addPkgTest(b, test_step, "src/gzip/gzip.zig", target, optimize, &.{});
    _ = addPkgTest(b, test_step, "src/tile/tile.zig", target, optimize, &.{
        .{ .name = "mvt", .module = mvt_mod },
    });
    const pmtiles_test = addPkgTest(b, test_step, "src/pmtiles/pmtiles.zig", target, optimize, &.{
        .{ .name = "gzip", .module = gzip_mod },
        .{ .name = "mvt", .module = mvt_mod },
    });
    addMvtFixture(b, pmtiles_test); // pmtiles.zig's round-trip test embeds it
    _ = addPkgTest(b, test_step, "src/s57_mvt/s57_mvt.zig", target, optimize, &.{
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "s100", .module = s100_mod },
        .{ .name = "mvt", .module = mvt_mod },
        .{ .name = "tile", .module = tile_mod },
    });
    _ = addPkgTest(b, test_step, "src/bake_enc/bake_enc.zig", target, optimize, &.{
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "s57_mvt", .module = s57_mvt_mod },
        .{ .name = "pmtiles", .module = pmtiles_mod },
        .{ .name = "tile", .module = tile_mod },
    });
    _ = addPkgTest(b, test_step, "src/assets/assets.zig", target, optimize, &.{});
    _ = addPkgTest(b, test_step, "src/chartstyle/chartstyle.zig", target, optimize, &.{});
}
