//! Light-sector reach: how far a LIGHTS feature's sector legs/arcs reach, so the
//! baker and the emitter widen the LIGHTS spatial-cull margin enough that a
//! directional light's ground legs are not dropped on the tiles they cross.
//! Pure over s57.

const std = @import("std");
const s57 = @import("s57");

// The reach bounds live in the tiles leaf (tiles.tile) so the runtime
// compositor — a dependency leaf without the scene — applies the SAME ring
// when it pulls a cell's figures into neighbouring tiles. Re-exported here
// for the baker/emitter callers. GROUND-length legs (directional lights:
// nmi2metres(nominal range), LightSectored.lua) exceed the mm bound by far
// at fine zooms — lightReachTiles is the honest per-zoom bound.
pub const LIGHT_AUG_REACH_TILES = @import("tiles").tile.LIGHT_AUG_REACH_TILES;
pub const lightReachTiles = @import("tiles").tile.lightReachTiles;

/// How far a cell's constructed sector figures (emitAugFigures) can reach beyond
/// their feature anchors, summarised per cell so tile addressing (bake_enc
/// buildTileMap / the live tileRefs) can include the cell in neighbouring tiles
/// its raw bbox never touches — otherwise legs/arcs clip exactly at the boundary.
pub const LightReach = struct {
    /// Union bbox [w,s,e,n] of the aug-figure-bearing features' anchors (feature
    /// nodes + explicit AugmentedPoint anchors); null = no sector figures at all.
    bbox: ?[4]f64 = null,
    /// Max ground-distance leg length in metres (AugmentedRay with a GeographicCRS
    /// length — directional-light legs); 0 = display-mm figures only.
    range_m: f64 = 0,
};

// The nth comma-separated field of an instruction argument ("" past the end).
fn instrCsv(s: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) if (i == n) return std.mem.trim(u8, part, " ");
    return "";
}

// Fold one aug-figure-bearing feature's anchors + ground length into `r`:
// the feature node plus any explicit AugmentedPoint anchors in the stream.
fn foldLightReach(r: *LightReach, cell: *const s57.Cell, f: s57.Feature, stream: []const u8) void {
    var b: [4]f64 = if (r.bbox) |bb| bb else .{ 1e9, 1e9, -1e9, -1e9 };
    if (cell.pointGeometry(f)) |pg| {
        b[0] = @min(b[0], pg.lon());
        b[1] = @min(b[1], pg.lat());
        b[2] = @max(b[2], pg.lon());
        b[3] = @max(b[3], pg.lat());
    }
    var it = std.mem.splitScalar(u8, stream, ';');
    while (it.next()) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const key = item[0..colon];
        const val = item[colon + 1 ..];
        if (std.mem.eql(u8, key, "AugmentedRay")) {
            // "AugmentedRay:<bearingCRS>,<bearing>,<lenCRS>,<len>" — a GeographicCRS
            // length is ground metres (the directional-light leg); else display mm.
            if (std.mem.eql(u8, instrCsv(val, 2), "GeographicCRS")) {
                const len = std.fmt.parseFloat(f64, instrCsv(val, 3)) catch 0;
                r.range_m = @max(r.range_m, len);
            }
        } else if (std.mem.eql(u8, key, "AugmentedPoint")) {
            // "AugmentedPoint:<CRS>,<lon>,<lat>" — an explicit figure anchor.
            const lon = std.fmt.parseFloat(f64, instrCsv(val, 1)) catch continue;
            const lat = std.fmt.parseFloat(f64, instrCsv(val, 2)) catch continue;
            b[0] = @min(b[0], lon);
            b[1] = @min(b[1], lat);
            b[2] = @max(b[2], lon);
            b[3] = @max(b[3], lat);
        }
    }
    if (b[0] <= b[2]) r.bbox = b;
}

/// EXACT per-cell sector-figure reach, from the portrayal instruction streams:
/// a feature constructs figures iff its stream carries AugmentedRay/ArcByRadius
/// (LightSectored legs/arcs), so this can't drift from what emitAugFigures will
/// actually draw (including context-parameter effects like FullLightLines).
/// Only prim==1 features can emit figures (processFeatureParsed). Allocation-free.
pub fn collectLightReach(cell: *const s57.Cell, portrayal: ?[]const ?[]const u8) LightReach {
    var r = LightReach{};
    const streams = portrayal orelse return r;
    for (cell.features, 0..) |f, fi| {
        if (f.prim != 1 or fi >= streams.len) continue;
        const stream = streams[fi] orelse continue;
        if (std.mem.indexOf(u8, stream, "AugmentedRay:") == null and
            std.mem.indexOf(u8, stream, "ArcByRadius:") == null) continue;
        foldLightReach(&r, cell, f, stream);
    }
    return r;
}

test "collectLightReach: AugmentedRay ground legs + anchors from the streams" {
    const gpa = std.testing.allocator;
    const feats = [_]s57.Feature{
        // A directional light: GeographicCRS leg 16668 m + a sector arc.
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 75, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }} },
        // A plain sectored light: LocalCRS (display-mm) legs only.
        .{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = 75, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 2 }, .ornt = 255 }} },
        // A buoy with no figures at all.
        .{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 14, .refs = &.{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 3 }, .ornt = 255 }} },
    };
    var cell = s57.Cell{
        .params = .{ .cscl = 80_000 },
        .vectors = &.{},
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa),
        .edges = std.AutoHashMap(u32, usize).init(gpa),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer cell.deinit();
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(-76.52, 39.20));
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 2, s57.LonLat.init(-76.40, 39.30));
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 3, s57.LonLat.init(-76.10, 39.10));

    const streams = [_]?[]const u8{
        "ViewingGroup:27070;DrawingPriority:8;AugmentedRay:GeographicCRS,45.0,GeographicCRS,16668;LineStyle:dash,3.51,0.32,CHBLK;LineInstruction:_simple_;ClearGeometry",
        "DrawingPriority:8;AugmentedRay:GeographicCRS,120.0,LocalCRS,25.0;LineInstruction:_simple_;ArcByRadius:0,0,20,120,90;LineInstruction:_simple_;ClearGeometry",
        "DrawingPriority:7;PointInstruction:BOYLAT01",
    };
    const r = collectLightReach(&cell, &streams);
    // Ground range from the directional leg only; mm-only figures add no range.
    try std.testing.expectEqual(@as(f64, 16668), r.range_m);
    // The bbox unions BOTH figure-bearing lights, not the figuresless buoy.
    const bb = r.bbox orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, -76.52), bb[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 39.20), bb[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -76.40), bb[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 39.30), bb[3], 1e-9);

    // No streams at all -> no reach.
    try std.testing.expectEqual(@as(?[4]f64, null), collectLightReach(&cell, null).bbox);

    // An explicit AugmentedPoint anchor extends the bbox beyond the node.
    const anchored = [_]?[]const u8{
        "AugmentedPoint:GeographicCRS,-76.60,39.10;ArcByRadius:0,0,25,0,360;LineInstruction:_simple_;ClearGeometry",
        null,
        null,
    };
    const ra = collectLightReach(&cell, &anchored);
    const ab = ra.bbox orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, -76.60), ab[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 39.10), ab[1], 1e-9);
}
