const std = @import("std");
const engine = @import("engine");

// Archive-wide double-draw audit (scamin-standalone acceptance): walk every
// tile, decode the point_symbols_scamin layer, and report CROSS-CELL pairs
// of the same class + same symbol within ~30 m whose visibility windows
// (smax, scamin] intersect — i.e. two copies of one object that some display
// scale would render simultaneously. Zero expected after the dedup.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 audit-pairs <file.pmtiles>\n", .{});
        return;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var r = try engine.pmtiles.Reader.init(a, data);
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
    try Walk.f(&r, a, r.root, &ids);
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
