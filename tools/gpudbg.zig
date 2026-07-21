const std = @import("std");
const compose = @import("compose");
const chart = @import("chart");
const render = @import("render");
const common = @import("common.zig");

/// `gpudbg <archive-dir> <lon> <lat> <zoom>` — render the GPU VIEW scene (labels
/// assembled via the declutter pool) and report the SDF-glyph quad weights, to
/// verify the bold tier reaches the GPU vertex buffer (Quad.weight, offset 28 of
/// tile57_gpu_quad).
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 6) return common.usageErr("gpudbg <archive-dir> <lon> <lat> <zoom>");
    const dir = args[2];
    const lon = std.fmt.parseFloat(f64, args[3]) catch return common.usageErr("bad lon");
    const lat = std.fmt.parseFloat(f64, args[4]) catch return common.usageErr("bad lat");
    const zoom = std.fmt.parseFloat(f64, args[5]) catch return common.usageErr("bad zoom");

    var paths = std.ArrayList([]const u8).empty;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return common.usageErr("cannot open dir");
    defer d.close(io);
    var walker = d.walk(a) catch return common.usageErr("cannot walk dir");
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".pmtiles")) continue;
        paths.append(a, std.fs.path.join(a, &.{ dir, entry.path }) catch continue) catch {};
    }
    const src = (compose.ComposeSource.openFiles(io, a, paths.items, null) catch return common.usageErr("open failed")) orelse
        return common.usageErr("no coverage archives");
    defer src.deinit();

    var settings = render.resolve.Settings{ .display_other = true };
    const gs = chart.renderComposeGpuScene(src, lon, lat, zoom, 900, 700, .day, &settings) catch |e| {
        std.debug.print("gpu scene error: {s}\n", .{@errorName(e)});
        return;
    };
    defer gs.deinit();

    var total: usize = 0;
    var weighted: usize = 0;
    var maxw: f32 = 0;
    for (gs.scene.quads) |q| {
        total += 1;
        if (q.weight > 0) {
            weighted += 1;
            maxw = @max(maxw, q.weight);
        }
    }
    std.debug.print("gpu view {d},{d} z{d}: {d} quads, {d} with weight>0 (max {d:.3})\n", .{ lon, lat, zoom, total, weighted, maxw });
}
