//! S-57 -> S-101 feature adaptation for the portrayal engine: map each S-57
//! feature's object class to its S-101 feature class name and translate the
//! S-57 attribute codes the rules read into S-101 attribute names. A minimal,
//! growing port of internal/engine/s101/complex.go (resolveCode + buildRoot).
//!
//! The adapted features feed the Host* callbacks; geometry stays in s57.Cell and
//! is attached when instructions are translated to MVT.

const std = @import("std");
const s57 = @import("s57");
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

// S-57 simple attributes the S-101 catalogue models as a single-instance complex
// attribute wrapping one *Value sub-attribute. The DRAFT rules index these
// complexes directly (e.g. feature.verticalClearanceClosed.verticalClearanceValue,
// feature.orientation.orientationValue), so synthesize them when the S-57 attr is
// present. Ported from chartplotter-go's `clearances` map + the orientation alias.
const ComplexFromSimple = struct { code: u16, complex: []const u8, sub: []const u8 };
const complex_from_simple = [_]ComplexFromSimple{
    .{ .code = s57.ATTR_ORIENT, .complex = "orientation", .sub = "orientationValue" },
    .{ .code = s57.ATTR_VERCCL, .complex = "verticalClearanceClosed", .sub = "verticalClearanceValue" },
    .{ .code = s57.ATTR_VERCLR, .complex = "verticalClearanceFixed", .sub = "verticalClearanceValue" },
    .{ .code = s57.ATTR_VERCOP, .complex = "verticalClearanceOpen", .sub = "verticalClearanceValue" },
    .{ .code = s57.ATTR_HORCLR, .complex = "horizontalClearanceFixed", .sub = "horizontalClearanceValue" },
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
            .min_lon = rings[0][0].lon(),
            .min_lat = rings[0][0].lat(),
            .max_lon = rings[0][0].lon(),
            .max_lat = rings[0][0].lat(),
        };
        if (f.attrFloat(s57.ATTR_DRVAL1)) |d| {
            da.drval1 = d;
            da.has_drval1 = true;
        }
        for (rings) |ring| for (ring) |c| {
            da.min_lon = @min(da.min_lon, c.lon());
            da.max_lon = @max(da.max_lon, c.lon());
            da.min_lat = @min(da.min_lat, c.lat());
            da.max_lat = @max(da.max_lat, c.lat());
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
    return s57.areaRepresentativePoint(a, parts);
}

// --- TOPMAR folding (S-52 TOPMAR02) ----------------------------------------
// S-57 encodes a buoy/beacon topmark as a SEPARATE TOPMAR point feature
// co-located with its parent; S-101 models it as a complex attribute ON the
// parent (read by the TOPMAR02 CSP). Index TOPMAR features by location so each
// can be folded into its co-located parent, and drop the standalone TOPMAR
// (it has no S-101 feature class and would portray as a magenta unknown mark).
// Port of internal/engine/portrayal/s101topmark.go + s101/complex.go.

const TopmarkData = struct { shape: []const u8, colour: []const u8 };

// A stable location key for a point feature's vertex, quantized so a parent and
// its topmark (which share the vertex) collide. Mirrors the Go pointLocKey
// (7-decimal fixed format); the exact string only needs to be self-consistent.
fn pointLocKey(a: std.mem.Allocator, pt: s57.LonLat) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:.7},{d:.7}", .{ pt.lon(), pt.lat() });
}

fn buildTopmarkIndex(a: std.mem.Allocator, cell: *const s57.Cell) !std.StringHashMap(TopmarkData) {
    var idx = std.StringHashMap(TopmarkData).init(a);
    for (cell.features) |f| {
        if (f.objl != s57.OBJL_TOPMAR) continue;
        const pt = cell.pointGeometry(f) orelse continue;
        const shape = std.mem.trim(u8, f.attr(s57.ATTR_TOPSHP) orelse "", " ");
        const colour = std.mem.trim(u8, f.attr(s57.ATTR_COLOUR) orelse "", " ");
        if (shape.len == 0 and colour.len == 0) continue;
        try idx.put(try pointLocKey(a, pt), .{ .shape = shape, .colour = colour });
    }
    return idx;
}

// A buoy/beacon (or light float) carries a topmark — its S-101 rule reads
// feature.topmark. Matched by S-57 acronym, like the Go isTopmarkParent.
fn isTopmarkParent(objl: u16) bool {
    const acr = catalogue.acronymByObjl(objl) orelse return false;
    return std.mem.startsWith(u8, acr, "BOY") or
        std.mem.startsWith(u8, acr, "BCN") or
        std.mem.eql(u8, acr, "LITFLT");
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
/// dependent aliasing — LIGHTS, MORFAC, ADMARE — is handled by resolveClass; this
/// returns the catalogue's primary alias target.)
pub fn resolveCode(objl: u16) ?[]const u8 {
    return catalogue.resolveFeatureByObjl(objl);
}

// --- S-57 list-value helpers (port of complex.go firstListVal/hasListVal) ----
// S-57 enumeration attributes are comma-separated integer lists (e.g. CATLIT
// "1,6"); these read the head / membership the way the Go routing does.

/// First integer of an S-57 comma-separated list value, or 0 if absent/unparseable.
fn firstListVal(csv: ?[]const u8) i64 {
    const s = csv orelse return 0;
    const head = std.mem.trim(u8, std.mem.sliceTo(s, ','), " ");
    return std.fmt.parseInt(i64, head, 10) catch 0;
}

/// Whether the S-57 comma-separated list value contains `want`.
fn hasListVal(csv: ?[]const u8, want: i64) bool {
    const s = csv orelse return false;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, part, " "), 10) catch continue;
        if (n == want) return true;
    }
    return false;
}

/// Whether feature `f` carries a present, non-blank value for attribute `code`
/// (an all-spaces value reads as absent, mirroring Go's `attrs[x] != ""`).
fn attrNonEmpty(f: s57.Feature, code: u16) bool {
    const v = f.attr(code) orelse return false;
    return std.mem.trim(u8, v, " ").len > 0;
}

/// S-57 MORFAC -> S-101 feature class by CATMOR (category of mooring/warping
/// facility). Port of complex.go resolveMooringClass: dolphin->Dolphin,
/// bollard->Bollard, chain/wire/cable->MooringTrot, mooring buoy->MooringBuoy;
/// post/pile/tie-up-wall/unknown fall back to Pile. Returns null if the resolved
/// class isn't in the catalogue (caller then falls back to the alias lookup).
fn resolveMooringClass(f: s57.Feature) ?[]const u8 {
    const code: []const u8 = switch (firstListVal(f.attr(s57.ATTR_CATMOR))) {
        1, 2 => "Dolphin", // dolphin, deviation dolphin
        3 => "Bollard",
        6 => "MooringTrot", // chain / wire / cable
        7 => "MooringBuoy",
        else => "Pile", // post or pile (5), tie-up wall (4), unknown
    };
    return if (catalogue.hasFeature(code)) code else null;
}

/// S-57 LIGHTS -> S-101 light class by attributes (port of complex.go
/// resolveLightClass). Air-obstruction (CATLIT 6) and fog-detector (CATLIT 7)
/// lights have dedicated rules that just add the standard flare + description, so
/// route those faithfully. Sectored (SECTR1+SECTR2) and directional (CATLIT 1)
/// lights resolve to LightSectored in the oracle, but that rule iterates the
/// nested sectorCharacteristics complex the single-level complex plumbing here
/// can't synthesize yet (buildLightSectors); routing them there would emit nothing
/// (the flare would vanish), so keep them on LightAllAround — the flare +
/// characteristic still render, strictly closer to the oracle than an empty draw.
fn resolveLightClass(f: s57.Feature) []const u8 {
    // Preserve the oracle's precedence: sectored/directional outrank the
    // air-obstruction/fog-detector categories (a light that is both stays the
    // sectored class), so test them first even though both map to LightAllAround
    // here pending buildLightSectors.
    if (attrNonEmpty(f, s57.ATTR_SECTR1) and attrNonEmpty(f, s57.ATTR_SECTR2)) return "LightAllAround";
    const catlit = f.attr(s57.ATTR_CATLIT);
    if (hasListVal(catlit, 1)) return "LightAllAround"; // directional -> LightSectored (deferred)
    if (hasListVal(catlit, 6)) return "LightAirObstruction"; // air obstruction
    if (hasListVal(catlit, 7)) return "LightFogDetector"; // fog detector
    return "LightAllAround";
}

/// S-57 object class -> S-101 feature class, resolving the attribute-dependent
/// one-to-many mappings the catalogue alias can't express. Port of complex.go
/// resolveCode (the switch + the default catalogue-alias fallback). Returns null
/// for an unmapped class (the caller then skips the feature).
fn resolveClass(f: s57.Feature) ?[]const u8 {
    switch (f.objl) {
        // LIGHTS aliases to LightAllAround/LightSectored/LightAirObstruction/
        // LightFogDetector depending on attributes (resolveLightClass).
        s57.OBJL_LIGHTS => return resolveLightClass(f),
        // ADMARE aliases to AdministrationArea and VesselTrafficServiceArea; the
        // plain administration area is the correct default (VTS is a distinct class).
        s57.OBJL_ADMARE => if (catalogue.hasFeature("AdministrationArea")) return "AdministrationArea",
        // MORFAC decomposes by CATMOR into distinct point classes (no single alias).
        s57.OBJL_MORFAC => if (resolveMooringClass(f)) |code| return code,
        // S-101 merged the separation line (TSELNE, curve) and zone (TSEZNE, surface)
        // into one geometry-distinguished class with no alias.
        s57.OBJL_TSELNE, s57.OBJL_TSEZNE => if (catalogue.hasFeature("SeparationZoneOrLine")) return "SeparationZoneOrLine",
        else => {},
    }
    // Default: catalogue alias by acronym. resolveFeatureByObjl covers the numeric
    // S-57 classes; meta classes (M_*, OBJL >= 300) are absent from the numeric
    // table, so reach their acronym via the acronymByObjl fallback and alias that
    // (e.g. M_ACCY -> QualityOfNonBathymetricData, M_QUAL -> QualityOfBathymetricData).
    if (resolveCode(f.objl)) |code| return code;
    if (catalogue.acronymByObjl(f.objl)) |acr| {
        // M_NSYS's oracle output is the dedicated navSystemBuild S-52 boundary
        // (MARSYS51/NAVARE51 + direction-of-buoyage arrow; Go s101build.go:307),
        // which supersedes its LocalDirectionOfBuoyage alias. Until that override
        // is ported, skip M_NSYS rather than draw the wrong (S-101 DIRBOY) arrow
        // its alias would emit — a missing boundary is closer to the oracle than a
        // different symbol. (Tracked: portrayal-fallbacks navSystemBuild.)
        if (std.mem.eql(u8, acr, "M_NSYS")) return null;
        return catalogue.resolveFeature(acr);
    }
    return null;
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
    // TOPMAR features (built from the FULL feature set) fold into co-located
    // buoys/beacons below; the standalone features are then skipped.
    var topmark_index = try buildTopmarkIndex(a, cell);
    for (cell.features, 0..) |f, i| {
        // SOUNDG (objl 129) is emitted directly as a multipoint by s57_mvt
        // (bypassing portrayal), so don't portray it — it would just error on the
        // multipoint primitive the rule path doesn't model.
        if (f.objl == 129) continue;
        // TOPMAR is folded into its co-located buoy/beacon as the topmark complex
        // (below); the standalone feature has no S-101 class, so don't portray it.
        if (f.objl == s57.OBJL_TOPMAR) continue;
        // S-57 object class -> S-101 feature class, including the attribute-
        // dependent aliases (LIGHTS, MORFAC, ADMARE, TSELNE/TSEZNE) and the meta
        // classes (M_*); an unmapped class is skipped.
        const code = resolveClass(f) orelse continue;
        const prim = primitiveName(f.prim);
        if (prim.len == 0) continue;
        var attrs = std.ArrayList(NameVal).empty;
        var complex = std.ArrayList(ComplexAttr).empty;
        var name: []const u8 = "";
        var catzoc: []const u8 = "";
        for (f.attrs) |at| {
            // A present-but-blank S-57 attribute (e.g. an unknown VALSOU, all
            // spaces) means "absent": serving "" would make the framework build a
            // malformed ScaledDecimal{Value=nil} for a 'real' attr (tonumber("")
            // == nil), which crashes the danger depth comparison. Skip it, and
            // serve the trimmed value so numeric strings parse cleanly.
            const v = std.mem.trim(u8, at.value, " ");
            if (v.len == 0) continue;
            if (at.code == s57.ATTR_OBJNAM) name = v; // OBJNAM -> featureName
            if (at.code == s57.ATTR_CATZOC) catzoc = v; // CATZOC -> zoneOfConfidence
            if (catalogue.resolveAttrByCode(at.code)) |aname|
                try attrs.append(a, .{ .name = aname, .value = v });
        }

        // featureName[1] from OBJNAM. language + nameUsage are mandatory: the
        // framework's GetFeatureName requires nameUsage (and prefers language=='eng');
        // without them PortrayFeatureName emits no text (mirrors Go complex.go:90-92).
        if (name.len > 0) {
            const subs = try a.alloc(NameVal, 3);
            subs[0] = .{ .name = "name", .value = name };
            subs[1] = .{ .name = "language", .value = "eng" };
            subs[2] = .{ .name = "nameUsage", .value = "1" }; // selected even if language differs
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
        // orientation / clearance complexes from their S-57 simple attrs, so the
        // route + bridge rules (NavigationLine, RecommendedTrack, SpanOpening) can
        // index feature.<complex>.<value> instead of erroring on a nil complex.
        for (complex_from_simple) |m| {
            const raw = f.attr(m.code) orelse continue;
            const v = std.mem.trim(u8, raw, " ");
            if (v.len == 0) continue;
            const subs = try a.alloc(NameVal, 1);
            subs[0] = .{ .name = m.sub, .value = v };
            try complex.append(a, .{ .name = m.complex, .subs = subs });
        }
        // SpanOpening (opening bridges) indexes feature.verticalClearanceClosed
        // unconditionally (a draft-rule bug), so guarantee the complex exists —
        // empty when the bridge carries no VERCCL — and the rule reads a nil value
        // instead of crashing on a nil complex.
        if (std.mem.eql(u8, code, "SpanOpening")) {
            const vc = f.attr(s57.ATTR_VERCCL);
            const present = vc != null and std.mem.trim(u8, vc.?, " ").len > 0;
            if (!present) try complex.append(a, .{ .name = "verticalClearanceClosed", .subs = &.{} });
        }

        // TOPMAR folding: a co-located TOPMAR's shape/colour -> the parent's
        // S-101 `topmark` complex (read by the TOPMAR02 CSP, which picks the
        // topmark symbol from topmarkDaymarkShape). Mirrors s101/complex.go.
        if (isTopmarkParent(f.objl)) {
            if (cell.pointGeometry(f)) |pt| {
                const key = try pointLocKey(a, pt);
                if (topmark_index.get(key)) |tm| {
                    var subs = std.ArrayList(NameVal).empty;
                    try subs.append(a, .{ .name = "topmarkDaymarkShape", .value = tm.shape });
                    if (tm.colour.len > 0) try subs.append(a, .{ .name = "colour", .value = tm.colour });
                    try complex.append(a, .{ .name = "topmark", .subs = subs.items });
                }
            }
        }

        // Derived depth attributes for under/awash dangers (S-52 DEPVAL): supply
        // defaultClearanceDepth ALWAYS (else the rule errors on a nil depth) and
        // surroundingDepth ONLY when the danger sits in a depth area (its absence
        // keeps UDWHAZ05's conservative "unknown surrounding => dangerous" branch).
        if (isDangerCode(code)) {
            var clearance: f64 = 0;
            if (representativePoint(a, cell, f)) |pt| {
                if (depth_index.shoalestDrval1(pt.lon(), pt.lat())) |d| {
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
                arr[0] = .{ pg.lon(), pg.lat(), z };
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

test "resolveClass routes the attribute-dependent S-57 classes" {
    const t = std.testing;
    // ADMARE -> AdministrationArea (NOT the catalogue's VesselTrafficServiceArea alias).
    try t.expectEqualStrings("AdministrationArea", resolveClass(.{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = s57.OBJL_ADMARE }).?);
    // TSELNE (curve) and TSEZNE (surface) both -> SeparationZoneOrLine (merged, no alias).
    try t.expectEqualStrings("SeparationZoneOrLine", resolveClass(.{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = s57.OBJL_TSELNE }).?);
    try t.expectEqualStrings("SeparationZoneOrLine", resolveClass(.{ .rcnm = 100, .rcid = 3, .prim = 3, .objl = s57.OBJL_TSEZNE }).?);
    // MORFAC decomposes by CATMOR; absent/unknown -> Pile.
    const dolphin = [_]s57.Attr{.{ .code = s57.ATTR_CATMOR, .value = "1" }};
    try t.expectEqualStrings("Dolphin", resolveClass(.{ .rcnm = 100, .rcid = 4, .prim = 1, .objl = s57.OBJL_MORFAC, .attrs = &dolphin }).?);
    const buoy = [_]s57.Attr{.{ .code = s57.ATTR_CATMOR, .value = "7" }};
    try t.expectEqualStrings("MooringBuoy", resolveClass(.{ .rcnm = 100, .rcid = 5, .prim = 1, .objl = s57.OBJL_MORFAC, .attrs = &buoy }).?);
    try t.expectEqualStrings("Pile", resolveClass(.{ .rcnm = 100, .rcid = 6, .prim = 1, .objl = s57.OBJL_MORFAC }).?);
    // Meta classes resolve via their acronym alias: M_ACCY (300) and M_QUAL (308).
    try t.expectEqualStrings("QualityOfNonBathymetricData", resolveClass(.{ .rcnm = 100, .rcid = 7, .prim = 3, .objl = 300 }).?);
    try t.expectEqualStrings("QualityOfBathymetricData", resolveClass(.{ .rcnm = 100, .rcid = 8, .prim = 3, .objl = 308 }).?);
    // A plain LIGHTS (no category) -> LightAllAround.
    try t.expectEqualStrings("LightAllAround", resolveClass(.{ .rcnm = 100, .rcid = 9, .prim = 1, .objl = s57.OBJL_LIGHTS }).?);
    // An unmapped object class resolves to null (caller skips it).
    try t.expect(resolveClass(.{ .rcnm = 100, .rcid = 10, .prim = 1, .objl = 9999 }) == null);
}

test "resolveLightClass routes LIGHTS by category" {
    const t = std.testing;
    const lights = struct {
        fn f(rcid: u32, attrs: []const s57.Attr) s57.Feature {
            return .{ .rcnm = 100, .rcid = rcid, .prim = 1, .objl = s57.OBJL_LIGHTS, .attrs = attrs };
        }
    }.f;
    // Air-obstruction (CATLIT 6) and fog-detector (CATLIT 7) route faithfully.
    const air = [_]s57.Attr{.{ .code = s57.ATTR_CATLIT, .value = "6" }};
    try t.expectEqualStrings("LightAirObstruction", resolveLightClass(lights(1, &air)));
    const fog = [_]s57.Attr{.{ .code = s57.ATTR_CATLIT, .value = "7" }};
    try t.expectEqualStrings("LightFogDetector", resolveLightClass(lights(2, &fog)));
    // CATLIT as a list still matches membership.
    const air_list = [_]s57.Attr{.{ .code = s57.ATTR_CATLIT, .value = "1,6" }};
    // ...but a directional (CATLIT 1) light outranks air-obstruction and (pending
    // buildLightSectors) stays LightAllAround rather than its LightSectored class.
    try t.expectEqualStrings("LightAllAround", resolveLightClass(lights(3, &air_list)));
    // Sectored light (SECTR1+SECTR2) -> LightAllAround for now (would be LightSectored).
    const sect = [_]s57.Attr{
        .{ .code = s57.ATTR_SECTR1, .value = "045" },
        .{ .code = s57.ATTR_SECTR2, .value = "090" },
    };
    try t.expectEqualStrings("LightAllAround", resolveLightClass(lights(4, &sect)));
    // A plain light -> LightAllAround.
    try t.expectEqualStrings("LightAllAround", resolveLightClass(lights(5, &.{})));
}

test "TOPMAR folds into co-located buoy as the topmark complex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const topmar_attrs = [_]s57.Attr{.{ .code = s57.ATTR_TOPSHP, .value = "2" }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 10, .prim = 1, .objl = 17, .refs = &node_ref }, // BOYLAT
        .{ .rcnm = 100, .rcid = 11, .prim = 1, .objl = s57.OBJL_TOPMAR, .refs = &node_ref, .attrs = &topmar_attrs },
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
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(-76.5, 39.0));

    const adapted = try adaptCell(a, &cell);
    // The standalone TOPMAR is dropped; only the buoy is adapted.
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    var found = false;
    for (adapted[0].complex) |c| {
        if (std.mem.eql(u8, c.name, "topmark")) {
            found = true;
            try std.testing.expectEqualStrings("topmarkDaymarkShape", c.subs[0].name);
            try std.testing.expectEqualStrings("2", c.subs[0].value);
        }
    }
    try std.testing.expect(found);
}

test "DepthIndex shoalest DRVAL1 lookup" {
    const t = std.testing;
    // Area A is a 10x10 box (DRVAL1 10); area B a 2..8 box inside it (DRVAL1 3).
    var ring_a = [_]s57.LonLat{
        s57.LonLat.init(0, 0),  s57.LonLat.init(10, 0),
        s57.LonLat.init(10, 10), s57.LonLat.init(0, 10),
    };
    var ring_b = [_]s57.LonLat{
        s57.LonLat.init(2, 2), s57.LonLat.init(8, 2),
        s57.LonLat.init(8, 8), s57.LonLat.init(2, 8),
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
