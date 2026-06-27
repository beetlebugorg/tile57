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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const sub: []const u8 = if (args.len >= 2) args[1] else "help";

    if (std.mem.eql(u8, sub, "bake")) {
        return runBake(io, arena, args);
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

/// `bake <cell.000> -o <out.pmtiles> [--rules DIR] [--minzoom N] [--maxzoom N] [update.001 ...]`
fn runBake(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var minzoom: u8 = DEFAULT_MINZOOM;
    var maxzoom: u8 = DEFAULT_MAXZOOM;
    var updates = std.ArrayList([]const u8).empty;

    var i: usize = 2; // skip exe + "bake"
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return usageErr("missing value for -o/--output");
            out = args[i];
        } else if (std.mem.eql(u8, arg, "--rules")) {
            i += 1;
            if (i >= args.len) return usageErr("missing value for --rules");
            rules = args[i];
        } else if (std.mem.eql(u8, arg, "--minzoom")) {
            i += 1;
            if (i >= args.len) return usageErr("missing value for --minzoom");
            minzoom = std.fmt.parseInt(u8, args[i], 10) catch return usageErr("--minzoom must be an integer");
        } else if (std.mem.eql(u8, arg, "--maxzoom")) {
            i += 1;
            if (i >= args.len) return usageErr("missing value for --maxzoom");
            maxzoom = std.fmt.parseInt(u8, args[i], 10) catch return usageErr("--maxzoom must be an integer");
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

    // Read the base cell + any updates listed on the command line.
    const base_bytes = try std.Io.Dir.cwd().readFileAlloc(io, base_path, a, .unlimited);
    const update_bytes = try a.alloc([]const u8, updates.items.len);
    for (updates.items, 0..) |u, ui| {
        update_bytes[ui] = try std.Io.Dir.cwd().readFileAlloc(io, u, a, .unlimited);
    }

    var cell = try engine.s57.parseCellWithUpdates(a, base_bytes, update_bytes);
    defer cell.deinit();

    // S-101 portrayal: run the embedded-Lua rule engine over the cell's adapted
    // features (same path the live library uses) so baked tiles carry full S-101
    // styling. The arena `a` outlives tile generation below, as portrayCell
    // requires. Portrayal failure (e.g. rules dir not found) is non-fatal:
    // generateTile then falls back to the built-in classify() styling.
    const rules_dir = resolveRulesDir(rules);
    const portrayal: ?[]const ?[]const u8 = if (engine.portray.portrayCell(a, &cell, rules_dir)) |res|
        res
    else |err| blk: {
        std.debug.print(
            "warning: S-101 portrayal failed ({s}) with rules dir '{s}'; baking with classify() fallback\n",
            .{ @errorName(err), rules_dir },
        );
        break :blk null;
    };

    const b = cell.bounds() orelse {
        std.debug.print("error: {s} has no geometry to bake\n", .{base_path});
        return;
    };
    // bounds() -> [min_lon, min_lat, max_lon, max_lat] (west, south, east, north).

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
                const tile_mvt = try engine.s57_mvt.generateTile(a, &cell, z, tx, ty, portrayal);
                if (tile_mvt.len == 0) continue; // empty tile: nothing covered here
                try tiles.append(a, .{ .z = z, .x = tx, .y = ty, .mvt = tile_mvt });
            }
        }
    }

    if (tiles.items.len == 0) {
        std.debug.print("warning: no non-empty tiles produced for zoom {d}..{d}\n", .{ minzoom, maxzoom });
    }

    const opts = engine.pmtiles.WriteOptions{
        .min_lon_e7 = toE7(b[0]),
        .min_lat_e7 = toE7(b[1]),
        .max_lon_e7 = toE7(b[2]),
        .max_lat_e7 = toE7(b[3]),
    };
    const archive = try engine.pmtiles.write(a, tiles.items, opts);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = archive });

    std.debug.print(
        "baked {d} cell ({d} update file(s) applied) -> {s}\n  {d} tiles written, zoom {d}..{d}\n  output {d} bytes ({d:.1} MB)\n",
        .{
            @as(usize, 1),         updates.items.len, out_path,
            tiles.items.len,       minzoom,           maxzoom,
            archive.len,           @as(f64, @floatFromInt(archive.len)) / (1024.0 * 1024.0),
        },
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
        \\  chartplotter-bake inspect <file.pmtiles> [z x y]
        \\  chartplotter-bake cell <file.000>
        \\  chartplotter-bake version
        \\  chartplotter-bake help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM });
}
