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
const chart = @import("chart"); // streaming ENC_ROOT open + quilted view render

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

    if (std.mem.eql(u8, sub, "png") or std.mem.eql(u8, sub, "renderpng")) {
        return runRender(io, arena, args, .png);
    }

    if (std.mem.eql(u8, sub, "pdf")) {
        return runRender(io, arena, args, .pdf);
    }

    if (std.mem.eql(u8, sub, "ascii")) {
        return runAscii(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "explore") or std.mem.eql(u8, sub, "inspect-s57")) {
        return runExplore(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "cells")) {
        // Per-cell metadata JSON (the tile57_chart_cells ABI).
        if (args.len < 3) {
            std.debug.print("usage: tile57 cells <cell.000 | ENC_ROOT>\n", .{});
            return;
        }
        engine.portray.setQuiet(true);
        const c = chart.Chart.openPath(args[2], null, false) catch {
            std.debug.print("cannot open {s}\n", .{args[2]});
            return;
        };
        defer c.deinit();
        const json = (c.cellsJson() catch null) orelse {
            std.debug.print("no cells\n", .{});
            return;
        };
        defer chart.freeBytes(json);
        var stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(io, json) catch {};
        stdout.writeStreamingAll(io, "\n") catch {};
        return;
    }

    if (std.mem.eql(u8, sub, "catalog")) {
        // Exchange-set catalogue JSON (the tile57_catalog_entries ABI).
        if (args.len < 3) {
            std.debug.print("usage: tile57 catalog <CATALOG.031>\n", .{});
            return;
        }
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
        const entries = engine.s57.parseCatalog(arena, data) orelse {
            std.debug.print("parse error\n", .{});
            return;
        };
        var out = std.ArrayList(u8).empty;
        try out.append(arena, '[');
        for (entries, 0..) |e, i| {
            if (i > 0) try out.appendSlice(arena, ",\n ");
            try out.print(arena, "{{\"file\":\"{s}\",\"longName\":\"{s}\",\"impl\":\"{s}\"", .{ e.path, e.long_name, e.impl });
            if (e.bbox) |b| try out.print(arena, ",\"bbox\":[{d},{d},{d},{d}]", .{ b[0], b[1], b[2], b[3] });
            try out.append(arena, '}');
        }
        try out.appendSlice(arena, "]\n");
        std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
        return;
    }

    if (std.mem.eql(u8, sub, "features")) {
        // GeoJSON feature query (the tile57_chart_features ABI).
        if (args.len < 4) {
            std.debug.print("usage: tile57 features <cell.000 | ENC_ROOT> <ACR[,ACR...]>\n", .{});
            return;
        }
        engine.portray.setQuiet(true);
        const c = chart.Chart.openPath(args[2], null, false) catch {
            std.debug.print("cannot open {s}\n", .{args[2]});
            return;
        };
        defer c.deinit();
        const json = (c.featuresJson(args[3]) catch null) orelse {
            std.debug.print("no matching features\n", .{});
            return;
        };
        defer chart.freeBytes(json);
        var stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(io, json) catch {};
        stdout.writeStreamingAll(io, "\n") catch {};
        return;
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
                {
                    // Decode with the codec matching the archive's tile type — both
                    // return the same DecodedLayer shape, so the dump below is shared.
                    const layers = if (h.tile_type == .mlt)
                        try engine.mlt.decode(arena, tile)
                    else
                        try engine.mvt.decode(arena, tile);
                    std.debug.print("  tile {d}/{d}/{d}: {d} bytes ({s}), {d} layers:\n", .{ z, x, y, tile.len, @tagName(h.tile_type), layers.len });
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

    // Per-zoom size/count stats for a PMTiles archive (verification aid: the
    // scamin-standalone coarse-tile growth measurement). Walks every directory
    // entry (root + leaves) and sums compressed tile bytes per zoom; run-length
    // entries count each addressed tile once at the shared length.
    if (std.mem.eql(u8, sub, "zoomsizes")) {
        if (args.len < 3) {
            std.debug.print("usage: tile57 zoomsizes <file.pmtiles>\n", .{});
            return;
        }
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
        var r = try engine.pmtiles.Reader.init(arena, data);
        defer r.deinit();
        var counts = [_]usize{0} ** 25;
        var sizes = [_]u64{0} ** 25;
        const zoomOf = struct {
            fn f(tid: u64) u8 {
                var acc: u64 = 0;
                var z: u6 = 0;
                while (z < 25) : (z += 1) {
                    const n = @as(u64, 1) << (2 * z);
                    if (tid < acc + n) return @intCast(z);
                    acc += n;
                }
                return 24;
            }
        }.f;
        const Walk = struct {
            fn f(rd: *engine.pmtiles.Reader, a2: std.mem.Allocator, dir: []const engine.pmtiles.Entry, cnt: *[25]usize, sz: *[25]u64) !void {
                for (dir) |e| {
                    if (e.run_length == 0) {
                        const raw0 = rd.bytes[@intCast(rd.header.leaf_dir_offset + e.offset)..][0..e.length];
                        const raw = if (rd.header.internal_compression == .gzip)
                            try engine.gzip.decompress(a2, raw0)
                        else
                            raw0;
                        const leaf = try engine.pmtiles.deserializeDir(a2, raw);
                        try f(rd, a2, leaf, cnt, sz);
                        continue;
                    }
                    var k: u64 = 0;
                    while (k < e.run_length) : (k += 1) {
                        const z = zoomOf(e.tile_id + k);
                        cnt[z] += 1;
                        sz[z] += e.length;
                    }
                }
            }
        };
        try Walk.f(&r, arena, r.root, &counts, &sizes);
        std.debug.print("zoom  tiles      bytes    avg\n", .{});
        for (counts, sizes, 0..) |c, s, z| if (c > 0)
            std.debug.print("z{d:<3} {d:>6} {d:>10} {d:>6}\n", .{ z, c, s, s / c });
        return;
    }

    // Archive-wide fill-down hole audit (district-pack z6–z8 acceptance): a tile
    // that HAS content at z+1 but whose parent at z is EMPTY, inside coverage, is
    // a defect — the low-zoom hole the band-handoff fill-down closes. Enumerates
    // present tiles from the directory (inverse-hilbert), then counts distinct
    // absent parents that have >=1 present child. Per-zoom breakdown + total.
    if (std.mem.eql(u8, sub, "audit-holes")) {
        if (args.len < 3) {
            std.debug.print("usage: tile57 audit-holes <file.pmtiles>\n", .{});
            return;
        }
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
        var r = try engine.pmtiles.Reader.init(arena, data);
        defer r.deinit();
        // Recover (z,x,y) from a hilbert tile id (inverse of pmtiles.zxyToTileId).
        const idToZxy = struct {
            fn f(tid_in: u64) struct { z: u8, x: u32, y: u32 } {
                var acc: u64 = 0;
                var z: u6 = 0;
                while (z < 32) : (z += 1) {
                    const n = @as(u64, 1) << (2 * z);
                    if (tid_in < acc + n) break;
                    acc += n;
                }
                var t = tid_in - acc;
                const side: u64 = @as(u64, 1) << z;
                var x: u64 = 0;
                var y: u64 = 0;
                var s: u64 = 1;
                while (s < side) : (s *= 2) {
                    const rx: u64 = 1 & (t / 2);
                    const ry: u64 = 1 & (t ^ rx);
                    if (ry == 0) {
                        if (rx == 1) {
                            x = s -% 1 -% x;
                            y = s -% 1 -% y;
                        }
                        const tmp = x;
                        x = y;
                        y = tmp;
                    }
                    x += s * rx;
                    y += s * ry;
                    t /= 4;
                }
                return .{ .z = z, .x = @intCast(x), .y = @intCast(y) };
            }
        }.f;
        // Collect every present (z,x,y) key.
        var present = std.AutoHashMap(u64, void).init(arena);
        const key = struct {
            fn f(z: u8, x: u32, y: u32) u64 {
                return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
            }
        }.f;
        const Walk = struct {
            fn f(rd: *engine.pmtiles.Reader, a2: std.mem.Allocator, dir: []const engine.pmtiles.Entry, out: *std.AutoHashMap(u64, void), idfn: anytype, keyfn: anytype) !void {
                for (dir) |e| {
                    if (e.run_length == 0) {
                        const raw0 = rd.bytes[@intCast(rd.header.leaf_dir_offset + e.offset)..][0..e.length];
                        const raw = if (rd.header.internal_compression == .gzip) try engine.gzip.decompress(a2, raw0) else raw0;
                        const leaf = try engine.pmtiles.deserializeDir(a2, raw);
                        try f(rd, a2, leaf, out, idfn, keyfn);
                        continue;
                    }
                    var k: u64 = 0;
                    while (k < e.run_length) : (k += 1) {
                        const zxy = idfn(e.tile_id + k);
                        try out.put(keyfn(zxy.z, zxy.x, zxy.y), {});
                    }
                }
            }
        };
        try Walk.f(&r, arena, r.root, &present, idToZxy, key);
        // For each present tile, test its parent; a distinct absent parent with a
        // present child is one hole. Bucketed by the PARENT zoom.
        var holes = std.AutoHashMap(u64, void).init(arena);
        var per_zoom = [_]usize{0} ** 25;
        var it = present.keyIterator();
        while (it.next()) |kp| {
            const z: u8 = @intCast(kp.* >> 48);
            if (z == 0 or z <= r.header.min_zoom) continue;
            const x: u32 = @intCast((kp.* >> 24) & 0xFFFFFF);
            const y: u32 = @intCast(kp.* & 0xFFFFFF);
            const pk = key(z - 1, x / 2, y / 2);
            if (present.contains(pk)) continue;
            if ((try holes.getOrPut(pk)).found_existing) continue;
            per_zoom[z - 1] += 1;
        }
        if (args.len >= 4 and std.mem.eql(u8, args[3], "-v")) {
            var hit = holes.keyIterator();
            while (hit.next()) |hk| std.debug.print("    hole {d}/{d}/{d}\n", .{ @as(u8, @intCast(hk.* >> 48)), @as(u32, @intCast((hk.* >> 24) & 0xFFFFFF)), @as(u32, @intCast(hk.* & 0xFFFFFF)) });
        }
        std.debug.print("{s}\n  present tiles: {d}  zoom {d}..{d}\n", .{ args[2], present.count(), r.header.min_zoom, r.header.max_zoom });
        std.debug.print("  fill-down holes (absent parent with a present child), by parent zoom:\n", .{});
        var total: usize = 0;
        for (per_zoom, 0..) |c, z| if (c > 0) {
            std.debug.print("    z{d:<2} {d}\n", .{ z, c });
            total += c;
        };
        std.debug.print("  TOTAL holes: {d}\n", .{total});
        return;
    }

    // Archive-wide double-draw audit (scamin-standalone acceptance): walk every
    // tile, decode the point_symbols_scamin layer, and report CROSS-CELL pairs
    // of the same class + same symbol within ~30 m whose visibility windows
    // (smax, scamin] intersect — i.e. two copies of one object that some display
    // scale would render simultaneously. Zero expected after the dedup.
    if (std.mem.eql(u8, sub, "audit-pairs")) {
        if (args.len < 3) {
            std.debug.print("usage: tile57 audit-pairs <file.pmtiles>\n", .{});
            return;
        }
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
        var r = try engine.pmtiles.Reader.init(arena, data);
        defer r.deinit();
        // Collect (z,x,y) for every addressed tile via the directory walk.
        var ids = std.ArrayList(u64).empty;
        const Walk = struct {
            fn f(rd: *engine.pmtiles.Reader, a2: std.mem.Allocator, dir: []const engine.pmtiles.Entry, out: *std.ArrayList(u64)) !void {
                for (dir) |e| {
                    if (e.run_length == 0) {
                        const raw0 = rd.bytes[@intCast(rd.header.leaf_dir_offset + e.offset)..][0..e.length];
                        const raw = if (rd.header.internal_compression == .gzip)
                            try engine.gzip.decompress(a2, raw0)
                        else
                            raw0;
                        const leaf = try engine.pmtiles.deserializeDir(a2, raw);
                        try f(rd, a2, leaf, out);
                        continue;
                    }
                    var k: u64 = 0;
                    while (k < e.run_length) : (k += 1) try out.append(a2, e.tile_id + k);
                }
            }
        };
        try Walk.f(&r, arena, r.root, &ids);
        const Pt = struct { lon: f64, lat: f64, scamin: i64, smax: i64, class: []const u8, sym: []const u8, celln: []const u8 };
        var pairs: usize = 0;
        var tiles_scanned: usize = 0;
        var feats_scanned: usize = 0;
        var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer scratch.deinit();
        for (ids.items) |tid| {
            // tile_id -> z/x/y (invert zxyToTileId: subtract zoom bases, then Hilbert d2xy).
            var acc: u64 = 0;
            var z: u6 = 0;
            while (true) : (z += 1) {
                const n = @as(u64, 1) << (2 * z);
                if (tid < acc + n) break;
                acc += n;
            }
            var t: u64 = tid - acc;
            var x: u64 = 0;
            var y: u64 = 0;
            var sbit: u64 = 1;
            while (sbit < (@as(u64, 1) << @intCast(z))) : (sbit <<= 1) {
                const rx: u64 = 1 & (t / 2);
                const ry: u64 = 1 & (t ^ rx);
                if (ry == 0) {
                    if (rx == 1) {
                        x = sbit - 1 - x;
                        y = sbit - 1 - y;
                    }
                    const tmp = x;
                    x = y;
                    y = tmp;
                }
                x += sbit * rx;
                y += sbit * ry;
                t /= 4;
            }
            _ = scratch.reset(.retain_capacity);
            const a2 = scratch.allocator();
            const bytes = (r.getTile(a2, @intCast(z), @intCast(x), @intCast(y)) catch continue) orelse continue;
            const layers = if (r.header.tile_type == .mlt)
                engine.mlt.decode(a2, bytes) catch continue
            else
                engine.mvt.decode(a2, bytes) catch continue;
            tiles_scanned += 1;
            const tb = engine.tile.tileBoundsLonLat(@intCast(z), @intCast(x), @intCast(y));
            for (layers) |L| {
                if (!std.mem.eql(u8, L.name, "point_symbols_scamin")) continue;
                var pts = std.ArrayList(Pt).empty;
                for (L.features) |feat| {
                    if (feat.parts.len == 0 or feat.parts[0].len == 0) continue;
                    var scamin: i64 = 0;
                    var smax: i64 = 0;
                    var class: []const u8 = "";
                    var sym: []const u8 = "";
                    var celln: []const u8 = "";
                    for (feat.properties) |pr| {
                        if (std.mem.eql(u8, pr.key, "scamin")) scamin = switch (pr.value) {
                            .int => |v| v,
                            .uint => |v| @intCast(v),
                            else => 0,
                        };
                        if (std.mem.eql(u8, pr.key, "smax")) smax = switch (pr.value) {
                            .int => |v| v,
                            .uint => |v| @intCast(v),
                            else => 0,
                        };
                        if (std.mem.eql(u8, pr.key, "class")) class = switch (pr.value) {
                            .string => |v| v,
                            else => "",
                        };
                        if (std.mem.eql(u8, pr.key, "symbol_name")) sym = switch (pr.value) {
                            .string => |v| v,
                            else => "",
                        };
                        if (std.mem.eql(u8, pr.key, "cell")) celln = switch (pr.value) {
                            .string => |v| v,
                            else => "",
                        };
                    }
                    if (sym.len == 0 or class.len == 0) continue;
                    const px = feat.parts[0][0];
                    const fx = @as(f64, @floatFromInt(px.x)) / @as(f64, @floatFromInt(L.extent));
                    const fy = @as(f64, @floatFromInt(px.y)) / @as(f64, @floatFromInt(L.extent));
                    try pts.append(a2, .{
                        .lon = tb[0] + (tb[2] - tb[0]) * fx,
                        .lat = tb[3] - (tb[3] - tb[1]) * fy,
                        .scamin = scamin,
                        .smax = smax,
                        .class = class,
                        .sym = sym,
                        .celln = celln,
                    });
                    feats_scanned += 1;
                }
                for (pts.items, 0..) |pa, i| {
                    for (pts.items[i + 1 ..]) |pb| {
                        if (!std.mem.eql(u8, pa.class, pb.class) or !std.mem.eql(u8, pa.sym, pb.sym)) continue;
                        if (std.mem.eql(u8, pa.celln, pb.celln)) continue; // same-cell co-located aids are legit
                        if (engine.scene.scamin_pts.distM(pa.lon, pa.lat, pb.lon, pb.lat) > 30.0) continue;
                        // Visibility windows (smax, scamin] must intersect for a pair to
                        // ever render simultaneously.
                        const lo = @max(pa.smax, pb.smax);
                        const hi = @min(pa.scamin, pb.scamin);
                        if (hi <= lo) continue;
                        pairs += 1;
                        if (pairs <= 12)
                            std.debug.print("  pair z{d} {s}/{s} @({d:.5},{d:.5}) [{s} sc={d} sm={d}] vs [{s} sc={d} sm={d}]\n", .{ z, pa.class, pa.sym, pa.lon, pa.lat, pa.celln, pa.scamin, pa.smax, pb.celln, pb.scamin, pb.smax });
                    }
                }
            }
        }
        std.debug.print("audit-pairs: {d} tiles, {d} scamin point features, {d} cross-cell simultaneous pairs\n", .{ tiles_scanned, feats_scanned, pairs });
        return;
    }

    // Dump one LIVE tile from an ENC_ROOT (chart.zig lazy path — the same code
    // the host's live cell-backed set serves), decoded like `inspect`, so the
    // live and bake pipelines can be diffed feature-by-feature.
    if (std.mem.eql(u8, sub, "livetile")) {
        if (args.len < 6) {
            std.debug.print("usage: tile57 livetile <ENC_ROOT> <z> <x> <y> [layer]\n", .{});
            return;
        }
        const z = try std.fmt.parseInt(u8, args[3], 10);
        const x = try std.fmt.parseInt(u32, args[4], 10);
        const y = try std.fmt.parseInt(u32, args[5], 10);
        const c = chart.Chart.openPath(args[2], null, true) catch |e| {
            std.debug.print("open failed: {s}\n", .{@errorName(e)});
            return;
        };
        defer c.deinit();
        c.tile_format = .mvt;
        const bytes = (c.tile(z, x, y) catch |e| {
            std.debug.print("tile failed: {s}\n", .{@errorName(e)});
            return;
        }) orelse {
            std.debug.print("tile {d}/{d}/{d}: empty\n", .{ z, x, y });
            return;
        };
        const layers = try engine.mvt.decode(arena, bytes);
        std.debug.print("live tile {d}/{d}/{d}: {d} bytes, {d} layers:\n", .{ z, x, y, bytes.len, layers.len });
        const want: ?[]const u8 = if (args.len >= 7) args[6] else null;
        for (layers) |L| {
            std.debug.print("  {s}: {d} features\n", .{ L.name, L.features.len });
            if (want) |w| if (std.mem.eql(u8, w, L.name)) for (L.features, 0..) |feat, fi| {
                std.debug.print("    [{d}] {s}:", .{ fi, @tagName(feat.geom_type) });
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
            .{ .objl = 42, .name = "DEPARE" },  .{ .objl = 30, .name = "COALNE" },
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
    var format: engine.scene.TileFormat = .mlt; // tile encoding: mlt (default) or mvt

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

// tile57 png|pdf <cell.000 | bundle.pmtiles> <z> <x> <y> -o <out> [flags]  (one tile)
// tile57 png|pdf <source> --view <lon,lat,zoom> --size WxH -o <out> [flags] (a view)
// The render-engine pixel path: parse + portray a cell (or replay a baked
// PMTiles bundle), drive the engine through PixelSurface -> RasterCanvas ->
// PNG, or the same op stream -> PdfCanvas -> a deterministic vector PDF with
// real text objects. A view renders ONE whole scene across every covering
// tile (labels + declutter over the full canvas, no seams).
fn runRender(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8, output: render.pixel.Output) !void {
    if (args.len < 4) {
        std.debug.print("usage: tile57 {s} <cell.000|bundle.pmtiles> <z> <x> <y> -o <out> [--size N] [--palette day|dusk|night] [--rules DIR] [--dq] [--scale F]\n" ++
            "       tile57 {s} <source> --view <lon,lat,zoom> --size WxH -o <out> [flags]\n", .{ @tagName(output), @tagName(output) });
        return;
    }
    const path = args[2];
    const tile_mode = args[3].len > 0 and args[3][0] != '-';
    var z: u8 = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    if (tile_mode) {
        if (args.len < 6) return usageErr("tile mode needs z x y");
        z = std.fmt.parseInt(u8, args[3], 10) catch return usageErr("bad z");
        x = std.fmt.parseInt(u32, args[4], 10) catch return usageErr("bad x");
        y = std.fmt.parseInt(u32, args[5], 10) catch return usageErr("bad y");
    }

    var out_path: ?[]const u8 = null;
    var size_w: u32 = 256;
    var size_h: u32 = 256;
    var palette: render.resolve.PaletteId = .day;
    var rules: ?[]const u8 = null;
    var dq = false;
    var size_scale: f64 = 1.0; // physical-size multiplier (S-52 mm -> true mm)
    var view: ?struct { lon: f64, lat: f64, zoom: f64 } = null;
    // Mariner settings (defaults match the app: other ON for spot soundings).
    var m = render.resolve.MarinerSettings{ .display_other = true };
    var f = Flags{ .args = args, .i = if (tile_mode) 5 else 2 };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = f.next() orelse return usageErr("-o needs a path");
        } else if (std.mem.eql(u8, arg, "--size")) {
            const v = f.next() orelse return usageErr("--size needs a value");
            if (std.mem.indexOfScalar(u8, v, 'x')) |xi| {
                size_w = std.fmt.parseInt(u32, v[0..xi], 10) catch return usageErr("bad --size");
                size_h = std.fmt.parseInt(u32, v[xi + 1 ..], 10) catch return usageErr("bad --size");
            } else {
                size_w = std.fmt.parseInt(u32, v, 10) catch return usageErr("bad --size");
                size_h = size_w;
            }
        } else if (std.mem.eql(u8, arg, "--view")) {
            const v = f.next() orelse return usageErr("--view needs lon,lat,zoom");
            var it = std.mem.splitScalar(u8, v, ',');
            const lon = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lon");
            const lat = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lat");
            const zm = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view zoom");
            view = .{ .lon = lon, .lat = lat, .zoom = zm };
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
        } else if (std.mem.eql(u8, arg, "--safety")) {
            const v = f.next() orelse return usageErr("--safety needs metres");
            m.safety_contour = std.fmt.parseFloat(f64, v) catch return usageErr("bad --safety");
        } else if (std.mem.eql(u8, arg, "--safety-depth")) {
            const v = f.next() orelse return usageErr("--safety-depth needs metres");
            m.safety_depth = std.fmt.parseFloat(f64, v) catch return usageErr("bad --safety-depth");
        } else if (std.mem.eql(u8, arg, "--shallow")) {
            const v = f.next() orelse return usageErr("--shallow needs metres");
            m.shallow_contour = std.fmt.parseFloat(f64, v) catch return usageErr("bad --shallow");
        } else if (std.mem.eql(u8, arg, "--deep")) {
            const v = f.next() orelse return usageErr("--deep needs metres");
            m.deep_contour = std.fmt.parseFloat(f64, v) catch return usageErr("bad --deep");
        } else if (std.mem.eql(u8, arg, "--feet")) {
            m.depth_unit = .feet;
        } else if (std.mem.eql(u8, arg, "--no-names")) {
            m.text_names = false;
        } else if (std.mem.eql(u8, arg, "--no-light-text")) {
            m.show_light_descriptions = false;
        } else if (std.mem.eql(u8, arg, "--no-other-text")) {
            m.text_other = false;
        } else if (std.mem.eql(u8, arg, "--no-other")) {
            m.display_other = false;
        } else if (std.mem.eql(u8, arg, "--plain")) {
            m.boundary_style = .plain;
        } else if (std.mem.eql(u8, arg, "--simplified")) {
            m.simplified_points = true;
        } else if (std.mem.eql(u8, arg, "--full-sectors")) {
            m.show_full_sector_lines = true;
        } else return usageErr("unknown flag");
    }
    const out = out_path orelse return usageErr("-o <out.png> is required");
    if (!tile_mode and view == null) return usageErr("--view lon,lat,zoom is required without z x y");

    // A DIRECTORY source is an ENC_ROOT: open it streaming through the chart
    // layer (band-quilted cell selection per covering view tile) and render.
    const is_dir = blk: {
        var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch break :blk false;
        d.close(io);
        break :blk true;
    };
    if (is_dir) {
        const v = view orelse return usageErr("an ENC_ROOT source needs --view");
        engine.portray.setQuiet(true);
        const c = chart.Chart.openPath(path, rules, false) catch return usageErr("cannot open ENC_ROOT");
        defer c.deinit();
        m.scheme = switch (palette) {
            .day => .day,
            .dusk => .dusk,
            .night => .night,
        };
        m.data_quality = dq;
        m.size_scale = size_scale;
        const bytes = c.renderView(v.lon, v.lat, v.zoom, size_w, size_h, palette, &m, output) catch return usageErr("render failed");
        defer chart.freeBytes(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes });
        std.debug.print("wrote {s}: view {d:.4},{d:.4} z{d:.2}, {d}x{d}px (ENC_ROOT quilt), {d} bytes\n", .{ out, v.lon, v.lat, v.zoom, size_w, size_h, bytes.len });
        return;
    }

    const from_bundle = std.mem.endsWith(u8, path, ".pmtiles");
    if (from_bundle and view == null) return usageErr("a .pmtiles source needs --view");

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var cell: engine.s57.Cell = undefined;
    var streams: []const ?[]const u8 = &.{};
    if (!from_bundle) {
        cell = try engine.s57.parseCell(a, data);
        engine.portray.setQuiet(true);
        // LIVE portrayal context: the mariner's real safety contour / depth /
        // contours / styles evaluate INSIDE the rules — the native win over
        // the tile path's fixed bake context.
        streams = try engine.portray.portrayCellWith(a, &cell, resolveRulesDir(rules), .{
            .safety_contour = m.safety_contour,
            .safety_depth = m.safety_depth,
            .shallow_contour = m.shallow_contour,
            .deep_contour = m.deep_contour,
            .plain_boundaries = m.boundary_style == .plain,
            .simplified_symbols = m.simplified_points,
            .full_light_lines = m.show_full_sector_lines,
        });
    }
    defer if (!from_bundle) cell.deinit();

    var colors = try render.resolve.Colors.init(a, catalog_embed.colorprofile[0].bytes);
    m.data_quality = dq;
    m.size_scale = size_scale;
    const settings = m;

    const zoom: f64 = if (view) |v| v.zoom else @floatFromInt(z);
    var ps = if (view != null) blk: {
        // 512-and-up outputs read as @2x (the CSS baseline is 256/tile).
        const dpr: f32 = if (@min(size_w, size_h) >= 512) 2 else 1;
        const zi = @round(zoom);
        const pt = 256.0 * std.math.pow(f64, 2.0, zoom - zi) * dpr;
        break :blk render.pixel.PixelSurface.initView(a, &colors, palette, &settings, zoom, size_w, size_h, @floatCast(pt), engine.tile.EXTENT);
    } else render.pixel.PixelSurface.init(a, &colors, palette, &settings, zoom, size_w, engine.tile.EXTENT);

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
    ps.output = output;

    // Complex-linestyle table (idempotent; arena-backed — this run only).
    const ls_srcs = try a.alloc(assets.LineStyleSrc, catalog_embed.linestyles.len);
    for (catalog_embed.linestyles, 0..) |e, li| ls_srcs[li] = .{ .id = e.name, .xml = e.bytes };
    engine.scene.registerLinestylesXml(a, ls_srcs);

    const bytes = if (from_bundle) blk: {
        // Bundle-sourced replay: decode each covering baked tile and re-emit
        // it as Surface calls (bake context frozen; live-swappable props —
        // danger depth, sounding composition/unit — re-evaluate here).
        const v = view.?;
        var rd = try engine.pmtiles.Reader.init(a, data);
        defer rd.deinit();
        var vt = engine.scene.ViewTiles.init(v.lon, v.lat, v.zoom, size_w, size_h, ps.px_per_tile);
        const surf = ps.asSurface();
        try surf.beginScene(vt.z);
        const is_mlt = rd.header.tile_type == .mlt;
        while (vt.next()) |t| {
            const tb = (rd.getTile(a, t.z, t.x, t.y) catch continue) orelse continue;
            const layers = if (is_mlt)
                engine.mlt.decode(a, tb) catch continue
            else
                engine.mvt.decode(a, tb) catch continue;
            ps.setOrigin(t.origin_x, t.origin_y);
            try engine.scene.replayTile(surf, layers);
        }
        break :blk try surf.endScene(a);
    } else blk: {
        const cells = [_]engine.scene.CellRef{.{ .cell = &cell, .portrayal = streams }};
        break :blk if (view) |v|
            try engine.scene.generateView(&ps, a, a, &cells, v.lon, v.lat, v.zoom, false)
        else
            try engine.scene.generateTile(ps.asSurface(), a, a, &cells, z, x, y, false);
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes });
    if (view) |v| {
        std.debug.print("wrote {s}: view {d:.4},{d:.4} z{d:.2}, {d}x{d}px, {d} draw ops, {d} bytes\n", .{ out, v.lon, v.lat, v.zoom, size_w, size_h, ps.ops.items.len, bytes.len });
    } else {
        std.debug.print("wrote {s}: tile {d}/{d}/{d}, {d}x{d}px, {d} draw ops, {d} bytes\n", .{ out, z, x, y, size_w, size_h, ps.ops.items.len, bytes.len });
    }
}

// tile57 ascii <cell.000 | ENC_ROOT | bundle.pmtiles> --view <lon,lat,zoom>
//     [--size COLSxROWS (default: terminal size)] [--palette day|dusk|night] [--ansi] [--tui] [--kitty] [--rules DIR]
// The chart on stdout as a Unicode text grid — the render-engine EXAMPLE
// backend (src/render/ascii.zig): the same chart layer + view driver as
// `tile57 png`, with the AsciiSurface at the end instead of the pixel one.
fn runAscii(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 ascii <cell.000|ENC_ROOT|bundle.pmtiles> --view <lon,lat,zoom> [--size COLSxROWS (default: terminal size)] [--palette day|dusk|night] [--ansi] [--tui] [--kitty] [--rules DIR]\n", .{});
        return;
    }
    const path = args[2];
    var cols: u32 = 100;
    var rows: u32 = 36;
    var size_given = false;
    var palette: render.resolve.PaletteId = .day;
    var rules: ?[]const u8 = null;
    var ansi = false;
    var tui = false;
    var kitty = false;
    var view: ?struct { lon: f64, lat: f64, zoom: f64 } = null;
    var f = Flags{ .args = args, .i = 2 };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "--view")) {
            const v = f.next() orelse return usageErr("--view needs lon,lat,zoom");
            var it = std.mem.splitScalar(u8, v, ',');
            const lon = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lon");
            const lat = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lat");
            const zm = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view zoom");
            view = .{ .lon = lon, .lat = lat, .zoom = zm };
        } else if (std.mem.eql(u8, arg, "--size")) {
            const v = f.next() orelse return usageErr("--size needs COLSxROWS");
            const xi = std.mem.indexOfScalar(u8, v, 'x') orelse return usageErr("bad --size");
            cols = std.fmt.parseInt(u32, v[0..xi], 10) catch return usageErr("bad --size");
            rows = std.fmt.parseInt(u32, v[xi + 1 ..], 10) catch return usageErr("bad --size");
            size_given = true;
        } else if (std.mem.eql(u8, arg, "--palette")) {
            const v = f.next() orelse return usageErr("--palette needs a value");
            palette = std.meta.stringToEnum(render.resolve.PaletteId, v) orelse return usageErr("palette must be day|dusk|night");
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.next() orelse return usageErr("--rules needs a dir");
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi = true;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            tui = true;
        } else if (std.mem.eql(u8, arg, "--kitty")) {
            kitty = true;
        } else return usageErr("unknown flag");
    }
    const v = view orelse return usageErr("--view lon,lat,zoom is required");
    // No explicit --size: fit the terminal (minus a prompt line) so the
    // picture never line-wraps; non-TTY output (pipes/files) keeps the fixed
    // default. ANSI mode additionally brackets its output in DECAWM
    // autowrap-off (see AsciiSurface), so even an over-wide grid clips at the
    // right edge instead of wrapping.
    if (!size_given) {
        if (terminalSize(io)) |ts| {
            cols = @max(20, ts[0]);
            rows = @max(10, ts[1] -| 1);
        }
    }
    if (cols == 0 or rows == 0) return usageErr("--size must be positive");

    engine.portray.setQuiet(true);
    const c = if (std.mem.endsWith(u8, path, ".pmtiles")) blk: {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        break :blk chart.Chart.openBytes(data, .pmtiles, rules) catch return usageErr("cannot open bundle");
    } else chart.Chart.openPath(path, rules, false) catch return usageErr("cannot open source");
    defer c.deinit();

    var m = render.resolve.MarinerSettings{ .display_other = true };
    m.scheme = switch (palette) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
    if (tui) return runAsciiTui(io, a, c, v.lon, v.lat, v.zoom, palette, &m, ansi, kitty);

    if (kitty) {
        // Real S-52 pixels inline via the kitty graphics protocol (Ghostty,
        // Kitty, WezTerm, Konsole): the grid's cell count times the
        // terminal's cell-pixel size (or the 10x20 guess off-TTY).
        const cp = cellPx(terminalSize(io));
        const png_bytes = c.renderView(v.lon, v.lat, v.zoom, cols * cp[0], rows * cp[1], palette, &m, .png) catch return usageErr("render failed");
        defer chart.freeBytes(png_bytes);
        const seq = render.kitty.encodePng(a, png_bytes) catch return usageErr("encode failed");
        std.Io.File.stdout().writeStreamingAll(io, seq) catch {};
        std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
        return;
    }

    const text = c.renderAscii(v.lon, v.lat, v.zoom, cols, rows, palette, &m, ansi) catch return usageErr("render failed");
    defer chart.freeBytes(text);
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

// `tile57 ascii --tui`: an interactive pan/zoom loop around the ascii surface.
// Arrow keys pan by an eighth of the view, +/- zoom by half a level, q (or
// ctrl-c) quits. cbreak-style input (no echo/canonical, OPOST kept so \n still
// carriage-returns), alternate screen + hidden cursor, terminal re-measured
// every frame so a resize just repaints.
fn runAsciiTui(io: std.Io, a: std.mem.Allocator, c: *chart.Chart, lon0: f64, lat0: f64, zoom0: f64, palette: render.resolve.PaletteId, m: *render.resolve.MarinerSettings, ansi: bool, kitty: bool) !void {
    const stdout = std.Io.File.stdout();
    const stdin_fd = std.Io.File.stdin().handle;
    const old = std.posix.tcgetattr(stdin_fd) catch return usageErr("--tui needs a terminal");
    var raw = old;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false; // ctrl-c arrives as 0x03 → clean quit through the defers
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(stdin_fd, .NOW, raw) catch return usageErr("--tui needs a terminal");
    defer std.posix.tcsetattr(stdin_fd, .NOW, old) catch {};
    stdout.writeStreamingAll(io, "\x1b[?1049h\x1b[?25l") catch {}; // alt screen, hide cursor
    defer stdout.writeStreamingAll(io, "\x1b[?25h\x1b[?1049l") catch {};

    var lon = lon0;
    var lat = lat0;
    var zoom = zoom0;
    var last: [2]u32 = .{ 0, 0 };
    // kitty pan cache: per zoom step, a 3x-viewport region image lives in the
    // terminal's store; panning inside it is a ~40-byte placement escape.
    // Slots are keyed by round(zoom*2) and evicted round-robin.
    const Region = struct { zkey: i32 = std.math.minInt(i32), id: u32 = 0, tl_x: f64 = 0, tl_y: f64 = 0, w: u32 = 0, h: u32 = 0 };
    var regions: [3]Region = .{ .{}, .{}, .{} };
    var evict: usize = 0;
    while (true) {
        const ts_raw = terminalSize(io);
        const ts = ts_raw orelse .{ 100, 37, 0, 0 };
        const cols = @max(20, ts[0]);
        const rows = @max(10, ts[1]) - 1; // chart rows; the last line is the status bar
        if (cols != last[0] or rows != last[1]) {
            stdout.writeStreamingAll(io, "\x1b[2J") catch {};
            last = .{ cols, rows };
        }
        // Frame: kitty mode paints the REAL S-52 pixel portrayal (PNG through
        // the kitty graphics protocol) sized to the chart rows' pixel extent;
        // ascii mode paints the text grid.
        const cp = cellPx(ts_raw);
        const view_w: u32 = if (kitty) cols * cp[0] else cols;
        const view_h: u32 = if (kitty) rows * cp[1] else rows * 2; // ascii cell = 1x2 px
        if (kitty) {
            // World-pixel geometry at this zoom (256*2^zoom px globe).
            const world_px = 256.0 * std.math.pow(f64, 2.0, zoom);
            const vc = worldPxOf(lon, lat, world_px);
            const zkey: i32 = @intFromFloat(@round(zoom * 2.0));
            var reg: ?*@TypeOf(regions[0]) = null;
            for (&regions) |*r| if (r.zkey == zkey) {
                reg = r;
            };
            // A cached region only survives if the whole viewport still fits.
            var off_x: f64 = 0;
            var off_y: f64 = 0;
            if (reg) |r| {
                if (r.w < view_w or r.h < view_h) {
                    reg = null; // terminal grew past the cached region
                } else {
                    off_x = vc[0] - @as(f64, @floatFromInt(view_w)) / 2.0 - r.tl_x;
                    off_y = vc[1] - @as(f64, @floatFromInt(view_h)) / 2.0 - r.tl_y;
                    if (off_x < 0 or off_y < 0 or
                        off_x > @as(f64, @floatFromInt(r.w - view_w)) or
                        off_y > @as(f64, @floatFromInt(r.h - view_h))) reg = null;
                }
            }
            if (reg == null) {
                // (Re)render a 3x-viewport region centred here and transmit it
                // into an evicted slot. The render is the slow step (~a few
                // seconds); everything until the region's edge is then free.
                // Loader note on the status line — the region render blocks
                // for a few seconds and this is the only sign of life.
                const note = std.fmt.allocPrint(a, "\x1b[{d};1H\x1b[7m rendering\xe2\x80\xa6 \x1b[0m\x1b[K", .{rows + 1}) catch break;
                stdout.writeStreamingAll(io, note) catch {};
                a.free(note);
                const r = &regions[evict];
                evict = (evict + 1) % regions.len;
                r.zkey = zkey;
                if (r.id == 0) r.id = @intCast(100 + evict);
                r.w = view_w * 3;
                r.h = view_h * 3;
                r.tl_x = vc[0] - @as(f64, @floatFromInt(r.w)) / 2.0;
                r.tl_y = vc[1] - @as(f64, @floatFromInt(r.h)) / 2.0;
                const png_bytes = c.renderView(lon, lat, zoom, r.w, r.h, palette, m, .png) catch break;
                const seq = render.kitty.transmitPng(a, png_bytes, r.id) catch break;
                chart.freeBytes(png_bytes);
                stdout.writeStreamingAll(io, seq) catch {};
                a.free(seq);
                reg = r;
                off_x = vc[0] - @as(f64, @floatFromInt(view_w)) / 2.0 - r.tl_x;
                off_y = vc[1] - @as(f64, @floatFromInt(view_h)) / 2.0 - r.tl_y;
            }
            const pl = render.kitty.place(a, reg.?.id, @intFromFloat(@max(0, off_x)), @intFromFloat(@max(0, off_y)), view_w, view_h) catch break;
            stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
            stdout.writeStreamingAll(io, "\x1b[H") catch {};
            stdout.writeStreamingAll(io, pl) catch {};
            a.free(pl);
        } else {
            const text = c.renderAscii(lon, lat, zoom, cols, rows, palette, m, ansi) catch break;
            stdout.writeStreamingAll(io, "\x1b[H") catch {};
            stdout.writeStreamingAll(io, text) catch {};
            chart.freeBytes(text);
        }
        const status = std.fmt.allocPrint(a, "\x1b[{d};1H\x1b[7m \xe2\x86\x90\xe2\x86\x91\xe2\x86\x93\xe2\x86\x92 pan  +/- zoom  q quit  {d:.4},{d:.4} z{d:.2} \x1b[0m\x1b[K", .{ rows + 1, lat, lon, zoom }) catch break;
        stdout.writeStreamingAll(io, status) catch {};

        // Drain a whole read of input before re-rendering: key-repeat (a held
        // arrow) coalesces several ESC [ A/B/C/D sequences into one read, so
        // parse the buffer as a stream and apply every key — one repaint per
        // batch keeps a held arrow smooth instead of frames-behind.
        var b: [64]u8 = undefined;
        const n = std.posix.read(stdin_fd, &b) catch break;
        if (n == 0) break;
        // Pan steps: an eighth of the view span, in the frame's own pixels
        // (ascii cell = 1x2 px; sixel = real pixels) on a 256*2^zoom px world.
        const world = 256.0 * std.math.pow(f64, 2.0, zoom);
        const dlon = @as(f64, @floatFromInt(view_w)) / 8.0 * 360.0 / world;
        const dy_px = @as(f64, @floatFromInt(view_h)) / 8.0;
        var i: usize = 0;
        while (i < n) {
            if (b[i] == 0x1b and i + 2 < n and b[i + 1] == '[') {
                switch (b[i + 2]) {
                    'A' => lat = mercShift(lat, dy_px, world),
                    'B' => lat = mercShift(lat, -dy_px, world),
                    'C' => lon = @min(180, lon + dlon),
                    'D' => lon = @max(-180, lon - dlon),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b[i]) {
                '+', '=' => zoom = @min(18.0, zoom + 0.5),
                '-', '_' => zoom = @max(3.0, zoom - 0.5),
                'q', 'Q', 0x03 => return,
                else => {},
            }
            i += 1;
        }
    }
}

// ===========================================================================
// `tile57 explore` — the S-57 + S-101 learning / debug tool.
//
// For every feature of a cell it surfaces THREE data levels the engine already
// computes (it invents nothing):
//   1. Raw S-57       — object-class acronym + the acronym→value attribute map
//                       + geometry primitive (s57.Cell + catalogue).
//   2. S-101 portrayal — the ';'-separated Key:Value instruction stream the Lua
//                       rules emit (portray.portrayCell), RAW and PARSED into
//                       symbols / lines / fills / texts / aug figures
//                       (s101_instr.parse).
//   3. Resolved calls — what the portrayal BECOMES after geometry resolution:
//                       the Surface vtable calls, captured by the recording
//                       InspectSurface (render/inspect.zig) driven through
//                       scene.appendTile, matched back to each feature by its
//                       S-57 attribute fingerprint (FeatureMeta.s57_json).
// ===========================================================================

const ExAttr = struct { acr: []const u8, code: u16, value: []const u8 };

const ExLevel3 = struct {
    calls: []const render.inspect.Call,
    z: u8,
    x: u32,
    y: u32,
    matched: bool, // this feature was found in the sampled tile (else out of view)
};

// Where to point renderView for a feature's `--kitty` thumbnail: the anchor
// lon/lat + a per-feature zoom (a point sits at its node and renders at the
// cell's native band zoom; a line/area is centred on its bbox at a zoom that
// frames it). `framed` distinguishes the two for the caption. `frac`/`band_max`
// let the TUI RE-FRAME for its much larger dynamic canvas (the console keeps the
// THUMB_PX-square `zoom`): `frac` is the bbox's larger normalized-globe span
// (world=1.0), `band_max` the cell's native band-max zoom. `frac <= 0` = point /
// degenerate bbox — render at `band_max`.
const ExThumb = struct { lon: f64, lat: f64, zoom: f64, framed: bool, frac: f64 = 0, band_max: f64 = 0 };

// The TUI kitty thumbnail's cross-frame state. `seq` is the cached a=T
// (transmit-AND-display) kitty sequence for the currently-rendered feature,
// re-emitted every frame (after the text) so the text redraw can't leave it
// stale; `sel` is the feature index it was built for; `w`/`h` are the pixel size
// it was rendered at (a terminal resize changes the target size, so the cache is
// invalidated when they differ). `arena` owns `seq` and is reset when the
// selection changes — the render (the slow step) runs once per selection,
// matching the old transmit-once model.
const ThumbState = struct {
    sel: ?usize = null,
    seq: ?[]const u8 = null,
    w: u32 = 0,
    h: u32 = 0,
    arena: *std.heap.ArenaAllocator,
};

// Console thumbnail crop size (device px). Small on purpose — a glanceable proof
// of what the portrayal actually draws, inline beside the text dump. The TUI sizes
// its own thumbnail dynamically (fills the detail pane); THUMB_PX is the baseline
// the TUI scales symbols against so a fixed-device-px point mark still reads big.
const THUMB_PX: u32 = 200;

// Background colour token the isolated feature thumbnail clears to: DEPMS, the
// S-52 light shallow-water shade — a solid "mini scene" sea the single feature's
// black/coloured marks read clearly against.
const THUMB_BG: []const u8 = "DEPMS";

const ExRow = struct {
    cell_name: []const u8,
    cell_id: usize = 0, // index into the source cell list (TUI lazy re-load); 0 for streaming
    index: usize, // feature index within its cell
    rcid: u32,
    foid: u64,
    prim: u8,
    objl: u16,
    class: []const u8, // S-57 acronym ("LIGHTS") or "?<objl>"
    s101: []const u8, // S-101 feature-class name ("Light") or ""
    attrs: []const ExAttr,
    raw: ?[]const u8, // level 2: raw instruction stream
    parsed: ?engine.s101_instr.Portrayal, // level 2: parsed
    resolved: ?ExLevel3, // level 3
    thumb: ?ExThumb, // --kitty: where to render this feature's thumbnail (null = no geometry)
};

// One source cell in an explore run: the path (relative to the run's `dir`) to
// re-read + re-parse on demand. The TUI holds one of these per cell so it can
// lazily rebuild a selected feature's level-3 + thumbnail without keeping every
// cell's heavy recorded-render pass resident.
const ExCellSrc = struct { base_rel: []const u8 };

// The TUI's per-feature INDEX entry: just enough to navigate + show levels 1+2.
// It deliberately does NOT keep the structured attrs/raw/parsed portrayal or the
// full portrayal stream (those are formatted into `det12` once and dropped), nor
// any level-3 calls — level 3 + the kitty thumbnail are rebuilt lazily from the
// re-parsed cell on selection. `index` is the feature's position within its cell,
// `cell_id` indexes the cell source list.
const ExIndexRow = struct {
    class: []const u8, // filter key (S-57 acronym or "?<objl>")
    label: []const u8, // left-pane list label
    det12: []const []const u8, // pre-formatted levels 1+2 detail lines
    cell_id: usize,
    index: usize,
    prim: u8, // S-57 primitive (1 point / 2 line / 3 area) — geometry glyph in the tree
    objl: u16, // object-class code — the group header's S-101 human name
};

const ExFilters = struct {
    classes: ?[]const u8 = null, // comma-separated acronym allow-list
    obj: ?u64 = null, // match feature index OR rcid OR foid
    zoom: ?f64 = null, // override the auto fit-zoom for the resolving pass
    do_resolve: bool = true,
    kitty: bool = false, // compute each row's per-feature thumbnail view (--kitty)
};

fn exPrimName(p: u8) []const u8 {
    return switch (p) {
        1 => "point",
        2 => "line",
        3 => "area",
        255 => "none",
        else => "?",
    };
}

fn exCatName(c: i64) []const u8 {
    return switch (c) {
        0 => "base",
        1 => "standard",
        2 => "other",
        else => "?",
    };
}

// The largest zoom (<= `cap`) at which the whole cell bbox falls inside a SINGLE
// web-mercator tile — so one appendTile pass records every feature, and at the
// finest such zoom the cell nearly fills the 4096-unit tile (geometry stays crisp
// rather than collapsing). bounds = [west, south, east, north].
fn exFitTile(bounds: [4]f64, cap: u8) ExLevel3 {
    const nw = engine.tile.lonLatToWorld(bounds[0], bounds[3]); // (min x, min y: y grows south)
    const se = engine.tile.lonLatToWorld(bounds[2], bounds[1]); // (max x, max y)
    var z: u8 = cap;
    while (true) : (z -= 1) {
        const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
        const x0: i64 = @intFromFloat(@floor(nw[0] * n));
        const x1: i64 = @intFromFloat(@floor(se[0] * n));
        const y0: i64 = @intFromFloat(@floor(nw[1] * n));
        const y1: i64 = @intFromFloat(@floor(se[1] * n));
        if ((x0 == x1 and y0 == y1) or z == 0)
            return .{ .calls = &.{}, .z = z, .x = @intCast(@max(0, x0)), .y = @intCast(@max(0, y0)), .matched = false };
    }
}

// The tile containing the cell centre at an explicit zoom (--zoom override).
fn exTileAt(bounds: [4]f64, zoom: f64) ExLevel3 {
    const z: u8 = @intFromFloat(std.math.clamp(@round(zoom), 0, 22));
    const c = engine.tile.lonLatToWorld((bounds[0] + bounds[2]) / 2.0, (bounds[1] + bounds[3]) / 2.0);
    const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    return .{ .calls = &.{}, .z = z, .x = @intFromFloat(@floor(c[0] * n)), .y = @intFromFloat(@floor(c[1] * n)), .matched = false };
}

// Pick the renderView point + zoom for a feature's `--kitty` thumbnail. A POINT
// feature sits at its node, rendered at the cell's native band zoom (the finest
// zoom the cell is compiled for, so SCAMIN never gates the symbol out). A LINE or
// AREA is centred on its geometry bbox at the zoom that frames the larger span to
// ~80% of the crop. Returns null when the feature has no resolvable geometry.
fn exThumbView(a: std.mem.Allocator, cell: *engine.s57.Cell, f: engine.s57.Feature) ?ExThumb {
    const band = engine.bake_enc.bandOf(cell.params.cscl);
    const zr = engine.bake_enc.bandZooms(band);
    const band_max: f64 = @floatFromInt(zr.max);
    if (f.prim == 1) {
        const p = cell.pointGeometry(f) orelse return null;
        return .{ .lon = p.lon(), .lat = p.lat(), .zoom = band_max, .framed = false, .frac = 0, .band_max = band_max };
    }
    // Line/area: bbox of the assembled geometry parts.
    const parts = cell.geometryParts(a, f) catch return null;
    var min_lon: f64 = 1e9;
    var min_lat: f64 = 1e9;
    var max_lon: f64 = -1e9;
    var max_lat: f64 = -1e9;
    var any = false;
    for (parts) |part| for (part) |pt| {
        any = true;
        min_lon = @min(min_lon, pt.lon());
        min_lat = @min(min_lat, pt.lat());
        max_lon = @max(max_lon, pt.lon());
        max_lat = @max(max_lat, pt.lat());
    };
    if (!any) return null;
    const clon = (min_lon + max_lon) / 2.0;
    const clat = (min_lat + max_lat) / 2.0;
    // Frame the bbox: the larger normalized-globe span * 256*2^z should fill ~80%
    // of the crop. Fall back to the band zoom for a degenerate (zero-span) bbox.
    const nw = worldPxOf(min_lon, max_lat, 1.0);
    const se = worldPxOf(max_lon, min_lat, 1.0);
    const frac = @max(@abs(se[0] - nw[0]), @abs(se[1] - nw[1]));
    var zoom: f64 = band_max;
    if (frac > 1e-12) {
        const target = @as(f64, @floatFromInt(THUMB_PX)) * 0.8;
        zoom = std.math.clamp(std.math.log2(target / (256.0 * frac)), 2.0, 19.0);
    }
    return .{ .lon = clon, .lat = clat, .zoom = zoom, .framed = true, .frac = frac, .band_max = band_max };
}

// The framing zoom that fills ~`fill` of a `target_px`-min-dimension canvas with
// this feature's geometry. A POINT (or a degenerate bbox) renders at the cell's
// native band-max zoom. Used by the TUI to reframe for its larger dynamic canvas
// (the console keeps the fixed THUMB_PX-square `ExThumb.zoom`). The upper zoom
// clamp is deliberately high (24, past any real band) so a tiny line/area still
// scales up to fill the big canvas instead of sitting as a speck on empty sea.
fn exThumbZoom(t: ExThumb, target_px: f64, fill: f64) f64 {
    if (!t.framed or t.frac <= 1e-12) return t.band_max;
    const target = target_px * fill;
    return std.math.clamp(std.math.log2(target / (256.0 * t.frac)), 2.0, 24.0);
}

fn exClassMatches(list: []const u8, acr: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |w| {
        const t = std.mem.trim(u8, w, " ");
        if (t.len > 0 and std.ascii.eqlIgnoreCase(t, acr)) return true;
    }
    return false;
}

// Feature fingerprint = class + NUL + acronym→value blob. The SAME key the
// recording surface sees (FeatureMeta.class / .s57_json), so a recorded draw pass
// matches its source feature. Allocated into `a`.
fn exKey(a: std.mem.Allocator, class: []const u8, s57_json: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ class, s57_json }) catch class;
}

const ExQueue = struct { idxs: std.ArrayList(usize) = .empty, head: usize = 0 };

// The whole-cell recording pass, indexed for per-feature level-3 lookup. Built
// once per cell by exSetupResolve; the queue heads advance as kept features are
// folded IN FEATURE ORDER (exFoldResolved), so the same cell must be folded in a
// single ascending sweep (exProcessCell / exStreamCell / the TUI cell cache all do).
const ExResolveCtx = struct {
    recorded: []const render.inspect.RecordedFeature,
    qmap: std.StringHashMap(ExQueue),
    view: ExLevel3, // z/x/y of the sampled tile (calls empty; per-feature calls fold in)
};

// Drive the recording surface once over the whole cell and index the recorded
// passes by feature fingerprint. Returns null when resolving is disabled or the
// cell has no bounds (level 3 unavailable). Everything is allocated into `a`
// (the recorded `Call` lists carry the geometry — the memory-heavy part — so `a`
// should be a per-cell arena that is reset before the next cell).
fn exSetupResolve(a: std.mem.Allocator, cell: *engine.s57.Cell, portrayal: ?[]const ?[]const u8, F: ExFilters) ?ExResolveCtx {
    if (!F.do_resolve) return null;
    const b = cell.bounds() orelse return null;
    const v = if (F.zoom) |zz| exTileAt(b, zz) else exFitTile(b, 19);
    var is = render.inspect.InspectSurface.init(a);
    const surf = is.asSurface();
    surf.beginScene(v.z) catch {};
    const one = [_]engine.scene.CellRef{.{ .cell = cell, .portrayal = portrayal }};
    engine.scene.appendTile(surf, a, &one, v.z, v.x, v.y, true) catch {};
    _ = surf.endScene(a) catch {};
    var qmap = std.StringHashMap(ExQueue).init(a);
    const recorded = is.features.items;
    for (recorded, 0..) |rf, ri| {
        const key = exKey(a, rf.meta.class, rf.meta.s57_json);
        const gop = qmap.getOrPut(key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.idxs.append(a, ri) catch {};
    }
    return .{ .recorded = recorded, .qmap = qmap, .view = v };
}

// Level 3 for one feature: fold its consecutive recorded passes (boundary/point
// variant passes + constructed sector figures are emitted adjacently) into one
// call list, CONSUMING the fingerprint queue. Must be called in feature order for
// the cell's kept features. Caveat: two neighbouring features that share a class
// AND identical attributes (mostly attribute-less areas like LNDARE) can merge —
// attributed features (the tool's focus) are distinct, so this is exact for them.
fn exFoldResolved(a: std.mem.Allocator, f: engine.s57.Feature, class: ?[]const u8, ctx: *ExResolveCtx) !ExLevel3 {
    var matched = false;
    var call_items: []const render.inspect.Call = &.{};
    if (class) |cls| {
        const s57_json = engine.scene.encodeS57Attrs(a, f) catch "";
        const key = exKey(a, cls, s57_json);
        if (ctx.qmap.getPtr(key)) |q| if (q.head < q.idxs.items.len) {
            var calls = std.ArrayList(render.inspect.Call).empty;
            var idx = q.idxs.items[q.head];
            q.head += 1;
            try calls.appendSlice(a, ctx.recorded[idx].calls.items);
            while (q.head < q.idxs.items.len and q.idxs.items[q.head] == idx + 1) {
                idx = q.idxs.items[q.head];
                q.head += 1;
                try calls.appendSlice(a, ctx.recorded[idx].calls.items);
            }
            matched = true;
            call_items = calls.items;
        };
    }
    return .{ .calls = call_items, .z = ctx.view.z, .x = ctx.view.x, .y = ctx.view.y, .matched = matched };
}

// Whether a feature passes the class/object filters (the shared gate used by the
// count pre-pass, the streaming emit and the TUI index/cache — kept identical so
// output byte-for-byte matches across paths).
fn exPasses(F: ExFilters, class: ?[]const u8, f: engine.s57.Feature, fi: usize) bool {
    if (F.classes) |cl| {
        if (class == null or !exClassMatches(cl, class.?)) return false;
    }
    if (F.obj) |want| {
        if (fi != want and f.rcid != want and f.foid != want) return false;
    }
    return true;
}

// Build one feature's ExRow (all three levels) into `a`. Strings are duped into
// `a`, so the cell may be freed afterwards. `ctx` (when non-null) is consumed in
// feature order — the caller must invoke this for kept features in ascending index
// order. Assumes the feature already passed the filters (exPasses).
fn exBuildRow(a: std.mem.Allocator, cell: *engine.s57.Cell, cell_name: []const u8, cell_id: usize, fi: usize, f: engine.s57.Feature, class: ?[]const u8, portrayal: ?[]const ?[]const u8, ctx: ?*ExResolveCtx, F: ExFilters) !ExRow {
    var attrs = std.ArrayList(ExAttr).empty;
    for (f.attrs) |at| {
        const acr = engine.catalogue.attrAcronym(at.code) orelse
            std.fmt.allocPrint(a, "?{d}", .{at.code}) catch "?";
        try attrs.append(a, .{ .acr = acr, .code = at.code, .value = try a.dupe(u8, std.mem.trim(u8, at.value, " ")) });
    }

    const raw: ?[]const u8 = if (portrayal) |p| (if (fi < p.len) p[fi] else null) else null;
    const parsed: ?engine.s101_instr.Portrayal = if (raw) |s| (engine.s101_instr.parse(a, s) catch null) else null;

    const resolved: ?ExLevel3 = if (ctx) |c| try exFoldResolved(a, f, class, c) else null;
    const thumb: ?ExThumb = if (F.kitty) exThumbView(a, cell, f) else null;

    return .{
        .cell_name = cell_name,
        .cell_id = cell_id,
        .index = fi,
        .rcid = f.rcid,
        .foid = f.foid,
        .prim = f.prim,
        .objl = f.objl,
        .class = class orelse (std.fmt.allocPrint(a, "?{d}", .{f.objl}) catch "?"),
        .s101 = engine.catalogue.resolveFeatureByObjl(f.objl) orelse "",
        .attrs = attrs.items,
        .raw = raw,
        .parsed = parsed,
        .resolved = resolved,
        .thumb = thumb,
    };
}

// Collect one parsed cell's features into `rows` (levels 1+2 always; level 3 when
// do_resolve and the cell has bounds). Strings a Row keeps are duped into `a`, so
// the caller may deinit the cell afterwards. Used to build the TUI's lightweight
// feature index (with F.do_resolve = false, F.kitty = false — level 3 + thumbs are
// computed lazily on selection); console/JSON stream per feature via exStreamCell.
fn exProcessCell(a: std.mem.Allocator, cell: *engine.s57.Cell, name: []const u8, rules: []const u8, F: ExFilters, cell_id: usize, rows: *std.ArrayList(ExRow)) !void {
    const portrayal: ?[]const ?[]const u8 = engine.portray.portrayCell(a, cell, rules) catch null;
    var ctx_storage = exSetupResolve(a, cell, portrayal, F);
    const ctx: ?*ExResolveCtx = if (ctx_storage) |*c| c else null;
    const cell_name = try a.dupe(u8, if (name.len > 0) name else cell.name);

    for (cell.features, 0..) |f, fi| {
        const class = engine.catalogue.acronymByObjl(f.objl);
        if (!exPasses(F, class, f, fi)) continue;
        const row = try exBuildRow(a, cell, cell_name, cell_id, fi, f, class, portrayal, ctx, F);
        try rows.append(a, row);
    }
}

// A short list label for a feature: its name (OBJNAM) if any, else a FOID/index.
fn exLabel(a: std.mem.Allocator, row: ExRow) []const u8 {
    for (row.attrs) |at| {
        if (std.mem.eql(u8, at.acr, "OBJNAM") and at.value.len > 0)
            return std.fmt.allocPrint(a, "{s} {s}", .{ row.class, at.value }) catch row.class;
    }
    if (row.foid != 0)
        return std.fmt.allocPrint(a, "{s} foid:{x}", .{ row.class, row.foid }) catch row.class;
    return std.fmt.allocPrint(a, "{s} #{d}", .{ row.class, row.index }) catch row.class;
}

// Format one recorded Surface call in S-52 shorthand (SY/LS/AC/AP/TX + args).
fn exAppendCall(a: std.mem.Allocator, out: *std.ArrayList(u8), call: render.inspect.Call) !void {
    switch (call) {
        .fill_area => |c| {
            try out.print(a, "    fillArea AC({s})  rings={d} verts={d}", .{ c.token, c.rings, c.verts });
            if (c.depth) |d| try out.print(a, "  depth={d}..{d}m", .{ d.d1, d.d2 });
            try out.append(a, '\n');
        },
        .fill_pattern => |c| try out.print(a, "    fillPattern AP({s})  rings={d} verts={d}\n", .{ c.name, c.rings, c.verts }),
        .stroke_line => |c| {
            try out.print(a, "    strokeLine LS({s},{d:.2},{s})  segs={d} verts={d}", .{ c.token, c.width_px, @tagName(c.dash), c.lines, c.verts });
            if (c.valdco) |v| try out.print(a, "  valdco={d}", .{v});
            try out.append(a, '\n');
        },
        .draw_symbol => |c| {
            try out.print(a, "    drawSymbol SY({s}) @({d},{d}) rot={d:.0}{s} scale={d:.2} {s}", .{ c.name, c.at.x, c.at.y, c.rot_deg, if (c.rot_north) "N" else "", c.scale, @tagName(c.placement) });
            if (c.danger_depth) |d| try out.print(a, " danger={d}m", .{d});
            try out.append(a, '\n');
        },
        .draw_sounding => |c| {
            try out.print(a, "    drawSounding {d}m", .{c.depth_m});
            if (c.swept) try out.appendSlice(a, " swept");
            if (c.low_acc) try out.appendSlice(a, " lowAcc");
            try out.print(a, " @({d},{d})\n", .{ c.at.x, c.at.y });
        },
        .draw_text => |c| try out.print(a, "    drawText TX(\"{s}\") {s} size={d:.0} {s}/{s} @({d},{d})\n", .{ c.text, c.color, c.font_size, c.halign, c.valign, c.at.x, c.at.y }),
    }
}

// The per-feature detail is emitted in two parts so the TUI can keep only levels
// 1+2 resident and format level 3 lazily on selection; the console streamer calls
// both back-to-back for the classic full dump.

// Levels 1+2 (header + S-57 attributes + S-101 portrayal) — cheap, and the only
// part the TUI keeps resident per feature. Level 3 (exFormatLevel3) is appended
// lazily on selection.
fn exFormatDetail12(a: std.mem.Allocator, out: *std.ArrayList(u8), row: ExRow) !void {
    try out.print(a, "[{s} #{d}] {s}", .{ row.cell_name, row.index, row.class });
    if (row.s101.len > 0) try out.print(a, " ({s})", .{row.s101});
    try out.print(a, "  prim={s} objl={d} rcid={d}", .{ exPrimName(row.prim), row.objl, row.rcid });
    if (row.foid != 0) try out.print(a, " foid={x}", .{row.foid});
    try out.append(a, '\n');

    // Level 1 — raw S-57 attributes.
    try out.appendSlice(a, "  1. S-57 attributes:\n");
    if (row.attrs.len == 0) {
        try out.appendSlice(a, "     (none)\n");
    } else for (row.attrs) |at| {
        try out.print(a, "     {s} = {s}\n", .{ at.acr, at.value });
    }

    // Level 2 — S-101 portrayal instruction stream (raw + parsed).
    try out.appendSlice(a, "  2. S-101 portrayal instructions:\n");
    if (row.raw) |raw| {
        try out.print(a, "     raw: {s}\n", .{raw});
    } else {
        try out.appendSlice(a, "     raw: (class unmapped, or emitted nothing)\n");
    }
    if (row.parsed) |p| {
        try out.print(a, "     parsed: prio={d} cat={s} vg={d}", .{ p.draw_prio, exCatName(p.cat), p.vg });
        if (p.date_start.len > 0 or p.date_end.len > 0) try out.print(a, " date=[{s}..{s}]", .{ p.date_start, p.date_end });
        try out.append(a, '\n');
        if (p.fill_token) |t| try out.print(a, "       fill:   AC({s})\n", .{t});
        for (p.patterns) |pat| try out.print(a, "       pattern: AP({s})\n", .{pat});
        for (p.lines) |ln| try out.print(a, "       line:   LS({s}, w={d:.2}, {s})\n", .{ ln.style, ln.width, ln.color });
        for (p.points) |pt| try out.print(a, "       symbol: SY({s}) rot={d:.0}{s} off={d:.2},{d:.2}\n", .{ pt.symbol, pt.rotation, if (pt.rot_north) "N" else "", pt.offset_x, pt.offset_y });
        for (p.texts) |tx| try out.print(a, "       text:   TX(\"{s}\") {s} size={d:.0} {s}/{s} grp={d}\n", .{ tx.text, tx.color, tx.font_size, tx.halign, tx.valign, tx.group });
        if (p.aug_figures.len > 0) {
            var rays: usize = 0;
            var arcs: usize = 0;
            for (p.aug_figures) |fig| if (fig.is_ray) {
                rays += 1;
            } else {
                arcs += 1;
            };
            try out.print(a, "       augmented: {d} ray(s), {d} arc(s) (light sector figure)\n", .{ rays, arcs });
        }
    }
}

// Level 3 — resolved Surface calls (from an already-folded ExLevel3, or null when
// resolving is disabled / the cell has no bounds).
fn exFormatLevel3(a: std.mem.Allocator, out: *std.ArrayList(u8), resolved: ?ExLevel3) !void {
    try out.appendSlice(a, "  3. Resolved Surface calls:\n");
    if (resolved) |lo| {
        if (!lo.matched) {
            try out.print(a, "     (not in the sampled tile z{d} {d}/{d}/{d}; use --zoom to sample a tile it covers)\n", .{ lo.z, lo.z, lo.x, lo.y });
        } else if (lo.calls.len == 0) {
            try out.print(a, "     (no draw calls at z{d} tile {d}/{d}/{d} — gated or geometry clipped)\n", .{ lo.z, lo.z, lo.x, lo.y });
        } else {
            try out.print(a, "     (z{d} tile {d}/{d}/{d})\n", .{ lo.z, lo.z, lo.x, lo.y });
            for (lo.calls) |c| try exAppendCall(a, out, c);
        }
    } else {
        try out.appendSlice(a, "     (resolving disabled / cell has no bounds)\n");
    }
}

fn exJsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => if (ch < 0x20) try out.print(a, "\\u{x:0>4}", .{ch}) else try out.append(a, ch),
    };
    try out.append(a, '"');
}

// One feature as a JSON object (no surrounding array / comma — the streaming
// caller writes `[`, the `,\n` separators and the closing `]\n`).
fn exWriteJsonRow(a: std.mem.Allocator, out: *std.ArrayList(u8), row: ExRow) !void {
    try out.print(a, "{{\"cell\":\"{s}\",\"index\":{d},\"rcid\":{d},\"foid\":\"{x}\",\"prim\":\"{s}\",\"objl\":{d},\"class\":", .{ row.cell_name, row.index, row.rcid, row.foid, exPrimName(row.prim), row.objl });
    try exJsonStr(a, out, row.class);
    try out.appendSlice(a, ",\"s101\":");
    try exJsonStr(a, out, row.s101);
    // Level 1.
    try out.appendSlice(a, ",\"attrs\":{");
    for (row.attrs, 0..) |at, j| {
        if (j > 0) try out.append(a, ',');
        try exJsonStr(a, out, at.acr);
        try out.append(a, ':');
        try exJsonStr(a, out, at.value);
    }
    try out.appendSlice(a, "}");
    // Level 2.
    try out.appendSlice(a, ",\"portrayal_raw\":");
    if (row.raw) |raw| try exJsonStr(a, out, raw) else try out.appendSlice(a, "null");
    if (row.parsed) |p| {
        try out.print(a, ",\"portrayal\":{{\"prio\":{d},\"cat\":\"{s}\",\"vg\":{d},\"fill\":", .{ p.draw_prio, exCatName(p.cat), p.vg });
        if (p.fill_token) |t| try exJsonStr(a, out, t) else try out.appendSlice(a, "null");
        try out.appendSlice(a, ",\"symbols\":[");
        for (p.points, 0..) |pt, j| {
            if (j > 0) try out.append(a, ',');
            try exJsonStr(a, out, pt.symbol);
        }
        try out.appendSlice(a, "],\"texts\":[");
        for (p.texts, 0..) |tx, j| {
            if (j > 0) try out.append(a, ',');
            try exJsonStr(a, out, tx.text);
        }
        try out.print(a, "],\"lines\":{d},\"patterns\":{d},\"aug_figures\":{d}}}", .{ p.lines.len, p.patterns.len, p.aug_figures.len });
    } else try out.appendSlice(a, ",\"portrayal\":null");
    // Level 3.
    if (row.resolved) |lo| {
        try out.print(a, ",\"resolved\":{{\"z\":{d},\"x\":{d},\"y\":{d},\"matched\":{},\"calls\":[", .{ lo.z, lo.x, lo.y, lo.matched });
        for (lo.calls, 0..) |c, j| {
            if (j > 0) try out.append(a, ',');
            try exJsonStr(a, out, @tagName(std.meta.activeTag(c)));
        }
        try out.appendSlice(a, "]}");
    } else try out.appendSlice(a, ",\"resolved\":null");
    try out.appendSlice(a, "}");
}

// Read a base cell's sequential .001.. update files from `dir` (auto-discovery,
// like the streaming chart loader). Missing = end of chain.
fn exReadUpdates(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, base_rel: []const u8) []const []const u8 {
    if (!std.mem.endsWith(u8, base_rel, ".000")) return &.{};
    const stem = base_rel[0 .. base_rel.len - 4];
    var list = std.ArrayList([]const u8).empty;
    var u: u32 = 1;
    while (u <= 999) : (u += 1) {
        const upn = std.fmt.allocPrint(a, "{s}.{d:0>3}", .{ stem, u }) catch break;
        const ub = dir.readFileAlloc(io, upn, a, .unlimited) catch break;
        list.append(a, ub) catch break;
    }
    return list.items;
}

// Parse `base_rel` from `dir` (with its updates) into `a`. All cell allocations
// (bytes, updates, the parsed Cell + its child arena/maps) live in `a`, so the
// caller reclaims them by resetting `a` — no cell.deinit() needed. `quiet`
// suppresses the read/parse diagnostics for the throwaway count pre-pass.
fn exParseCellFrom(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, base_rel: []const u8, quiet: bool) ?engine.s57.Cell {
    const base = dir.readFileAlloc(io, base_rel, a, .unlimited) catch {
        if (!quiet) std.debug.print("cannot read {s}\n", .{base_rel});
        return null;
    };
    const updates = exReadUpdates(io, a, dir, base_rel);
    return engine.s57.parseCellWithUpdates(a, base, updates) catch {
        if (!quiet) std.debug.print("cannot parse {s}\n", .{base_rel});
        return null;
    };
}

// The count pre-pass for the multi-cell console header ("N feature(s)"): parse the
// cell into `a` and count features passing the filters, WITHOUT portrayal or the
// recording surface. Cheap + memory-bounded (the caller resets `a` after).
fn exCountCell(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, base_rel: []const u8, F: ExFilters) usize {
    // quiet: a broken cell is reported once, by the heavy streaming pass that follows.
    const cell = exParseCellFrom(io, a, dir, base_rel, true) orelse return 0;
    var n: usize = 0;
    for (cell.features, 0..) |f, fi| {
        if (exPasses(F, engine.catalogue.acronymByObjl(f.objl), f, fi)) n += 1;
    }
    return n;
}

// A small buffered sink over stdout: append into a reusable buffer and flush in
// ~64 KiB chunks (and at teardown), so the explore dump streams out instead of
// materialising the whole thing in one giant ArrayList. The buffer backing lives
// in a long-lived allocator (the process arena); clearRetainingCapacity reuses it.
const OutBuf = struct {
    io: std.Io,
    f: std.Io.File,
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    const FLUSH_AT: usize = 1 << 16;

    fn write(self: *OutBuf, bytes: []const u8) void {
        self.buf.appendSlice(self.a, bytes) catch {
            // On OOM growing the buffer, flush what we have and write directly.
            self.flush();
            self.f.writeStreamingAll(self.io, bytes) catch {};
            return;
        };
        if (self.buf.items.len >= FLUSH_AT) self.flush();
    }
    fn flush(self: *OutBuf) void {
        if (self.buf.items.len == 0) return;
        self.f.writeStreamingAll(self.io, self.buf.items) catch {};
        self.buf.clearRetainingCapacity();
    }
};

const ExOut = enum { console, json };

const EX_SEP = "\n────────────────────────────────────────────────────────────────\n";

// Stream one cell's matching features to `out` (console detail or JSON objects),
// building each feature's ExRow in `fa_arena` (reset per feature) and the whole-
// cell portrayal + recording pass in `ca_arena` (the caller resets it before the
// next cell). Peak memory = ONE cell, never the whole source. The JSON `first`
// flag carries comma state across cells.
fn exStreamCell(
    ca_arena: *std.heap.ArenaAllocator,
    fa_arena: *std.heap.ArenaAllocator,
    cell: *engine.s57.Cell,
    name: []const u8,
    rules: []const u8,
    F: ExFilters,
    mode: ExOut,
    out: *OutBuf,
    first: *bool,
    palette: render.resolve.PaletteId,
    m: *const render.resolve.MarinerSettings,
) !void {
    const ca = ca_arena.allocator();
    const portrayal: ?[]const ?[]const u8 = engine.portray.portrayCell(ca, cell, rules) catch null;
    var ctx_storage = exSetupResolve(ca, cell, portrayal, F);
    const ctx: ?*ExResolveCtx = if (ctx_storage) |*c| c else null;
    const cell_name = try ca.dupe(u8, if (name.len > 0) name else cell.name);

    for (cell.features, 0..) |f, fi| {
        const class = engine.catalogue.acronymByObjl(f.objl);
        if (!exPasses(F, class, f, fi)) continue;

        _ = fa_arena.reset(.retain_capacity);
        const fa = fa_arena.allocator();
        const row = try exBuildRow(fa, cell, cell_name, 0, fi, f, class, portrayal, ctx, F);

        var chunk = std.ArrayList(u8).empty;
        switch (mode) {
            .console => {
                try chunk.appendSlice(fa, EX_SEP);
                try exFormatDetail12(fa, &chunk, row);
                try exFormatLevel3(fa, &chunk, row.resolved);
                if (F.kitty) try exAppendThumb(fa, &chunk, cell, portrayal, fi, row, palette, m);
            },
            .json => {
                if (!first.*) try chunk.appendSlice(fa, ",\n");
                try exWriteJsonRow(fa, &chunk, row);
                first.* = false;
            },
        }
        out.write(chunk.items);
    }
}

fn runExplore(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 explore <cell.000 | ENC_ROOT> [--class ACR[,ACR..]] [--object FOID|RCID|INDEX] [--zoom N] [--json] [--tui] [--kitty] [--no-resolve] [--rules DIR]\n", .{});
        return;
    }
    const path = args[2];
    var F = ExFilters{};
    var json = false;
    var tui = false;
    var kitty = false;
    var rules_flag: ?[]const u8 = null;
    var f = Flags{ .args = args, .i = 2 };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "--class")) {
            F.classes = f.val("--class") orelse return;
        } else if (std.mem.eql(u8, arg, "--object")) {
            const v = f.val("--object") orelse return;
            F.obj = std.fmt.parseInt(u64, v, 0) catch return usageErr("--object must be an integer (FOID/RCID/index; 0x.. for hex FOID)");
        } else if (std.mem.eql(u8, arg, "--zoom")) {
            const v = f.val("--zoom") orelse return;
            F.zoom = std.fmt.parseFloat(f64, v) catch return usageErr("--zoom must be a number");
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            tui = true;
        } else if (std.mem.eql(u8, arg, "--kitty")) {
            kitty = true;
            F.kitty = true;
        } else if (std.mem.eql(u8, arg, "--no-resolve")) {
            F.do_resolve = false;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules_flag = f.val("--rules") orelse return;
        } else return usageErr("unknown flag");
    }

    engine.portray.setQuiet(true);
    engine.catalogue.warmUp();
    const rules = resolveRulesDir(rules_flag);

    // --kitty: each feature's thumbnail is an ISOLATED render of that one feature's
    // resolved portrayal on a solid background (chart.renderFeature) — built from the
    // same re-parsed cell + portrayal streams the text dump uses, so no separate Chart
    // handle is opened.
    const palette: render.resolve.PaletteId = .day;
    var m = render.resolve.MarinerSettings{ .display_other = true };
    m.scheme = .day;

    // Collect the source cell list (one .000, or every *.000 under an ENC_ROOT).
    // `dir` stays open for the whole run (the TUI re-reads cells on demand).
    var dir: std.Io.Dir = undefined;
    var cell_paths = std.ArrayList([]const u8).empty;
    if (std.mem.endsWith(u8, path, ".000")) {
        const dirp = std.fs.path.dirname(path) orelse ".";
        dir = std.Io.Dir.cwd().openDir(io, dirp, .{}) catch return usageErr("cannot open cell directory");
        try cell_paths.append(a, try a.dupe(u8, std.fs.path.basename(path)));
    } else {
        dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return usageErr("source must be a .000 file or an ENC_ROOT directory");
        var walker = dir.walk(a) catch return usageErr("cannot walk ENC_ROOT");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".000")) continue;
            try cell_paths.append(a, try a.dupe(u8, entry.path));
        }
    }
    defer dir.close(io);

    // Per-cell scratch (heavy: parse + portrayal + recording surface) reset before
    // every cell, and a per-feature scratch reset before every feature — both backed
    // by the page allocator so freed pages return to the OS. Peak stays at ONE cell
    // regardless of how big the ENC_ROOT is.
    var cell_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cell_arena.deinit();
    var feat_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer feat_arena.deinit();

    // --- TUI: build only the lightweight feature INDEX (levels 1+2) resident; the
    //     level-3 resolve + kitty thumbnail are computed lazily per selection. ---
    if (tui) {
        var index_F = F;
        index_F.do_resolve = false; // level 3 is lazy (per selection)
        index_F.kitty = false; // thumbnails are lazy (per selection)
        // Build the lightweight index: parse + portray each cell in the per-cell
        // scratch (freed after), keeping only the formatted levels-1+2 lines + label
        // on the process arena. Peak during the build stays at one cell; the resident
        // index scales with feature COUNT (text), not with geometry.
        var index = std.ArrayList(ExIndexRow).empty;
        for (cell_paths.items, 0..) |base_rel, cid| {
            _ = cell_arena.reset(.free_all);
            const ca = cell_arena.allocator();
            var cell = exParseCellFrom(io, ca, dir, base_rel, false) orelse continue;
            var rows = std.ArrayList(ExRow).empty; // transient (scratch)
            exProcessCell(ca, &cell, std.fs.path.basename(base_rel), rules, index_F, cid, &rows) catch {};
            for (rows.items) |row| {
                var d = std.ArrayList(u8).empty;
                exFormatDetail12(a, &d, row) catch continue;
                index.append(a, .{
                    .class = a.dupe(u8, row.class) catch continue,
                    .label = a.dupe(u8, exLabel(ca, row)) catch continue,
                    .det12 = splitLines(a, d.items) catch continue,
                    .cell_id = cid,
                    .index = row.index,
                    .prim = row.prim,
                    .objl = row.objl,
                }) catch {};
            }
        }
        _ = cell_arena.reset(.free_all);
        if (index.items.len == 0) {
            std.debug.print("no matching features (source opened, but nothing passed the filters)\n", .{});
            return;
        }
        var cells = std.ArrayList(ExCellSrc).empty;
        for (cell_paths.items) |bp| try cells.append(a, .{ .base_rel = bp });
        return exploreTui(io, a, index.items, cells.items, dir, rules, F, kitty, palette, &m, path);
    }

    // --- Non-TUI: stream each cell's features straight to a buffered stdout, one
    //     cell resident at a time. ---
    var outbuf = OutBuf{ .io = io, .f = std.Io.File.stdout(), .a = a };
    defer outbuf.flush();
    outbuf.buf.ensureTotalCapacity(a, OutBuf.FLUSH_AT) catch {};

    if (json) {
        outbuf.write("[");
        var first = true;
        for (cell_paths.items) |base_rel| {
            _ = cell_arena.reset(.free_all);
            var cell = exParseCellFrom(io, cell_arena.allocator(), dir, base_rel, false) orelse continue;
            exStreamCell(&cell_arena, &feat_arena, &cell, std.fs.path.basename(base_rel), rules, F, .json, &outbuf, &first, palette, &m) catch {};
        }
        outbuf.write("]\n");
        return;
    }

    // Console. The header ("N feature(s)") needs the grand total up front: a single
    // cell yields it from its own filter pass (one parse); an ENC_ROOT gets it from a
    // cheap parse-only count pre-pass — byte-identical output, at the cost of parsing
    // each cell twice (the heavy portrayal + recording still run only once).
    var first = true;
    if (cell_paths.items.len == 1) {
        _ = cell_arena.reset(.free_all);
        var cell = exParseCellFrom(io, cell_arena.allocator(), dir, cell_paths.items[0], false) orelse {
            std.debug.print("no matching features (source opened, but nothing passed the filters)\n", .{});
            return;
        };
        var total: usize = 0;
        for (cell.features, 0..) |fe, fi| {
            if (exPasses(F, engine.catalogue.acronymByObjl(fe.objl), fe, fi)) total += 1;
        }
        if (total == 0) {
            std.debug.print("no matching features (source opened, but nothing passed the filters)\n", .{});
            return;
        }
        outbuf.write(std.fmt.allocPrint(a, "{d} feature(s)\n", .{total}) catch "");
        exStreamCell(&cell_arena, &feat_arena, &cell, std.fs.path.basename(cell_paths.items[0]), rules, F, .console, &outbuf, &first, palette, &m) catch {};
        return;
    }

    var total: usize = 0;
    for (cell_paths.items) |base_rel| {
        _ = cell_arena.reset(.free_all);
        total += exCountCell(io, cell_arena.allocator(), dir, base_rel, F);
    }
    if (total == 0) {
        std.debug.print("no matching features (source opened, but nothing passed the filters)\n", .{});
        return;
    }
    outbuf.write(std.fmt.allocPrint(a, "{d} feature(s)\n", .{total}) catch "");
    for (cell_paths.items) |base_rel| {
        _ = cell_arena.reset(.free_all);
        var cell = exParseCellFrom(io, cell_arena.allocator(), dir, base_rel, false) orelse continue;
        exStreamCell(&cell_arena, &feat_arena, &cell, std.fs.path.basename(base_rel), rules, F, .console, &outbuf, &first, palette, &m) catch {};
    }
}

// Console `--kitty`: after a row's text dump, append a one-line caption + the
// feature's RESOLVED render as an inline kitty-graphics PNG. The render is
// ISOLATED — only this feature's portrayal (chart.renderFeature, only_fi = fi)
// on a solid background, NOT a map crop of the surrounding scene. Any failure
// prints a short note instead of an image (graceful degradation), never an error.
fn exAppendThumb(a: std.mem.Allocator, out: *std.ArrayList(u8), cell: *engine.s57.Cell, portrayal: ?[]const ?[]const u8, fi: usize, row: ExRow, palette: render.resolve.PaletteId, m: *const render.resolve.MarinerSettings) !void {
    const tv = row.thumb orelse {
        try out.appendSlice(a, "  resolved render: (no renderable geometry)\n");
        return;
    };
    const png = chart.renderFeature(cell, portrayal, fi, tv.lon, tv.lat, tv.zoom, THUMB_PX, THUMB_PX, palette, m, THUMB_BG, .png) catch {
        try out.appendSlice(a, "  resolved render: (renderFeature failed for this feature)\n");
        return;
    };
    defer chart.freeBytes(png);
    const seq = render.kitty.encodePng(a, png) catch {
        try out.appendSlice(a, "  resolved render: (kitty encode failed)\n");
        return;
    };
    try out.print(a, "  resolved render (isolated) — {d}x{d}px {s} @ z{d:.1} ({d:.4},{d:.4}):\n", .{ THUMB_PX, THUMB_PX, if (tv.framed) "bbox" else "anchor", tv.zoom, tv.lon, tv.lat });
    try out.appendSlice(a, seq);
    try out.append(a, '\n');
}

// ---- explore --tui: colour + layout vocabulary -----------------------------
// Standard 8/16-colour ANSI only (+ bold/dim/reverse) so it degrades on plain
// terminals; no 256-colour assumptions. Colours are zero display-width, applied
// AFTER any width clipping, so column maths stays exact.
const EXC_RESET = "\x1b[0m";
const EXC_BOLD = "\x1b[1m";
const EXC_DIM = "\x1b[2m";
const EXC_REV = "\x1b[7m";
const EXC_RED = "\x1b[31m";
const EXC_GREEN = "\x1b[32m";
const EXC_YELLOW = "\x1b[33m";
const EXC_BLUE = "\x1b[34m";
const EXC_MAGENTA = "\x1b[35m";
const EXC_CYAN = "\x1b[36m";
const EXC_BCYAN = "\x1b[1;36m"; // class acronym (group header + feature title)
const EXC_H1 = "\x1b[1;33m"; // detail section "1. S-57 attributes"
const EXC_H2 = "\x1b[1;35m"; // detail section "2. S-101 portrayal instructions"
const EXC_H3 = "\x1b[1;32m"; // detail section "3. Resolved Surface calls"
const EXC_SPACES = " " ** 80;

// Per-primitive geometry glyph + colour for the class tree (point ● / line ─ /
// area ▬). All are single display columns but multi-byte UTF-8 — see dispWidth.
fn exGeomGlyph(prim: u8) []const u8 {
    return switch (prim) {
        1 => "\u{25CF}", // ● point
        2 => "\u{2500}", // ─ line
        3 => "\u{25AC}", // ▬ area
        else => "\u{00B7}", // · unknown
    };
}
fn exGeomColor(prim: u8) []const u8 {
    return switch (prim) {
        1 => EXC_CYAN,
        2 => EXC_GREEN,
        3 => EXC_BLUE,
        else => EXC_DIM,
    };
}
fn exGeomName(prim: u8) []const u8 {
    return switch (prim) {
        1 => "point",
        2 => "line",
        3 => "area",
        else => "other",
    };
}
fn exPrimSlot(prim: u8) usize {
    return switch (prim) {
        1 => 0,
        2 => 1,
        3 => 2,
        else => 3,
    };
}

// A class group in the tree: the member feature rows (indices into the resident
// index), a per-primitive tally for the header glyph + summary, the S-101 human
// name, and a collapse flag. Built once (the index is fixed for the session).
const ExGroup = struct {
    class: []const u8,
    members: []const usize, // indices into the resident `rows` (ExIndexRow) list
    counts: [4]usize, // [point, line, area, other]
    dominant: u8, // S-57 primitive of the header glyph (most common in the class)
    s101: []const u8, // S-101 feature-class name for the header, or ""
    expanded: bool,
};

// One flattened, on-screen row: a group HEADER, or a FEATURE under an expanded
// group. `row` indexes the resident index (only meaningful when !is_header).
const ExVisRow = struct { is_header: bool, group: usize, row: usize };

fn exLtClass(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// Group the resident index by S-57 class, sorted alphabetically by acronym. All
// allocations land in `a` (tiny — just index lists + group headers), so this is
// memory-negligible next to the level-3/thumbnail arenas.
fn exBuildGroups(a: std.mem.Allocator, rows: []const ExIndexRow) ![]ExGroup {
    var map = std.StringHashMap(std.ArrayList(usize)).init(a);
    for (rows, 0..) |row, i| {
        const gop = try map.getOrPut(row.class);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).empty;
        try gop.value_ptr.append(a, i);
    }
    var classes = std.ArrayList([]const u8).empty;
    var kit = map.keyIterator();
    while (kit.next()) |k| try classes.append(a, k.*);
    std.mem.sort([]const u8, classes.items, {}, exLtClass);

    var groups = std.ArrayList(ExGroup).empty;
    for (classes.items) |cls| {
        const members = map.get(cls).?.items;
        var counts = [_]usize{ 0, 0, 0, 0 };
        for (members) |ri| counts[exPrimSlot(rows[ri].prim)] += 1;
        var dom: u8 = 1;
        var best: usize = 0;
        for ([_]u8{ 1, 2, 3, 255 }) |p| {
            const c = counts[exPrimSlot(p)];
            if (c > best) {
                best = c;
                dom = p;
            }
        }
        try groups.append(a, .{
            .class = cls,
            .members = members,
            .counts = counts,
            .dominant = dom,
            .s101 = engine.catalogue.resolveFeatureByObjl(rows[members[0]].objl) orelse "",
            .expanded = false,
        });
    }
    // A single-group source opens expanded — no point hiding the only class.
    if (groups.items.len == 1) groups.items[0].expanded = true;
    return groups.items;
}

// The feature-row label with its redundant leading class stripped (the class is
// already the group header): "LIGHTS Thomas Point" -> "Thomas Point".
fn exSubLabel(row: ExIndexRow) []const u8 {
    if (std.mem.startsWith(u8, row.label, row.class) and
        row.label.len > row.class.len and row.label[row.class.len] == ' ')
        return row.label[row.class.len + 1 ..];
    return row.label;
}

// The header-summary detail shown when a GROUP header is selected (cheap — no
// cell re-parse). Lines land in `a` (a per-detail arena, reset per selection).
fn exGroupDetail(a: std.mem.Allocator, g: ExGroup, rows: []const ExIndexRow) ![]const []const u8 {
    _ = rows;
    var lines = std.ArrayList([]const u8).empty;
    if (g.s101.len > 0)
        try lines.append(a, try std.fmt.allocPrint(a, "{s}  ({s})", .{ g.class, g.s101 }))
    else
        try lines.append(a, try a.dupe(u8, g.class));
    try lines.append(a, "");
    try lines.append(a, try std.fmt.allocPrint(a, "  {d} feature(s) in this class", .{g.members.len}));
    var gb = std.ArrayList(u8).empty;
    try gb.appendSlice(a, "  geometry: ");
    var first = true;
    for ([_]u8{ 1, 2, 3, 255 }) |p| {
        const c = g.counts[exPrimSlot(p)];
        if (c == 0) continue;
        if (!first) try gb.appendSlice(a, "  ");
        first = false;
        try gb.print(a, "{d} {s}", .{ c, exGeomName(p) });
    }
    try lines.append(a, gb.items);
    try lines.append(a, try std.fmt.allocPrint(a, "  status: {s}", .{if (g.expanded) "expanded" else "collapsed"}));
    try lines.append(a, "");
    if (g.expanded)
        try lines.append(a, "  <-/Enter/Space  collapse this class")
    else
        try lines.append(a, "  ->/Enter/Space  expand this class");
    try lines.append(a, "  then select a feature to inspect its");
    try lines.append(a, "  S-57 attributes + portrayal + resolved render");
    return lines.items;
}

// Display width in terminal columns: count UTF-8 scalars (lead bytes), each as a
// single column. Correct for the ASCII + box-drawing glyphs the tree uses; the
// honest caveat is East-Asian "ambiguous width" glyphs (● ▬ ·) render as 2 cols
// in CJK-wide terminals, which this counts as 1 (assumes a Western-width font).
fn dispWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) w += 1;
    }
    return w;
}

// Clip `s` to at most `cols` display columns on a UTF-8 scalar boundary.
fn clipCols(s: []const u8, cols: usize) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const lead = (s[i] & 0xC0) != 0x80;
        if (lead and w >= cols) break;
        if (lead) w += 1;
        i += 1;
    }
    return s[0..i];
}

// A full-width reverse-video status bar (title / footer). `text` must be plain
// (no escapes) so the width maths is exact; the whole bar is reverse (+ optional
// bold), then padded with spaces to `cols`.
fn exEmitBar(fa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8, cols: usize, bold: bool) !void {
    try buf.appendSlice(fa, EXC_REV);
    if (bold) try buf.appendSlice(fa, EXC_BOLD);
    const c = clipCols(text, cols);
    try buf.appendSlice(fa, c);
    var w = dispWidth(c);
    while (w < cols) : (w += 1) try buf.append(fa, ' ');
    try buf.appendSlice(fa, EXC_RESET);
}

// One coloured segment of a left-pane row (text + its known display width +
// optional SGR colour). Assembling from known-width parts lets exEmitLeft clip
// and pad by columns without measuring around the embedded escapes.
const ExSeg = struct { t: []const u8, w: usize, c: []const u8 };

// Emit one left-pane cell of exactly `width` columns from coloured segments,
// clipping the overflowing segment on a scalar boundary and padding the rest. A
// selected row is drawn as a plain reverse-video bar (segment colours dropped so
// fg-on-reverse never muddies the highlight).
fn exEmitLeft(fa: std.mem.Allocator, buf: *std.ArrayList(u8), segs: []const ExSeg, width: usize, selected: bool) !void {
    if (selected) try buf.appendSlice(fa, EXC_REV);
    var used: usize = 0;
    for (segs) |sg| {
        if (used >= width) break;
        const avail = width - used;
        const colour = !selected and sg.c.len > 0;
        if (sg.w <= avail) {
            if (colour) try buf.appendSlice(fa, sg.c);
            try buf.appendSlice(fa, sg.t);
            if (colour) try buf.appendSlice(fa, EXC_RESET);
            used += sg.w;
        } else {
            const clipped = clipCols(sg.t, avail);
            if (colour) try buf.appendSlice(fa, sg.c);
            try buf.appendSlice(fa, clipped);
            if (colour) try buf.appendSlice(fa, EXC_RESET);
            used += dispWidth(clipped);
            break;
        }
    }
    while (used < width) : (used += 1) try buf.append(fa, ' ');
    if (selected) try buf.appendSlice(fa, EXC_RESET);
}

fn exTokenColor(op: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, op, "SY")) return EXC_MAGENTA; // symbol name
    if (std.mem.eql(u8, op, "AC")) return EXC_CYAN; // area colour token
    if (std.mem.eql(u8, op, "AP")) return EXC_CYAN; // area pattern
    if (std.mem.eql(u8, op, "LS")) return EXC_CYAN; // line style
    if (std.mem.eql(u8, op, "TX")) return EXC_GREEN; // text
    return null;
}

// Colourise S-52 shorthand opcodes (SY/AC/AP/LS/TX) in a detail line: dim the
// "XX(" opener, colour the parenthesised token by opcode. Leaves everything else
// untouched (best-effort — a ')' inside a TX string ends the run early).
fn exColorTokens(fa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 3 <= s.len and s[i + 2] == '(' and
            s[i] >= 'A' and s[i] <= 'Z' and s[i + 1] >= 'A' and s[i + 1] <= 'Z')
        {
            if (exTokenColor(s[i .. i + 2])) |col| {
                var j = i + 3;
                while (j < s.len and s[j] != ')') j += 1;
                try buf.appendSlice(fa, EXC_DIM);
                try buf.appendSlice(fa, s[i .. i + 3]);
                try buf.appendSlice(fa, EXC_RESET);
                try buf.appendSlice(fa, col);
                try buf.appendSlice(fa, s[i + 3 .. j]);
                try buf.appendSlice(fa, EXC_RESET);
                if (j < s.len) {
                    try buf.append(fa, ')');
                    j += 1;
                }
                i = j;
                continue;
            }
        }
        try buf.append(fa, s[i]);
        i += 1;
    }
}

// Emit one detail-pane line, clipped to `budget` columns, with colour applied by
// line type: the group-summary title, the numbered S-57/S-101/resolved section
// headers, the feature title, attribute acronyms, and S-52 opcode tokens. The
// underlying text is the SAME bytes the console path prints — colour lives only
// here, so `--json`/console stay byte-identical.
fn exEmitDetail(fa: std.mem.Allocator, buf: *std.ArrayList(u8), line: []const u8, budget: usize, first_header: bool) !void {
    const s = clipCols(line, budget);
    if (first_header) {
        try buf.appendSlice(fa, EXC_BCYAN);
        try buf.appendSlice(fa, s);
        try buf.appendSlice(fa, EXC_RESET);
        return;
    }
    if (std.mem.startsWith(u8, s, "  1. ")) return exSection(fa, buf, s, EXC_H1);
    if (std.mem.startsWith(u8, s, "  2. ")) return exSection(fa, buf, s, EXC_H2);
    if (std.mem.startsWith(u8, s, "  3. ")) return exSection(fa, buf, s, EXC_H3);
    if (s.len > 0 and s[0] == '[') {
        try buf.appendSlice(fa, EXC_BOLD);
        try buf.appendSlice(fa, s);
        try buf.appendSlice(fa, EXC_RESET);
        return;
    }
    // Attribute line: five leading spaces, an uppercase acronym, then " = ".
    if (std.mem.startsWith(u8, s, "     ") and s.len > 6 and s[5] >= 'A' and s[5] <= 'Z') {
        if (std.mem.indexOf(u8, s, " = ")) |eq| {
            try buf.appendSlice(fa, s[0..5]);
            try buf.appendSlice(fa, EXC_YELLOW);
            try buf.appendSlice(fa, s[5..eq]);
            try buf.appendSlice(fa, EXC_RESET);
            try buf.appendSlice(fa, s[eq..]);
            return;
        }
    }
    try exColorTokens(fa, buf, s);
}

fn exSection(fa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, color: []const u8) !void {
    try buf.appendSlice(fa, color);
    try buf.appendSlice(fa, s);
    try buf.appendSlice(fa, EXC_RESET);
}

// `tile57 explore --tui`: a two-pane feature explorer. Left = a COLLAPSIBLE class
// tree (group headers + indented features under expanded groups); right = the
// selected feature's three-level detail (or a group summary on a header). j/k or
// arrows move; ->/Enter/Space expand, <- collapse, E/C expand/collapse all;
// PgUp/PgDn page; g/G home/end; [/] scroll detail; / filters by class; q quits.
// Same termios raw-mode + alt-screen scaffolding as `tile57 ascii --tui`;
// dependency-free. With `--kitty` the selected feature's RESOLVED render is
// placed as a kitty-graphics thumbnail in the top-right of the detail pane
// (transmit-once-per-selection + place, deleted each frame — the same
// cached-region pattern as the ascii kitty TUI, so it never scrolls the layout).
fn exploreTui(io: std.Io, a: std.mem.Allocator, rows: []const ExIndexRow, cells: []const ExCellSrc, dir: std.Io.Dir, rules: []const u8, F: ExFilters, kitty: bool, palette: render.resolve.PaletteId, m: *const render.resolve.MarinerSettings, source: []const u8) !void {
    const stdout = std.Io.File.stdout();
    const stdin_fd = std.Io.File.stdin().handle;
    const old = std.posix.tcgetattr(stdin_fd) catch return usageErr("--tui needs a terminal");
    var raw = old;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false; // ctrl-c arrives as 0x03 → clean quit through the defers
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(stdin_fd, .NOW, raw) catch return usageErr("--tui needs a terminal");
    defer std.posix.tcsetattr(stdin_fd, .NOW, old) catch {};
    stdout.writeStreamingAll(io, "\x1b[?1049h\x1b[?25l") catch {}; // alt screen, hide cursor
    defer stdout.writeStreamingAll(io, "\x1b[?25h\x1b[?1049l") catch {};
    const do_kitty = kitty;
    defer if (do_kitty) stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
    // The kitty thumbnail's cross-frame state + its dedicated arena (owns the cached
    // a=T sequence; reset per selection). `sel_cell`/`sel_portrayal` persist the
    // re-parsed cell + portrayal the isolated render draws from (sel_arena-owned;
    // valid while `cached_cell` matches).
    var thumb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer thumb_arena.deinit();
    var thumb = ThumbState{ .arena = &thumb_arena };
    var sel_cell: ?*engine.s57.Cell = null;
    var sel_portrayal: ?[]const ?[]const u8 = null;

    // The resident index (rows) already carries each feature's label + LEVELS 1+2
    // detail lines. Level 3 (resolved calls) + the kitty thumbnail are computed
    // LAZILY per selection below — never held for every feature.

    // The class tree: group the index by S-57 class once (it is fixed for the
    // session); `expanded` toggles per header. Memory-negligible next to the arenas.
    const groups = try exBuildGroups(a, rows);
    const src_base = std.fs.path.basename(source);

    // Lazy level-3/thumbnail state. `sel_arena` caches ONE cell's re-parse +
    // recording + folded resolved calls (rebuilt only when the selection crosses to
    // another cell). `det_arena` holds just the currently-shown feature's level-3
    // (or a group header summary). Both page-backed so their resets return memory to
    // the OS. This is what keeps a 3000+-feature cell viable.
    var sel_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer sel_arena.deinit();
    var det_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer det_arena.deinit();
    // Per-FRAME scratch (bounded to one redraw) for the output buffer + tiny format
    // temporaries, reset each frame so the process arena never grows with redraws.
    var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer frame_arena.deinit();
    const need_cell = F.do_resolve or do_kitty; // no re-parse needed if neither
    var cached_cell: ?usize = null;
    var resolved_by_fi: []?ExLevel3 = &.{}; // current cell, indexed by feature index
    var thumb_by_fi: []?ExThumb = &.{};
    var cur_det: []const []const u8 = &.{}; // detail lines for the current selection
    var det_is_header = false; // cur_det is a group summary (colour its title line)
    // What cur_det was built for: kind 0=none 1=feature 2=header, id = rows[] index
    // (feature) or group index (header). det_kind = 3 forces a rebuild after a tree
    // mutation (expand/collapse changes the header summary or the feature set).
    var det_kind: u8 = 3;
    var det_id: usize = 0;

    var filt_buf: [64]u8 = undefined;
    var filt_len: usize = 0;
    var filtering = false; // typing into the class filter
    var sel: usize = 0; // index into the flattened visible-row list
    // With --kitty the point of the tool is the render, so don't open on a class
    // HEADER (which has no thumbnail) — expand the first group and land on its
    // first feature so a render is visible immediately. Without --kitty, groups
    // open collapsed (a tidy class list to navigate).
    if (do_kitty and groups.len > 0) {
        groups[0].expanded = true;
        sel = 1; // vis row 0 is the first header; row 1 is its first feature
    }
    var top: usize = 0; // first visible list row
    var det_top: usize = 0; // detail scroll offset
    // After a tree mutation the flattened list shifts; relocate the selection onto
    // this stable (group, header?/row) identity rather than onto a stale index.
    var sel_target: ?ExVisRow = null;

    // The flattened visible rows: a header per matching group, plus its features
    // when expanded. Rebuilt each frame into a reused buffer (no per-frame growth).
    var vis = std.ArrayList(ExVisRow).empty;
    while (true) {
        const filt = filt_buf[0..filt_len];
        vis.clearRetainingCapacity();
        var nvis_groups: usize = 0;
        for (groups, 0..) |g, gidx| {
            if (filt.len > 0 and indexOfIgnoreCase(g.class, filt) == null) continue;
            nvis_groups += 1;
            try vis.append(a, .{ .is_header = true, .group = gidx, .row = 0 });
            if (g.expanded) for (g.members) |ri|
                try vis.append(a, .{ .is_header = false, .group = gidx, .row = ri });
        }
        // Relocate the selection after a tree mutation, then clamp it in range.
        if (sel_target) |t| {
            sel_target = null;
            for (vis.items, 0..) |v, k| {
                if (v.group == t.group and v.is_header == t.is_header and (v.is_header or v.row == t.row)) {
                    sel = k;
                    break;
                }
            }
        }
        if (vis.items.len == 0) sel = 0 else if (sel >= vis.items.len) sel = vis.items.len - 1;

        const cur: ?ExVisRow = if (vis.items.len > 0) vis.items[sel] else null;
        // `gi`: the resident-index row of the selected FEATURE (null on a header /
        // empty view) — the key for the lazy level-3 + thumbnail. Model unchanged.
        const gi: ?usize = if (cur) |c| (if (c.is_header) null else c.row) else null;

        // Rebuild the detail only when the selected item's identity changes (or a
        // tree mutation forced det_kind = 3). A FEATURE re-parses + re-records its
        // cell once on a cell crossing (cached); a HEADER shows a cheap summary.
        var want_kind: u8 = 0;
        var want_id: usize = 0;
        if (cur) |c| {
            if (c.is_header) {
                want_kind = 2;
                want_id = c.group;
            } else {
                want_kind = 1;
                want_id = c.row;
            }
        }
        if (want_kind != det_kind or want_id != det_id) {
            det_kind = want_kind;
            det_id = want_id;
            det_top = 0;
            det_is_header = want_kind == 2;
            if (want_kind == 0) {
                cur_det = &[_][]const u8{"(no classes match the filter)"};
            } else if (want_kind == 2) {
                _ = det_arena.reset(.retain_capacity);
                cur_det = exGroupDetail(det_arena.allocator(), groups[want_id], rows) catch
                    &[_][]const u8{groups[want_id].class};
            } else {
                const g = want_id;
                const row = rows[g];
                if (need_cell and (cached_cell == null or cached_cell.? != row.cell_id) and row.cell_id < cells.len) {
                    _ = sel_arena.reset(.free_all);
                    cached_cell = null;
                    resolved_by_fi = &.{};
                    thumb_by_fi = &.{};
                    sel_cell = null;
                    sel_portrayal = null;
                    thumb.sel = null; // the cached thumbnail belonged to the old cell
                    const sa = sel_arena.allocator();
                    if (exParseCellFrom(io, sa, dir, cells[row.cell_id].base_rel, true)) |cell_val| {
                        // Persist the parsed Cell in sel_arena so the isolated thumbnail
                        // render can reach it across frames (a stack local would dangle).
                        if (sa.create(engine.s57.Cell)) |cell| {
                            cell.* = cell_val;
                            const portrayal = engine.portray.portrayCell(sa, cell, rules) catch null;
                            var ctx_storage = exSetupResolve(sa, cell, portrayal, F);
                            const ctx: ?*ExResolveCtx = if (ctx_storage) |*cc| cc else null;
                            var rbf: []?ExLevel3 = &.{};
                            if (sa.alloc(?ExLevel3, cell.features.len)) |buf| {
                                rbf = buf;
                                @memset(rbf, null);
                            } else |_| {}
                            var tbf: []?ExThumb = &.{};
                            if (do_kitty) {
                                if (sa.alloc(?ExThumb, cell.features.len)) |buf| {
                                    tbf = buf;
                                    @memset(tbf, null);
                                } else |_| {}
                            }
                            // Fold every kept feature IN ORDER (the queue consumes in feature
                            // order, exactly as the console path does), so a random-access
                            // lookup by feature index is byte-identical to the eager dump.
                            for (cell.features, 0..) |fe, cfi| {
                                const class = engine.catalogue.acronymByObjl(fe.objl);
                                if (!exPasses(F, class, fe, cfi)) continue;
                                if (ctx) |c2| {
                                    if (cfi < rbf.len) rbf[cfi] = exFoldResolved(sa, fe, class, c2) catch null;
                                }
                                if (do_kitty and cfi < tbf.len) tbf[cfi] = exThumbView(sa, cell, fe);
                            }
                            resolved_by_fi = rbf;
                            thumb_by_fi = tbf;
                            sel_cell = cell;
                            sel_portrayal = portrayal;
                            cached_cell = row.cell_id;
                        } else |_| {}
                    }
                }
                _ = det_arena.reset(.retain_capacity);
                const da = det_arena.allocator();
                const resolved: ?ExLevel3 = if (row.index < resolved_by_fi.len) resolved_by_fi[row.index] else null;
                var l3 = std.ArrayList(u8).empty;
                exFormatLevel3(da, &l3, resolved) catch {};
                const l3_lines = splitLines(da, l3.items) catch &[_][]const u8{};
                var lines = std.ArrayList([]const u8).empty;
                for (rows[g].det12) |ln| lines.append(da, ln) catch {};
                for (l3_lines) |ln| lines.append(da, ln) catch {};
                cur_det = lines.items;
            }
        }

        const ts_raw = terminalSize(io);
        const ts = ts_raw orelse .{ 100, 37, 0, 0 };
        const cols: usize = @max(40, ts[0]);
        const term_rows: usize = @max(8, ts[1]);
        const body_h = term_rows - 2; // one title row, one footer row
        const left_w = @min(@as(usize, 40), cols / 2);
        const right_w = cols - left_w - 3; // " │ " separator

        // Keep the selection on screen.
        if (sel < top) top = sel;
        if (sel >= top + body_h) top = sel + 1 - body_h;

        _ = frame_arena.reset(.retain_capacity);
        const fa = frame_arena.allocator();
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(fa, "\x1b[H");

        // Title bar: source + totals (+ the matching-class count while filtering).
        var hdr = std.ArrayList(u8).empty;
        try hdr.print(fa, " tile57 explore   {s}   {d} features \u{00B7} {d} classes", .{ src_base, rows.len, groups.len });
        if (filt.len > 0) try hdr.print(fa, "   filter \"{s}\" \u{2192} {d}", .{ filt, nvis_groups });
        try exEmitBar(fa, &buf, hdr.items, cols, true);
        try buf.appendSlice(fa, "\x1b[K\n");

        var r: usize = 0;
        while (r < body_h) : (r += 1) {
            // Left: the collapsible class tree, windowed around `top`.
            const li = top + r;
            if (li < vis.items.len) {
                const v = vis.items[li];
                const selected = li == sel;
                var segs: [8]ExSeg = undefined;
                var ns: usize = 0;
                if (v.is_header) {
                    const g = groups[v.group];
                    segs[ns] = .{ .t = if (g.expanded) "\u{25BE} " else "\u{25B8} ", .w = 2, .c = EXC_DIM };
                    ns += 1;
                    segs[ns] = .{ .t = g.class, .w = g.class.len, .c = EXC_BCYAN };
                    ns += 1;
                    const cnt: []const u8 = std.fmt.allocPrint(fa, "{d}", .{g.members.len}) catch "?";
                    const leftw = 2 + g.class.len;
                    const rightw = cnt.len + 2; // count + space + glyph
                    const spw = if (left_w > leftw + rightw) left_w - leftw - rightw else 1;
                    const spwc = @min(spw, EXC_SPACES.len);
                    segs[ns] = .{ .t = EXC_SPACES[0..spwc], .w = spwc, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = cnt, .w = cnt.len, .c = EXC_DIM };
                    ns += 1;
                    segs[ns] = .{ .t = " ", .w = 1, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = exGeomGlyph(g.dominant), .w = 1, .c = exGeomColor(g.dominant) };
                    ns += 1;
                } else {
                    const row = rows[v.row];
                    const sub = exSubLabel(row);
                    const dim = std.mem.startsWith(u8, sub, "foid:") or (sub.len > 0 and sub[0] == '#');
                    segs[ns] = .{ .t = "  ", .w = 2, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = exGeomGlyph(row.prim), .w = 1, .c = exGeomColor(row.prim) };
                    ns += 1;
                    segs[ns] = .{ .t = " ", .w = 1, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = sub, .w = dispWidth(sub), .c = if (dim) EXC_DIM else "" };
                    ns += 1;
                }
                try exEmitLeft(fa, &buf, segs[0..ns], left_w, selected);
            } else {
                var k: usize = 0;
                while (k < left_w) : (k += 1) try buf.append(fa, ' ');
            }
            // Separator.
            try buf.appendSlice(fa, " ");
            try buf.appendSlice(fa, EXC_DIM);
            try buf.appendSlice(fa, "\u{2502}"); // │
            try buf.appendSlice(fa, EXC_RESET);
            try buf.appendSlice(fa, " ");
            // Right: the detail pane, windowed around `det_top`, colourised per line.
            const di = det_top + r;
            if (di < cur_det.len) try exEmitDetail(fa, &buf, cur_det[di], right_w, det_is_header and di == 0);
            try buf.appendSlice(fa, "\x1b[K\n");
        }

        // Footer keybar.
        if (filtering) {
            const t: []const u8 = std.fmt.allocPrint(fa, " filter class: {s}_    enter=apply   esc=clear", .{filt}) catch " filter";
            try exEmitBar(fa, &buf, t, cols, false);
        } else {
            try exEmitBar(fa, &buf, " j/k move  \u{2192}/enter expand  \u{2190} collapse  E/C all  / filter  [ ] scroll  q quit", cols, false);
        }
        try buf.appendSlice(fa, "\x1b[J"); // clear anything below
        stdout.writeStreamingAll(io, buf.items) catch {};

        // --kitty: the selected FEATURE's ISOLATED render (only that feature's
        // portrayal on a solid background), transmit-and-displayed in the LOWER
        // part of the detail pane, BELOW the text, AFTER the text so it never
        // scrolls the layout. A header selection (gi == null) or an unavailable
        // cell clears any prior image.
        if (do_kitty) {
            const rendered = if (gi) |g| blk: {
                const cp = sel_cell orelse break :blk false;
                const tv: ?ExThumb = if (rows[g].index < thumb_by_fi.len) thumb_by_fi[rows[g].index] else null;
                // Text lines currently visible in the detail pane (the image tucks
                // in just below them, pinned to the pane's lower rows).
                const text_rows: usize = if (cur_det.len > det_top) @min(cur_det.len - det_top, body_h) else 0;
                exTuiThumb(io, a, stdout, &thumb, cp, sel_portrayal, rows[g].index, tv, palette, m, right_w, left_w, term_rows, text_rows, ts_raw);
                break :blk true;
            } else false;
            if (!rendered) {
                stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
                thumb.sel = null;
            }
        }

        // Input.
        var b: [64]u8 = undefined;
        const n = std.posix.read(stdin_fd, &b) catch break;
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) {
            const c = b[i];
            if (filtering) {
                switch (c) {
                    0x0d, 0x0a => filtering = false, // enter (CR or LF): apply
                    0x1b => {
                        filt_len = 0;
                        filtering = false;
                    }, // esc: clear
                    0x7f, 0x08 => filt_len -|= 1, // backspace
                    else => if (c >= 0x20 and c < 0x7f and filt_len < filt_buf.len) {
                        filt_buf[filt_len] = c;
                        filt_len += 1;
                    },
                }
                i += 1;
                continue;
            }
            // Nav mode. Cursor escape sequences first (arrows + PgUp/PgDn).
            if (c == 0x1b and i + 2 < n and b[i + 1] == '[') {
                switch (b[i + 2]) {
                    'A' => sel -|= 1, // up
                    'B' => sel += 1, // down
                    'C' => { // right: expand the selected header
                        if (cur) |cc| if (cc.is_header) {
                            groups[cc.group].expanded = true;
                            det_kind = 3;
                            sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                        };
                    },
                    'D' => { // left: collapse the selected header (or a feature's parent)
                        if (cur) |cc| {
                            groups[cc.group].expanded = false;
                            det_kind = 3;
                            sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                        }
                    },
                    '5' => sel -|= body_h, // PgUp (ESC[5~)
                    '6' => sel += body_h, // PgDn (ESC[6~)
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (c) {
                'k' => sel -|= 1,
                'j' => sel += 1,
                'g' => sel = 0,
                'G' => sel = if (vis.items.len > 0) vis.items.len - 1 else 0,
                '[' => det_top -|= 1, // scroll detail up
                ']' => det_top += 1, // scroll detail down
                ' ', 0x0d, 0x0a => { // space / enter: toggle the selected header
                    if (cur) |cc| if (cc.is_header) {
                        groups[cc.group].expanded = !groups[cc.group].expanded;
                        det_kind = 3;
                        sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                    };
                },
                'E' => { // expand all classes
                    for (groups) |*g| g.expanded = true;
                    det_kind = 3;
                    if (cur) |cc| sel_target = cc;
                },
                'C' => { // collapse all classes
                    for (groups) |*g| g.expanded = false;
                    det_kind = 3;
                    if (cur) |cc| sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                },
                '/' => {
                    filtering = true;
                    filt_len = 0;
                },
                'q', 'Q', 0x03 => return,
                else => {},
            }
            i += 1;
        }
        if (vis.items.len > 0 and sel >= vis.items.len) sel = vis.items.len - 1;
        if (cur_det.len > 0) det_top = @min(det_top, cur_det.len - 1) else det_top = 0;
    }
}

// Draw the selected feature's `--kitty` thumbnail as a LARGE isolated render
// (only feature `fi`'s portrayal on a solid background — chart.renderFeature),
// filling the detail pane's width and its lower rows, positioned BELOW the text.
// Sizing: the image fills `right_w` cells wide and ~60% of the body's rows tall
// (clamped to a sane pixel max), its top pinned just under the visible text lines
// so the pane's upper rows always keep the class/attribute header; long text
// simply scrolls behind the image. The framing zoom is recomputed for this bigger
// canvas (a line/area frames its bbox to ~80% of the min canvas dimension; a point
// renders at the cell band-max zoom, and its fixed-device-px symbol is scaled up
// via size_scale so it doesn't look lost on the large canvas).
//
// The render + kitty encode run ONCE per selection (cached in `st`, re-run only if
// the target pixel size changes, e.g. a terminal resize); every frame re-emits the
// cached a=T sequence AFTER the text so the redraw can't leave it stale. a=T
// (transmit-AND-display at the cursor) is the SAME escape shape as the console
// `--kitty` path. The image is drawn strictly within the pane's body rows (footer
// stays clear) so its cursor-advance can't scroll the text away. Any failure — or
// a pane too small to hold a useful image — clears the image and leaves the text
// pane intact (graceful degradation).
fn exTuiThumb(io: std.Io, a: std.mem.Allocator, stdout: std.Io.File, st: *ThumbState, cell: *engine.s57.Cell, portrayal: ?[]const ?[]const u8, fi: usize, tv_in: ?ExThumb, palette: render.resolve.PaletteId, m: *const render.resolve.MarinerSettings, right_w: usize, left_w: usize, term_rows: usize, text_rows: usize, ts_raw: ?[4]u32) void {
    const clear = struct {
        fn f(io_: std.Io, out: std.Io.File, s: *ThumbState) void {
            out.writeStreamingAll(io_, render.kitty.delete_all) catch {};
            s.sel = null;
            s.seq = null;
        }
    }.f;
    const tv = tv_in orelse {
        clear(io, stdout, st);
        return;
    };

    // Pane budget. The body owns rows 2..term_rows-1 (title row 1, footer last);
    // reserve its lower part for the image, keeping >= min_text_rows of text above.
    const cp = cellPx(ts_raw);
    const cpw: usize = cp[0];
    const cph: usize = cp[1];
    const body_h: usize = term_rows - 2;
    const min_img_rows: usize = 6;
    const min_text_rows: usize = 3;
    const min_img_cols: usize = 16;
    if (body_h < min_img_rows + min_text_rows or right_w < min_img_cols) {
        clear(io, stdout, st);
        return;
    }

    // Image size in cells: fill the detail-pane width, ~60% of the body's height,
    // each clamped to a sane pixel maximum so a huge terminal doesn't transmit an
    // enormous PNG. Then position it below the text (pinned to the pane's bottom).
    const max_px: usize = 1600;
    var img_cols: usize = right_w;
    if (img_cols * cpw > max_px) img_cols = @max(min_img_cols, max_px / cpw);
    var img_rows: usize = (body_h * 3) / 5;
    img_rows = std.math.clamp(img_rows, min_img_rows, body_h - min_text_rows);
    if (img_rows * cph > max_px) img_rows = @max(min_img_rows, max_px / cph);
    const w: u32 = @intCast(img_cols * cpw);
    const h: u32 = @intCast(img_rows * cph);
    const top_offset: usize = @min(text_rows, body_h - img_rows); // text rows kept above the image
    const img_top_row: usize = 2 + top_offset; // 1-based; +img_rows-1 <= term_rows-1
    const col1: usize = left_w + 4; // 1-based left edge of the detail pane's content

    // (Re)render the isolated feature + build its a=T sequence only when the
    // selection OR the target pixel size changed (the render is the slow step; the
    // cached bytes are cheap to re-emit). The framing zoom is recomputed for this
    // canvas, and point symbols are enlarged (size_scale) so they read at this size.
    if (st.sel == null or st.sel.? != fi or st.seq == null or st.w != w or st.h != h) {
        _ = st.arena.reset(.retain_capacity);
        const ta = st.arena.allocator();
        const min_dim: f64 = @floatFromInt(@min(w, h));
        const zoom = exThumbZoom(tv, min_dim, 0.8);
        var s = m.*;
        s.size_scale *= std.math.clamp(min_dim / @as(f64, @floatFromInt(THUMB_PX)), 1.0, 3.0);
        const png = chart.renderFeature(cell, portrayal, fi, tv.lon, tv.lat, zoom, w, h, palette, &s, THUMB_BG, .png) catch {
            clear(io, stdout, st);
            return;
        };
        defer chart.freeBytes(png);
        const seq = render.kitty.encodePng(ta, png) catch {
            clear(io, stdout, st);
            return;
        };
        st.seq = seq;
        st.sel = fi;
        st.w = w;
        st.h = h;
    }
    // Each frame: clear the previous frame's image, move the (hidden) cursor to the
    // image's top-left cell below the text, then transmit+display the cached image.
    const move = std.fmt.allocPrint(a, "\x1b[{d};{d}H", .{ img_top_row, col1 }) catch return;
    defer a.free(move);
    stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
    stdout.writeStreamingAll(io, move) catch {};
    stdout.writeStreamingAll(io, st.seq.?) catch {};
}

// Split text into lines (no trailing empty line for a final '\n'). Arena-owned.
fn splitLines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(a, line);
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

// Byte-clip a string to at most `w` bytes (a debug TUI; wide/UTF-8 clipping is
// best-effort, the terminal tolerates it).
fn clip(s: []const u8, w: usize) []const u8 {
    return if (s.len <= w) s else s[0..w];
}

fn padTo(a: std.mem.Allocator, buf: *std.ArrayList(u8), from: usize, to: usize) !void {
    var i = from;
    while (i < to) : (i += 1) try buf.append(a, ' ');
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// A lon/lat's Web-Mercator world-pixel position on a `world`-pixel globe.
fn worldPxOf(lon: f64, lat: f64, world: f64) [2]f64 {
    const rad = lat * std.math.pi / 180.0;
    const y = std.math.log(f64, std.math.e, std.math.tan(std.math.pi / 4.0 + rad / 2.0));
    return .{
        (lon + 180.0) / 360.0 * world,
        (1.0 - y / std.math.pi) / 2.0 * world,
    };
}

// Shift a latitude by `px` screen pixels (positive = north) on a `world`-pixel
// Web-Mercator globe — exact Mercator, so panning doesn't drift at high lat.
fn mercShift(lat: f64, px: f64, world: f64) f64 {
    const rad = lat * std.math.pi / 180.0;
    const y = std.math.log(f64, std.math.e, std.math.tan(std.math.pi / 4.0 + rad / 2.0));
    const y2 = y + px * 2.0 * std.math.pi / world;
    const lat2 = (2.0 * std.math.atan(std.math.exp(y2)) - std.math.pi / 2.0) * 180.0 / std.math.pi;
    return std.math.clamp(lat2, -85.0, 85.0);
}

// The controlling terminal's {cols, rows, xpixel, ypixel}, or null when
// stdout isn't a TTY (or the platform gives us no TIOCGWINSZ) — the `ascii`
// grid's no-wrap default and the `--sixel` pixel geometry. xpixel/ypixel are
// 0 when the terminal doesn't report them.
// The std.Progress terminal-size pattern (Io.operate device_io_control).
fn terminalSize(io: std.Io) ?[4]u32 {
    if (@import("builtin").os.tag == .windows) return null;
    const f = std.Io.File.stdout();
    if ((f.isTty(io) catch return null) == false) return null;
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = (io.operate(.{ .device_io_control = .{
        .file = f,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return null).device_io_control;
    if (err < 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ ws.col, ws.row, ws.xpixel, ws.ypixel };
}

// The terminal's character-cell size in pixels for sixel geometry: reported
// xpixel/ypixel over cols/rows when available, else the common 10x20 guess.
fn cellPx(ts: ?[4]u32) [2]u32 {
    if (ts) |t| {
        if (t[2] > 0 and t[3] > 0) return .{ @max(4, t[2] / t[0]), @max(8, t[3] / t[1]) };
    }
    return .{ 10, 20 };
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
        \\      --format mlt|mvt    tile encoding (default mlt = MapLibre Tile;
        \\                          mvt = Mapbox Vector Tile, kept for consumers
        \\                          without an MLT decoder)
        \\  tile57 assets <portrayal-catalog-dir> -o <out-dir>
        \\      Emit just the portrayal assets (colortables.json today) for a
        \\      catalogue, independent of any cell.
        \\  tile57 style <portrayal-catalog-dir> --scheme day -o <out.json>
        \\      Emit one MapLibre style.json (colours from the catalogue, or
        \\      --colortables FILE). --scheme day|dusk|night; --source-tiles/
        \\      --pmtiles-url pick the source; --sprite/--glyphs enable symbol/text
        \\      layers; --minzoom/--maxzoom.
        \\  tile57 png|pdf <cell.000 | bundle.pmtiles> <z> <x> <y> -o <out> [--size N] [--palette P]
        \\  tile57 png|pdf <source> --view <lon,lat,zoom> --size WxH -o <out>
        \\      Render a tile or a view through the native S-52 pixel path:
        \\      PNG raster or deterministic vector PDF (real text objects).
        \\      Sources: an S-57 cell (live portrayal) or a baked .pmtiles
        \\      bundle (tile replay). --dq data-quality overlay; --scale F
        \\      physical-size multiplier; --palette day|dusk|night.
        \\  tile57 ascii <cell.000 | ENC_ROOT | bundle.pmtiles> --view <lon,lat,zoom> [--size COLSxROWS (default: terminal size)] [--ansi] [--kitty]
        \\      The chart on stdout as a Unicode text grid (the example render
        \\      backend). --ansi adds xterm-256 color; --palette day|dusk|night.
        \\  tile57 explore <cell.000 | ENC_ROOT> [--class ACR[,ACR..]] [--object FOID|RCID|INDEX]
        \\      Dump, per feature, the RAW S-57 (class + attributes), the S-101
        \\      portrayal instruction stream (raw + parsed), and the resolved
        \\      Surface draw calls. --zoom N picks the resolving tile; --json;
        \\      --no-resolve skips the draw-call pass; --tui opens the two-pane
        \\      explorer (arrows select, / filters by class, q quits); --kitty
        \\      adds a live thumbnail of each feature's resolved render (inline in
        \\      console mode, in the TUI detail pane) for graphics terminals.
        \\  tile57 inspect <file.pmtiles> [z x y]
        \\  tile57 cell <file.000>
        \\  tile57 objlcount <file.000> <objl> [prim]   (corpus scan: find cells with an object class)
        \\  tile57 version
        \\  tile57 help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM, DEFAULT_LRU_BUDGET, DEFAULT_SUPER_DZ });
}
