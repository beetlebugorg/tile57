const std = @import("std");
const compose = @import("compose");
const chart = @import("chart");
const render = @import("render");
const sprite = @import("sprite");
const common = @import("common.zig");

/// `gpudbg atlas` — build the three label-tier SDF atlases twice and report their
/// dimensions + a sample glyph UV, to check the chart.zig build (tile57's quad UVs)
/// and the capi build (the host's texture) produce the SAME layout.
fn dumpAtlas(io: std.Io, a: std.mem.Allocator) !void {
    const cps = try sprite.glyph.defaultCodepoints(a);
    const faces = [_]struct { name: []const u8, font: []const u8 }{
        .{ .name = "regular", .font = render.font.notosans },
        .{ .name = "bold", .font = render.font.notosans_bold },
        .{ .name = "italic", .font = render.font.notosans_italic },
    };
    for (faces) |fc| {
        var at1 = try sprite.glyph.build(a, fc.font, cps, 32.0, 6);
        var at2 = try sprite.glyph.build(a, fc.font, cps, 32.0, 6);
        const gA1 = at1.info('A').?;
        const gA2 = at2.info('A').?;
        std.debug.print("{s}: {d}x{d} vs {d}x{d} | 'A' uv0=({d:.4},{d:.4}) vs ({d:.4},{d:.4}) {s}\n", .{
            fc.name,      at1.width, at1.height, at2.width, at2.height,
            gA1.u0,       gA1.v0,    gA2.u0,     gA2.v0,
            if (at1.height == at2.height and gA1.v0 == gA2.v0) "MATCH" else "MISMATCH",
        });
        // Write the atlas PNG for a visual check.
        if (try at1.encodePng(a)) |png| {
            const path = try std.fmt.allocPrint(a, "/tmp/atlas_{s}.png", .{fc.name});
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
        }
    }
}

/// `gpudbg <archive-dir> <lon> <lat> <zoom>` — render the GPU VIEW scene (labels
/// assembled via the declutter pool) and report the SDF-glyph quad weights, to
/// verify the bold tier reaches the GPU vertex buffer (Quad.weight, offset 28 of
/// tile57_gpu_quad).
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len >= 3 and std.mem.eql(u8, args[2], "atlas")) return dumpAtlas(io, a);
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
    const gs = chart.renderComposeGpuScene(src, lon, lat, zoom, 900, 700, .day, &settings, 1.0) catch |e| {
        std.debug.print("gpu scene error: {s}\n", .{@errorName(e)});
        return;
    };
    defer gs.deinit();

    var total: usize = 0;
    var weighted: usize = 0;
    var maxw: f32 = 0;
    var flipped: usize = 0; // contour-value quads (flip=1, map-aligned, tangent set)
    var sample_off: ?[2]f32 = null;
    var sample_tan: u8 = 0;
    for (gs.scene.quads) |q| {
        total += 1;
        if (q.weight > 0) {
            weighted += 1;
            maxw = @max(maxw, q.weight);
        }
        if (q.flip != 0) {
            flipped += 1;
            if (sample_off == null and (q.ox != 0 or q.oy != 0)) {
                sample_off = .{ q.ox, q.oy };
                sample_tan = q.tangent_q;
            }
        }
    }
    std.debug.print("gpu view {d},{d} z{d}: {d} quads, {d} with weight>0 (max {d:.3})\n", .{ lon, lat, zoom, total, weighted, maxw });
    // A contour value's quads must be tangent-rotated (a non-axis-aligned corner
    // offset) and flagged for the shader's uprightness flip.
    if (sample_off) |off| {
        const deg = @as(f32, @floatFromInt(sample_tan)) / 256.0 * 360.0;
        std.debug.print("contour-label quads: {d} (flip=1, map-aligned); sample corner off=({d:.2},{d:.2}) tangent~{d:.0}deg\n", .{ flipped, off[0], off[1], deg });
    } else {
        std.debug.print("contour-label quads: {d}\n", .{flipped});
    }
}
