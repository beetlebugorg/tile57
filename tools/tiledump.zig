//! tile57 tiledump <tile.mlt|tile.mvt> — decode ONE raw (decompressed) vector
//! tile and summarise it: per-layer feature counts by geometry type, plus value
//! histograms for the properties that identify portrayal output (class,
//! symbol_name, ls). For debugging what a bake or the compositor actually put
//! in a tile.
//!
//! --geom CLASS switches to per-feature geometry mode: each polygon/line
//! feature with class=CLASS prints its properties and, per ring/part, the
//! point count, bbox, and (polygons) signed area — plus the full coordinate
//! list under --coords. For hunting degenerate geometry.
//!
//! --verts is the density attribution: per layer, per class, how many features,
//! rings/parts and VERTICES the tile carries, sorted by vertex count. Vertices
//! are what the portrayal tessellates and the GPU uploads, so this is the table
//! that says where a heavy low-zoom tile's cost actually lives — and the
//! before/after ledger for any generalization change. Polygon rows also report
//! how many rings fall under one display pixel squared (SUBPX: |area| < 2·64
//! extent-units², one 512-px-tile display pixel = EXTENT/512 = 8 units), the
//! rings that tessellate to invisible triangles.

const std = @import("std");
const engine = @import("engine");

const Count = struct { pts: u32 = 0, lines: u32 = 0, polys: u32 = 0 };

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 tiledump <tile.mlt|tile.mvt> [--prop KEY] [--geom CLASS [--coords]] [--verts]\n", .{});
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var extra_prop: ?[]const u8 = null;
    var geom_class: ?[]const u8 = null;
    var coords = false;
    var verts = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--prop") and i + 1 < args.len) {
            extra_prop = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--geom") and i + 1 < args.len) {
            geom_class = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--coords")) {
            coords = true;
        } else if (std.mem.eql(u8, args[i], "--verts")) {
            verts = true;
        }
    }
    if (verts) {
        const layers = engine.mlt.decode(a, bytes) catch |mlt_err| blk: {
            break :blk engine.mvt.decode(a, bytes) catch {
                std.debug.print("not a decodable MLT ({s}) or MVT tile\n", .{@errorName(mlt_err)});
                return;
            };
        };
        return dumpVerts(io, a, layers);
    }

    const layers = engine.mlt.decode(a, bytes) catch |mlt_err| blk: {
        break :blk engine.mvt.decode(a, bytes) catch {
            std.debug.print("not a decodable MLT ({s}) or MVT tile\n", .{@errorName(mlt_err)});
            return;
        };
    };

    if (geom_class) |cls| return dumpGeom(io, a, layers, cls, coords);

    var out = std.ArrayList(u8).empty;
    for (layers) |layer| {
        var c = Count{};
        var hist = std.StringHashMap(u32).init(a);
        const keys = [_][]const u8{ "class", "symbol_name", "ls" };
        for (layer.features) |f| {
            switch (f.geom_type) {
                .point => c.pts += 1,
                .linestring => c.lines += 1,
                .polygon => c.polys += 1,
                .unknown => {},
            }
            for (f.properties) |p| {
                const interesting = for (keys) |k| {
                    if (std.mem.eql(u8, p.key, k)) break true;
                } else (extra_prop != null and std.mem.eql(u8, p.key, extra_prop.?));
                if (!interesting) continue;
                // Numeric properties histogram too: `--prop scamin` / `--prop band`
                // are how you read a tile's scale gating and band mix, and they are
                // ints on the wire.
                const tag = switch (p.value) {
                    .string => |v| try std.fmt.allocPrint(a, "{s}={s}", .{ p.key, v }),
                    .int => |v| try std.fmt.allocPrint(a, "{s}={d}", .{ p.key, v }),
                    .uint => |v| try std.fmt.allocPrint(a, "{s}={d}", .{ p.key, v }),
                    .float => |v| try std.fmt.allocPrint(a, "{s}={d}", .{ p.key, v }),
                    .double => |v| try std.fmt.allocPrint(a, "{s}={d}", .{ p.key, v }),
                    .boolean => |v| try std.fmt.allocPrint(a, "{s}={}", .{ p.key, v }),
                };
                const g = try hist.getOrPutValue(tag, 0);
                g.value_ptr.* += 1;
            }
        }
        try out.print(a, "layer {s}: {d} pts, {d} lines, {d} polys\n", .{ layer.name, c.pts, c.lines, c.polys });
        var it = hist.iterator();
        while (it.next()) |e| try out.print(a, "    {s} x{d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
}

// One (layer, class) bucket of the --verts attribution.
const Bucket = struct {
    layer: []const u8,
    class: []const u8,
    feats: u32 = 0,
    parts: u32 = 0,
    verts: u64 = 0,
    subpx: u32 = 0, // polygon rings below one display px^2 (see the module docs)
};

// One display pixel at 512 CSS px/tile is EXTENT/512 = 8 extent units, so a
// ring of one display px^2 has |2·area| = 2·64 units^2. The shoelace sum is
// twice the signed area, hence the comparison against 2·64 directly.
const SUBPX_AREA2: i64 = 2 * 64;

fn dumpVerts(io: std.Io, a: std.mem.Allocator, layers: []const engine.mvt.DecodedLayer) !void {
    var buckets = std.ArrayList(Bucket).empty;
    var index = std.StringHashMap(usize).init(a);
    var total_verts: u64 = 0;
    for (layers) |layer| {
        for (layer.features) |f| {
            const cls = for (f.properties) |p| {
                if (std.mem.eql(u8, p.key, "class") and p.value == .string) break p.value.string;
            } else "-";
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ layer.name, cls });
            const g = try index.getOrPut(key);
            if (!g.found_existing) {
                g.value_ptr.* = buckets.items.len;
                try buckets.append(a, .{ .layer = layer.name, .class = cls });
            }
            const b = &buckets.items[g.value_ptr.*];
            b.feats += 1;
            for (f.parts) |ring| {
                b.parts += 1;
                b.verts += ring.len;
                total_verts += ring.len;
                if (f.geom_type != .polygon or ring.len < 3) continue;
                var area2: i64 = 0;
                for (ring, 0..) |pt, pi| {
                    const nxt = ring[(pi + 1) % ring.len];
                    area2 += @as(i64, pt.x) * nxt.y - @as(i64, nxt.x) * pt.y;
                }
                if (@abs(area2) < SUBPX_AREA2) b.subpx += 1;
            }
        }
    }
    std.mem.sort(Bucket, buckets.items, {}, struct {
        fn lt(_: void, x: Bucket, y: Bucket) bool {
            return x.verts > y.verts;
        }
    }.lt);
    var out = std.ArrayList(u8).empty;
    try out.print(a, "{s:<14} {s:<10} {s:>7} {s:>7} {s:>9} {s:>7}\n", .{ "layer", "class", "feats", "parts", "verts", "subpx" });
    for (buckets.items) |b| try out.print(a, "{s:<14} {s:<10} {d:>7} {d:>7} {d:>9} {d:>7}\n", .{ b.layer, b.class, b.feats, b.parts, b.verts, b.subpx });
    try out.print(a, "TOTAL verts {d}\n", .{total_verts});
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
}

fn dumpGeom(io: std.Io, a: std.mem.Allocator, layers: []const engine.mvt.DecodedLayer, cls: []const u8, coords: bool) !void {
    var out = std.ArrayList(u8).empty;
    for (layers) |layer| {
        for (layer.features, 0..) |f, fi| {
            if (f.geom_type == .point) continue;
            const matched = for (f.properties) |p| {
                if (std.mem.eql(u8, p.key, "class") and p.value == .string and std.mem.eql(u8, p.value.string, cls)) break true;
            } else false;
            if (!matched) continue;
            try out.print(a, "{s}[{d}] {s}", .{ layer.name, fi, @tagName(f.geom_type) });
            for (f.properties) |p| {
                switch (p.value) {
                    .string => |v| try out.print(a, " {s}={s}", .{ p.key, v }),
                    .float => |v| try out.print(a, " {s}={d}", .{ p.key, v }),
                    .double => |v| try out.print(a, " {s}={d}", .{ p.key, v }),
                    .int => |v| try out.print(a, " {s}={d}", .{ p.key, v }),
                    .uint => |v| try out.print(a, " {s}={d}", .{ p.key, v }),
                    .boolean => |v| try out.print(a, " {s}={}", .{ p.key, v }),
                }
            }
            try out.print(a, "\n", .{});
            for (f.parts, 0..) |ring, ri| {
                var min_x: i32 = std.math.maxInt(i32);
                var min_y: i32 = std.math.maxInt(i32);
                var max_x: i32 = std.math.minInt(i32);
                var max_y: i32 = std.math.minInt(i32);
                var area2: i64 = 0; // twice the signed area (shoelace)
                for (ring, 0..) |pt, pi| {
                    min_x = @min(min_x, pt.x);
                    min_y = @min(min_y, pt.y);
                    max_x = @max(max_x, pt.x);
                    max_y = @max(max_y, pt.y);
                    const nxt = ring[(pi + 1) % ring.len];
                    area2 += @as(i64, pt.x) * nxt.y - @as(i64, nxt.x) * pt.y;
                }
                try out.print(a, "  ring[{d}]: {d} pts, bbox [{d},{d}..{d},{d}], area2 {d}\n", .{ ri, ring.len, min_x, min_y, max_x, max_y, area2 });
                if (coords) {
                    for (ring) |pt| try out.print(a, "    {d},{d}\n", .{ pt.x, pt.y });
                }
            }
        }
    }
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
}
