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
        \\  tile57 inspect <file.pmtiles> [z x y]
        \\  tile57 cell <file.000>
        \\  tile57 objlcount <file.000> <objl> [prim]   (corpus scan: find cells with an object class)
        \\  tile57 version
        \\  tile57 help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM, DEFAULT_LRU_BUDGET, DEFAULT_SUPER_DZ });
}
