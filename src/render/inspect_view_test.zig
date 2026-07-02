//! Engine test for the RECORDING backend (render/inspect.zig): drive the REAL
//! embedded S-101 Lua rules over a tiny in-memory fixture cell, run the render
//! engine through scene.appendTile with an InspectSurface, and assert that each
//! feature's THREE data levels line up — the same collection the `tile57 explore`
//! CLI performs:
//!
//!   1. raw S-57      — FeatureMeta.class / .s57_json on the recorded feature
//!   2. S-101 stream  — portray.portrayCell → s101_instr.parse
//!   3. resolved calls — the Surface calls the InspectSurface captured
//!
//! End-to-end seam: portray -> instruction parse -> geometry/clip -> Surface
//! calls -> recorded structure. Own test artifact, like ascii_view_test: `portray`
//! links libc + Lua + the rule registry.

const std = @import("std");
const s57 = @import("s57");
const portray = @import("portray");
const scene = @import("scene");
const render = @import("render");
const tile = @import("tiles").tile;

// Find the first recorded feature of an S-57 object-class acronym.
fn byClass(is: *const render.inspect.InspectSurface, acr: []const u8) ?render.inspect.RecordedFeature {
    for (is.features.items) |rf| {
        if (std.mem.eql(u8, rf.meta.class, acr)) return rf;
    }
    return null;
}

test "inspect view: real rules -> InspectSurface records the 3 levels per feature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fixture inside tile z8/128/96: a DEPARE (2..5 m) area filling the WEST half,
    // a COALNE line down the middle, and a BOYLAT lateral buoy at the centre.
    const z: u8 = 8;
    const x: u32 = 128;
    const y: u32 = 96;
    const tb = tile.tileBoundsLonLat(z, x, y);
    const w = tb[2] - tb[0];
    const h = tb[3] - tb[1];
    const clon = (tb[0] + tb[2]) / 2;
    const clat = (tb[1] + tb[3]) / 2;

    const depare_attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "2" },
        .{ .code = s57.ATTR_DRVAL2, .value = "5" },
    };
    const buoy_attrs = [_]s57.Attr{
        .{ .code = 23, .value = "1" }, // CATLAM: port-hand
        .{ .code = s57.ATTR_COLOUR, .value = "3" }, // red
        .{ .code = s57.ATTR_OBJNAM, .value = "Test Buoy 5" },
    };
    // The buoy is a POINT feature pointing at an isolated node (VI) at the centre.
    const buoy_refs = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 5001 }, .ornt = 255 }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &depare_attrs }, // DEPARE
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = 30 }, // COALNE
        .{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 17, .foid = 0xB0501, .attrs = &buoy_attrs, .refs = &buoy_refs }, // BOYLAT
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
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 5001, s57.LonLat.init(clon, clat));

    // Pre-assembled geometry (CellRef.geo), parallel to cell.features. Area + line
    // carry rings/lines; the point feature's slot is null (it uses the node above).
    const water_ring = [_]s57.LonLat{
        s57.LonLat.init(tb[0], tb[1]),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1]),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1] + h),
        s57.LonLat.init(tb[0], tb[1] + h),
        s57.LonLat.init(tb[0], tb[1]),
    };
    const coast_line = [_]s57.LonLat{
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1]),
        s57.LonLat.init(tb[0] + 0.5 * w, tb[1] + h),
    };
    const geo = try a.alloc(?[][]s57.LonLat, 3);
    inline for (.{ water_ring, coast_line }, 0..) |part, i| {
        const parts = try a.alloc([]s57.LonLat, 1);
        parts[0] = try a.dupe(s57.LonLat, &part);
        geo[i] = parts;
    }
    geo[2] = null; // the buoy is a point (node geometry)

    // Level 2 source: the real S-101 instruction streams (indexed by feature).
    portray.setQuiet(true);
    const streams = try portray.portrayCell(a, &cell, "");
    try std.testing.expectEqual(@as(usize, 3), streams.len);

    // Level 3: drive the recording surface over the single covering tile.
    var is = render.inspect.InspectSurface.init(a);
    const surf = is.asSurface();
    try surf.beginScene(z);
    const cells = [_]scene.CellRef{.{ .cell = &cell, .portrayal = streams, .geo = geo }};
    try scene.appendTile(surf, a, &cells, z, x, y, true);
    _ = try surf.endScene(a);

    try std.testing.expect(is.features.items.len >= 3);

    // --- DEPARE: level 1 meta carries the class + attribute blob; level 3 is a
    //     depth-shade area fill. ---
    const depare = byClass(&is, "DEPARE") orelse return error.NoDepare;
    try std.testing.expect(std.mem.indexOf(u8, depare.meta.s57_json, "DRVAL1") != null); // level 1
    var depare_fill: ?[]const u8 = null;
    for (depare.calls.items) |c| switch (c) {
        .fill_area => |fa| depare_fill = fa.token,
        else => {},
    };
    try std.testing.expect(depare_fill != null); // level 3: an area fill happened
    try std.testing.expect(std.mem.startsWith(u8, depare_fill.?, "DEP")); // a depth-shade token

    // Its level-2 stream parses to a fill instruction (ColorFill:DEP..).
    const depare_parsed = try @import("s100").s101_instr.parse(a, streams[0].?);
    try std.testing.expect(depare_parsed.fill_token != null);

    // --- COALNE: a line feature resolves to a stroke. ---
    const coalne = byClass(&is, "COALNE") orelse return error.NoCoalne;
    var coalne_stroked = false;
    for (coalne.calls.items) |c| switch (c) {
        .stroke_line => coalne_stroked = true,
        else => {},
    };
    try std.testing.expect(coalne_stroked);

    // --- BOYLAT: level 1 name is in the blob; level 2 emits a PointInstruction;
    //     level 3 draws a point symbol at the buoy node. ---
    const buoy = byClass(&is, "BOYLAT") orelse return error.NoBuoy;
    try std.testing.expect(std.mem.indexOf(u8, buoy.meta.s57_json, "OBJNAM") != null); // level 1

    const buoy_parsed = try @import("s100").s101_instr.parse(a, streams[2].?);
    try std.testing.expect(buoy_parsed.points.len >= 1); // level 2: a symbol instruction

    var buoy_symbol: ?[]const u8 = null;
    for (buoy.calls.items) |c| switch (c) {
        .draw_symbol => |ds| buoy_symbol = ds.name,
        else => {},
    };
    try std.testing.expect(buoy_symbol != null); // level 3: a point symbol was drawn
    try std.testing.expect(buoy_symbol.?.len > 0);
}
