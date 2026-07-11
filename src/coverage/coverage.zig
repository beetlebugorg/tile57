//! Per-cell coverage carried IN the per-cell PMTiles metadata JSON. The
//! per-cell-composite bake writes one PMTiles per cell whose metadata embeds that
//! cell's M_COVR coverage + compilation scale + identity, so the compositor can
//! rebuild the ownership partition (geo.partition) from the baked archives WITHOUT
//! re-parsing the .000. This round-trips exactly the per-cell facts the partition
//! adapter consumes: coverage rings, cscl, and the (date, name) tie-break keys.
//!
//! Coordinates are S-57's native integer lon/lat (degrees × 1e7), stored VERBATIM as
//! JSON integer pairs `[lon_e7, lat_e7]` — never through f64 — so adjacent cells that
//! digitised a shared border independently round to the same integers and the boolean
//! seam-dissolve stays exact.
//!
//! `band` is a convenience field derived from cscl (bandOf); a consumer re-derives it
//! for correctness rather than trusting the stored value. `cov2` (CATCOV=2 no-data) is
//! a reserved slot, empty today — the s57 side captures only CATCOV=1.

const std = @import("std");
const s57 = @import("s57");

/// One cell's coverage + identity — everything the ownership partition needs to place
/// this cell without re-parsing. Ring geometry is `[feature][ring][point]`, matching
/// `s57.Cell.mcovrCoverage`, so a decoded value plugs straight into the partition
/// adapter. Slices are owned by whoever built or decoded the value.
pub const ChartCoverage = struct {
    name: []const u8, // file basename stem (verbatim — the ownership tie-break name)
    date: []const u8, // post-update DSID ISDT (YYYYMMDD), or "" if absent
    cscl: i32, // compilation scale 1:N (0 = unknown)
    band: u8, // derived bandOf(cscl); convenience/debug only
    bbox: [4]i32, // [w, s, e, n] integer lon/lat (lon_e7/lat_e7)
    cov1: []const []const []const s57.LonLat, // M_COVR CATCOV=1: [feature][ring][point]
    cov2: []const []const []const s57.LonLat = &.{}, // reserved (CATCOV=2 no-data)
    // Sector-figure reach (the metadata's sibling "light_reach" key, null when the
    // cell constructs no figures) — decodeFromMetadata fills it so the compositor
    // can widen tile addressing without re-portraying the cell.
    light_reach: ?LightReach = null,
};

/// Sector-figure reach summary carried beside "coverage" in the per-cell archive
/// metadata (key "light_reach", written only when the cell's portrayal constructs
/// light sector figures): the union bbox of the figure-bearing anchors plus the
/// max ground-length directional-leg span. The compositor widens its tile
/// addressing with the SAME ring the baker used (tiles.tile.lightReachTiles), so
/// legs/arcs survive into neighbouring tiles the cell owns no ground in.
pub const LightReach = struct {
    bbox: [4]f64, // [w, s, e, n] degrees — union of figure-bearing anchors
    range_m: f64 = 0, // max ground-length leg (directional lights), metres
};

/// Serialize a light-reach summary to the JSON object embedded under the
/// metadata's "light_reach" key. Caller owns the returned bytes.
pub fn encodeLightReachJson(a: std.mem.Allocator, lr: LightReach) ![]u8 {
    return std.json.Stringify.valueAlloc(a, lr, .{});
}

/// Build a ChartCoverage from a parsed cell. `name` is the caller's identity string
/// (the file basename stem, matching the coverage loader / ownership oracle) and
/// `band` the caller's `bake_enc.bandOf(cscl)` tag; both keep this module free of the
/// band + loader policy. Coverage rings are allocated in `a`; `name`/`date` are
/// borrowed (encode before the cell is freed).
pub fn fromCell(a: std.mem.Allocator, cell: *const s57.Cell, name: []const u8, band: u8) ChartCoverage {
    const cov1 = cell.mcovrCoverage(a);
    return .{
        .name = name,
        .date = cell.dsid.isdt,
        .cscl = cell.params.cscl,
        .band = band,
        .bbox = bboxOf(cov1),
        .cov1 = cov1,
    };
}

fn bboxOf(polys: []const []const []const s57.LonLat) [4]i32 {
    var b = [4]i32{ std.math.maxInt(i32), std.math.maxInt(i32), std.math.minInt(i32), std.math.minInt(i32) };
    var any = false;
    for (polys) |poly| for (poly) |ring| for (ring) |p| {
        any = true;
        b[0] = @min(b[0], p.lon_e7);
        b[1] = @min(b[1], p.lat_e7);
        b[2] = @max(b[2], p.lon_e7);
        b[3] = @max(b[3], p.lat_e7);
    };
    return if (any) b else .{ 0, 0, 0, 0 };
}

// ---- JSON round-trip -----------------------------------------------------
//
// The wire form uses `[2]i32` points so `std.json` emits compact `[lon,lat]` pairs
// (half the bytes of `{lon_e7,lat_e7}` objects) that round-trip losslessly as
// integers. The on-disk value lives under the "coverage" key of the PMTiles metadata
// object; `encodeJson` emits that value, the writer splices it in.

const P = [2]i32;

const Dto = struct {
    v: u32 = 0,
    name: []const u8 = "",
    date: []const u8 = "",
    cscl: i32 = 0,
    band: u8 = 0,
    bbox: [4]i32 = .{ 0, 0, 0, 0 },
    cov1: []const []const []const P = &.{},
    cov2: []const []const []const P = &.{},
};

// The metadata object as far as this module cares: everything else (name, format,
// vector_layers, scamin) is skipped via ignore_unknown_fields.
const Envelope = struct { coverage: ?Dto = null, light_reach: ?LightReach = null };

/// Serialize `cov` to the JSON object embedded under the metadata's "coverage" key.
/// Caller owns the returned bytes (allocated in `a`).
pub fn encodeJson(a: std.mem.Allocator, cov: ChartCoverage) ![]u8 {
    const dto = Dto{
        .v = 1,
        .name = cov.name,
        .date = cov.date,
        .cscl = cov.cscl,
        .band = cov.band,
        .bbox = cov.bbox,
        .cov1 = try toWire(a, cov.cov1),
        .cov2 = try toWire(a, cov.cov2),
    };
    return std.json.Stringify.valueAlloc(a, dto, .{});
}

/// Extract the coverage embedded in a PMTiles metadata JSON blob, or null if absent /
/// unparseable. The whole result (rings + strings) is allocated in `a`.
pub fn decodeFromMetadata(a: std.mem.Allocator, metadata_json: []const u8) !?ChartCoverage {
    var parsed = std.json.parseFromSlice(Envelope, a, metadata_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit(); // frees the DTO's own arena; the copies below live in `a`
    const dto = parsed.value.coverage orelse return null;
    return ChartCoverage{
        .name = try a.dupe(u8, dto.name),
        .date = try a.dupe(u8, dto.date),
        .cscl = dto.cscl,
        .band = dto.band,
        .bbox = dto.bbox,
        .cov1 = try fromWire(a, dto.cov1),
        .cov2 = try fromWire(a, dto.cov2),
        .light_reach = parsed.value.light_reach, // POD — safe past parsed.deinit()
    };
}

fn toWire(a: std.mem.Allocator, src: []const []const []const s57.LonLat) ![]const []const []const P {
    const polys = try a.alloc([]const []const P, src.len);
    for (src, 0..) |poly, i| {
        const rings = try a.alloc([]const P, poly.len);
        for (poly, 0..) |ring, j| {
            const pts = try a.alloc(P, ring.len);
            for (ring, 0..) |p, k| pts[k] = .{ p.lon_e7, p.lat_e7 };
            rings[j] = pts;
        }
        polys[i] = rings;
    }
    return polys;
}

fn fromWire(a: std.mem.Allocator, src: []const []const []const P) ![]const []const []const s57.LonLat {
    const polys = try a.alloc([]const []const s57.LonLat, src.len);
    for (src, 0..) |poly, i| {
        const rings = try a.alloc([]const s57.LonLat, poly.len);
        for (poly, 0..) |ring, j| {
            const pts = try a.alloc(s57.LonLat, ring.len);
            for (ring, 0..) |p, k| pts[k] = .{ .lon_e7 = p[0], .lat_e7 = p[1] };
            rings[j] = pts;
        }
        polys[i] = rings;
    }
    return polys;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn ll(lon_e7: i32, lat_e7: i32) s57.LonLat {
    return .{ .lon_e7 = lon_e7, .lat_e7 = lat_e7 };
}

test "coverage round-trips through the metadata envelope, integers exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two M_COVR features: a square, and one with a hole (exterior + interior ring).
    const sq = try a.dupe(s57.LonLat, &.{ ll(-763_000_000, 386_000_000), ll(-762_000_000, 386_000_000), ll(-762_000_000, 387_000_000), ll(-763_000_000, 387_000_000) });
    const ext = try a.dupe(s57.LonLat, &.{ ll(0, 0), ll(100, 0), ll(100, 100), ll(0, 100) });
    const hole = try a.dupe(s57.LonLat, &.{ ll(40, 40), ll(60, 40), ll(60, 60), ll(40, 60) });
    const feat0 = try a.dupe([]const s57.LonLat, &.{sq});
    const feat1 = try a.dupe([]const s57.LonLat, &.{ ext, hole });
    const cov1 = try a.dupe([]const []const s57.LonLat, &.{ feat0, feat1 });

    const cov = ChartCoverage{
        .name = "US5MD1MC",
        .date = "20210115",
        .cscl = 20_000,
        .band = 1,
        .bbox = .{ -763_000_000, 0, 100, 387_000_000 },
        .cov1 = cov1,
    };

    const inner = try encodeJson(a, cov);
    // Embed under "coverage" alongside the other metadata keys the decoder must skip.
    const meta = try std.fmt.allocPrint(a, "{{\"name\":\"chartplotter\",\"format\":\"pbf\",\"scamin\":[1000,2000],\"coverage\":{s}}}", .{inner});

    const got = (try decodeFromMetadata(a, meta)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("US5MD1MC", got.name);
    try testing.expectEqualStrings("20210115", got.date);
    try testing.expectEqual(@as(i32, 20_000), got.cscl);
    try testing.expectEqual(@as(u8, 1), got.band);
    try testing.expectEqual([4]i32{ -763_000_000, 0, 100, 387_000_000 }, got.bbox);
    try testing.expectEqual(@as(usize, 2), got.cov1.len);
    try testing.expectEqual(@as(usize, 1), got.cov1[0].len); // square: one ring
    try testing.expectEqual(@as(usize, 2), got.cov1[1].len); // holed: exterior + hole
    // A vertex survives byte-exact (no f64 round-trip).
    try testing.expectEqual(ll(-763_000_000, 386_000_000), got.cov1[0][0][0]);
    try testing.expectEqual(ll(60, 60), got.cov1[1][1][2]);
    try testing.expectEqual(@as(usize, 0), got.cov2.len);
}

test "metadata without a coverage key decodes to null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const meta = "{\"name\":\"chartplotter\",\"format\":\"pbf\",\"scamin\":[1000]}";
    try testing.expect((try decodeFromMetadata(a, meta)) == null);
}

test "bboxOf spans all rings; empty coverage yields a zero bbox" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ring = try a.dupe(s57.LonLat, &.{ ll(-5, -3), ll(7, -3), ll(7, 9), ll(-5, 9) });
    const feat = try a.dupe([]const s57.LonLat, &.{ring});
    const cov1 = try a.dupe([]const []const s57.LonLat, &.{feat});
    try testing.expectEqual([4]i32{ -5, -3, 7, 9 }, bboxOf(cov1));
    try testing.expectEqual([4]i32{ 0, 0, 0, 0 }, bboxOf(&.{}));
}
