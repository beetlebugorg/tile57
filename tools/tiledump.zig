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

const std = @import("std");
const engine = @import("engine");

const Count = struct { pts: u32 = 0, lines: u32 = 0, polys: u32 = 0 };

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 tiledump <tile.mlt|tile.mvt> [--prop KEY]\n", .{});
        return;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var extra_prop: ?[]const u8 = null;
    var geom_class: ?[]const u8 = null;
    var coords = false;
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
        }
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
                switch (p.value) {
                    .string => |v| {
                        const tag = try std.fmt.allocPrint(a, "{s}={s}", .{ p.key, v });
                        const g = try hist.getOrPutValue(tag, 0);
                        g.value_ptr.* += 1;
                    },
                    else => {},
                }
            }
        }
        try out.print(a, "layer {s}: {d} pts, {d} lines, {d} polys\n", .{ layer.name, c.pts, c.lines, c.polys });
        var it = hist.iterator();
        while (it.next()) |e| try out.print(a, "    {s} x{d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
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
