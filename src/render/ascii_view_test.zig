//! Engine test for the ASCII backend: drive the REAL embedded S-101 Lua rules
//! over a tiny in-memory fixture cell, run the render engine through
//! scene.generateView with an AsciiSurface, and assert STRUCTURAL properties
//! of the text grid (dimensions, land/water characters where the fixture put
//! them) — deliberately not byte-golden, so portrayal-rule tweaks that don't
//! change the geography don't churn this test.
//!
//! End-to-end seam: portray -> instruction parse -> geometry/clip -> Surface
//! calls -> character lowering -> op sort -> grid -> UTF-8 rows.
//!
//! Own test artifact: `portray` links libc + Lua + the rule registry.

const std = @import("std");
const s57 = @import("s57");
const portray = @import("portray");
const scene = @import("scene");
const render = @import("render");
const tile = @import("tiles").tile;

// The embedded S-101 color profile (ANSI mode resolves through it; the plain
// render below never consults it, but the surface takes it either way).
const colorprofile_registry = @import("colorprofile_registry");

test "ascii view: water shades left, land '#' right, coastline between" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fixture inside tile z8/128/96 (lon 0..1.4, lat ~32): DEPARE (2..5 m)
    // fills the WEST half, LNDARE the EAST half, COALNE runs between them.
    const z: u8 = 8;
    const x: u32 = 128;
    const y: u32 = 96;
    const tb = tile.tileBoundsLonLat(z, x, y);
    const w = tb[2] - tb[0];
    const h = tb[3] - tb[1];

    const depare_attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "2" },
        .{ .code = s57.ATTR_DRVAL2, .value = "5" },
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &depare_attrs }, // DEPARE
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 71 }, // LNDARE
        .{ .rcnm = 100, .rcid = 3, .prim = 2, .objl = 30 }, // COALNE
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

    // Pre-assembled geometry (CellRef.geo), like the pixel golden test.
    const water_ring = [_]s57.LonLat{
        s57.LonLat.init(tb[0], tb[1]),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1]),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1] + h),
        s57.LonLat.init(tb[0], tb[1] + h),
        s57.LonLat.init(tb[0], tb[1]),
    };
    const land_ring = [_]s57.LonLat{
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1]),
        s57.LonLat.init(tb[2], tb[1]),
        s57.LonLat.init(tb[2], tb[1] + h),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1] + h),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1]),
    };
    const coast_line = [_]s57.LonLat{
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1]),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1] + h),
    };
    const geo = try a.alloc(?[][]s57.LonLat, 3);
    inline for (.{ water_ring, land_ring, coast_line }, 0..) |part, i| {
        const parts = try a.alloc([]s57.LonLat, 1);
        parts[0] = try a.dupe(s57.LonLat, &part);
        geo[i] = parts;
    }

    portray.setQuiet(true);
    const streams = try portray.portrayCell(a, &cell, "");

    var colors = try render.resolve.Colors.init(a, colorprofile_registry.entries[0].bytes);
    const settings = render.resolve.MarinerSettings{};
    // 64x32 chars = a 64x64 px view at z8 (px_per_tile 256), centred on the
    // tile: the whole grid sits inside the fixture, split down the middle.
    const cols: u32 = 64;
    const rows: u32 = 32;
    var as = render.ascii.AsciiSurface.initView(a, &colors, .day, &settings, 8.0, cols, rows, 256.0, tile.EXTENT);

    const cells = [_]scene.CellRef{.{ .cell = &cell, .portrayal = streams, .geo = geo }};
    const text = try scene.generateView(&as, a, a, &cells, (tb[0] + tb[2]) / 2, (tb[1] + tb[3]) / 2, 8.0, false);

    // Exact dimensions: `rows` '\n'-terminated rows of `cols` codepoints.
    var grid = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue; // trailing split after the last '\n'
        try std.testing.expectEqual(@as(usize, cols), try std.unicode.utf8CountCodepoints(row));
        try grid.append(a, row);
    }
    try std.testing.expectEqual(@as(usize, rows), grid.items.len);

    // The geography landed where the fixture put it: land '#' fills the east
    // half, a DEPARE water shade the west, the coastline strokes '|' between.
    var land: usize = 0;
    for (grid.items) |row| land += std.mem.count(u8, row, "#");
    try std.testing.expect(land > cols * rows / 4);
    const mid = grid.items[rows / 2];
    var cps = (try std.unicode.Utf8View.init(mid)).iterator();
    var c: u32 = 0;
    var west: u21 = 0;
    var east: u21 = 0;
    while (cps.nextCodepoint()) |cp| : (c += 1) {
        if (c == cols / 4) west = cp;
        if (c == 3 * cols / 4) east = cp;
    }
    try std.testing.expectEqual(@as(u21, '#'), east);
    // A shallow DEPARE lowers to one of the water shades — which one depends
    // on the rule's contour context, so accept the ramp, not one shade.
    try std.testing.expect(west == '▒' or west == '░' or west == '~' or west == '%');
    try std.testing.expect(std.mem.indexOf(u8, text, "|") != null);
}
