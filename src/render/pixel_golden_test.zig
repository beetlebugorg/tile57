//! Golden-image test for the pixel path (Gate 2): drive the REAL embedded
//! S-101 Lua rules over a tiny in-memory fixture cell, run the render engine
//! through generateTileSurface with a PixelSurface, and hash the PNG bytes.
//!
//! End-to-end seam: portray -> instruction parse -> geometry/clip -> Surface
//! calls -> resolver (embedded colorProfile) -> op sort -> RasterCanvas -> PNG.
//! Re-bless the sha only via an explicit commit after eyeballing the image
//! (the test always writes /tmp/tile57-pixel-golden.png for that).
//!
//! Own test artifact: `portray` links libc + Lua + the rule registry.

const std = @import("std");
const s57 = @import("s57");
const portray = @import("portray");
const scene = @import("scene");
const render = @import("render");
const tile = @import("tiles").tile;

// The embedded S-101 color profile (same bytes colortables.json is built from).
const colorprofile_registry = @import("colorprofile_registry");

test "golden PNG: depth-area fill + coastline stroke through the pixel path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fixture: one DEPARE (5..10 m) square + one COALNE polyline crossing it,
    // placed inside tile z8/128/96 (lon 0..1.4, lat ~32).
    const z: u8 = 8;
    const x: u32 = 128;
    const y: u32 = 96;
    const tb = tile.tileBoundsLonLat(z, x, y);
    const w = tb[2] - tb[0];
    const h = tb[3] - tb[1];

    const depare_attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "5" },
        .{ .code = s57.ATTR_DRVAL2, .value = "10" },
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &depare_attrs }, // DEPARE
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = 30 }, // COALNE
    };
    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = std.AutoHashMap(u32, usize).init(a),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    // Pre-assembled geometry (CellRef.geo), like the engine's variant tests:
    // DEPARE ring inset 25% into the tile; COALNE cuts across diagonally.
    const ring = [_]s57.LonLat{
        s57.LonLat.init(tb[0] + 0.25 * w, tb[1] + 0.25 * h),
        s57.LonLat.init(tb[0] + 0.75 * w, tb[1] + 0.25 * h),
        s57.LonLat.init(tb[0] + 0.75 * w, tb[1] + 0.75 * h),
        s57.LonLat.init(tb[0] + 0.25 * w, tb[1] + 0.75 * h),
        s57.LonLat.init(tb[0] + 0.25 * w, tb[1] + 0.25 * h),
    };
    const coast = [_]s57.LonLat{
        s57.LonLat.init(tb[0] + 0.10 * w, tb[1] + 0.15 * h),
        s57.LonLat.init(tb[0] + 0.60 * w, tb[1] + 0.55 * h),
        s57.LonLat.init(tb[0] + 0.90 * w, tb[1] + 0.90 * h),
    };
    const ring_parts = try a.alloc([]s57.LonLat, 1);
    ring_parts[0] = try a.dupe(s57.LonLat, &ring);
    const coast_parts = try a.alloc([]s57.LonLat, 1);
    coast_parts[0] = try a.dupe(s57.LonLat, &coast);
    const geo = try a.alloc(?[][]s57.LonLat, 2);
    geo[0] = ring_parts;
    geo[1] = coast_parts;

    portray.setQuiet(true);
    const streams = try portray.portrayCell(a, &cell, "");

    var colors = try render.resolve.Colors.init(a, colorprofile_registry.entries[0].bytes);
    const settings = render.resolve.MarinerSettings{};
    var ps = render.pixel.PixelSurface.init(a, &colors, .day, &settings, @floatFromInt(z), 256, tile.EXTENT);

    const cells = [_]scene.CellRef{.{ .cell = &cell, .portrayal = streams, .geo = geo }};
    const bytes = try scene.generateTileSurface(a, a, &cells, z, x, y, false, ps.asSurface());

    // Always drop the image for eyeballing / re-blessing.
    {
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/tile57-pixel-golden.png", .data = bytes }) catch {};
    }

    // Sanity before the golden: something was buffered and painted.
    try std.testing.expect(ps.ops.items.len >= 2);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, bytes[0..4]);

    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha, .{});
    const hex = std.fmt.bytesToHex(sha, .lower);
    // GOLDEN — re-bless via explicit commit after inspecting the PNG above.
    // Blessed 2026-07-01: grey NODTA ground, DEPARE 5-10m blue fill inset 25%,
    // dark CSTLN coastline crossing SW->NE with AA and round joins.
    try std.testing.expectEqualStrings("2ac9be7a907a108bbd7fb7a264fa9914ab7efe133ecf6ccfedd0b5111eda9303", &hex);
}
