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
const bundle = @import("bundle"); // chart-bundle pipeline (asset emitters etc.) — the lib owns it
const render = @import("render"); // pixel path: PixelSurface + resolver (renderpng)
const catalog_embed = @import("catalog"); // embedded portrayal assets (colour profile)

const VERSION = "tile57 0.1.0";

const DEFAULT_MINZOOM: u8 = 8;
const DEFAULT_MAXZOOM: u8 = 16;

// Lazy-baker tuning (bake-root): LRU budget = parsed cells kept loaded across
// super-tiles; super-tile depth = how far below a band's min zoom the spatial
// batch tile sits. Overridable via --lru / --superdz for tuning.
const DEFAULT_LRU_BUDGET: usize = 64;
const DEFAULT_SUPER_DZ: u8 = 3;

// Env access lives in the Lua C shim (Zig 0.16 gates env behind std.Io);
// returns the S-101 rules dir from TILE57_S101_RULES or null. Mirrors capi.zig.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

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

    if (std.mem.eql(u8, sub, "style")) {
        return runStyle(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "renderpng")) {
        return runRenderPng(io, arena, args);
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
                if (h.tile_type == .mlt) {
                    // MLT isn't decodable here (no in-engine MLT decoder); dump the
                    // decompressed bytes as hex so they can be fed to a reference
                    // decoder. Cap the hex so a big tile doesn't flood the terminal.
                    std.debug.print("  tile {d}/{d}/{d}: {d} bytes (MLT)\n", .{ z, x, y, tile.len });
                    if (tile.len <= 8192) {
                        std.debug.print("  hex:", .{});
                        for (tile) |c| std.debug.print("{x:0>2}", .{c});
                        std.debug.print("\n", .{});
                    } else std.debug.print("  (>{d} bytes; re-bake a sparser tile for a hex dump)\n", .{@as(usize, 8192)});
                } else {
                    const layers = try engine.mvt.decode(arena, tile);
                    std.debug.print("  tile {d}/{d}/{d}: {d} bytes, {d} layers:\n", .{ z, x, y, tile.len, layers.len });
                    // Optional 7th arg names a layer whose features' properties are
                    // dumped (verification aid; does not touch bake output).
                    const want: ?[]const u8 = if (args.len >= 7) args[6] else null;
                    for (layers) |L| {
                        std.debug.print("    {s}: {d} features (extent {d})\n", .{ L.name, L.features.len, L.extent });
                        if (want) |w| if (std.mem.eql(u8, w, L.name)) for (L.features, 0..) |feat, fi| {
                            std.debug.print("      [{d}] {s}:", .{ fi, @tagName(feat.geom_type) });
                            // First geometry coord (verification aid: spot duplicate
                            // point symbols at the same tile-space position).
                            if (feat.parts.len > 0 and feat.parts[0].len > 0) {
                                const p0 = feat.parts[0][0];
                                std.debug.print(" @({d},{d})", .{ p0.x, p0.y });
                            }
                            for (feat.properties) |p| switch (p.value) {
                                .string => |sv| std.debug.print(" {s}=\"{s}\"", .{ p.key, sv }),
                                .int => |iv| std.debug.print(" {s}={d}", .{ p.key, iv }),
                                .double => |dv| std.debug.print(" {s}={d}", .{ p.key, dv }),
                                .float => |fv| std.debug.print(" {s}={d}", .{ p.key, fv }),
                                .uint => |uv| std.debug.print(" {s}={d}", .{ p.key, uv }),
                                .boolean => |bv| std.debug.print(" {s}={}", .{ p.key, bv }),
                            };
                            std.debug.print("\n", .{});
                        };
                    }
                }
            } else std.debug.print("  tile {d}/{d}/{d}: not found\n", .{ z, x, y });
        }
        return;
    }

    // Lean corpus scan: count features of one object class (optionally one
    // primitive) in a single cell, parse-only (no topology assembly), one line
    // per matching cell — drive a whole ENC_ROOT with `find … | xargs -P`. Used
    // to find real cells that exercise a conversion change (e.g. a point DAMCON).
    if (std.mem.eql(u8, sub, "objlcount")) {
        if (args.len < 4) {
            std.debug.print("usage: tile57 objlcount <file.000> <objl> [prim]\n", .{});
            return;
        }
        const path = args[2];
        const want_objl = std.fmt.parseInt(u16, args[3], 10) catch {
            std.debug.print("error: objl must be an integer\n", .{});
            return;
        };
        const want_prim: ?u8 = if (args.len >= 5) (std.fmt.parseInt(u8, args[4], 10) catch null) else null;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch {
            std.debug.print("{s} READ_ERROR\n", .{path});
            return;
        };
        var cell = engine.s57.parseCell(arena, data) catch {
            std.debug.print("{s} PARSE_ERROR\n", .{path});
            return;
        };
        defer cell.deinit();
        // objl 0 = histogram mode: emit every object class that appears as a POINT
        // (prim 1) in this cell, one line each. One corpus sweep then aggregates which
        // classes ever occur as points — cross-reference against S-101 rules with no
        // Point branch to find latent "renders nothing" bugs (as for point DAMCON).
        if (want_objl == 0) {
            var hist = [_]usize{0} ** 1024;
            for (cell.features) |f| if (f.prim == 1 and f.objl < 1024) {
                hist[f.objl] += 1;
            };
            for (hist, 0..) |cnt, objl| if (cnt > 0)
                std.debug.print("objl={d} point={d}\n", .{ objl, cnt });
            return;
        }
        var pc = [_]usize{0} ** 256;
        for (cell.features) |f| if (f.objl == want_objl) {
            pc[f.prim] += 1;
        };
        const total = pc[1] + pc[2] + pc[3] + pc[255];
        const match = if (want_prim) |wp| pc[wp] > 0 else total > 0;
        if (match) {
            std.debug.print("{s} objl={d} point={d} line={d} area={d} none={d}\n", .{ path, want_objl, pc[1], pc[2], pc[3], pc[255] });
            // Locate matches of the requested primitive (default point) + dump their
            // attributes, one delimitable block per feature (helps pin the tile a change
            // lands in, identify an unknown class by its attribute codes, and scan the
            // corpus for per-feature attribute presence on line/area classes too).
            const dump_prim: u8 = want_prim orelse 1;
            for (cell.features) |f| if (f.objl == want_objl and f.prim == dump_prim) {
                std.debug.print("    feature rcid={d} prim={d}\n", .{ f.rcid, f.prim });
                if (f.prim == 1) if (cell.pointGeometry(f)) |p|
                    std.debug.print("      point @ lon={d:.6} lat={d:.6}\n", .{ p.lon(), p.lat() });
                for (f.attrs) |at|
                    std.debug.print("      attr {d} = \"{s}\"\n", .{ at.code, std.mem.trim(u8, at.value, " ") });
            };
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

// ---- assets / bundle ----------------------------------------------------

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

// ---- assets / bundle emitters: moved to src/bundle.zig (the lib owns the pipeline;
// the CLI is a thin wrapper). Aliased so the command handlers below are unchanged. --
const emitColorTables = bundle.emitColorTables;
const emitLinestyles = bundle.emitLinestyles;
const emitSprites = bundle.emitSprites;
const emitPatterns = bundle.emitPatterns;
const emitSpriteMln = bundle.emitSpriteMln;
const colorTablesBytes = bundle.colorTablesBytes;
const linestylesBytes = bundle.linestylesBytes;
const spriteAtlasBytes = bundle.spriteAtlasBytes;
const patternAtlasBytes = bundle.patternAtlasBytes;
const spriteMlnBytes = bundle.spriteMlnBytes;
const DEFAULT_CSS = bundle.DEFAULT_CSS;

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

/// `bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [--catalog DIR]
///  [--minzoom N] [--maxzoom N] [--lru N] [--superdz N] [--created ISO8601]` —
/// THE bake command. A single cell or a whole ENC_ROOT, streamed through the same
/// lazy banded bake into a self-contained chart bundle: tiles/chart.pmtiles +
/// assets/colortables.json + sprite-mln + style-{day,dusk,night}.json +
/// manifest.json (pins schema_version, couples tiles to portrayal).
fn runBake(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var catalog: ?[]const u8 = null;
    var created: []const u8 = "";
    var minzoom: u8 = DEFAULT_MINZOOM;
    var maxzoom: u8 = DEFAULT_MAXZOOM;
    var lru: usize = DEFAULT_LRU_BUDGET; // lazy-bake tuning: parsed cells held resident
    var super_dz: u8 = DEFAULT_SUPER_DZ; // lazy-bake tuning: spatial super-tile depth
    var format: engine.s57_mvt.TileFormat = .mvt; // tile encoding: mvt (default) or mlt

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
        } else if (std.mem.eql(u8, arg, "--lru")) {
            lru = f.int(usize, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--superdz")) {
            super_dz = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--format")) {
            const v = f.val(arg) orelse return;
            format = if (std.mem.eql(u8, v, "mlt")) .mlt else if (std.mem.eql(u8, v, "mvt")) .mvt else return usageErr("--format must be mvt or mlt");
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (base == null) {
            base = arg;
        } else {
            return usageErr("unexpected argument (cell updates are auto-discovered next to the .000)");
        }
    }

    const base_path = base orelse return usageErr("missing <cell.000 | ENC_ROOT> input");
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");
    if (lru < 1) return usageErr("--lru must be >= 1");

    // The whole tiles + assets + manifest pipeline lives in the `bundle` lib module
    // (bundle.bakeBundle) so any consumer (the C ABI, a Go/JS binding) emits the same
    // package; the CLI just resolves args -> options and prints the summary.
    const res = bundle.bakeBundle(io, a, .{
        .input = base_path,
        .out_dir = out_dir,
        .rules_dir = resolveRulesDir(rules),
        .catalog_dir = resolveCatalogDir(catalog),
        .generator = VERSION,
        .created = created,
        .minzoom = minzoom,
        .maxzoom = maxzoom,
        .lru = lru,
        .super_dz = super_dz,
        .format = format,
    }) catch |err| {
        std.debug.print("error: cannot bake {s} ({s})\n", .{ base_path, @errorName(err) });
        return;
    };

    std.debug.print(
        "bundled {d} cell(s) -> {s}/\n  tiles/chart.pmtiles + assets/colortables.json + sprite-mln + style-{{day,dusk,night}}.json + manifest.json (schema {s})\n",
        .{ res.cell_count, out_dir, assets.SCHEMA_VERSION },
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

// tile57 renderpng <cell.000> <z> <x> <y> -o <out.png> [--size N] [--palette P] [--rules DIR]
// The render-engine pixel path over ONE cell (no band quilting): parse +
// portray the cell (fixed bake context for now), drive the engine through
// PixelSurface -> RasterCanvas -> PNG. The in-repo render-to-PNG verify path.
// P2 scope: area fills + line strokes; symbols/soundings/text land at P3/P4.
fn runRenderPng(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 6) {
        std.debug.print("usage: tile57 renderpng <cell.000> <z> <x> <y> -o <out.png> [--size N] [--palette day|dusk|night] [--rules DIR]\n", .{});
        return;
    }
    const path = args[2];
    const z = std.fmt.parseInt(u8, args[3], 10) catch return usageErr("bad z");
    const x = std.fmt.parseInt(u32, args[4], 10) catch return usageErr("bad x");
    const y = std.fmt.parseInt(u32, args[5], 10) catch return usageErr("bad y");

    var out_path: ?[]const u8 = null;
    var size: u32 = 256;
    var palette: render.resolve.PaletteId = .day;
    var rules: ?[]const u8 = null;
    var dq = false;
    var size_scale: f64 = 1.0; // physical-size multiplier (S-52 mm -> true mm)
    var f = Flags{ .args = args, .i = 5 }; // positionals end at args[5]
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = f.next() orelse return usageErr("-o needs a path");
        } else if (std.mem.eql(u8, arg, "--size")) {
            const v = f.next() orelse return usageErr("--size needs a value");
            size = std.fmt.parseInt(u32, v, 10) catch return usageErr("bad --size");
        } else if (std.mem.eql(u8, arg, "--palette")) {
            const v = f.next() orelse return usageErr("--palette needs a value");
            palette = std.meta.stringToEnum(render.resolve.PaletteId, v) orelse return usageErr("palette must be day|dusk|night");
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.next() orelse return usageErr("--rules needs a dir");
        } else if (std.mem.eql(u8, arg, "--dq")) {
            dq = true; // S-52 data-quality overlay (M_QUAL DQUAL* patterns)
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const v = f.next() orelse return usageErr("--scale needs a value");
            size_scale = std.fmt.parseFloat(f64, v) catch return usageErr("bad --scale");
        } else return usageErr("unknown flag");
    }
    const out = out_path orelse return usageErr("-o <out.png> is required");

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var cell = try engine.s57.parseCell(a, data);
    defer cell.deinit();
    engine.portray.setQuiet(true);
    const streams = try engine.portray.portrayCell(a, &cell, resolveRulesDir(rules));

    var colors = try render.resolve.Colors.init(a, catalog_embed.colorprofile[0].bytes);
    // Display "other" on by default: spot soundings are S-52 category Other,
    // and this is the recreational verify path (the host enables Other too).
    const settings = render.resolve.MarinerSettings{ .display_other = true, .data_quality = dq, .size_scale = size_scale };
    var ps = render.pixel.PixelSurface.init(a, &colors, palette, &settings, @floatFromInt(z), size, engine.tile.EXTENT);

    // Vector symbol store over the embedded catalogue, palette-matched CSS.
    const css_name = switch (palette) {
        .day => "daySvgStyle",
        .dusk => "duskSvgStyle",
        .night => "nightSvgStyle",
    };
    var css_data: []const u8 = "";
    for (catalog_embed.css) |e| {
        if (std.mem.eql(u8, e.name, css_name)) css_data = e.bytes;
    }
    const sym_srcs = try a.alloc(sprite.SvgSrc, catalog_embed.symbols.len);
    for (catalog_embed.symbols, 0..) |e, si| sym_srcs[si] = .{ .id = e.name, .svg = e.bytes };
    const fill_srcs = try a.alloc(sprite.AreaFillSrc, catalog_embed.areafills.len);
    for (catalog_embed.areafills, 0..) |e, fi| fill_srcs[fi] = .{ .id = e.name, .xml = e.bytes };
    const store = try sprite.CatalogStore.init(a, sym_srcs, fill_srcs, css_data);
    defer store.deinit();
    ps.store = store.asStore();

    const cells = [_]engine.s57_mvt.CellRef{.{ .cell = &cell, .portrayal = streams }};
    const bytes = try engine.s57_mvt.generateTileSurface(a, a, &cells, z, x, y, false, ps.asSurface());
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes });
    std.debug.print("wrote {s}: tile {d}/{d}/{d}, {d}x{d}px, {d} draw ops, {d} bytes\n", .{ out, z, x, y, size, size, ps.ops.items.len, bytes.len });
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
        \\  tile57 bake <cell.000 | ENC_ROOT> -o <out-dir> [options]
        \\      Bake a single S-57 cell OR a whole ENC_ROOT (every <CELL>.000 +
        \\      its auto-discovered updates, zoom-banded per cell by compilation
        \\      scale) into a self-contained chart bundle, streamed to disk:
        \\      <out>/tiles/chart.pmtiles + assets/colortables.json + sprite-mln +
        \\      style-{{day,dusk,night}}.json + manifest.json (pins schema_version,
        \\      couples tiles to portrayal).
        \\      -o, --output DIR    output bundle directory (required)
        \\      --rules DIR         S-101 portrayal rules directory (default: embedded)
        \\      --catalog DIR       PortrayalCatalog (default: parent of --rules)
        \\      --minzoom N         lowest zoom to bake (default {d})
        \\      --maxzoom N         highest zoom to bake (default {d})
        \\      --created ISO8601   stamp the manifest (no wall clock in-process)
        \\      --lru N             parsed cells held resident (lazy-bake tuning; trade
        \\                          memory for fewer re-parses; default {d})
        \\      --superdz N         spatial super-tile depth below a band's min zoom
        \\                          (lazy-bake tuning; default {d})
        \\      --format mvt|mlt    tile encoding (default mvt; mlt = MapLibre Tile)
        \\  tile57 assets <portrayal-catalog-dir> -o <out-dir>
        \\      Emit just the portrayal assets (colortables.json today) for a
        \\      catalogue, independent of any cell.
        \\  tile57 style <portrayal-catalog-dir> --scheme day -o <out.json>
        \\      Emit one MapLibre style.json (colours from the catalogue, or
        \\      --colortables FILE). --scheme day|dusk|night; --source-tiles/
        \\      --pmtiles-url pick the source; --sprite/--glyphs enable symbol/text
        \\      layers; --minzoom/--maxzoom.
        \\  tile57 renderpng <cell.000> <z> <x> <y> -o <out.png> [--size N] [--palette day|dusk|night]
        \\      Render one tile of a cell to PNG through the native pixel path
        \\      (fills + strokes; symbols/text pending).
        \\  tile57 inspect <file.pmtiles> [z x y]
        \\  tile57 cell <file.000>
        \\  tile57 objlcount <file.000> <objl> [prim]   (corpus scan: find cells with an object class)
        \\  tile57 version
        \\  tile57 help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM, DEFAULT_LRU_BUDGET, DEFAULT_SUPER_DZ });
}
