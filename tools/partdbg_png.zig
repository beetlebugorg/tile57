//! Render one tile of a partition-debug PMTiles to a PNG — a self-check that the
//! ownership faces actually fill. Each "partition" feature is filled with its
//! `color` property using the nonzero rule (what MapLibre uses), so a blank output
//! means the geometry itself is wrong, not the viewer.
//!
//!   tile57 partdbg-png <file.pmtiles> <z> <x> <y> <out.png>

const std = @import("std");
const engine = @import("engine");
const render = @import("render");
const cv = render.canvas;

fn hex(s: []const u8) cv.Color {
    if (s.len < 7 or s[0] != '#') return .{ .r = 200, .g = 200, .b = 200 };
    const v = std.fmt.parseInt(u32, s[1..7], 16) catch return .{ .r = 200, .g = 200, .b = 200 };
    return .{ .r = @intCast((v >> 16) & 0xff), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff), .a = 210 };
}

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 7) {
        std.debug.print("usage: tile57 partdbg-png <file.pmtiles> <z> <x> <y> <out.png>\n", .{});
        return;
    }
    const path = args[2];
    const z = try std.fmt.parseInt(u8, args[3], 10);
    const x = try std.fmt.parseInt(u32, args[4], 10);
    const y = try std.fmt.parseInt(u32, args[5], 10);
    const out = args[6];

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var r = try engine.pmtiles.Reader.init(a, bytes);
    defer r.deinit();
    const tb = (try r.getTile(a, z, x, y)) orelse {
        std.debug.print("tile {d}/{d}/{d} not found\n", .{ z, x, y });
        return;
    };
    const layers = try engine.mvt.decode(a, tb);

    const W: u32 = 1024;
    var rc = try render.raster.RasterCanvas.init(a, W, W);
    defer rc.deinit();
    rc.clear(.{ .r = 18, .g = 22, .b = 26 });
    const canvas = rc.asCanvas();
    const sc: f32 = @as(f32, @floatFromInt(W)) / 4096.0;

    var n: usize = 0;
    for (layers) |L| {
        if (!std.mem.eql(u8, L.name, "partition")) continue;
        for (L.features) |f| {
            var col = cv.Color{ .r = 200, .g = 200, .b = 200, .a = 210 };
            for (f.properties) |pr| if (std.mem.eql(u8, pr.key, "color") and pr.value == .string) {
                col = hex(pr.value.string);
            };
            var rings = std.ArrayList([]const cv.Point).empty;
            for (f.parts) |ring| {
                const rr = try a.alloc(cv.Point, ring.len);
                for (ring, 0..) |p, i| rr[i] = .{ .x = @as(f32, @floatFromInt(p.x)) * sc, .y = @as(f32, @floatFromInt(p.y)) * sc };
                try rings.append(a, rr);
            }
            try canvas.fillPath(rings.items, col, .nonzero);
            n += 1;
        }
    }
    const png = try render.png.encodeRgba(a, rc.px, W, W);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = png });
    std.debug.print("rendered {d} partition features from {d}/{d}/{d} -> {s}\n", .{ n, z, x, y, out });
}
