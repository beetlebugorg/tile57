const std = @import("std");

// The vendored S-101 PortrayalCatalog, relative to the engine/ build root. Its
// Rules (Lua) + Symbols/LineStyles/AreaFills/ColorProfiles (assets) are embedded
// into the binary so tile57 portrays + styles charts with no on-disk catalogue.
const PORTRAYAL_CATALOG = "vendor/S-101_Portrayal-Catalogue/PortrayalCatalog";

// Lua 5.4 core sources (vendored from lua.org), minus the standalone mains.
const lua_sources = [_][]const u8{
    "lapi.c",    "lauxlib.c",  "lbaselib.c", "lcode.c",    "lcorolib.c", "lctype.c",
    "ldblib.c",  "ldebug.c",   "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
    "linit.c",   "liolib.c",   "llex.c",     "lmathlib.c", "lmem.c",     "loadlib.c",
    "lobject.c", "lopcodes.c", "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
    "lstrlib.c", "ltable.c",   "ltablib.c",  "ltm.c",      "lundump.c",  "lutf8lib.c",
    "lvm.c",     "lzio.c",
};

// The distilled S-101 catalogue + S-57 numeric code tables, embedded. They live
// under vendor/, outside any module's src/ root, so they're added as named
// imports (catalogue.zig @embedFile's them) rather than relative @embedFile.
fn addCatalogueJson(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("catalogue_json", .{ .root_source_file = b.path("vendor/s101/catalogue.json") });
    mod.addAnonymousImport("s57codes_json", .{ .root_source_file = b.path("vendor/s101/s57codes.json") });
    mod.addAnonymousImport("permitted_json", .{ .root_source_file = b.path("vendor/s101/permitted.json") });
}

// Attach the embedded Lua 5.4 interpreter + the portrayal C shim to a module.
// Attached to the `portray` module — which both libtile57.a and the baker import
// — so the Lua runtime is defined once and can't drift between them.
//
// `posix`: define LUA_USE_POSIX (Unix). On Windows it must stay OFF — forcing it
// pulls in <unistd.h>/dlopen; without it luaconf.h auto-selects LUA_USE_WINDOWS
// from _WIN32. lua_shim.c is already portable (only getenv + ANSI stdio).
fn addLua(b: *std.Build, mod: *std.Build.Module, posix: bool) void {
    mod.addIncludePath(b.path("vendor/lua/src"));
    const shim_flags: []const []const u8 = if (posix) &.{"-DLUA_USE_POSIX"} else &.{};
    mod.addCSourceFile(.{ .file = b.path("src/portray/lua_shim.c"), .flags = shim_flags });
    const lua_flags: []const []const u8 = if (posix)
        &.{ "-std=gnu99", "-DLUA_USE_POSIX", "-O2" }
    else
        &.{ "-std=gnu99", "-O2" };
    mod.addCSourceFiles(.{
        .root = b.path("vendor/lua/src"),
        .files = &lua_sources,
        .flags = lua_flags,
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

// Embed every `ext` file under the build-root-relative `dir_rel` into a generated
// Zig module that exposes:
//     pub const Entry = struct { name: []const u8, bytes: []const u8 };
//     pub const entries = [_]Entry{ ... };
// where `name` is the file stem (the Lua `require` name / asset id) and `bytes`
// is the file content, @embedFile'd. Each file rides as a tracked anonymous
// import, so editing or adding a resource re-triggers the build. The directory is
// walked at configure time (host fs) and the entries are sorted for a
// reproducible build. Used to bake the S-101 portrayal catalogue (Rules, Symbols,
// LineStyles, …) into the binary so tile57 needs no on-disk catalogue at runtime.
fn embedDir(b: *std.Build, registry_name: []const u8, dir_rel: []const u8, ext: []const u8) *std.Build.Module {
    const io = b.graph.io;
    const abs = b.pathFromRoot(dir_rel);
    var dir = std.Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true }) catch |e|
        std.debug.panic("embedDir: cannot open '{s}': {s} (run `git submodule update --init --recursive`?)", .{ abs, @errorName(e) });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |e| std.debug.panic("embedDir: iterate '{s}': {s}", .{ abs, @errorName(e) })) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);

    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "pub const Entry = struct { name: []const u8, bytes: []const u8 };\n") catch @panic("OOM");
    src.appendSlice(b.allocator, "pub const entries = [_]Entry{\n") catch @panic("OOM");
    for (names.items) |fname| {
        const stem = fname[0 .. fname.len - ext.len];
        const line = b.fmt("    .{{ .name = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ stem, fname });
        src.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const wf = b.addWriteFiles();
    const reg_mod = b.createModule(.{ .root_source_file = wf.add(b.fmt("{s}.zig", .{registry_name}), src.items) });
    for (names.items) |fname| {
        reg_mod.addAnonymousImport(fname, .{ .root_source_file = b.path(b.pathJoin(&.{ dir_rel, fname })) });
    }
    return reg_mod;
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
    // Default to ReleaseFast: the tile57 CLI is a compute-heavy baking tool, and a
    // Debug build bakes ~2.6x slower (no inlining/hoisting/vectorisation). A plain
    // `zig build` (gen-style.sh, ad-hoc bakes) should produce a fast binary; pass
    // `-Doptimize=Debug` (or ReleaseSafe) for development. (The C++ host's
    // libtile57.a already builds ReleaseFast explicitly via CMake / zig-build-lib.sh,
    // which pass -Doptimize and so still work.) NB: not standardOptimizeOption's
    // preferred_optimize_mode — that keeps the no-flag default at Debug and drops
    // the -Doptimize option entirely.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    // Lua: POSIX feature flags on Unix; Windows lets luaconf.h auto-pick
    // LUA_USE_WINDOWS. The portray module is target-agnostic (it inherits each
    // consumer's target), but on a given host the lib + baker share this OS, so
    // gate the flag on the top-level target.
    const lua_posix = target.result.os.tag != .windows;

    // Foundational packages, mirroring the Go oracle's pkg layout. Pure Zig (no
    // libc/Lua) and target-agnostic: they omit target/optimize so the same module
    // objects compile under both the glibc test/lib build and the static-musl
    // baker build, inheriting each consumer's target.
    // DAG: iso8211 <- s57 <- s101; tiles (leaf) <- render <- scene.
    // The embedded catalogue JSON rides on s101 (catalogue.zig @embedFile's it).
    //
    // ISO/IEC 8211 container reader (src/iso8211/): the bottom layer, a pure
    // std-only leaf. Its own module so a consumer can decode 8211 records
    // without depending on any S-57 semantics.
    const iso8211_mod = b.addModule("iso8211", .{
        .root_source_file = b.path("src/iso8211/iso8211.zig"),
    });
    const s57_mod = b.addModule("s57", .{
        .root_source_file = b.path("src/s57/s57.zig"),
        .imports = &.{.{ .name = "iso8211", .module = iso8211_mod }},
    });
    const s101_mod = b.addModule("s101", .{
        .root_source_file = b.path("src/s101/s101.zig"),
        .imports = &.{.{ .name = "s57", .module = s57_mod }},
    });
    addCatalogueJson(b, s101_mod);

    // Tile encoding + addressing (src/tiles/): MVT + MLT encoders, gzip, the
    // PMTiles container, and web-mercator tile math. One pure leaf module
    // (mirrors the Go oracle's internal/engine/{mvt,tile,pmtiles}).
    const tiles_mod = b.addModule("tiles", .{
        .root_source_file = b.path("src/tiles/tiles.zig"),
    });

    // Render engine (src/render/): the semantic Surface contract + noop
    // surface, the resolver (colors at palette, display gates), and the pixel
    // machinery (Canvas primitive seam, RasterCanvas, PNG encoder, PixelSurface).
    // One pure module; imports tiles (TilePoint alias) + style (settings model)
    // only — never s57/s101/portray. NOTE: declared before style_mod exists,
    // so that edge is attached right after style_mod below.
    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/render/render.zig"),
        .imports = &.{.{ .name = "tiles", .module = tiles_mod }},
    });
    // The embedded label face (render/font.zig @embedFile's it; OFL 1.1 —
    // see THIRD_PARTY_LICENSES.md).
    const addFont = struct {
        fn f(bb: *std.Build, m: *std.Build.Module) void {
            m.addAnonymousImport("font_ttf", .{ .root_source_file = bb.path("vendor/fonts/NotoSans-Regular.ttf") });
        }
    }.f;
    addFont(b, render_mod);

    // Integer computational geometry (src/geometry/): the Martinez polygon boolean +
    // the coverage-clipped best-available partition. Pure (std-only); the scene
    // engine + baker use it for the cross-band composite.
    const geometry_mod = b.addModule("geometry", .{ .root_source_file = b.path("src/geometry/geometry.zig") });

    // Per-cell M_COVR coverage sidecar (src/coverage/): CellCoverage plus the
    // fromCell / encodeJson / decodeFromMetadata round-trip carried in PMTiles
    // metadata. Pure over s57 (the LonLat point type) + std.json; the baker writes
    // it and the compositor reads it.
    const coverage_mod = b.addModule("coverage", .{
        .root_source_file = b.path("src/coverage/coverage.zig"),
        .imports = &.{.{ .name = "s57", .module = s57_mod }},
    });

    // The tile engine (src/scene/): S-57 -> tile-surface generation plus the
    // banded ENC_ROOT baker (bake_enc.zig, mirrors the Go oracle's
    // internal/engine/baker — folded in as the engine's batch driver).
    const scene_mod = b.addModule("scene", .{
        .root_source_file = b.path("src/scene/scene.zig"),
        .imports = &.{
            .{ .name = "s57", .module = s57_mod },
            .{ .name = "s101", .module = s101_mod },
            .{ .name = "tiles", .module = tiles_mod },
            .{ .name = "render", .module = render_mod },
            .{ .name = "geometry", .module = geometry_mod },
            .{ .name = "coverage", .module = coverage_mod },
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
            .{ .name = "s101", .module = s101_mod },
        },
    });
    addLua(b, portray_mod, lua_posix);
    // Embed the S-101 Lua rules (216 framework + feature-class files) so the Lua
    // `require` searcher in lua_shim.c can load them from memory — tile57 portrays
    // S-57 cells with no on-disk catalogue. An explicit rules dir still overrides.
    portray_mod.addImport("rules_registry", embedDir(b, "rules_registry", PORTRAYAL_CATALOG ++ "/Rules", ".lua"));

    // MapLibre style generation (src/style/): color tables, line styles, the
    // style.json layer set (maplibre.zig), and the S-52 mariner settings model +
    // expression builders (chartstyle.zig, a Zig port of the web client's
    // s52-style.mjs builders). Consumed by the C ABI, the CLI, and the render
    // resolver's settings model. Pure + target-agnostic.
    const style_mod = b.addModule("style", .{
        .root_source_file = b.path("src/style/style.zig"),
    });
    // The render module's settings-model edge (declared above style_mod).
    render_mod.addImport("style", style_mod);
    // The scene module's complex-linestyle XML analysis (also declared above).
    scene_mod.addImport("style", style_mod);

    // S-101 sprite/pattern atlas builder (nanosvg + stb PNG). libc (the C libs),
    // target-less so it inherits the consumer's target (only the bake tool, which
    // already links libc for Lua). Not in pure_pkgs — the tests stay libc-free.
    const sprite_mod = b.addModule("sprite", .{
        .root_source_file = b.path("src/sprite/sprite.zig"),
        .link_libc = true,
        // render: the vector-symbol types (symbols.Symbol/SymbolStore) the
        // CatalogStore produces for the pixel path.
        .imports = &.{.{ .name = "render", .module = render_mod }},
    });
    addSvgRaster(b, sprite_mod);

    // All pure packages, imported by name into engine / libtile57.a / the baker.
    // (portray is libc, wired separately into the lib + baker only.)
    const pure_pkgs = [_]std.Build.Module.Import{
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "s101", .module = s101_mod },
        .{ .name = "tiles", .module = tiles_mod },
        .{ .name = "scene", .module = scene_mod },
        .{ .name = "render", .module = render_mod },
        .{ .name = "style", .module = style_mod },
        .{ .name = "geometry", .module = geometry_mod },
    };

    // Full engine surface (the pure root.zig packages + the embedded-Lua `portray`
    // module) as ONE import named "engine", via bake_root.zig. Target-agnostic: it
    // inherits each consumer's target, so the static-musl baker, libtile57.a (host
    // target), and the shared bundle module below all compile it against their own
    // target over the same singleton leaf packages.
    const engine_full = b.createModule(.{
        .root_source_file = b.path("src/bake_root.zig"),
        .link_libc = true, // portray (embedded Lua) needs the C runtime
    });
    addPkgs(engine_full, &pure_pkgs);
    engine_full.addImport("portray", portray_mod);

    // The embedded S-52 colour profile. Built ONCE and shared: the C ABI imports it
    // directly (tile57_colortables_default / tile57_style_template) AND it rides on
    // catalog_embed below. A second embedDir for the same dir would create a second
    // same-named module and collide in the libtile57.a build (where both are present).
    const colorprofile_registry = embedDir(b, "colorprofile_registry", PORTRAYAL_CATALOG ++ "/ColorProfiles", ".xml");

    // The S-101 portrayal *assets* embedded into the binary: symbol SVGs, the palette
    // CSS, line-style + area-fill XML, and the colour profile. The bundle pipeline
    // emits colortables / sprites / patterns / style.json from these with no on-disk
    // catalogue; a --catalog / positional dir still overrides (read from disk). Shared
    // by the CLI baker AND libtile57.a (so the C ABI bake_bundle needs no catalogue).
    const catalog_embed = b.createModule(.{ .root_source_file = b.path("tools/catalog_embed.zig") });
    catalog_embed.addImport("symbols_registry", embedDir(b, "symbols_registry", PORTRAYAL_CATALOG ++ "/Symbols", ".svg"));
    catalog_embed.addImport("css_registry", embedDir(b, "css_registry", PORTRAYAL_CATALOG ++ "/Symbols", ".css"));
    catalog_embed.addImport("linestyles_registry", embedDir(b, "linestyles_registry", PORTRAYAL_CATALOG ++ "/LineStyles", ".xml"));
    catalog_embed.addImport("areafills_registry", embedDir(b, "areafills_registry", PORTRAYAL_CATALOG ++ "/AreaFills", ".xml"));
    catalog_embed.addImport("colorprofile_registry", colorprofile_registry);

    // The chart-bundle module: S-101 portrayal asset emission + the per-cell composite
    // (ownership partition + on-demand compositor). Target-agnostic + libc (the sprite
    // atlas builder), so the CLI baker AND libtile57.a share the SAME emitters over the
    // shared singleton packages. See src/bundle.zig.
    const bundle_mod = b.createModule(.{
        .root_source_file = b.path("src/bundle.zig"),
        .link_libc = true,
        .imports = &.{
            .{ .name = "engine", .module = engine_full },
            .{ .name = "style", .module = style_mod },
            .{ .name = "sprite", .module = sprite_mod },
            .{ .name = "catalog", .module = catalog_embed },
        },
    });

    // Pure-Zig public module (no libc). Used by the unit tests so that
    // Zig-linked test binary doesn't pull in the system crt.
    const mod = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPkgs(mod, &pure_pkgs);
    addMvtFixture(b, mod); // mvt_parity_test (in the engine module) embeds it

    // Public, consumable Zig library module: `@import("tile57")` after adding this
    // package as a dependency. The curated public surface (src/tile57.zig) — the
    // full engine API (Source/bake/style), so it links libc + the Lua portrayal
    // engine like libtile57.a. (Consumers wanting only the libc-free format/encode
    // packages can import those directly.)
    const tile57_mod = b.addModule("tile57", .{
        .root_source_file = b.path("src/tile57.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPkgs(tile57_mod, &pure_pkgs);
    tile57_mod.addImport("portray", portray_mod);
    tile57_mod.addImport("sprite", sprite_mod); // sprite/pattern atlas generation

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
    lib_mod.addImport("sprite", sprite_mod); // C ABI: sprite/pattern atlas generation
    lib_mod.addImport("bundle", bundle_mod); // C ABI: the whole chart-bundle pipeline (bake_bundle)
    // The full engine surface as a NAMED import (not a root.zig file-import), so the
    // single root.zig file isn't claimed by both lib_mod and engine_full (which bundle
    // pulls in) — Zig requires each file to belong to exactly one module per artifact.
    lib_mod.addImport("engine", engine_full);
    // The S-52 colour profile (shared module, built once above) so the C ABI can
    // generate the colortables + base style template with no on-disk catalogue
    // (tile57_colortables_default / tile57_style_template).
    lib_mod.addImport("colorprofile_registry", colorprofile_registry);
    lib_mod.addImport("catalog", catalog_embed); // chart.renderView symbol/pattern store
    const lib = b.addLibrary(.{ .name = "tile57", .linkage = .static, .root_module = lib_mod });
    // Bundle compiler-rt INTO the static archive. A non-Zig linker (the CGO host's gcc/clang,
    // `go test`) has no access to Zig's compiler-rt, so builtins the code references — e.g.
    // `roundq` (f128 @round, pulled in by std.json's number→int coercion in coverage decode) —
    // would be undefined at link time. Static libs default to NOT bundling it; force it on so
    // libtile57.a is self-contained for C consumers.
    lib.bundle_compiler_rt = true;
    if (target.result.os.tag == .macos) {
        // Apple's ld64 rejects 64-bit mach-o archive members whose offsets aren't
        // 8-byte aligned, and Zig's archiver doesn't align them — so the raw
        // `zig build` archive fails to link into the CGO host ("... not 8-byte
        // aligned"). Re-pack it here, as part of the build, so a plain `zig build`
        // alone emits an ld64-compatible libtile57.a (no wrapper needed):
        // scripts/macho-align.sh partial-links every member into one relocatable
        // object and re-wraps it with Apple's libtool. See the script for why.
        const repack = b.addSystemCommand(&.{b.pathFromRoot("scripts/macho-align.sh")});
        repack.setEnvironmentVariable("ZIG", b.graph.zig_exe); // `zig ar` need not be on PATH
        repack.addFileArg(lib.getEmittedBin());
        const aligned = repack.addOutputFileArg("libtile57.a");
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned, "libtile57.a").step);
    } else {
        b.installArtifact(lib);
    }

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
    // The chart layer (src/chart.zig) as a module for the CLI: streaming
    // ENC_ROOT open + band-quilted view rendering (`tile57 png|pdf <ENC_ROOT>`).
    // The lib compiles the same file relatively (capi/tile57 roots); this is a
    // separate compilation for the separate binary.
    const chart_mod = b.createModule(.{
        .root_source_file = b.path("src/chart.zig"),
        .link_libc = true, // portray (embedded Lua)
        .imports = &.{
            .{ .name = "s57", .module = s57_mod },
            .{ .name = "s101", .module = s101_mod },
            .{ .name = "tiles", .module = tiles_mod },
            .{ .name = "scene", .module = scene_mod },
            .{ .name = "render", .module = render_mod },
            .{ .name = "portray", .module = portray_mod },
            .{ .name = "sprite", .module = sprite_mod },
            .{ .name = "catalog", .module = catalog_embed },
        },
    });
    chart_mod.addImport("style", style_mod); // linestyle XML analysis

    const bake_target = if (target.result.os.tag == .linux and target.result.abi != .musl)
        b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .linux, .abi = .musl })
    else
        target;

    const bake = b.addExecutable(.{
        .name = "tile57",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/main.zig"),
            .target = bake_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine", .module = engine_full },
                .{ .name = "style", .module = style_mod },
                .{ .name = "sprite", .module = sprite_mod },
                .{ .name = "catalog", .module = catalog_embed },
                .{ .name = "bundle", .module = bundle_mod },
                .{ .name = "render", .module = render_mod }, // renderpng pixel path
                .{ .name = "chart", .module = chart_mod }, // ENC_ROOT view renders
            },
        }),
    });
    b.installArtifact(bake);

    const run_bake = b.addRunArtifact(bake);
    if (b.args) |args| run_bake.addArgs(args);
    b.step("run", "Run the bake CLI").dependOn(&run_bake.step);

    // S-57 -> S-101 portrayal attribute-coverage check (conformance recon; see
    // conformance-testability plan). Pure std, no engine imports — it just
    // reads vendor/s101/*.json + the vendored Lua rules from disk at run time.
    // Runs from the repo root (build cwd), so its default relative paths resolve.
    const cov = b.addExecutable(.{
        .name = "s101-coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/s101_coverage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cov = b.addRunArtifact(cov);
    if (b.args) |args| run_cov.addArgs(args);
    b.step("s101-coverage", "Scan S-101 portrayal rules and check adapter attribute coverage").dependOn(&run_cov.step);

    // ---- JS/wasm style engine (bindings/) -----------------------------------
    //
    // A tiny entry point that compiles `chartstyle.buildStyle` to wasm so a
    // front-end can turn S-52 mariner settings into a MapLibre style.json fully
    // client-side. The MapLibre template + S-52 colortables are @embedFile'd (as
    // anonymous imports, mirroring addCatalogueJson) so the wasm needs no file
    // inputs. The shared settings parser is reused by the native parity oracle so
    // the two backends can't drift. All additive — a plain `zig build` / `zig
    // build test` is unaffected; `zig build wasm` builds the wasm.
    const style_settings_mod = b.addModule("style_settings", .{
        .root_source_file = b.path("bindings/shared/settings.zig"),
        .imports = &.{.{ .name = "style", .module = style_mod }},
    });

    // Attach the embedded template + colortables to a bindings consumer module.
    const addStyleAssets = struct {
        fn f(bb: *std.Build, m: *std.Build.Module) void {
            m.addAnonymousImport("template_json", .{ .root_source_file = bb.path("bindings/wasm/assets/template.json") });
            m.addAnonymousImport("colortables_json", .{ .root_source_file = bb.path("bindings/wasm/assets/colortables.json") });
        }
    }.f;

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("bindings/wasm/style_wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall, // smallest wasm; this isn't a hot path
        .imports = &.{
            .{ .name = "style", .module = style_mod },
            .{ .name = "settings", .module = style_settings_mod },
        },
    });
    addStyleAssets(b, wasm_mod);
    const wasm = b.addExecutable(.{ .name = "style-engine", .root_module = wasm_mod });
    wasm.entry = .disabled; // reactor-style: no _start, just the exported fns
    wasm.rdynamic = true; // export the `export fn`s into the wasm export table
    const wasm_step = b.step("wasm", "Build the wasm style engine (bindings/)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // Native parity oracle: same engine + same template/colortables/settings,
    // native target. `zig build style-parity` builds it; the parity script diffs
    // its output against the wasm/JS output.
    const parity_mod = b.createModule(.{
        .root_source_file = b.path("bindings/parity/parity.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "style", .module = style_mod },
            .{ .name = "settings", .module = style_settings_mod },
        },
    });
    addStyleAssets(b, parity_mod);
    const parity = b.addExecutable(.{ .name = "style-parity", .root_module = parity_mod });
    b.step("style-parity", "Build the native style-parity oracle (bindings/)")
        .dependOn(&b.addInstallArtifact(parity, .{}).step);

    // Tests. The engine module (root.zig) covers its own files — the relative-
    // imported gzip/pmtiles/tile/scene/bake_enc + the MVT parity test. Each
    // standalone package is tested through its own root (addPkgTest), since a
    // module import does NOT pull another module's `test {}` blocks in.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    // The sprite module (SDF glyph atlas lives here): needs the C glue
    // (stb_truetype/nanosvg) + libc + render.
    const sprite_test = addPkgTest(b, test_step, "src/sprite/sprite.zig", target, optimize, &.{
        .{ .name = "render", .module = render_mod },
    });
    sprite_test.link_libc = true;
    addSvgRaster(b, sprite_test);

    _ = addPkgTest(b, test_step, "src/iso8211/iso8211.zig", target, optimize, &.{});
    _ = addPkgTest(b, test_step, "src/s57/s57.zig", target, optimize, &.{
        .{ .name = "iso8211", .module = iso8211_mod },
    });
    const s101_test = addPkgTest(b, test_step, "src/s101/s101.zig", target, optimize, &.{
        .{ .name = "s57", .module = s57_mod },
    });
    addCatalogueJson(b, s101_test); // catalogue.zig @embedFile's the JSON
    const tiles_test = addPkgTest(b, test_step, "src/tiles/tiles.zig", target, optimize, &.{});
    addMvtFixture(b, tiles_test); // pmtiles.zig's round-trip test embeds it
    _ = addPkgTest(b, test_step, "src/scene/scene.zig", target, optimize, &.{
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "s101", .module = s101_mod },
        .{ .name = "tiles", .module = tiles_mod },
        .{ .name = "render", .module = render_mod },
        .{ .name = "style", .module = style_mod },
        .{ .name = "geometry", .module = geometry_mod },
    });
    _ = addPkgTest(b, test_step, "src/style/style.zig", target, optimize, &.{});
    // Geometry core for the cross-band composition (pure, std-only).
    _ = addPkgTest(b, test_step, "src/geometry/geometry.zig", target, optimize, &.{});
    // Compose core (clip-to-face): pure over mvt + geometry. Its own step for fast iteration,
    // and part of the main suite.
    const compose_deps = [_]std.Build.Module.Import{
        .{ .name = "tiles", .module = tiles_mod },
        .{ .name = "geometry", .module = geometry_mod },
    };
    const compose_step = b.step("compose-test", "Run the compose-core (clip-to-face) tests");
    _ = addPkgTest(b, compose_step, "src/scene/compose.zig", target, optimize, &compose_deps);
    _ = addPkgTest(b, test_step, "src/scene/compose.zig", target, optimize, &compose_deps);

    // The chart-bundle module hosts the per-cell composite (composeTile / ComposeSource). Its full
    // dep set (engine + assets/sprite/catalog) needs libc, so create the test module directly
    // rather than via addPkgTest (which omits link_libc).
    const bundle_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bundle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "engine", .module = engine_full },
            .{ .name = "style", .module = style_mod },
            .{ .name = "sprite", .module = sprite_mod },
            .{ .name = "catalog", .module = catalog_embed },
        },
    });
    const bundle_test_step = b.step("bundle-test", "Run the bundle / per-cell composite tests");
    bundle_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bundle_test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bundle_test_mod })).step);
    // Per-cell coverage sidecar (JSON round-trip carried in PMTiles metadata): pure
    // over s57 + std.json. Part of the main suite.
    _ = addPkgTest(b, test_step, "src/coverage/coverage.zig", target, optimize, &.{
        .{ .name = "s57", .module = s57_mod },
    });
    // The render module: Surface contract + noop lifecycle smoke test (pins
    // the contract), resolver gates/colors, Canvas + RasterCanvas + PNG +
    // PixelSurface.
    const render_test = addPkgTest(b, test_step, "src/render/render.zig", target, optimize, &.{
        .{ .name = "tiles", .module = tiles_mod },
        .{ .name = "style", .module = style_mod },
    });
    addFont(b, render_test);
    // Golden portrayal-instruction test (assertion #5): drives the real embedded Lua
    // rules end-to-end. It rides its own artifact because `portray` links libc + Lua +
    // the rule registry (those settings + C sources propagate from portray_mod), unlike
    // the libc-free pure-package tests above.
    _ = addPkgTest(b, test_step, "src/portray/portray_golden_test.zig", target, optimize, &.{
        .{ .name = "portray", .module = portray_mod },
        .{ .name = "s57", .module = s57_mod },
    });
    // Golden-image test for the pixel path (Gate 2): real Lua rules -> engine ->
    // PixelSurface -> PNG, sha-asserted. libc for the same reason as above.
    const pixel_golden = addPkgTest(b, test_step, "src/render/pixel_golden_test.zig", target, optimize, &.{
        .{ .name = "portray", .module = portray_mod },
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "scene", .module = scene_mod },
        .{ .name = "render", .module = render_mod },
        .{ .name = "tiles", .module = tiles_mod },
    });
    pixel_golden.addImport("colorprofile_registry", colorprofile_registry);
    // The ASCII backend's engine test: same fixture-cell pattern as the pixel
    // golden, but asserting structural grid properties, never golden bytes.
    const ascii_view = addPkgTest(b, test_step, "src/render/ascii_view_test.zig", target, optimize, &.{
        .{ .name = "portray", .module = portray_mod },
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "scene", .module = scene_mod },
        .{ .name = "render", .module = render_mod },
        .{ .name = "tiles", .module = tiles_mod },
    });
    ascii_view.addImport("colorprofile_registry", colorprofile_registry);
    // The recording backend's engine test (render/inspect.zig, the `tile57 explore`
    // tool): real rules -> scene.appendTile -> InspectSurface, asserting the 3-level
    // record. libc for the same reason as the pixel/ascii golden tests (portray).
    _ = addPkgTest(b, test_step, "src/render/inspect_view_test.zig", target, optimize, &.{
        .{ .name = "portray", .module = portray_mod },
        .{ .name = "s57", .module = s57_mod },
        .{ .name = "s101", .module = s101_mod },
        .{ .name = "scene", .module = scene_mod },
        .{ .name = "render", .module = render_mod },
        .{ .name = "tiles", .module = tiles_mod },
    });
    // bindings/ shared settings parser (used by the wasm engine + parity oracle).
    _ = addPkgTest(b, test_step, "bindings/shared/settings.zig", target, optimize, &.{
        .{ .name = "style", .module = style_mod },
    });
    // The public root (src/tile57.zig) is compile-checked via lib_root.zig in the
    // libtile57.a build — it imports source.zig (Lua/libc), so it can't be a pure
    // pkg test here.
}
