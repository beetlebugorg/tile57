//! tile57 tiledump <tile.mlt|tile.mvt> — decode ONE raw (decompressed) vector
//! tile and summarise it: per-layer feature counts by geometry type, plus value
//! histograms for the properties that identify portrayal output (class,
//! symbol_name, ls). For debugging what a bake or the compositor actually put
//! in a tile.

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
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--prop") and i + 1 < args.len) {
            extra_prop = args[i + 1];
            i += 1;
        }
    }

    const layers = engine.mlt.decode(a, bytes) catch |mlt_err| blk: {
        break :blk engine.mvt.decode(a, bytes) catch {
            std.debug.print("not a decodable MLT ({s}) or MVT tile\n", .{@errorName(mlt_err)});
            return;
        };
    };

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
