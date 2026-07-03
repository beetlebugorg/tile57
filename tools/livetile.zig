const std = @import("std");
const engine = @import("engine");
const chart = @import("chart"); // streaming ENC_ROOT open + quilted view render

// Dump one LIVE tile from an ENC_ROOT (chart.zig lazy path — the same code
// the host's live cell-backed set serves), decoded like `inspect`, so the
// live and bake pipelines can be diffed feature-by-feature.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = io;
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
    const layers = try engine.mvt.decode(a, bytes);
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
