//! tile57 — the offline S-57 -> PMTiles baker / inspector CLI.
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
const sprite = @import("sprite");
const embedded_assets = @import("catalog"); // S-101 portrayal assets embedded into the binary

const VERSION = "tile57 0.1.0";

const DEFAULT_MINZOOM: u8 = 8;
const DEFAULT_MAXZOOM: u8 = 16;

// Lazy-baker tuning (bake-root): LRU budget = parsed cells kept loaded across
// super-tiles; super-tile depth = how far below a band's min zoom the spatial
// batch tile sits. Overridable via --lru / --superdz for tuning.
const DEFAULT_LRU_BUDGET: usize = 64;
const DEFAULT_SUPER_DZ: u8 = 3;

// Total parse+portray calls across the bake (atomic; workers run in parallel).
// Compared against the cell count per band to surface excessive re-parsing.
var g_parses = std.atomic.Value(usize).init(0);

// Env access lives in the Lua C shim (Zig 0.16 gates env behind std.Io);
// returns the S-101 rules dir from TILE57_S101_RULES or null. Mirrors capi.zig.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

// Wall-clock seconds (libc time(); std.time is behind std.Io in 0.16). For bake
// progress timing only — coarse is fine.
extern fn time(t: ?*c_long) callconv(.c) c_long;
fn nowSec() i64 {
    return @intCast(time(null));
}

// Resolve the S-101 rules directory: explicit --rules, else TILE57_S101_RULES,
// else "" — which tells the portrayal engine to use the rules embedded in the
// binary (rules_embed.zig), so tile57 needs no on-disk catalogue. A non-empty
// path is layered onto package.path ahead of the embedded searcher, so an
// explicit dir always wins.
fn resolveRulesDir(explicit: ?[]const u8) []const u8 {
    if (explicit) |d| return d;
    if (tg_env_rules()) |dirz| return std.mem.span(dirz);
    return "";
}

// True if `path` is a directory (an ENC_ROOT) rather than a single cell.000 file.
fn isDir(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
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

    if (std.mem.eql(u8, sub, "sprite")) {
        return runSprite(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "pattern")) {
        return runPattern(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "sprite-mln")) {
        return runSpriteMln(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "bundle")) {
        return runBundle(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "style")) {
        return runStyle(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "inspect")) {
        if (args.len < 3) {
            std.debug.print("usage: tile57 inspect <file.pmtiles> [z x y]\n", .{});
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
            std.debug.print("usage: tile57 cell <file.000>\n", .{});
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
        {
            // Per-cell memory breakdown (counts × struct sizes) to find the bloat.
            var pts: usize = 0;
            var snds: usize = 0;
            for (cell.vectors) |v| {
                pts += v.points.len;
                snds += v.soundings.len;
            }
            var attrs: usize = 0;
            var refs: usize = 0;
            var attrbytes: usize = 0;
            for (cell.features) |f| {
                attrs += f.attrs.len;
                refs += f.refs.len;
                for (f.attrs) |x| attrbytes += x.value.len;
            }
            const LL = @sizeOf(engine.s57.LonLat);
            const kb = 1024;
            std.debug.print(
                "  mem: pts={d}({d}KB @{d}B) snds={d}({d}KB) vecstructs={d}KB | attrs={d}({d}KB val) refs={d} featstructs={d}KB\n",
                .{ pts, pts * LL / kb, LL, snds, snds * @sizeOf(engine.s57.Sounding) / kb, cell.vectors.len * @sizeOf(engine.s57.VectorRecord) / kb, attrs, attrbytes / kb, refs, cell.features.len * @sizeOf(engine.s57.Feature) / kb },
            );
        }
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
                        sample_ok = p.lon() >= gb.?[0] - 1e-6 and p.lon() <= gb.?[2] + 1e-6 and
                            p.lat() >= gb.?[1] - 1e-6 and p.lat() <= gb.?[3] + 1e-6;
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
                        const dx = g[i].lon() - g[i - 1].lon();
                        const dy = g[i].lat() - g[i - 1].lat();
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

    const base_path = base orelse return usageErr("missing <cell.000 | ENC_ROOT> input");
    const out_path = out orelse return usageErr("missing -o/--output <out.pmtiles>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");

    // `bake` takes a single cell.000 OR an ENC_ROOT directory — same archive out.
    if (isDir(io, base_path)) {
        const rzoom_max: u8 = if (maxzoom == DEFAULT_MAXZOOM) 18 else maxzoom; // root default 18
        const rb = bakeRoot(io, a, base_path, out_path, resolveRulesDir(rules), minzoom, rzoom_max, DEFAULT_LRU_BUDGET, DEFAULT_SUPER_DZ, false) catch |err| {
            std.debug.print("error: cannot bake ENC_ROOT {s} ({s})\n", .{ base_path, @errorName(err) });
            return;
        };
        std.debug.print("\nbaked {d} cells -> {s}\n", .{ rb.cells.len, out_path });
        return;
    }

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
        "baked 1 cell ({d} update file(s) applied) -> {s}\n  {d} tiles written, zoom {d}..{d}\n  output {d} bytes ({d:.1} MB)\n",
        .{ updates.items.len, out_path, res.tiles, minzoom, maxzoom, res.archive.len, @as(f64, @floatFromInt(res.archive.len)) / (1024.0 * 1024.0) },
    );
}

// ---- assets / bundle ----------------------------------------------------

// colorProfile.xml relative to a PortrayalCatalog directory. The baker's default
// rules dir is <catalog>/Rules; ColorProfiles is its sibling.
const COLOR_PROFILE_REL = "ColorProfiles/colorProfile.xml";

// Resolve the PortrayalCatalog directory: explicit arg, else "" — which tells the
// asset emitters below to use the catalogue embedded in the binary (catalog_embed
// / catalog), so the CLI needs no on-disk catalogue. A non-empty path reads the
// assets from disk instead, overriding the embedded copy.
fn resolveCatalogDir(explicit: ?[]const u8) []const u8 {
    return explicit orelse "";
}

// "embedded" when the catalogue is served from the binary (dir == ""), else `dir`
// — for the per-command progress prints.
fn catalogLabel(dir: []const u8) []const u8 {
    return if (dir.len == 0) "embedded" else dir;
}

// ---- embedded catalogue assets (the `dir == ""` path of the readers) ---------

// Embedded Symbols/*.svg as sprite sources (id = file stem). Sorted at build time.
fn embeddedSymbols(a: std.mem.Allocator) ![]sprite.SvgSrc {
    const out = try a.alloc(sprite.SvgSrc, embedded_assets.symbols.len);
    for (embedded_assets.symbols, 0..) |e, i| out[i] = .{ .id = e.name, .svg = e.bytes };
    return out;
}

// Embedded AreaFills/*.xml as area-fill sources (id = file stem).
fn embeddedFills(a: std.mem.Allocator) ![]sprite.AreaFillSrc {
    const out = try a.alloc(sprite.AreaFillSrc, embedded_assets.areafills.len);
    for (embedded_assets.areafills, 0..) |e, i| out[i] = .{ .id = e.name, .xml = e.bytes };
    return out;
}

// Embedded LineStyles/*.xml as line-style sources (id = file stem).
fn embeddedLinestyles(a: std.mem.Allocator) ![]assets.LineStyleSrc {
    const out = try a.alloc(assets.LineStyleSrc, embedded_assets.linestyles.len);
    for (embedded_assets.linestyles, 0..) |e, i| out[i] = .{ .id = e.name, .xml = e.bytes };
    return out;
}

// Embedded palette stylesheet bytes by file name (e.g. "daySvgStyle.css"); the
// lookup is by stem, so callers can pass a bare name. Null if not embedded.
fn embeddedCss(css_name: []const u8) ?[]const u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(css_name));
    for (embedded_assets.css) |e| {
        if (std.mem.eql(u8, e.name, stem)) return e.bytes;
    }
    return null;
}

// The single embedded ColorProfiles/colorProfile.xml, or null if absent.
fn embeddedColorProfile() ?[]const u8 {
    for (embedded_assets.colorprofile) |e| return e.bytes;
    return null;
}

// Read the palette CSS: from the embedded catalogue (catalog_dir == "") or from
// <catalog_dir>/Symbols/<css_name> on disk.
fn readCss(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8) ![]const u8 {
    if (catalog_dir.len == 0) return embeddedCss(css_name) orelse error.MissingCss;
    const css_path = try std.fs.path.join(a, &.{ catalog_dir, SYMBOLS_REL, css_name });
    return std.Io.Dir.cwd().readFileAlloc(io, css_path, a, .unlimited);
}

// Emit colortables.json from a catalog dir into out_dir. Returns the bytes (arena
// owned) so `bundle` can reuse them without re-reading. Shared by assets/bundle.
fn colorTablesBytes(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8) ![]u8 {
    const xml = if (catalog_dir.len == 0)
        (embeddedColorProfile() orelse return error.MissingColorProfile)
    else blk: {
        const xml_path = try std.fs.path.join(a, &.{ catalog_dir, COLOR_PROFILE_REL });
        break :blk try std.Io.Dir.cwd().readFileAlloc(io, xml_path, a, .unlimited);
    };
    return assets.colorTablesJson(a, xml);
}

fn emitColorTables(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, out_path: []const u8) ![]u8 {
    const json = try colorTablesBytes(io, a, catalog_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json });
    return json;
}

// LineStyles/*.xml live under a PortrayalCatalog dir, alongside ColorProfiles.
const LINESTYLES_REL = "LineStyles";

// Read every LineStyles/*.xml under catalog_dir and emit linestyles.json (dash
// patterns + placed symbols). Returns the bytes (arena owned). Shared by
// assets/bundle. Mirrors the Go oracle's EmitS101 linestyles step.
fn linestylesBytes(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8) ![]u8 {
    if (catalog_dir.len == 0) return assets.linestylesJson(a, try embeddedLinestyles(a));
    const ls_dir_path = try std.fs.path.join(a, &.{ catalog_dir, LINESTYLES_REL });
    var dir = try std.Io.Dir.cwd().openDir(io, ls_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var srcs = std.ArrayList(assets.LineStyleSrc).empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".xml")) continue;
        const path = try a.dupe(u8, entry.path);
        const xml = dir.readFileAlloc(io, path, a, .unlimited) catch continue;
        const id = std.fs.path.stem(std.fs.path.basename(path));
        try srcs.append(a, .{ .id = id, .xml = xml });
    }
    return assets.linestylesJson(a, srcs.items);
}

fn emitLinestyles(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, out_path: []const u8) ![]u8 {
    const json = try linestylesBytes(io, a, catalog_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json });
    return json;
}

// Symbols/*.svg live under a PortrayalCatalog dir; the palette stylesheet
// (daySvgStyle.css etc.) lives alongside them.
const SYMBOLS_REL = "Symbols";
const DEFAULT_CSS = "daySvgStyle.css";

// Read every Symbols/*.svg + the palette CSS and build the sprite atlas
// (sprite.json + sprite.png). Mirrors the Go oracle's SpriteAtlasS101FS.
fn spriteAtlasBytes(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8) !sprite.Atlas {
    const srcs = try readSymbols(io, a, catalog_dir);
    const css = try readCss(io, a, catalog_dir, css_name);
    return sprite.spriteAtlas(a, srcs, css);
}

fn emitSprites(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8, json_path: []const u8, png_path: []const u8) !sprite.Atlas {
    const atlas = try spriteAtlasBytes(io, a, catalog_dir, css_name);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = atlas.json });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = atlas.png });
    return atlas;
}

const AREAFILLS_REL = "AreaFills";

// Read every Symbols/*.svg into a list (shared by the sprite + pattern atlases).
fn readSymbols(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8) ![]sprite.SvgSrc {
    if (catalog_dir.len == 0) return embeddedSymbols(a);
    const sym_dir_path = try std.fs.path.join(a, &.{ catalog_dir, SYMBOLS_REL });
    var dir = try std.Io.Dir.cwd().openDir(io, sym_dir_path, .{ .iterate = true });
    defer dir.close(io);
    var srcs = std.ArrayList(sprite.SvgSrc).empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".svg")) continue;
        const path = try a.dupe(u8, entry.path);
        const svg = dir.readFileAlloc(io, path, a, .unlimited) catch continue;
        try srcs.append(a, .{ .id = std.fs.path.stem(std.fs.path.basename(path)), .svg = svg });
    }
    return srcs.items;
}

// Read AreaFills/*.xml + Symbols/*.svg + the palette CSS and build the pattern
// atlas (patterns.json + patterns.png). Mirrors the Go oracle's PatternAtlasS101FS.
fn patternAtlasBytes(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8) !sprite.Atlas {
    const fills = try readFills(io, a, catalog_dir);
    const symbols = try readSymbols(io, a, catalog_dir);
    const css = try readCss(io, a, catalog_dir, css_name);
    return sprite.patternAtlas(a, fills, symbols, css);
}

fn emitPatterns(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8, json_path: []const u8, png_path: []const u8) !sprite.Atlas {
    const atlas = try patternAtlasBytes(io, a, catalog_dir, css_name);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = atlas.json });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = atlas.png });
    return atlas;
}

// Read every AreaFills/*.xml under catalog_dir (shared by pattern + sprite-mln).
fn readFills(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8) ![]sprite.AreaFillSrc {
    if (catalog_dir.len == 0) return embeddedFills(a);
    const af_dir_path = try std.fs.path.join(a, &.{ catalog_dir, AREAFILLS_REL });
    var dir = try std.Io.Dir.cwd().openDir(io, af_dir_path, .{ .iterate = true });
    defer dir.close(io);
    var fills = std.ArrayList(sprite.AreaFillSrc).empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".xml")) continue;
        const path = try a.dupe(u8, entry.path);
        const xml = dir.readFileAlloc(io, path, a, .unlimited) catch continue;
        try fills.append(a, .{ .id = std.fs.path.stem(std.fs.path.basename(path)), .xml = xml });
    }
    return fills.items;
}

// Build the MapLibre sprite (sprite-mln) directly from the catalogue's Symbols +
// AreaFills + palette CSS. Mirrors the old scripts/build_sprite.py, in Zig.
fn spriteMlnBytes(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8, soundings: []const []const u8) !sprite.Atlas {
    const symbols = try readSymbols(io, a, catalog_dir);
    const fills = try readFills(io, a, catalog_dir);
    const css = try readCss(io, a, catalog_dir, css_name);
    return sprite.spriteMln(a, symbols, fills, css, soundings);
}

// Distinct comma-joined sounding glyph stacks (sym_s/sym_g/symbol_names) across a
// baked archive's `soundings` layer — the strings the style's icon-image produces,
// so sprite-mln must carry a composite for each. Decodes each tile in bounds.
fn collectSoundingStacks(io: std.Io, a: std.mem.Allocator, archive: []const u8, minzoom: u8, maxzoom: u8, b: [4]f64) ![]const []const u8 {
    _ = io;
    var reader = engine.pmtiles.Reader.init(a, archive) catch return &.{};
    defer reader.deinit();
    var set = std.StringHashMap(void).init(a);
    var z: u8 = minzoom;
    while (z <= maxzoom) : (z += 1) {
        const nw = lonLatToTile(b[0], b[3], z);
        const se = lonLatToTile(b[2], b[1], z);
        var ty = nw[1];
        while (ty <= se[1]) : (ty += 1) {
            var tx = nw[0];
            while (tx <= se[0]) : (tx += 1) {
                const tile = (reader.getTile(a, z, tx, ty) catch null) orelse continue;
                const layers = engine.mvt.decode(a, tile) catch continue;
                for (layers) |L| {
                    if (!std.mem.eql(u8, L.name, "soundings")) continue;
                    for (L.features) |feat| {
                        for (feat.properties) |p| {
                            if (!std.mem.eql(u8, p.key, "sym_s") and !std.mem.eql(u8, p.key, "sym_g") and !std.mem.eql(u8, p.key, "symbol_names")) continue;
                            switch (p.value) {
                                .string => |sv| if (std.mem.indexOfScalar(u8, sv, ',') != null) set.put(sv, {}) catch {},
                                else => {},
                            }
                        }
                    }
                }
            }
        }
    }
    var out = std.ArrayList([]const u8).empty;
    var it = set.keyIterator();
    while (it.next()) |k| try out.append(a, k.*);
    return out.items;
}

// Emit sprite-mln.{json,png} + identical @2x copies (MapLibre requests @2x on
// HiDPI; a missing @2x sheet fails the whole sprite load).
fn emitSpriteMln(io: std.Io, a: std.mem.Allocator, catalog_dir: []const u8, css_name: []const u8, out_dir: []const u8, base: []const u8, soundings: []const []const u8) !sprite.Atlas {
    const atlas = try spriteMlnBytes(io, a, catalog_dir, css_name, soundings);
    for ([_][]const u8{ "", "@2x" }) |suffix| {
        const jn = try std.fmt.allocPrint(a, "{s}{s}.json", .{ base, suffix });
        const pn = try std.fmt.allocPrint(a, "{s}{s}.png", .{ base, suffix });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ out_dir, jn }), .data = atlas.json });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ out_dir, pn }), .data = atlas.png });
    }
    return atlas;
}

/// `sprite-mln <portrayal-catalog-dir> -o <out-dir> [--css daySvgStyle.css]` —
/// emit the MapLibre-ready sprite (sprite-mln.{json,png} + @2x): pivot-centred
/// symbols, ctr: bbox-centred variants, and pat: area-fill patterns.
fn runSpriteMln(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var css: []const u8 = DEFAULT_CSS;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--css")) {
            css = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const catalog_dir = resolveCatalogDir(catalog);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    // Catalogue-only: no tiles, so no sounding composites (the bundle adds those).
    const atlas = try emitSpriteMln(io, a, catalog_dir, css, out_dir, "sprite-mln", &.{});
    std.debug.print("emitted sprite-mln from {s} (css {s})\n  sprite-mln.json ({d} bytes) + .png ({d} bytes) + @2x\n", .{ catalogLabel(catalog_dir), css, atlas.json.len, atlas.png.len });
}

/// `pattern <portrayal-catalog-dir> -o <out-dir> [--css daySvgStyle.css]` — emit
/// the S-101 area-fill pattern atlas (patterns.json + patterns.png).
fn runPattern(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var css: []const u8 = DEFAULT_CSS;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--css")) {
            css = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const catalog_dir = resolveCatalogDir(catalog);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const json_path = try std.fs.path.join(a, &.{ out_dir, "patterns.json" });
    const png_path = try std.fs.path.join(a, &.{ out_dir, "patterns.png" });
    const atlas = try emitPatterns(io, a, catalog_dir, css, json_path, png_path);
    std.debug.print("emitted pattern atlas from {s} (css {s})\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n", .{ catalogLabel(catalog_dir), css, json_path, atlas.json.len, png_path, atlas.png.len });
}

/// `sprite <portrayal-catalog-dir> -o <out-dir> [--css daySvgStyle.css]` — emit
/// the S-101 symbol atlas (sprite.json + sprite.png) for a palette.
fn runSprite(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var css: []const u8 = DEFAULT_CSS;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--css")) {
            css = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const catalog_dir = resolveCatalogDir(catalog);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const json_path = try std.fs.path.join(a, &.{ out_dir, "sprite.json" });
    const png_path = try std.fs.path.join(a, &.{ out_dir, "sprite.png" });
    const atlas = try emitSprites(io, a, catalog_dir, css, json_path, png_path);
    std.debug.print("emitted sprite atlas from {s} (css {s})\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n", .{ catalogLabel(catalog_dir), css, json_path, atlas.json.len, png_path, atlas.png.len });
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
    const ls_path = try std.fs.path.join(a, &.{ out_dir, "linestyles.json" });
    const ls = try emitLinestyles(io, a, catalog_dir, ls_path);
    const sj_path = try std.fs.path.join(a, &.{ out_dir, "sprite.json" });
    const sp_path = try std.fs.path.join(a, &.{ out_dir, "sprite.png" });
    const atlas = try emitSprites(io, a, catalog_dir, DEFAULT_CSS, sj_path, sp_path);
    const pj_path = try std.fs.path.join(a, &.{ out_dir, "patterns.json" });
    const pp_path = try std.fs.path.join(a, &.{ out_dir, "patterns.png" });
    const pat = try emitPatterns(io, a, catalog_dir, DEFAULT_CSS, pj_path, pp_path);
    std.debug.print("emitted assets from {s}\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n", .{ catalogLabel(catalog_dir), ct_path, json.len, ls_path, ls.len, sj_path, atlas.json.len, sp_path, atlas.png.len, pj_path, pat.json.len, pp_path, pat.png.len });
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

    const base_path = base orelse return usageErr("missing <cell.000 | ENC_ROOT> input");
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");

    // 1. tiles -> <out>/tiles/chart.pmtiles. Input may be a single cell.000 or a
    // whole ENC_ROOT directory (band-streamed multi-cell bake, streamed to disk).
    const tiles_dir = try std.fs.path.join(a, &.{ out_dir, "tiles" });
    try std.Io.Dir.cwd().createDirPath(io, tiles_dir);
    const tiles_path = try std.fs.path.join(a, &.{ tiles_dir, "chart.pmtiles" });
    var bounds: [4]f64 = undefined;
    var cells: []const []const u8 = undefined;
    var snd_stacks: []const []const u8 = &.{}; // sounding glyph stacks for sprite-mln
    if (isDir(io, base_path)) {
        // ENC_ROOT: streamed straight to tiles_path; updates auto-discovered per cell.
        const rb = bakeRoot(io, a, base_path, tiles_path, resolveRulesDir(rules), minzoom, maxzoom, DEFAULT_LRU_BUDGET, DEFAULT_SUPER_DZ, true) catch |err| {
            std.debug.print("error: cannot bundle ENC_ROOT {s} ({s})\n", .{ base_path, @errorName(err) });
            return;
        };
        bounds = rb.bounds;
        cells = rb.cells;
        snd_stacks = rb.sounds;
    } else {
        const res = bakeCell(io, a, base_path, updates.items, resolveRulesDir(rules), minzoom, maxzoom) catch |err| switch (err) {
            error.NoGeometry => {
                std.debug.print("error: {s} has no geometry to bundle\n", .{base_path});
                return;
            },
            else => return err,
        };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tiles_path, .data = res.archive });
        bounds = res.bounds;
        const one = try a.alloc([]const u8, 1);
        one[0] = std.fs.path.stem(std.fs.path.basename(base_path));
        cells = one;
        snd_stacks = collectSoundingStacks(io, a, res.archive, minzoom, maxzoom, res.bounds) catch &.{};
    }

    // 2. assets -> <out>/assets/colortables.json + style-{day,dusk,night}.json
    const assets_dir = try std.fs.path.join(a, &.{ out_dir, "assets" });
    try std.Io.Dir.cwd().createDirPath(io, assets_dir);
    const ct_path = try std.fs.path.join(a, &.{ assets_dir, "colortables.json" });
    const ls_path = try std.fs.path.join(a, &.{ assets_dir, "linestyles.json" });
    _ = emitLinestyles(io, a, resolveCatalogDir(catalog), ls_path) catch |err|
        std.debug.print("warning: linestyles emit failed ({s})\n", .{@errorName(err)});
    // The bundle ships ONLY the MapLibre-ready sprite (sprite-mln): it already
    // contains the pivot-centred symbols + ctr:/pat: variants, so the raw
    // sprite.json/patterns.json (the web/oracle format) would be redundant here —
    // they stay available via the standalone `tile57 sprite`/`pattern` commands.
    // If sprite-mln emits, the styles get a `sprite` URL so symbols + patterns
    // render; snd_stacks (collected during the bake) gives it the sounding composites.
    const sprite_ok = if (emitSpriteMln(io, a, resolveCatalogDir(catalog), DEFAULT_CSS, assets_dir, "sprite-mln", snd_stacks)) |_| true else |err| blk: {
        std.debug.print("warning: sprite-mln emit failed ({s})\n", .{@errorName(err)});
        break :blk false;
    };
    var styles: ?assets.Manifest.Styles = null;
    if (emitColorTables(io, a, resolveCatalogDir(catalog), ct_path)) |ct| {
        // One style.json per palette, resolving colour tokens from the colortables.
        // sprite enables the symbol/pattern layers; glyphs (text) await SDF glyphs.
        var ok = true;
        for ([_][]const u8{ "day", "dusk", "night" }) |sc| {
            const sj = assets.styleJson(a, .{ .scheme = sc, .colortables_json = ct, .sprite = if (sprite_ok) "sprite-mln" else null }) catch {
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
    const b = bounds;
    const manifest = try assets.manifestJson(a, .{
        .generator = VERSION,
        .created = created,
        .tiles_rel = "tiles/chart.pmtiles",
        .colortables_rel = "assets/colortables.json",
        .minzoom = minzoom,
        .maxzoom = maxzoom,
        .bbox = b,
        .anchor = .{ (b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0 },
        .cells = cells,
        .styles = styles,
    });
    const manifest_path = try std.fs.path.join(a, &.{ out_dir, "manifest.json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });

    std.debug.print(
        "bundled {d} cell(s) -> {s}/\n  tiles/chart.pmtiles + assets/colortables.json + sprite-mln + style-{{day,dusk,night}}.json + manifest.json (schema {s})\n",
        .{ cells.len, out_dir, assets.SCHEMA_VERSION },
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

// Live bake-root progress context (file-level so the C-ABI Progress callback can
// read the current band + super-tile position alongside the running tile count).
const ProgressCtx = struct { band: []const u8 = "?", st: usize = 0, st_total: usize = 0 };
var g_prog: ProgressCtx = .{};
var g_bake_start: i64 = 0;

/// Console progress for bake-root: stage 0 = loading cells, 1 = baking tiles.
/// Shows band, super-tile position, running tile count, throughput and elapsed.
fn cliProgress(ctx: ?*anyopaque, stage: u8, done: usize, total: usize) callconv(.c) void {
    _ = ctx;
    _ = total;
    const secs = @as(f64, @floatFromInt(@max(nowSec() - g_bake_start, 1)));
    const rate = @as(f64, @floatFromInt(done)) / secs;
    if (stage == 0) {
        std.debug.print("\r  {s}: loading {d} cells    ", .{ g_prog.band, done });
    } else {
        std.debug.print("\r  {s}: super-tile {d}/{d}  {d} tiles  ({d:.0}/s, {d:.0}s)    ", .{ g_prog.band, g_prog.st, g_prog.st_total, done, rate, secs });
    }
}

// One ENC_ROOT base cell: its `.000` path (updates are <stem>.001…, found on load)
// and the cheap peek bbox [w,s,e,n], used to assign it to spatial super-tiles
// without a full parse.
const CellEntry = struct { path: []const u8, bbox: [4]f64 };

// A cell's portrayal: the per-feature S-101 instruction streams (+ display
// variants), computed ONCE by the Lua engine and kept resident for the whole band
// in `arena`. Compact relative to geometry, and the expensive thing to produce —
// so it's never recomputed, even when the cell's geometry is evicted + re-parsed.
const CellPortray = struct {
    arena: *std.heap.ArenaAllocator, // sticky: owns the streams below
    base: ?[]const ?[]const u8,
    plain: ?[]const ?[]const u8,
    simplified: ?[]const ?[]const u8,
    bounds: [4]f64,
};

// A cell's parsed geometry (the heavy part): the S-57 model + assembled geo cache.
// EVICTABLE under LRU pressure and re-parsed on demand (cheap — no re-portrayal).
const CellGeom = struct {
    cell: engine.s57.Cell, // cell.arena owns the geometry
    geo: ?engine.s57_mvt.GeoParts,
    geo_world: ?engine.s57_mvt.GeoWorld = null, // precomputed world coords (in geo_arena)
    geo_arena: ?*std.heap.ArenaAllocator,
    feat_bbox: []const ?[4]f64 = &.{}, // per-feature bbox for the per-tile cull (in geo_arena)
};

// Copy per-feature instruction streams into `a` (the sticky portrayal arena) so
// they outlive the transient portrayal arena. nulls (features with no stream) stay.
fn copyStreams(a: std.mem.Allocator, src: []const ?[]const u8) ![]const ?[]const u8 {
    const out = try a.alloc(?[]const u8, src.len);
    for (src, 0..) |s, i| out[i] = if (s) |bytes| try a.dupe(u8, bytes) else null;
    return out;
}

// Parallel cell loader. Each index READS its cell's .000 (+ sequential updates)
// from disk, parses it (a fresh per-thread Lua state; page allocator is
// thread-safe), builds its geo cache (evictable), and — only the first time the
// cell is loaded (portray[ci] == null) — runs the S-101 portrayal and copies the
// streams into a sticky arena. Reading in the worker (std.Io.Dir.readFileAlloc is
// thread-safe: each call opens its own handle, no shared mutable state) makes a
// super-tile's cell reads parallel, so a cold first-bake isn't disk-read-serial.
// Re-loads after a geometry eviction re-parse only, reusing the resident
// portrayal. Distinct ci per j ⇒ race-free.
const LoadWork = struct {
    cells: []const u32, // cell indices into `entries`
    entries: []const CellEntry, // cell file path; bytes read in-worker (parallel I/O)
    dir: std.Io.Dir,
    io: std.Io,
    portray: []?CellPortray, // resident; produced only when null
    geom: []?CellGeom, // (re)built every load
    rules_dir: []const u8,
    gpa: std.mem.Allocator,

    fn run(uptr: *anyopaque, j: usize) void {
        const c: *LoadWork = @ptrCast(@alignCast(uptr));
        const ci = c.cells[j];
        const bpath = c.entries[ci].path;
        const base = c.dir.readFileAlloc(c.io, bpath, c.gpa, .unlimited) catch return;
        defer c.gpa.free(base);
        if (base.len == 0) return;
        // Read sequential updates (.001…) until the first missing one.
        var ups = std.ArrayList([]const u8).empty;
        defer {
            for (ups.items) |ub| c.gpa.free(ub);
            ups.deinit(c.gpa);
        }
        const stem = bpath[0 .. bpath.len - 4];
        var u: u32 = 1;
        while (u <= 999) : (u += 1) {
            const upn = std.fmt.allocPrint(c.gpa, "{s}.{d:0>3}", .{ stem, u }) catch break;
            defer c.gpa.free(upn);
            const ub = c.dir.readFileAlloc(c.io, upn, c.gpa, .unlimited) catch break;
            ups.append(c.gpa, ub) catch {
                c.gpa.free(ub);
                break;
            };
        }
        _ = g_parses.fetchAdd(1, .monotonic); // count parses (re-parse diagnostics)
        var cell = engine.s57.parseCellWithUpdates(c.gpa, base, ups.items) catch return;
        const b = cell.bounds() orelse {
            cell.deinit();
            return;
        };
        var geo: ?engine.s57_mvt.GeoParts = null;
        var geo_world: ?engine.s57_mvt.GeoWorld = null;
        var geo_arena: ?*std.heap.ArenaAllocator = null;
        var feat_bbox: []const ?[4]f64 = &.{};
        if (c.gpa.create(std.heap.ArenaAllocator)) |ga| {
            ga.* = std.heap.ArenaAllocator.init(c.gpa);
            // Assemble line/area geometry once + its world coords, so every tile
            // reprojects cheaply (no per-point tan/log) — the bake's biggest cost.
            if (engine.s57_mvt.buildGeoCache(ga.allocator(), &cell)) |g| {
                geo = g;
                geo_world = engine.s57_mvt.buildGeoWorld(ga.allocator(), g) catch null;
            } else |_| {}
            feat_bbox = engine.s57_mvt.buildFeatBBox(ga.allocator(), &cell, geo) catch &.{};
            geo_arena = ga;
        } else |_| {}
        c.geom[ci] = .{ .cell = cell, .geo = geo, .geo_world = geo_world, .geo_arena = geo_arena, .feat_bbox = feat_bbox };

        if (c.portray[ci] != null) return; // already portrayed — reuse it (the speed win)
        const sticky = c.gpa.create(std.heap.ArenaAllocator) catch return;
        sticky.* = std.heap.ArenaAllocator.init(c.gpa);
        const sa = sticky.allocator();
        var tmp = std.heap.ArenaAllocator.init(c.gpa);
        defer tmp.deinit();
        if (engine.portray.portrayCellVariants(tmp.allocator(), &cell, c.rules_dir)) |cp| {
            c.portray[ci] = .{
                .arena = sticky,
                .base = copyStreams(sa, cp.base) catch null,
                .plain = if (cp.plain) |p| (copyStreams(sa, p) catch null) else null,
                .simplified = if (cp.simplified) |p| (copyStreams(sa, p) catch null) else null,
                .bounds = b,
            };
        } else |_| {
            // Portrayal failed: a resident entry with no streams (classify() fallback);
            // marks the cell portrayed so it isn't retried.
            c.portray[ci] = .{ .arena = sticky, .base = null, .plain = null, .simplified = null, .bounds = b };
        }
    }
};

/// `bake-root <ENC_ROOT> -o <out.pmtiles> [--rules DIR] [--minzoom N] [--maxzoom N]`
/// Walk an ENC_ROOT for every `<CELL>.000` base cell (+ its sequential `.001…`
/// updates), parse + portray each, and bake them into ONE PMTiles archive with
/// per-cell zoom banding by compilation scale (engine.bake_enc). Holds every cell
/// in memory at once (v1).
// A whole-ENC_ROOT bake result: the union bbox of the cells, their stems (for the
// bundle manifest), and the distinct sounding glyph stacks collected while baking
// (for sprite-mln). The archive itself is streamed straight to `out_path`. Shared
// by `bake`/`bake-root`/`bundle`.
const RootBake = struct { bounds: [4]f64, cells: []const []const u8, sounds: []const []const u8 };

// Per-tile sink for the streaming bake: feed each tile into the PMTiles
// StreamWriter (gzip+dedup, no raw-tile retention) and, in the same pass, collect
// its soundings-layer glyph stacks (so sprite-mln gets composites without a
// re-read). A per-tile scratch arena keeps the MVT decode from accumulating.
const BakeSink = struct {
    sw: *engine.pmtiles.StreamWriter,
    sounds: *std.StringHashMap(void),
    a: std.mem.Allocator, // persistent (sound-stack strings; returned to caller)
    gpa: std.mem.Allocator, // scratch backing
    collect_sounds: bool, // bundle wants sprite-mln sounding composites; plain bake doesn't

    // `comp` is the already-gzipped tile (compressed in the gen worker), so the
    // serial path here is just dedup + write — fast. Sounding-stack collection (only
    // for the bundle) gunzips + decodes; plain bake-root skips it entirely.
    fn run(ctx: ?*anyopaque, z: u8, x: u32, y: u32, comp: []const u8) anyerror!void {
        const self: *BakeSink = @ptrCast(@alignCast(ctx.?));
        if (self.collect_sounds) collect: {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const mvt = engine.gzip.decompress(scratch.allocator(), comp) catch break :collect;
            const layers = engine.mvt.decode(scratch.allocator(), mvt) catch break :collect;
            for (layers) |L| {
                if (!std.mem.eql(u8, L.name, "soundings")) continue;
                for (L.features) |feat| for (feat.properties) |p| {
                    if (!std.mem.eql(u8, p.key, "sym_s") and !std.mem.eql(u8, p.key, "sym_g") and !std.mem.eql(u8, p.key, "symbol_names")) continue;
                    switch (p.value) {
                        .string => |sv| if (std.mem.indexOfScalar(u8, sv, ',') != null and !self.sounds.contains(sv)) {
                            self.sounds.put(self.a.dupe(u8, sv) catch return, {}) catch {};
                        },
                        else => {},
                    }
                };
            }
        }
        try self.sw.addCompressed(z, x, y, comp);
    }
};

// NOAA cell naming: a US ENC's 3rd char is its navigational-purpose digit
// (1=overview … 6=berthing), so the catalogue fast-path can band a cell from its
// name without parsing its CSCL header. Null for non-conforming names.
fn bandFromStem(stem: []const u8) ?engine.bake_enc.Band {
    if (stem.len < 3 or (stem[0] != 'U' and stem[0] != 'u')) return null;
    return switch (stem[2]) {
        '6' => .berthing,
        '5' => .harbor,
        '4' => .approach,
        '3' => .coastal,
        '2' => .general,
        '1' => .overview,
        else => null,
    };
}

// Bake an ENC_ROOT directory into one band-streamed PMTiles archive written
// straight to `out_path` (the data section streams through a StreamWriter — only
// the compressed data + small directory are held, not the raw tiles). Returns the
// union bounds + cell stems + sounding stacks. error.NoGeometry if no cell parses.
fn bakeRoot(io: std.Io, a: std.mem.Allocator, root_path: []const u8, out_path: []const u8, rules_dir: []const u8, minzoom: u8, maxzoom: u8, lru_budget: usize, super_dz: u8, collect_sounds: bool) !RootBake {
    const page = std.heap.page_allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);

    // Pass 1: learn each cell's band + bbox. Fast path: an exchange-set catalogue
    // (CATALOG.031) gives every cell's coverage bbox in ONE file — band each from
    // its NOAA name digit, no per-cell parse (matches the Go reference). Fallback
    // (no catalogue): walk the dir and cheaply peek each cell (bbox + CSCL).
    const Bands = engine.bake_enc;
    var band_cells: [Bands.bands_fine_to_coarse.len]std.ArrayList(CellEntry) = undefined;
    for (&band_cells) |*bc| bc.* = std.ArrayList(CellEntry).empty;
    var cell_names = std.ArrayList([]const u8).empty;
    var ubox: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 }; // [w,s,e,n]
    var total_cells: usize = 0;

    const via_catalog = cat: {
        const cbytes = dir.readFileAlloc(io, "CATALOG.031", page, .unlimited) catch break :cat false;
        defer page.free(cbytes);
        const entries = engine.s57.parseCatalog(a, cbytes) orelse break :cat false;
        var n_cells: usize = 0;
        for (entries) |e| {
            if (!e.is_cell) continue;
            n_cells += 1;
            try cell_names.append(a, e.stem);
            total_cells += 1;
            const bb = e.bbox orelse continue;
            ubox[0] = @min(ubox[0], bb[0]);
            ubox[1] = @min(ubox[1], bb[1]);
            ubox[2] = @max(ubox[2], bb[2]);
            ubox[3] = @max(ubox[3], bb[3]);
            // Band from the name; for the rare non-NOAA name, peek that one cell.
            const band = bandFromStem(e.stem) orelse fb: {
                const cb = dir.readFileAlloc(io, e.path, page, .unlimited) catch break :fb Bands.bandOf(0);
                defer page.free(cb);
                const m = engine.s57.peekMeta(page, cb);
                break :fb Bands.bandOf(if (m) |mm| mm.cscl else 0);
            };
            try band_cells[@intFromEnum(band)].append(a, .{ .path = e.path, .bbox = bb });
        }
        break :cat n_cells > 0;
    };

    if (!via_catalog) {
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".000")) continue;
            const path = try a.dupe(u8, entry.path);
            const bytes = dir.readFileAlloc(io, path, page, .unlimited) catch continue;
            const meta = engine.s57.peekMeta(page, bytes);
            page.free(bytes);
            try cell_names.append(a, try a.dupe(u8, std.fs.path.stem(std.fs.path.basename(path))));
            total_cells += 1;
            // A cell with no peek-bbox has no geometry to bake — skip it (it would
            // produce no tiles). The peek bbox is a superset of the parsed bounds,
            // so a cell is assigned to every super-tile its real geometry touches.
            const m = meta orelse continue;
            const bb = m.bounds orelse continue;
            ubox[0] = @min(ubox[0], bb[0]);
            ubox[1] = @min(ubox[1], bb[1]);
            ubox[2] = @max(ubox[2], bb[2]);
            ubox[3] = @max(ubox[3], bb[3]);
            try band_cells[@intFromEnum(Bands.bandOf(m.cscl))].append(a, .{ .path = path, .bbox = bb });
        }
    }
    if (total_cells == 0) return error.NoGeometry;
    std.debug.print("baking {d} cells from {s} ({s}, rules: {s})\n", .{ total_cells, root_path, if (via_catalog) "via CATALOG.031" else "scanned", if (rules_dir.len == 0) "embedded" else rules_dir });

    engine.catalogue.warmUp(); // warm the shared catalogue before parallel portrayal
    engine.portray.setQuiet(true); // many threads -> suppress the per-cell stderr

    // Stream the gzipped tiles straight to a temp data file (concatenated into
    // out_path at the end) so the whole compressed archive never lives in RAM —
    // only the directory + dedup map do. Peak memory is then one band's cells.
    const data_tmp = try std.fmt.allocPrint(a, "{s}.data.tmp", .{out_path});
    var data_file = try std.Io.Dir.cwd().createFile(io, data_tmp, .{ .read = true });
    errdefer {
        data_file.close(io);
        std.Io.Dir.cwd().deleteFile(io, data_tmp) catch {};
    }
    var sw = engine.pmtiles.StreamWriter.initFile(page, io, data_file);
    defer sw.deinit();
    var sounds = std.StringHashMap(void).init(a);
    var sink = BakeSink{ .sw = &sw, .sounds = &sounds, .a = a, .gpa = page, .collect_sounds = collect_sounds };
    var baker = Bands.Baker.init(page, minzoom, maxzoom, .{ .ctx = &sink, .func = BakeSink.run });
    defer baker.deinit();

    // Pass 2: bake each band finest → coarsest (best-band dedup via baker.emitted).
    // Within a band, walk spatial "super-tiles" (one tile at zoom zs = zlo - SUPER_DZ):
    // load ONLY the cells overlapping each super-tile (parse + portray in parallel),
    // generate that super-tile's tiles (clipped, parallel), and keep parsed cells in
    // a small LRU so neighbouring super-tiles reuse them (cells span a few super-tiles
    // and are parsed once). Peak memory is the busiest super-tile's cells + the LRU
    // budget — not the whole band. Coarse bands have few (huge) cells and a tiny grid,
    // so they fall back to loading them together.
    std.debug.print("  (lazy bake: lru={d} cells, super-dz={d})\n", .{ lru_budget, super_dz });
    g_bake_start = nowSec();
    var done_cells: usize = 0;
    for (Bands.bands_fine_to_coarse) |band| {
        const entries = band_cells[@intFromEnum(band)].items;
        if (entries.len == 0) continue;
        const parses0 = g_parses.load(.monotonic);
        const band_start = nowSec();

        const zr = Bands.bandZooms(band);
        const zlo = @max(minzoom, zr.min);
        const zhi = @min(maxzoom, zr.max);
        if (zlo > zhi) {
            done_cells += entries.len;
            continue;
        }
        const zs: u8 = if (zlo >= super_dz) zlo - super_dz else 0;

        // Inverted index: super-tile (sx,sy at zs) → the cell indices overlapping it.
        var stmap = std.AutoHashMap(u64, std.ArrayList(u32)).init(page);
        defer {
            var vit = stmap.valueIterator();
            while (vit.next()) |v| v.deinit(page);
            stmap.deinit();
        }
        for (entries, 0..) |e, i| {
            const nw = lonLatToTile(e.bbox[0], e.bbox[3], zs);
            const se = lonLatToTile(e.bbox[2], e.bbox[1], zs);
            var sy = nw[1];
            while (sy <= se[1]) : (sy += 1) {
                var sx = nw[0];
                while (sx <= se[0]) : (sx += 1) {
                    const k = (@as(u64, sy) << 32) | sx; // row-major (spatial locality)
                    const gop = try stmap.getOrPut(k);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                    try gop.value_ptr.append(page, @intCast(i));
                }
            }
        }
        const stkeys = try page.alloc(u64, stmap.count());
        defer page.free(stkeys);
        {
            var kit = stmap.keyIterator();
            var j: usize = 0;
            while (kit.next()) |kp| : (j += 1) stkeys[j] = kp.*;
        }
        std.mem.sort(u64, stkeys, {}, struct {
            fn lt(_: void, x: u64, y: u64) bool {
                return x < y;
            }
        }.lt);
        g_prog.band = @tagName(band);
        g_prog.st = 0;
        g_prog.st_total = stkeys.len;
        std.debug.print("\n  band {s}: {d} cells, {d} super-tiles (z{d}-{d}) — baking…\n", .{ @tagName(band), entries.len, stkeys.len, zlo, zhi });

        // Per-band caches (index-aligned with `entries`): portrayal is RESIDENT
        // (computed once — the expensive Lua step — and cheap to keep); geometry is
        // the heavy part, held in an LRU and re-parsed (NOT re-portrayed) on demand.
        const portray = try page.alloc(?CellPortray, entries.len);
        defer page.free(portray);
        @memset(portray, null);
        const geom = try page.alloc(?CellGeom, entries.len);
        defer page.free(geom);
        @memset(geom, null);
        const used = try page.alloc(u64, entries.len); // LRU tick per cell (geometry)
        defer page.free(used);
        @memset(used, 0);
        const gave_up = try page.alloc(bool, entries.len); // parse failed: don't retry
        defer page.free(gave_up);
        @memset(gave_up, false);
        var n_geom: usize = 0; // loaded-geometry count (the LRU target)
        var tick: u64 = 0;

        for (stkeys, 0..) |stk, st_i| {
            g_prog.st = st_i + 1;
            const cells = stmap.get(stk).?.items;
            const sx: u32 = @intCast(stk & 0xFFFFFFFF);
            const sy: u32 = @intCast(stk >> 32);

            // (Re)load this super-tile's cells whose geometry isn't resident — each
            // worker reads its own cell's bytes + parses (+ portrays once) in
            // parallel, so cold reads aren't serialised. A cell already portrayed is
            // only re-parsed, never re-portrayed.
            var miss = std.ArrayList(u32).empty;
            defer miss.deinit(page);
            for (cells) |ci| if (geom[ci] == null and !gave_up[ci]) miss.append(page, ci) catch {};
            if (miss.items.len > 0) {
                var lw = LoadWork{ .cells = miss.items, .entries = entries, .dir = dir, .io = io, .portray = portray, .geom = geom, .rules_dir = rules_dir, .gpa = page };
                Bands.parallelFor(miss.items.len, &lw, LoadWork.run);
                for (miss.items) |ci| {
                    if (geom[ci] != null) n_geom += 1 else gave_up[ci] = true;
                }
            }
            tick += 1;
            for (cells) |ci| used[ci] = tick;

            // Generate this super-tile's tiles from its loaded cells (clipped, parallel):
            // pair each cell's geometry with its resident portrayal.
            var subset = std.ArrayList(Bands.Backend).empty;
            defer subset.deinit(page);
            for (cells) |ci| if (geom[ci]) |g| {
                const p = portray[ci];
                subset.append(page, .{
                    .cell = g.cell,
                    .portrayal = if (p) |pp| pp.base else null,
                    .portrayal_plain = if (p) |pp| pp.plain else null,
                    .portrayal_simplified = if (p) |pp| pp.simplified else null,
                    .geo = g.geo,
                    .geo_world = g.geo_world,
                    .feat_bbox = g.feat_bbox,
                    .bounds = if (p) |pp| pp.bounds else entries[ci].bbox,
                }) catch {};
            };
            baker.bakeBand(band, subset.items, .{ .zs = zs, .sx = sx, .sy = sy }, cliProgress, null) catch {};

            // Evict least-recently-used GEOMETRY beyond the budget (never this
            // super-tile's, which carry the current tick). Portrayal stays resident.
            while (n_geom > lru_budget) {
                var victim: ?usize = null;
                var best: u64 = std.math.maxInt(u64);
                for (geom, 0..) |g, ci| {
                    if (g != null and used[ci] < best) {
                        best = used[ci];
                        victim = ci;
                    }
                }
                const v = victim orelse break;
                if (used[v] == tick) break; // only the current super-tile's cells remain
                if (geom[v]) |*g| {
                    g.cell.deinit();
                    if (g.geo_arena) |p| {
                        p.deinit();
                        page.destroy(p);
                    }
                }
                geom[v] = null;
                n_geom -= 1;
            }
        }

        // Free remaining geometry + all resident portrayal at the end of the band.
        for (geom, 0..) |g, ci| if (g != null) {
            if (geom[ci]) |*gg| {
                gg.cell.deinit();
                if (gg.geo_arena) |p| {
                    p.deinit();
                    page.destroy(p);
                }
            }
        };
        for (portray, 0..) |p, ci| if (p != null) {
            portray[ci].?.arena.deinit();
            page.destroy(portray[ci].?.arena);
        };
        const parses = g_parses.load(.monotonic) - parses0;
        const band_secs = nowSec() - band_start;
        std.debug.print(
            "\r  band {s} done: {d} cells, {d} super-tiles, {d} tiles total, {d} parses ({d:.2}x), {d}s\n",
            .{ @tagName(band), entries.len, stkeys.len, baker.count, parses, @as(f64, @floatFromInt(parses)) / @as(f64, @floatFromInt(@max(entries.len, 1))), band_secs },
        );
        done_cells += entries.len;
        cliProgress(null, 0, done_cells, total_cells);
    }

    // Assemble out_path = prefix (header + directory + metadata) ++ the data
    // section streamed to data_tmp. The prefix is small; the data is copied in
    // bounded chunks (positional reads, no whole-archive buffer), then the temp
    // file is removed.
    const opts = engine.pmtiles.WriteOptions{
        .min_lon_e7 = toE7(ubox[0]),
        .min_lat_e7 = toE7(ubox[1]),
        .max_lon_e7 = toE7(ubox[2]),
        .max_lat_e7 = toE7(ubox[3]),
    };
    const pre = try sw.prefix(a, opts);
    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    try file.writeStreamingAll(io, pre);
    {
        const chunk = try a.alloc(u8, 1 << 20); // 1 MiB
        defer a.free(chunk);
        var pos: u64 = 0;
        while (pos < sw.data_len) {
            const want: usize = @intCast(@min(@as(u64, chunk.len), sw.data_len - pos));
            _ = try data_file.readPositionalAll(io, chunk[0..want], pos);
            try file.writeStreamingAll(io, chunk[0..want]);
            pos += want;
        }
    }
    file.close(io);
    data_file.close(io);
    std.Io.Dir.cwd().deleteFile(io, data_tmp) catch {};

    var stacks = std.ArrayList([]const u8).empty;
    var it = sounds.keyIterator();
    while (it.next()) |k| try stacks.append(a, k.*);
    return .{ .bounds = ubox, .cells = cell_names.items, .sounds = stacks.items };
}

/// `bake-root <ENC_ROOT> -o <out.pmtiles> [--rules DIR] [--minzoom N] [--maxzoom N]`
fn runBakeRoot(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var root: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var minzoom: u8 = 0;
    var maxzoom: u8 = 18;
    var lru: usize = DEFAULT_LRU_BUDGET;
    var super_dz: u8 = DEFAULT_SUPER_DZ;
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
        } else if (std.mem.eql(u8, arg, "--lru")) {
            lru = f.int(usize, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--superdz")) {
            super_dz = f.int(u8, arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (root == null) {
            root = arg;
        }
    }
    const root_path = root orelse return usageErr("missing <ENC_ROOT> input");
    const out_path = out orelse return usageErr("missing -o/--output <out.pmtiles>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");
    if (lru < 1) return usageErr("--lru must be >= 1");
    const rb = bakeRoot(io, a, root_path, out_path, resolveRulesDir(rules), minzoom, maxzoom, lru, super_dz, false) catch |err| {
        std.debug.print("error: {s} ({s})\n", .{ root_path, @errorName(err) });
        return;
    };
    std.debug.print("\nbaked {d} cells -> {s}\n", .{ rb.cells.len, out_path });
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
        \\  tile57 bake <cell.000> -o <out.pmtiles> [options] [update.001 ...]
        \\      -o, --output PATH   output PMTiles archive (required)
        \\      --rules DIR         S-101 portrayal rules directory (optional)
        \\      --minzoom N         lowest zoom to bake (default {d})
        \\      --maxzoom N         highest zoom to bake (default {d})
        \\  tile57 bake-root <ENC_ROOT> -o <out.pmtiles> [options]
        \\      Bake a whole ENC_ROOT (every <CELL>.000 + updates) into one
        \\      archive, zoom-banded per cell by compilation scale.
        \\      -o/--output, --rules as above; --minzoom/--maxzoom clamp the bands.
        \\  tile57 bundle <cell.000> -o <out-dir> [options] [update.001 ...]
        \\      Emit a self-contained chart bundle: tiles/chart.pmtiles +
        \\      assets/colortables.json + manifest.json (pins schema_version,
        \\      couples tiles to portrayal). --rules/--minzoom/--maxzoom as above;
        \\      --catalog DIR PortrayalCatalog (default: parent of --rules);
        \\      --created ISO8601 stamps the manifest (no wall clock in-process).
        \\  tile57 assets <portrayal-catalog-dir> -o <out-dir>
        \\      Emit just the portrayal assets (colortables.json today) for a
        \\      catalogue, independent of any cell.
        \\  tile57 style <portrayal-catalog-dir> --scheme day -o <out.json>
        \\      Emit one MapLibre style.json (colours from the catalogue, or
        \\      --colortables FILE). --scheme day|dusk|night; --source-tiles/
        \\      --pmtiles-url pick the source; --sprite/--glyphs enable symbol/text
        \\      layers; --minzoom/--maxzoom.
        \\  tile57 inspect <file.pmtiles> [z x y]
        \\  tile57 cell <file.000>
        \\  tile57 version
        \\  tile57 help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM });
}
