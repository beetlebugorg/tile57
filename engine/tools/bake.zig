//! chartplotter-bake — the offline S-57 -> PMTiles baker / inspector CLI.
//!
//! Subcommands:
//!   bake <cell.000> -o <out.pmtiles> [--rules DIR] [--minzoom N] [--maxzoom N] [update.001 ...]
//!       Decode an S-57 base cell (applying any update files), portray it, and
//!       pre-bake every web-mercator MVT tile covering the cell's bounds across
//!       the requested zoom range into a clustered PMTiles archive.
//!   inspect <file.pmtiles> [z x y]
//!       Parse a PMTiles archive (header + directory) and, if z/x/y is given,
//!       read+gunzip+decode that tile and list its MVT layers.
//!   cell <file.000>
//!       Decode + summarise an S-57 cell (record tally, bounds, topology).
//!   version
//!       Print the baker version.
//!   help
//!       Print usage.

const std = @import("std");
const engine = @import("engine");
const assets = @import("assets");

const VERSION = "chartplotter-bake 0.1.0";

const DEFAULT_MINZOOM: u8 = 8;
const DEFAULT_MAXZOOM: u8 = 16;

// Env access lives in the Lua C shim (Zig 0.16 gates env behind std.Io);
// returns the S-101 rules dir from TILE57_S101_RULES or null. Mirrors capi.zig.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

// Resolve the S-101 rules directory: explicit --rules, else TILE57_S101_RULES,
// else the vendored official catalogue relative to the CWD (works when the baker
// is run from the repo root, as the render host's resolveRulesDir also expects).
fn resolveRulesDir(explicit: ?[]const u8) []const u8 {
    if (explicit) |d| return d;
    if (tg_env_rules()) |dirz| return std.mem.span(dirz);
    return "vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules";
}

// Flag cursor shared by the subcommands: walk argv[2..], pull a value (or an int)
// for a flag, and on a missing/bad value print usage and yield null so the caller
// can `orelse return`. next() pre-increments, so its first call returns argv[2].
const Flags = struct {
    args: []const [:0]const u8,
    i: usize = 1,

    fn next(f: *Flags) ?[]const u8 {
        f.i += 1;
        return if (f.i < f.args.len) f.args[f.i] else null;
    }
    fn val(f: *Flags, flag: []const u8) ?[]const u8 {
        f.i += 1;
        if (f.i >= f.args.len) {
            std.debug.print("error: missing value for {s}\n\n", .{flag});
            printUsage();
            return null;
        }
        return f.args[f.i];
    }
    fn int(f: *Flags, comptime T: type, flag: []const u8) ?T {
        const v = f.val(flag) orelse return null;
        return std.fmt.parseInt(T, v, 10) catch {
            std.debug.print("error: {s} must be an integer\n\n", .{flag});
            printUsage();
            return null;
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const sub: []const u8 = if (args.len >= 2) args[1] else "help";

    if (std.mem.eql(u8, sub, "bake")) {
        return runBake(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "bake-root")) {
        return runBakeRoot(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "assets")) {
        return runAssets(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "bundle")) {
        return runBundle(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "style")) {
        return runStyle(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "inspect")) {
        if (args.len < 3) {
            std.debug.print("usage: chartplotter-bake inspect <file.pmtiles> [z x y]\n", .{});
            return;
        }
        const path = args[2];
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var r = try engine.pmtiles.Reader.init(arena, data);
        defer r.deinit();
        const h = r.header;
        std.debug.print(
            "{s}\n  zoom {d}..{d}  addressed={d} entries={d} contents={d}  tile_comp={s} internal={s}\n",
            .{ path, h.min_zoom, h.max_zoom, h.num_addressed_tiles, h.num_tile_entries, h.num_tile_contents, @tagName(h.tile_compression), @tagName(h.internal_compression) },
        );
        if (args.len >= 6) {
            const z = try std.fmt.parseInt(u8, args[3], 10);
            const x = try std.fmt.parseInt(u32, args[4], 10);
            const y = try std.fmt.parseInt(u32, args[5], 10);
            if (try r.getTile(arena, z, x, y)) |tile| {
                const layers = try engine.mvt.decode(arena, tile);
                std.debug.print("  tile {d}/{d}/{d}: {d} bytes, {d} layers:\n", .{ z, x, y, tile.len, layers.len });
                for (layers) |L| {
                    std.debug.print("    {s}: {d} features (extent {d})\n", .{ L.name, L.features.len, L.extent });
                }
            } else std.debug.print("  tile {d}/{d}/{d}: not found\n", .{ z, x, y });
        }
        return;
    }

    if (std.mem.eql(u8, sub, "cell")) {
        if (args.len < 3) {
            std.debug.print("usage: chartplotter-bake cell <file.000>\n", .{});
            return;
        }
        const path = args[2];
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var file = try engine.iso8211.parse(arena, data);
        defer file.deinit();
        const L = file.ddr.leader;
        std.debug.print(
            "{s}\n  DDR: interchange={c} version={c} tag_size={d} field_controls={d}\n  data records: {d}\n",
            .{ path, L.interchange_level, L.version, L.size_of_field_tag, file.field_controls.len, file.records.len },
        );
        // Tally the S-57 record kind by its leading field.
        var dsid: usize = 0;
        var frid: usize = 0;
        var vrid: usize = 0;
        var other: usize = 0;
        for (file.records) |r| {
            if (r.field("FRID") != null) frid += 1 else if (r.field("VRID") != null) vrid += 1 else if (r.field("DSID") != null) dsid += 1 else other += 1;
        }
        std.debug.print("  DSID={d} feature(FRID)={d} vector(VRID)={d} other={d}\n", .{ dsid, frid, vrid, other });

        // S-57 model: coordinate factors, geometry bounds, a few object classes.
        var cell = try engine.s57.parseCell(arena, data);
        defer cell.deinit();
        std.debug.print("  S-57: comf={d} cscl=1:{d}  vectors={d} features={d}\n", .{ cell.params.comf, cell.params.cscl, cell.vectors.len, cell.features.len });
        if (cell.bounds()) |b| {
            std.debug.print("  geometry bounds: lon [{d:.4}, {d:.4}]  lat [{d:.4}, {d:.4}]\n", .{ b[0], b[2], b[1], b[3] });
        }
        const named = [_]struct { objl: u16, name: []const u8 }{
            .{ .objl = 42, .name = "DEPARE" }, .{ .objl = 30, .name = "COALNE" },
            .{ .objl = 129, .name = "SOUNDG" }, .{ .objl = 71, .name = "LNDARE" },
            .{ .objl = 122, .name = "SLCONS" }, .{ .objl = 74, .name = "DEPCNT" },
        };
        for (named) |nm| {
            var c: usize = 0;
            for (cell.features) |f| {
                if (f.objl == nm.objl) c += 1;
            }
            if (c > 0) std.debug.print("    {s}(objl {d}): {d}\n", .{ nm.name, nm.objl, c });
        }

        // Topology assembly: resolve feature geometry via FSPT/VRPT/edges/nodes.
        var line_feats: usize = 0;
        var line_verts: usize = 0;
        var pt_feats: usize = 0;
        var sample_ok = false;
        const gb = cell.bounds();
        for (cell.features) |f| {
            if (f.prim == 2 or f.prim == 3) {
                const g = try cell.lineGeometry(arena, f);
                if (g.len >= 2) {
                    line_feats += 1;
                    line_verts += g.len;
                    if (!sample_ok and gb != null) {
                        const p = g[0];
                        sample_ok = p.lon >= gb.?[0] - 1e-6 and p.lon <= gb.?[2] + 1e-6 and
                            p.lat >= gb.?[1] - 1e-6 and p.lat <= gb.?[3] + 1e-6;
                    }
                }
            } else if (f.prim == 1) {
                if (cell.pointGeometry(f) != null) pt_feats += 1;
            }
        }
        std.debug.print("  assembled: {d} line/area features ({d} verts), {d} point features; sample in-bounds={}\n", .{ line_feats, line_verts, pt_feats, sample_ok });

        // prim histogram for DEPCNT(74) and SOUNDG(129).
        for ([_]u16{ 42, 30, 74, 129 }) |objl| {
            var pc = [_]usize{0} ** 256;
            for (cell.features) |f| if (f.objl == objl) {
                pc[f.prim] += 1;
            };
            std.debug.print("  objl {d} prim: point(1)={d} line(2)={d} area(3)={d} none(255)={d}\n", .{ objl, pc[1], pc[2], pc[3], pc[255] });
        }

        // Find features whose assembled geometry has an anomalously long
        // segment (a "jump"): symptom of concatenating non-contiguous FSPT
        // edges. Flag any segment longer than 10% of the cell diagonal.
        if (gb) |b| {
            const diag = @sqrt((b[2] - b[0]) * (b[2] - b[0]) + (b[3] - b[1]) * (b[3] - b[1]));
            const thresh = 0.10 * diag;
            var jumpy: usize = 0;
            var worst_objl: u16 = 0;
            var worst_len: f64 = 0;
            for (cell.features) |f| {
                if (f.prim != 2 and f.prim != 3) continue;
                // Measure the longest segment WITHIN each connected part (the
                // render uses lineGeometryParts, so per-part is what matters).
                const parts = cell.lineGeometryParts(arena, f) catch continue;
                var maxseg: f64 = 0;
                for (parts) |g| {
                    var i: usize = 1;
                    while (i < g.len) : (i += 1) {
                        const dx = g[i].lon - g[i - 1].lon;
                        const dy = g[i].lat - g[i - 1].lat;
                        const d = @sqrt(dx * dx + dy * dy);
                        if (d > maxseg) maxseg = d;
                    }
                }
                if (maxseg > thresh) {
                    jumpy += 1;
                    if (maxseg > worst_len) {
                        worst_len = maxseg;
                        worst_objl = f.objl;
                    }
                }
            }
            std.debug.print("  per-part geometry jumps (>10% cell diag): {d} features; worst objl={d} seg={d:.4} (diag={d:.4})\n", .{ jumpy, worst_objl, worst_len, diag });
        }

        // Confirm DRVAL1/DRVAL2 attribute codes on a sample DEPARE.
        for (cell.features) |f| {
            if (f.objl == 42 and f.attrs.len > 0) {
                std.debug.print("  sample DEPARE attrs: ", .{});
                for (f.attrs) |x| std.debug.print("[{d}]={s} ", .{ x.code, x.value });
                if (f.attrFloat(engine.s57.ATTR_DRVAL1)) |d| std.debug.print("-> DRVAL1={d:.1}", .{d});
                std.debug.print("\n", .{});
                break;
            }
        }
        return;
    }

    if (std.mem.eql(u8, sub, "version") or std.mem.eql(u8, sub, "--version")) {
        std.debug.print("{s}\n", .{VERSION});
        return;
    }

    printUsage();
}

// ---- bake ---------------------------------------------------------------

const BakeResult = struct { archive: []u8, bounds: [4]f64, tiles: usize };

/// Decode a base cell (+ updates), run S-101 portrayal, and bake every
/// web-mercator MVT tile covering its bounds across [minzoom,maxzoom] into a
/// PMTiles archive. Returns the archive plus the cell bounds and tile count.
/// Shared by `bake` (writes the archive) and `bundle` (wraps it with assets + a
/// manifest). bounds() -> [west, south, east, north]; error.NoGeometry if the
/// cell has nothing to bake.
fn bakeCell(
    io: std.Io,
    a: std.mem.Allocator,
    base_path: []const u8,
    updates: []const []const u8,
    rules_dir: []const u8,
    minzoom: u8,
    maxzoom: u8,
) !BakeResult {
    const base_bytes = try std.Io.Dir.cwd().readFileAlloc(io, base_path, a, .unlimited);
    const update_bytes = try a.alloc([]const u8, updates.len);
    for (updates, 0..) |u, ui| {
        update_bytes[ui] = try std.Io.Dir.cwd().readFileAlloc(io, u, a, .unlimited);
    }

    var cell = try engine.s57.parseCellWithUpdates(a, base_bytes, update_bytes);
    defer cell.deinit();

    // S-101 portrayal: run the embedded-Lua rule engine over the cell's adapted
    // features (same path the live library uses) so baked tiles carry full S-101
    // styling. The arena `a` outlives tile generation, as portrayCell requires.
    // Portrayal failure (e.g. rules dir not found) is non-fatal: generateTile
    // then falls back to the built-in classify() styling.
    // Three passes (default + plain-boundary + simplified-symbol) so baked tiles
    // carry the bnd/pts display-variant tags the client toggles live.
    const cp: engine.portray.CellPortrayal = if (engine.portray.portrayCellVariants(a, &cell, rules_dir)) |res|
        res
    else |err| blk: {
        std.debug.print(
            "warning: S-101 portrayal failed ({s}) with rules dir '{s}'; baking with classify() fallback\n",
            .{ @errorName(err), rules_dir },
        );
        break :blk .{ .base = &.{} };
    };

    const b = cell.bounds() orelse return error.NoGeometry;

    var tiles = std.ArrayList(engine.pmtiles.InputTile).empty;
    var z: u8 = minzoom;
    while (z <= maxzoom) : (z += 1) {
        // North-west corner -> (min x, min y); south-east corner -> (max x, max y).
        const nw = lonLatToTile(b[0], b[3], z);
        const se = lonLatToTile(b[2], b[1], z);
        var ty = nw[1];
        while (ty <= se[1]) : (ty += 1) {
            var tx = nw[0];
            while (tx <= se[0]) : (tx += 1) {
                // Generate with the page allocator, not the arena `a`: generateTile
                // frees a per-tile child arena each call, which an arena backing
                // would leak (tens of GB over a high-vertex cell).
                const one = [_]engine.s57_mvt.CellRef{.{ .cell = &cell, .portrayal = cp.base, .portrayal_plain = cp.plain, .portrayal_simplified = cp.simplified }};
                const tile_mvt = try engine.s57_mvt.generateTileMulti(std.heap.page_allocator, &one, z, tx, ty);
                if (tile_mvt.len == 0) continue; // empty tile: nothing covered here
                try tiles.append(a, .{ .z = z, .x = tx, .y = ty, .mvt = tile_mvt });
            }
        }
    }

    const opts = engine.pmtiles.WriteOptions{
        .min_lon_e7 = toE7(b[0]),
        .min_lat_e7 = toE7(b[1]),
        .max_lon_e7 = toE7(b[2]),
        .max_lat_e7 = toE7(b[3]),
    };
    const archive = try engine.pmtiles.write(a, tiles.items, opts);
    return .{ .archive = archive, .bounds = b, .tiles = tiles.items.len };
}

/// `bake <cell.000> -o <out.pmtiles> [--rules DIR] [--minzoom N] [--maxzoom N] [update.001 ...]`
fn runBake(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var minzoom: u8 = DEFAULT_MINZOOM;
    var maxzoom: u8 = DEFAULT_MAXZOOM;
    var updates = std.ArrayList([]const u8).empty;

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--minzoom")) {
            minzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--maxzoom")) {
            maxzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown flag '{s}'\n\n", .{arg});
            return printUsage();
        } else if (base == null) {
            base = arg;
        } else {
            try updates.append(a, arg);
        }
    }

    const base_path = base orelse return usageErr("missing <cell.000> input");
    const out_path = out orelse return usageErr("missing -o/--output <out.pmtiles>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");

    const res = bakeCell(io, a, base_path, updates.items, resolveRulesDir(rules), minzoom, maxzoom) catch |err| switch (err) {
        error.NoGeometry => {
            std.debug.print("error: {s} has no geometry to bake\n", .{base_path});
            return;
        },
        else => return err,
    };
    if (res.tiles == 0) {
        std.debug.print("warning: no non-empty tiles produced for zoom {d}..{d}\n", .{ minzoom, maxzoom });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = res.archive });

    std.debug.print(
        "baked {d} cell ({d} update file(s) applied) -> {s}\n  {d} tiles written, zoom {d}..{d}\n  output {d} bytes ({d:.1} MB)\n",
        .{
            @as(usize, 1),   updates.items.len, out_path,
            res.tiles,       minzoom,           maxzoom,
            res.archive.len, @as(f64, @floatFromInt(res.archive.len)) / (1024.0 * 1024.0),
        },
    );
}

// ---- assets / bundle ----------------------------------------------------

// colorProfile.xml relative to a PortrayalCatalog directory. The baker's default
// rules dir is <catalog>/Rules; ColorProfiles is its sibling.
const COLOR_PROFILE_REL = "ColorProfiles/colorProfile.xml";

// Resolve the PortrayalCatalog directory: explicit arg, else the parent of the
// resolved rules dir (…/PortrayalCatalog/Rules -> …/PortrayalCatalog).
fn resolveCatalogDir(explicit: ?[]const u8) []const u8 {
    if (explicit) |d| return d;
    const rules = resolveRulesDir(null);
    return std.fs.path.dirname(rules) orelse rules;
}

// Emit colortables.json from a catalog dir into out_dir. Returns the bytes (arena
// owned) so `bundle` can reuse them without re-reading. Shared by assets/bundle.
fn colorTablesBytes(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8) ![]u8 {
    const xml_path = try std.fs.path.join(a, &.{ catalog_dir, COLOR_PROFILE_REL });
    const xml = try std.Io.Dir.cwd().readFileAlloc(io, xml_path, a, .unlimited);
    return assets.colorTablesJson(a, xml);
}

fn emitColorTables(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, out_path: []const u8) ![]u8 {
    const json = try colorTablesBytes(io, a, catalog_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json });
    return json;
}

/// `assets <portrayal-catalog-dir> -o <out-dir>` — emit the portrayal assets
/// (colortables.json today; linestyles/sprites/glyphs to follow) for a catalogue.
fn runAssets(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const catalog_dir = resolveCatalogDir(catalog);

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const ct_path = try std.fs.path.join(a, &.{ out_dir, "colortables.json" });
    const json = try emitColorTables(io, a, catalog_dir, ct_path);
    std.debug.print("emitted assets from {s}\n  {s} ({d} bytes)\n", .{ catalog_dir, ct_path, json.len });
}

/// `bundle <cell.000> -o <out-dir> [--rules DIR] [--catalog DIR] [--minzoom N]
///  [--maxzoom N] [--created ISO8601] [update.001 …]` — one bake emits a
/// self-contained chart bundle: tiles/chart.pmtiles + assets/colortables.json +
/// manifest.json (pins schema_version, couples tiles to portrayal).
fn runBundle(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var catalog: ?[]const u8 = null;
    var created: []const u8 = "";
    var minzoom: u8 = DEFAULT_MINZOOM;
    var maxzoom: u8 = DEFAULT_MAXZOOM;
    var updates = std.ArrayList([]const u8).empty;

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--catalog")) {
            catalog = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--created")) {
            created = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--minzoom")) {
            minzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--maxzoom")) {
            maxzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (base == null) {
            base = arg;
        } else {
            try updates.append(a, arg);
        }
    }

    const base_path = base orelse return usageErr("missing <cell.000> input");
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");

    // 1. tiles -> <out>/tiles/chart.pmtiles
    const res = bakeCell(io, a, base_path, updates.items, resolveRulesDir(rules), minzoom, maxzoom) catch |err| switch (err) {
        error.NoGeometry => {
            std.debug.print("error: {s} has no geometry to bundle\n", .{base_path});
            return;
        },
        else => return err,
    };
    const tiles_dir = try std.fs.path.join(a, &.{ out_dir, "tiles" });
    try std.Io.Dir.cwd().createDirPath(io, tiles_dir);
    const tiles_path = try std.fs.path.join(a, &.{ tiles_dir, "chart.pmtiles" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tiles_path, .data = res.archive });

    // 2. assets -> <out>/assets/colortables.json + style-{day,dusk,night}.json
    const assets_dir = try std.fs.path.join(a, &.{ out_dir, "assets" });
    try std.Io.Dir.cwd().createDirPath(io, assets_dir);
    const ct_path = try std.fs.path.join(a, &.{ assets_dir, "colortables.json" });
    var styles: ?assets.Manifest.Styles = null;
    if (emitColorTables(io, a, resolveCatalogDir(catalog), ct_path)) |ct| {
        // One style.json per palette, resolving colour tokens from the colortables.
        // sprite/glyphs are omitted until those assets exist; areas + lines render.
        var ok = true;
        for ([_][]const u8{ "day", "dusk", "night" }) |sc| {
            const sj = assets.styleJson(a, .{ .scheme = sc, .colortables_json = ct }) catch {
                ok = false;
                break;
            };
            const name = try std.fmt.allocPrint(a, "style-{s}.json", .{sc});
            const sp = try std.fs.path.join(a, &.{ assets_dir, name });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = sj });
        }
        if (ok) styles = .{
            .day = "assets/style-day.json",
            .dusk = "assets/style-dusk.json",
            .night = "assets/style-night.json",
        };
    } else |err| {
        std.debug.print("warning: assets emit failed ({s}); bundle has tiles + manifest only\n", .{@errorName(err)});
    }

    // 3. manifest.json — pins schema_version, couples tiles <-> portrayal.
    const b = res.bounds;
    const cell_name = std.fs.path.stem(std.fs.path.basename(base_path));
    const manifest = try assets.manifestJson(a, .{
        .generator = VERSION,
        .created = created,
        .tiles_rel = "tiles/chart.pmtiles",
        .colortables_rel = "assets/colortables.json",
        .minzoom = minzoom,
        .maxzoom = maxzoom,
        .bbox = b,
        .anchor = .{ (b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0 },
        .cells = &.{cell_name},
        .styles = styles,
    });
    const manifest_path = try std.fs.path.join(a, &.{ out_dir, "manifest.json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });

    std.debug.print(
        "bundled {s} -> {s}/\n  tiles/chart.pmtiles ({d} tiles, {d:.1} MB)\n  assets/colortables.json + style-{{day,dusk,night}}.json + manifest.json (schema {s})\n",
        .{ cell_name, out_dir, res.tiles, @as(f64, @floatFromInt(res.archive.len)) / (1024.0 * 1024.0), assets.SCHEMA_VERSION },
    );
}

/// `style <portrayal-catalog-dir> --scheme S -o <out.json> [--colortables FILE]
///  [--source-tiles T] [--sprite BASE] [--glyphs TMPL] [--pmtiles-url URL]
///  [--minzoom N] [--maxzoom N]` — emit one MapLibre style.json (colours from an
/// explicit colortables.json or computed from the catalogue).
fn runStyle(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var colortables: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var scheme: []const u8 = "day";
    var opts = assets.StyleOpts{ .scheme = "day", .colortables_json = "" };
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--colortables")) {
            colortables = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--scheme")) {
            scheme = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--source-tiles")) {
            opts.source_tiles = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--sprite")) {
            opts.sprite = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--glyphs")) {
            opts.glyphs = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--pmtiles-url")) {
            opts.pmtiles_url = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--minzoom")) {
            opts.minzoom = f.int(u32, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--maxzoom")) {
            opts.maxzoom = f.int(u32, arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_path = out orelse return usageErr("missing -o/--output <out.json>");
    opts.scheme = scheme;
    // Colours come from an explicit --colortables JSON, else are computed from
    // the catalogue's colorProfile.xml (identical output).
    opts.colortables_json = if (colortables) |ctf|
        try std.Io.Dir.cwd().readFileAlloc(io, ctf, a, .unlimited)
    else
        try colorTablesBytes(io, a, resolveCatalogDir(catalog));
    const style = try assets.styleJson(a, opts);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = style });
    std.debug.print("wrote {s} ({s}, {d} bytes)\n", .{ out_path, scheme, style.len });
}

// ---- bake-root (whole ENC_ROOT -> one banded PMTiles) ------------------

/// Console progress for bake-root: stage 0 = loading/portraying cells, 1 = tiles.
/// `total` 0 (tile stage) prints just the running count.
fn cliProgress(ctx: ?*anyopaque, stage: u8, done: usize, total: usize) callconv(.c) void {
    _ = ctx;
    const label = if (stage == 0) "loading cells " else "baking tiles  ";
    if (total == 0) {
        std.debug.print("\r  {s} {d}    ", .{ label, done });
    } else {
        std.debug.print("\r  {s} {d}/{d}    ", .{ label, done, total });
        if (done == total) std.debug.print("\n", .{});
    }
}

// One cell's raw bytes (base + sequential updates), read on the main thread and
// handed to a worker to parse + portray in parallel.
const CellSource = struct { base: []const u8, updates: []const []const u8 };

// Parallel parse+portray worker context. Each index is independent: a fresh cell
// + its own portrayal arena + a per-thread Lua state (portray.zig g_ctx is
// thread-local). Workers use the page allocator (thread-safe); the shared
// catalogue is warmed before the loop. Results land in distinct out[i]/arenas[i].
const PortrayWork = struct {
    sources: []const CellSource,
    outs: []?engine.bake_enc.Backend,
    arenas: []?*std.heap.ArenaAllocator,
    rules_dir: []const u8,
    gpa: std.mem.Allocator,
    build_geo: bool,

    fn run(uptr: *anyopaque, i: usize) void {
        const c: *PortrayWork = @ptrCast(@alignCast(uptr));
        const src = c.sources[i];
        var cell = engine.s57.parseCellWithUpdates(c.gpa, src.base, src.updates) catch return;
        const b = cell.bounds() orelse {
            cell.deinit();
            return;
        };
        // One arena per cell holds both the portrayal streams and the assembled
        // geometry cache, freed together when the band is done.
        var portrayal: ?[]const ?[]const u8 = null;
        var portrayal_plain: ?[]const ?[]const u8 = null;
        var portrayal_simplified: ?[]const ?[]const u8 = null;
        var geo: ?engine.s57_mvt.GeoParts = null;
        const pa: ?*std.heap.ArenaAllocator = c.gpa.create(std.heap.ArenaAllocator) catch null;
        if (pa) |p| {
            p.* = std.heap.ArenaAllocator.init(c.gpa);
            if (engine.portray.portrayCellVariants(p.allocator(), &cell, c.rules_dir)) |cp| {
                portrayal = cp.base;
                portrayal_plain = cp.plain;
                portrayal_simplified = cp.simplified;
            } else |_| {}
            if (c.build_geo) geo = engine.s57_mvt.buildGeoCache(p.allocator(), &cell) catch null;
        }
        c.outs[i] = .{ .cell = cell, .portrayal = portrayal, .portrayal_plain = portrayal_plain, .portrayal_simplified = portrayal_simplified, .geo = geo, .bounds = b };
        c.arenas[i] = pa;
    }
};

/// `bake-root <ENC_ROOT> -o <out.pmtiles> [--rules DIR] [--minzoom N] [--maxzoom N]`
/// Walk an ENC_ROOT for every `<CELL>.000` base cell (+ its sequential `.001…`
/// updates), parse + portray each, and bake them into ONE PMTiles archive with
/// per-cell zoom banding by compilation scale (engine.bake_enc). Holds every cell
/// in memory at once (v1).
fn runBakeRoot(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var root: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var minzoom: u8 = 0;
    var maxzoom: u8 = 18;

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--minzoom")) {
            minzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--maxzoom")) {
            maxzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown flag '{s}'\n\n", .{arg});
            return printUsage();
        } else if (root == null) {
            root = arg;
        }
    }

    const root_path = root orelse return usageErr("missing <ENC_ROOT> input");
    const out_path = out orelse return usageErr("missing -o/--output <out.pmtiles>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");
    const rules_dir = resolveRulesDir(rules);

    const page = std.heap.page_allocator;
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch {
        std.debug.print("error: cannot open ENC_ROOT directory '{s}'\n", .{root_path});
        return;
    };
    defer dir.close(io);

    // Pass 1: walk for base cells and group their paths by navigational band
    // (a cheap CSCL peek — no geometry). Bands let the baker hold only one band's
    // cells at a time. Paths live in the process arena `a` (small, kept).
    const Bands = engine.bake_enc;
    var band_paths: [Bands.bands_fine_to_coarse.len]std.ArrayList([]const u8) = undefined;
    for (&band_paths) |*bp| bp.* = std.ArrayList([]const u8).empty;
    var total_cells: usize = 0;
    {
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".000")) continue;
            const path = try a.dupe(u8, entry.path);
            const bytes = dir.readFileAlloc(io, path, page, .unlimited) catch continue;
            const cscl = engine.s57.peekScale(page, bytes) orelse 0;
            page.free(bytes);
            try band_paths[@intFromEnum(Bands.bandOf(cscl))].append(a, path);
            total_cells += 1;
        }
    }
    if (total_cells == 0) {
        std.debug.print("error: no <CELL>.000 cells found under '{s}'\n", .{root_path});
        return;
    }
    std.debug.print("baking {d} cells from {s} -> {s} (rules: {s})\n", .{ total_cells, root_path, out_path, rules_dir });

    engine.catalogue.warmUp(); // warm the shared catalogue before parallel portrayal
    engine.portray.setQuiet(true); // many threads -> suppress the per-cell stderr

    var baker = Bands.Baker.init(page, minzoom, maxzoom);
    defer baker.deinit();

    // Pass 2: bake band-by-band, finest → coarsest (best-band dedup). Read a band's
    // files (serial IO), parse + portray them in parallel, bake, then free — so
    // peak memory is one band's cells and the portrayal runs across all cores.
    var loaded: usize = 0;
    for (Bands.bands_fine_to_coarse) |band| {
        const paths = band_paths[@intFromEnum(band)].items;
        if (paths.len == 0) continue;

        // Read this band's raw bytes on the main thread (IO isn't thread-safe here).
        var sources = std.ArrayList(CellSource).empty;
        for (paths) |bpath| {
            const base_bytes = dir.readFileAlloc(io, bpath, page, .unlimited) catch continue;
            const stem = bpath[0 .. bpath.len - 4];
            var ups = std.ArrayList([]const u8).empty;
            var k: u32 = 1;
            while (k <= 999) : (k += 1) {
                const upn = std.fmt.allocPrint(page, "{s}.{d:0>3}", .{ stem, k }) catch break;
                defer page.free(upn);
                const ub = dir.readFileAlloc(io, upn, page, .unlimited) catch break;
                ups.append(page, ub) catch break;
            }
            const updates = ups.toOwnedSlice(page) catch &.{};
            sources.append(page, .{ .base = base_bytes, .updates = updates }) catch {};
        }

        // Parse + portray in parallel.
        const outs = page.alloc(?Bands.Backend, sources.items.len) catch continue;
        defer page.free(outs);
        @memset(outs, null);
        const pas = page.alloc(?*std.heap.ArenaAllocator, sources.items.len) catch continue;
        defer page.free(pas);
        @memset(pas, null);
        var pw = PortrayWork{ .sources = sources.items, .outs = outs, .arenas = pas, .rules_dir = rules_dir, .gpa = page, .build_geo = Bands.cacheGeoForBand(band) };
        Bands.parallelFor(sources.items.len, &pw, PortrayWork.run);

        // The cells copied what they keep — free this band's raw bytes now.
        for (sources.items) |s| {
            page.free(s.base);
            for (s.updates) |u| page.free(u);
            page.free(s.updates);
        }
        sources.deinit(page);
        loaded += paths.len;
        cliProgress(null, 0, loaded, total_cells);

        // Collect the successful Backends (single owner) aligned with their arenas.
        var backends = std.ArrayList(Bands.Backend).empty;
        var band_arenas = std.ArrayList(?*std.heap.ArenaAllocator).empty;
        backends.ensureTotalCapacity(page, outs.len) catch {};
        band_arenas.ensureTotalCapacity(page, outs.len) catch {};
        for (outs, pas) |o, pa| if (o) |be| {
            backends.appendAssumeCapacity(be);
            band_arenas.appendAssumeCapacity(pa);
        };

        baker.bakeBand(band, backends.items, cliProgress, null) catch {};

        for (backends.items) |*be| be.cell.deinit();
        for (band_arenas.items) |pa| if (pa) |p| {
            p.deinit();
            page.destroy(p);
        };
        backends.deinit(page);
        band_arenas.deinit(page);
    }

    const archive = try baker.finish();
    defer page.free(archive);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = archive });
    std.debug.print(
        "\nbaked {d} cells -> {s}\n  output {d} bytes ({d:.1} MB)\n",
        .{ total_cells, out_path, archive.len, @as(f64, @floatFromInt(archive.len)) / (1024.0 * 1024.0) },
    );
}

/// lon/lat (deg) -> web-mercator tile (x, y) at zoom z, clamped to the valid range.
fn lonLatToTile(lon: f64, lat: f64, z: u8) [2]u32 {
    const w = engine.tile.lonLatToWorld(lon, lat); // normalised [0,1], y down
    const scale: f64 = @floatFromInt(@as(u64, 1) << @intCast(z));
    const max_idx: f64 = scale - 1.0;
    const fx = std.math.clamp(@floor(w[0] * scale), 0.0, max_idx);
    const fy = std.math.clamp(@floor(w[1] * scale), 0.0, max_idx);
    return .{ @intFromFloat(fx), @intFromFloat(fy) };
}

/// Degrees -> PMTiles E7 fixed-point.
fn toE7(v: f64) i32 {
    return @intFromFloat(@round(v * 1e7));
}

fn usageErr(msg: []const u8) void {
    std.debug.print("error: {s}\n\n", .{msg});
    printUsage();
}

fn printUsage() void {
    std.debug.print(
        \\{s} — offline S-57 -> PMTiles baker / inspector
        \\
        \\usage:
        \\  chartplotter-bake bake <cell.000> -o <out.pmtiles> [options] [update.001 ...]
        \\      -o, --output PATH   output PMTiles archive (required)
        \\      --rules DIR         S-101 portrayal rules directory (optional)
        \\      --minzoom N         lowest zoom to bake (default {d})
        \\      --maxzoom N         highest zoom to bake (default {d})
        \\  chartplotter-bake bake-root <ENC_ROOT> -o <out.pmtiles> [options]
        \\      Bake a whole ENC_ROOT (every <CELL>.000 + updates) into one
        \\      archive, zoom-banded per cell by compilation scale.
        \\      -o/--output, --rules as above; --minzoom/--maxzoom clamp the bands.
        \\  chartplotter-bake bundle <cell.000> -o <out-dir> [options] [update.001 ...]
        \\      Emit a self-contained chart bundle: tiles/chart.pmtiles +
        \\      assets/colortables.json + manifest.json (pins schema_version,
        \\      couples tiles to portrayal). --rules/--minzoom/--maxzoom as above;
        \\      --catalog DIR PortrayalCatalog (default: parent of --rules);
        \\      --created ISO8601 stamps the manifest (no wall clock in-process).
        \\  chartplotter-bake assets <portrayal-catalog-dir> -o <out-dir>
        \\      Emit just the portrayal assets (colortables.json today) for a
        \\      catalogue, independent of any cell.
        \\  chartplotter-bake style <portrayal-catalog-dir> --scheme day -o <out.json>
        \\      Emit one MapLibre style.json (colours from the catalogue, or
        \\      --colortables FILE). --scheme day|dusk|night; --source-tiles/
        \\      --pmtiles-url pick the source; --sprite/--glyphs enable symbol/text
        \\      layers; --minzoom/--maxzoom.
        \\  chartplotter-bake inspect <file.pmtiles> [z x y]
        \\  chartplotter-bake cell <file.000>
        \\  chartplotter-bake version
        \\  chartplotter-bake help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM });
}
