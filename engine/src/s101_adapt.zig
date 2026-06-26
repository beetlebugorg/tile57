//! S-57 -> S-101 feature adaptation for the portrayal engine: map each S-57
//! feature's object class to its S-101 feature class name and translate the
//! S-57 attribute codes the rules read into S-101 attribute names. A minimal,
//! growing port of internal/engine/s101/complex.go (resolveCode + buildRoot).
//!
//! The adapted features feed the Host* callbacks; geometry stays in s57.Cell and
//! is attached when instructions are translated to MVT.

const std = @import("std");
const s57 = @import("s57.zig");
const catalogue = @import("catalogue.zig");

pub const NameVal = struct { name: []const u8, value: []const u8 };

/// A synthesized S-101 complex attribute instance: a named group of simple
/// sub-attributes (NameVal). S-57 stores many of these flat (one simple per
/// feature) while the rules read them as complex; we wrap the flat value(s) back
/// into one instance. Carries featureName (from OBJNAM) and zoneOfConfidence
/// (from M_QUAL CATZOC). The Host* path serves them via tgp_complex_count /
/// tgp_complex_attr keyed by the attributePath's leading complex name.
pub const ComplexAttr = struct {
    name: []const u8, // S-101 complex attribute name, e.g. "featureName"
    subs: []NameVal, // simple sub-attribute name -> value (one instance)
};

pub const Adapted = struct {
    feature_index: usize, // index into cell.features (for geometry)
    code: []const u8, // S-101 feature class name (== rule file name)
    primitive: []const u8, // "Point" | "Curve" | "Surface"
    attrs: []NameVal, // S-101 attribute name -> value
    complex: []ComplexAttr = &.{}, // synthesized complex attributes
    // Point geometry (lon, lat, z) served to the rules via _HostFeaturePoints, so
    // HostGetSpatial can return a real Point for `#P` features — the S-101
    // framework's GetSpatial re-enters forever on a nil Point (the OBSTRN/WRECKS
    // "C stack overflow"). One entry for a point feature; empty otherwise.
    points: []const [3]f64 = &.{},
};

// --- Derived depth attributes (S-52 DEPVAL) --------------------------------
// Under/awash dangers (Obstruction/Wreck/UnderwaterAwashRock) of unknown depth
// make OBSTRN07/WRECKS05 error ("arithmetic on a nil Value") because they hard-
// require a depth. The danger inherits the shoalest DRVAL1 of the DEPARE/DRGARE it
// lies in. Port of internal/engine/portrayal/s101depth.go (DepthIndex/DerivedAttrs).

const DepthArea = struct {
    drval1: f64,
    has_drval1: bool,
    rings: []const []s57.LonLat, // first part is the exterior ring
    min_lon: f64,
    min_lat: f64,
    max_lon: f64,
    max_lat: f64,
};

const DepthIndex = struct {
    areas: []const DepthArea,

    /// Smallest (shoalest) DRVAL1 among the depth areas CONTAINING (lon,lat); null
    /// if the point lies in no depth area with a known DRVAL1 (depth then unknown).
    fn shoalestDrval1(self: DepthIndex, lon: f64, lat: f64) ?f64 {
        var best: f64 = 0;
        var found = false;
        for (self.areas) |area| {
            if (!area.has_drval1) continue;
            if (lon < area.min_lon or lon > area.max_lon or lat < area.min_lat or lat > area.max_lat) continue;
            if (s57.pointInRingsEvenOdd(lon, lat, area.rings)) {
                if (!found or area.drval1 < best) {
                    best = area.drval1;
                    found = true;
                }
            }
        }
        return if (found) best else null;
    }
};

/// Index the cell's DEPARE/DRGARE polygons (rings + DRVAL1 + bbox) for the
/// shoalest-depth lookup. Allocates into `a`.
fn buildDepthIndex(a: std.mem.Allocator, cell: *const s57.Cell) ![]DepthArea {
    var areas = std.ArrayList(DepthArea).empty;
    for (cell.features) |f| {
        if (f.objl != 42 and f.objl != 46) continue; // DEPARE / DRGARE
        const rings = try cell.lineGeometryParts(a, f);
        if (rings.len == 0 or rings[0].len == 0) continue;
        var da = DepthArea{
            .drval1 = 0,
            .has_drval1 = false,
            .rings = rings,
            .min_lon = rings[0][0].lon,
            .min_lat = rings[0][0].lat,
            .max_lon = rings[0][0].lon,
            .max_lat = rings[0][0].lat,
        };
        if (f.attrFloat(s57.ATTR_DRVAL1)) |d| {
            da.drval1 = d;
            da.has_drval1 = true;
        }
        for (rings) |ring| for (ring) |c| {
            da.min_lon = @min(da.min_lon, c.lon);
            da.max_lon = @max(da.max_lon, c.lon);
            da.min_lat = @min(da.min_lat, c.lat);
            da.max_lat = @max(da.max_lat, c.lat);
        };
        try areas.append(a, da);
    }
    return areas.items;
}

/// A danger feature's representative point: its node for a point primitive, else
/// the area representative point of its assembled parts.
fn representativePoint(a: std.mem.Allocator, cell: *const s57.Cell, f: s57.Feature) ?s57.LonLat {
    if (f.prim == 1) return cell.pointGeometry(f);
    const parts = cell.lineGeometryParts(a, f) catch return null;
    return s57.areaRepresentativePoint(parts);
}

fn isDangerCode(code: []const u8) bool {
    return std.mem.eql(u8, code, "Obstruction") or
        std.mem.eql(u8, code, "Wreck") or
        std.mem.eql(u8, code, "UnderwaterAwashRock");
}

fn fmtFloat(a: std.mem.Allocator, v: f64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v});
}

/// S-57 object class (OBJL) -> S-101 feature class code, via the Feature
/// Catalogue (OBJL -> acronym -> code). Covers all ~150 classes. (Attribute-
/// dependent aliasing — LIGHTS, MORFAC, ADMARE — is handled later; this returns
/// the catalogue's primary alias target.)
pub fn resolveCode(objl: u16) ?[]const u8 {
    return catalogue.resolveFeatureByObjl(objl);
}

fn primitiveName(prim: u8) []const u8 {
    return switch (prim) {
        1 => "Point",
        2 => "Curve",
        3 => "Surface",
        else => "",
    };
}

/// Adapt all mappable features of a cell. Allocates into `a` (use an arena).
pub fn adaptCell(a: std.mem.Allocator, cell: *const s57.Cell) ![]Adapted {
    var out = std.ArrayList(Adapted).empty;
    const depth_index = DepthIndex{ .areas = try buildDepthIndex(a, cell) };
    for (cell.features, 0..) |f, i| {
        // SOUNDG (objl 129) is emitted directly as a multipoint by s57_mvt
        // (bypassing portrayal), so don't portray it — it would just error on the
        // multipoint primitive the rule path doesn't model.
        if (f.objl == 129) continue;
        var code = resolveCode(f.objl) orelse meta: {
            // Meta object classes (M_*) are absent from the numeric S-57 code
            // table, so resolveCode can't reach their catalogue alias. Map the one
            // whose portrayal inputs we synthesize: M_QUAL (308) ->
            // QualityOfBathymetricData, so its CATZOC zone-of-confidence draws.
            if (f.objl == 308) break :meta "QualityOfBathymetricData";
            continue;
        };
        // LIGHTS (objl 75) needs attribute-dependent aliasing: the catalogue's
        // primary alias for the "LIGHTS" acronym is one variant (here
        // LightAirObstruction), but real navigational lights are LightAllAround
        // (or LightSectored when they carry sector limits). Route them so the
        // light flare + characteristic text (LightAllAround) actually renders.
        // (Sectored lights carry SECTR1/SECTR2 (codes 136/137); their sector
        // arcs aren't rendered from the stream yet, so all lights use
        // LightAllAround for now — the flare + characteristic still render.)
        if (f.objl == 75) code = "LightAllAround";
        const prim = primitiveName(f.prim);
        if (prim.len == 0) continue;
        var attrs = std.ArrayList(NameVal).empty;
        var complex = std.ArrayList(ComplexAttr).empty;
        var name: []const u8 = "";
        var catzoc: []const u8 = "";
        for (f.attrs) |at| {
            if (at.code == s57.ATTR_OBJNAM) name = at.value; // OBJNAM -> featureName
            if (at.code == s57.ATTR_CATZOC) catzoc = at.value; // CATZOC -> zoneOfConfidence
            if (catalogue.resolveAttrByCode(at.code)) |aname|
                try attrs.append(a, .{ .name = aname, .value = at.value });
        }

        // featureName[1].name from OBJNAM (text labels).
        if (name.len > 0) {
            const subs = try a.alloc(NameVal, 1);
            subs[0] = .{ .name = "name", .value = name };
            try complex.append(a, .{ .name = "featureName", .subs = subs });
        }
        // zoneOfConfidence[1].categoryOfZoneOfConfidenceInData from M_QUAL CATZOC,
        // so QualityOfBathymetricData reads the data-quality zone (S-57 stores it
        // flat). The optional nested fixedDateRange (DATSTA/DATEND) is not
        // synthesized — the single-level complex plumbing can't carry a nested
        // complex, and it's not needed to pick the DQUAL fill pattern.
        if (catzoc.len > 0) {
            const subs = try a.alloc(NameVal, 1);
            subs[0] = .{ .name = "categoryOfZoneOfConfidenceInData", .value = catzoc };
            try complex.append(a, .{ .name = "zoneOfConfidence", .subs = subs });
        }

        // Derived depth attributes for under/awash dangers (S-52 DEPVAL): supply
        // defaultClearanceDepth ALWAYS (else the rule errors on a nil depth) and
        // surroundingDepth ONLY when the danger sits in a depth area (its absence
        // keeps UDWHAZ05's conservative "unknown surrounding => dangerous" branch).
        if (isDangerCode(code)) {
            var clearance: f64 = 0;
            if (representativePoint(a, cell, f)) |pt| {
                if (depth_index.shoalestDrval1(pt.lon, pt.lat)) |d| {
                    clearance = d;
                    try attrs.append(a, .{ .name = "surroundingDepth", .value = try fmtFloat(a, d) });
                }
            }
            try attrs.append(a, .{ .name = "defaultClearanceDepth", .value = try fmtFloat(a, clearance) });
        }

        // Low-accuracy geometry (QUAPOS): expose the per-feature aggregate as a
        // simple attribute so the approximate-position dashed line style can be
        // applied. (S-52 draws low-accuracy lines dashed; the actual stroke ->
        // dashed switch lives in the instruction-translation layer — see notes.)
        const q = cell.featureQuapos(f);
        if (q != 0) try attrs.append(a, .{ .name = "qualityOfHorizontalMeasurement", .value = try std.fmt.allocPrint(a, "{d}", .{q}) });

        // Point geometry for `#P` spatial resolution: a point feature's node, with
        // z = VALSOU (a sounding/danger depth) when present. The framework needs a
        // real Point from HostGetSpatial or it recurses (see Adapted.points).
        var points: []const [3]f64 = &.{};
        if (f.prim == 1) {
            if (cell.pointGeometry(f)) |pg| {
                const z = f.attrFloat(s57.ATTR_VALSOU) orelse 0;
                const arr = try a.alloc([3]f64, 1);
                arr[0] = .{ pg.lon, pg.lat, z };
                points = arr;
            }
        }

        try out.append(a, .{ .feature_index = i, .code = code, .primitive = prim, .attrs = attrs.items, .complex = complex.items, .points = points });
    }
    return out.items;
}

test "adapt a depth area" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "5" },
        .{ .code = s57.ATTR_DRVAL2, .value = "10" },
        .{ .code = 999, .value = "x" }, // unmapped -> dropped
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &attrs },
        .{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = 9999 }, // unmapped class -> dropped
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

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("DepthArea", adapted[0].code);
    try std.testing.expectEqualStrings("Surface", adapted[0].primitive);
    try std.testing.expectEqual(@as(usize, 2), adapted[0].attrs.len);
    try std.testing.expectEqualStrings("depthRangeMinimumValue", adapted[0].attrs[0].name);
    try std.testing.expectEqualStrings("5", adapted[0].attrs[0].value);
}

test "DepthIndex shoalest DRVAL1 lookup" {
    const t = std.testing;
    // Area A is a 10x10 box (DRVAL1 10); area B a 2..8 box inside it (DRVAL1 3).
    var ring_a = [_]s57.LonLat{
        .{ .lon = 0, .lat = 0 },  .{ .lon = 10, .lat = 0 },
        .{ .lon = 10, .lat = 10 }, .{ .lon = 0, .lat = 10 },
    };
    var ring_b = [_]s57.LonLat{
        .{ .lon = 2, .lat = 2 }, .{ .lon = 8, .lat = 2 },
        .{ .lon = 8, .lat = 8 }, .{ .lon = 2, .lat = 8 },
    };
    var parts_a = [_][]s57.LonLat{ring_a[0..]};
    var parts_b = [_][]s57.LonLat{ring_b[0..]};
    const areas = [_]DepthArea{
        .{ .drval1 = 10, .has_drval1 = true, .rings = parts_a[0..], .min_lon = 0, .min_lat = 0, .max_lon = 10, .max_lat = 10 },
        .{ .drval1 = 3, .has_drval1 = true, .rings = parts_b[0..], .min_lon = 2, .min_lat = 2, .max_lon = 8, .max_lat = 8 },
    };
    const idx = DepthIndex{ .areas = &areas };

    // (5,5) is inside BOTH areas -> shoalest (smallest) DRVAL1 = 3.
    try t.expectEqual(@as(f64, 3), idx.shoalestDrval1(5, 5).?);
    // (1,1) is inside only the larger area A (DRVAL1 10).
    try t.expectEqual(@as(f64, 10), idx.shoalestDrval1(1, 1).?);
    // (20,20) is outside every area -> no containing depth area (depth unknown).
    try t.expect(idx.shoalestDrval1(20, 20) == null);
    // An area without a known DRVAL1 doesn't satisfy the lookup.
    const no_drval = [_]DepthArea{
        .{ .drval1 = 0, .has_drval1 = false, .rings = parts_a[0..], .min_lon = 0, .min_lat = 0, .max_lon = 10, .max_lat = 10 },
    };
    const idx2 = DepthIndex{ .areas = &no_drval };
    try t.expect(idx2.shoalestDrval1(5, 5) == null);
}
