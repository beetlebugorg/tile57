const std = @import("std");
const engine = @import("engine");

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 inspect <file.pmtiles> [z x y]\n", .{});
        return;
    }
    const path = args[2];
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var r = try engine.pmtiles.Reader.init(a, data);
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
        if (try r.getTile(a, z, x, y)) |tile| {
            {
                // Optional trailing `-o FILE` writes the raw (decompressed) tile
                // bytes out, so tiledump and friends can chew on the same tile.
                var ai: usize = 6;
                while (ai + 1 < args.len) : (ai += 1) {
                    if (std.mem.eql(u8, args[ai], "-o")) {
                        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[ai + 1], .data = tile });
                        std.debug.print("  wrote {s} ({d} bytes)\n", .{ args[ai + 1], tile.len });
                    }
                }
                // Decode with the codec matching the archive's tile type — both
                // return the same DecodedLayer shape, so the dump below is shared.
                const layers = if (h.tile_type == .mlt)
                    try engine.mlt.decode(a, tile)
                else
                    try engine.mvt.decode(a, tile);
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
