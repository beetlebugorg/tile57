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

/// One node of the synthesized attribute tree (port of internal/engine/s101/
/// complex.go's `cnode`): leaf simple values keyed by S-101 sub-attribute name,
/// plus nested complex children keyed by name (each name -> its ordered instances).
/// The feature root reuses this shape: `simple` holds the feature's own simple
/// attributes (translated to S-101 names, one raw value each — the host splits S-57
/// list values by the catalogue value type), and `children` hold the synthesized
/// top-level complex attributes, each possibly nesting further (light sectors). The
/// Host* path serves the tree via tgp_simple / tgp_complex_count, resolving the
/// framework attributePath through it. Built in adaptCell's arena; instances are
/// tiny, so key/value slices are used rather than maps.
pub const CNode = struct {
    simple: []const NameVal = &.{},
    children: []const ChildEntry = &.{},

    /// Walk the framework attributePath ("code:idx;code:idx;…") from this node to the
    /// container being queried. An empty path is the node itself; idx is 1-based.
    /// Returns null if any segment is missing — the framework then reads count 0 / no
    /// value, i.e. "attribute absent". Port of complex.go cnode.resolve.
    pub fn resolve(self: *const CNode, path: []const u8) ?*const CNode {
        if (path.len == 0) return self;
        var cur: *const CNode = self;
        var it = std.mem.splitScalar(u8, path, ';');
        while (it.next()) |seg| {
            const colon = std.mem.indexOfScalar(u8, seg, ':') orelse return null;
            const idx = std.fmt.parseInt(usize, std.mem.trim(u8, seg[colon + 1 ..], " "), 10) catch return null;
            if (idx < 1) return null;
            const list = cur.childList(seg[0..colon]) orelse return null;
            if (idx > list.len) return null;
            cur = &list[idx - 1];
        }
        return cur;
    }

    fn childList(self: *const CNode, code: []const u8) ?[]const CNode {
        for (self.children) |c| if (std.mem.eql(u8, c.code, code)) return c.nodes;
        return null;
    }

    /// First raw value of simple sub-attribute `code` at this node, or null.
    pub fn simpleValue(self: *const CNode, code: []const u8) ?[]const u8 {
        for (self.simple) |s| if (std.mem.eql(u8, s.name, code)) return s.value;
        return null;
    }

    /// Number of instances of complex child `code` at this node.
    pub fn childCount(self: *const CNode, code: []const u8) usize {
        return if (self.childList(code)) |l| l.len else 0;
    }
};

/// A named complex-attribute child of a CNode: `code` -> its ordered instances.
pub const ChildEntry = struct { code: []const u8, nodes: []const CNode };

/// Incrementally builds a CNode in `a` (an arena): accumulate simple values and
/// complex children, then `.build()`. addSimple drops empty values (mirrors Go
/// cnode.addSimple) so the framework reads "absent" rather than an empty string;
/// addChild appends instances under a code (a repeated code accumulates).
const NodeBuilder = struct {
    a: std.mem.Allocator,
    simple: std.ArrayList(NameVal) = .empty,
    children: std.ArrayList(ChildEntry) = .empty,

    fn addSimple(self: *NodeBuilder, code: []const u8, value: []const u8) !void {
        const v = std.mem.trim(u8, value, " ");
        if (v.len == 0) return;
        try self.simple.append(self.a, .{ .name = code, .value = v });
    }

    /// Append a sub-attribute keeping the value VERBATIM (even when empty), for the
    /// rare case the framework must read a present-but-empty value rather than absent.
    fn addSimpleRaw(self: *NodeBuilder, code: []const u8, value: []const u8) !void {
        try self.simple.append(self.a, .{ .name = code, .value = value });
    }

    fn addChild(self: *NodeBuilder, code: []const u8, node: CNode) !void {
        try appendChild(self.a, &self.children, code, node);
    }

    fn build(self: NodeBuilder) CNode {
        return .{ .simple = self.simple.items, .children = self.children.items };
    }
};

/// Append one complex-attribute instance under `code` in `list`, accumulating a
/// repeated code into its ordered instance slice (port of cnode.addChild). Allocates
/// the (re)grown node slice in `a`.
fn appendChild(a: std.mem.Allocator, list: *std.ArrayList(ChildEntry), code: []const u8, node: CNode) !void {
    for (list.items) |*ce| {
        if (std.mem.eql(u8, ce.code, code)) {
            const grown = try a.alloc(CNode, ce.nodes.len + 1);
            @memcpy(grown[0..ce.nodes.len], ce.nodes);
            grown[ce.nodes.len] = node;
            ce.nodes = grown;
            return;
        }
    }
    const one = try a.alloc(CNode, 1);
    one[0] = node;
    try list.append(a, .{ .code = code, .nodes = one });
}

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
    // The synthesized attribute tree: root.simple = the feature's own simple attrs
    // (S-101 name -> value), root.children = the top-level complex attributes (each
    // possibly nested). The Host* path resolves the framework attributePath through it.
    root: CNode = .{},
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

// --- LIGHTS (S-52 sectored/all-around lights) ------------------------------
// Port of internal/engine/s101/complex.go's resolveLightClass + buildLightSectors +
// buildRhythmOfLight: S-57 stores a light's characteristic/sector data flat; the
// LightSectored rule reads a nested sectorCharacteristics -> lightSector ->
// sectorLimit/directionalCharacter tree, and every light reads rhythmOfLight for its
// characteristic text. We synthesize both from the S-57 LIGHTS simple attributes.

/// Trimmed value of S-57 attribute `code` on `f`, or "" if absent.
fn attrTrim(f: s57.Feature, code: u16) []const u8 {
    return std.mem.trim(u8, f.attr(code) orelse "", " ");
}

/// Whether the S-57 comma-separated list value `csv` contains the integer `want`.
/// Port of complex.go hasListVal.
fn hasListVal(csv: []const u8, want: i64) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |p| {
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, p, " "), 10) catch continue;
        if (n == want) return true;
    }
    return false;
}

/// S-101 light class for an S-57 LIGHTS feature (port of complex.go resolveLightClass):
/// two sector limits OR a directional light -> LightSectored (sector legs/arcs +
/// directional characters); air obstruction / fog detector -> their dedicated rules;
/// everything else an all-around light.
fn resolveLightClass(f: s57.Feature) []const u8 {
    if (attrTrim(f, s57.ATTR_SECTR1).len > 0 and attrTrim(f, s57.ATTR_SECTR2).len > 0)
        return "LightSectored";
    const catlit = attrTrim(f, s57.ATTR_CATLIT);
    if (hasListVal(catlit, 1)) return "LightSectored"; // directional function
    if (hasListVal(catlit, 6)) return "LightAirObstruction";
    if (hasListVal(catlit, 7)) return "LightFogDetector";
    return "LightAllAround";
}

/// First integer in the S-57 comma-separated list `csv`, or 0 if none.
/// Port of complex.go firstListVal.
fn firstListVal(csv: []const u8) i64 {
    var it = std.mem.splitScalar(u8, csv, ',');
    const first = it.next() orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, first, " "), 10) catch 0;
}

/// MORFAC (mooring/warping facility) decomposes by CATMOR into distinct point
/// classes (no single alias). Port of complex.go resolveMooringClass.
fn resolveMooringClass(f: s57.Feature) ?[]const u8 {
    const code: []const u8 = switch (firstListVal(attrTrim(f, s57.ATTR_CATMOR))) {
        1, 2 => "Dolphin", // dolphin, deviation dolphin
        3 => "Bollard",
        6 => "MooringTrot", // chain / wire / cable
        7 => "MooringBuoy",
        else => "Pile", // post or pile (5), tie-up wall (4), unknown
    };
    return if (catalogue.hasFeature(code)) code else null;
}

/// S-57 object class -> S-101 feature class, including the attribute-dependent
/// aliases (LIGHTS, MORFAC, ADMARE, TSELNE/TSEZNE) and the meta classes (M_*);
/// an unmapped class returns null. Port of complex.go resolveCode + resolveClass.
/// Public so the tile emitter can tell a genuinely-unknown class (null → the
/// §10.1.1 QUESMRK1 mark) from a mapped class the rule simply didn't draw.
pub fn resolveClass(f: s57.Feature) ?[]const u8 {
    switch (f.objl) {
        s57.OBJL_LIGHTS => return resolveLightClass(f),
        s57.OBJL_ADMARE => if (catalogue.hasFeature("AdministrationArea")) return "AdministrationArea",
        s57.OBJL_MORFAC => if (resolveMooringClass(f)) |code| return code,
        s57.OBJL_TSELNE, s57.OBJL_TSEZNE => if (catalogue.hasFeature("SeparationZoneOrLine")) return "SeparationZoneOrLine",
        else => {},
    }
    // Default: catalogue alias by numeric class, then by acronym for meta (M_*)
    // classes absent from the numeric table (M_QUAL -> QualityOfBathymetricData, …).
    if (resolveCode(f.objl)) |code| return code;
    if (catalogue.acronymByObjl(f.objl)) |acr| {
        // M_NSYS's oracle output is the navSystemBuild S-52 boundary, not its
        // LocalDirectionOfBuoyage alias; skip until that override is ported.
        if (std.mem.eql(u8, acr, "M_NSYS")) return null;
        return catalogue.resolveFeature(acr);
    }
    return null;
}

/// Synthesize the nested sectorCharacteristics -> lightSector -> sectorLimit /
/// directionalCharacter tree LightSectored reads, from the S-57 LIGHTS attributes.
/// One S-57 LIGHTS feature carries exactly one sector; multiple sectors at a position
/// are separate co-located features. Port of complex.go buildLightSectors.
fn buildLightSectors(a: std.mem.Allocator, children: *std.ArrayList(ChildEntry), f: s57.Feature) !void {
    const sectr1 = attrTrim(f, s57.ATTR_SECTR1);
    const sectr2 = attrTrim(f, s57.ATTR_SECTR2);
    const orient = attrTrim(f, s57.ATTR_ORIENT);
    const sectored = sectr1.len > 0 and sectr2.len > 0;
    const directional = hasListVal(attrTrim(f, s57.ATTR_CATLIT), 1) and orient.len > 0;
    if (!sectored and !directional) return;

    var sc = NodeBuilder{ .a = a };
    try sc.addSimple("lightCharacteristic", attrTrim(f, s57.ATTR_LITCHR));
    try sc.addSimple("signalGroup", attrTrim(f, s57.ATTR_SIGGRP));
    try sc.addSimple("signalPeriod", attrTrim(f, s57.ATTR_SIGPER));

    var ls = NodeBuilder{ .a = a };
    // colour / lightVisibility are S-57 list values; addSimple stores the raw value and
    // the host splits it by the catalogue value type (== Go splitValue).
    try ls.addSimple("colour", attrTrim(f, s57.ATTR_COLOUR));
    try ls.addSimple("valueOfNominalRange", attrTrim(f, s57.ATTR_VALNMR));
    try ls.addSimple("lightVisibility", attrTrim(f, s57.ATTR_LITVIS));

    if (sectored) {
        var sl = NodeBuilder{ .a = a };
        var one = NodeBuilder{ .a = a };
        try one.addSimple("sectorBearing", sectr1);
        var two = NodeBuilder{ .a = a };
        try two.addSimple("sectorBearing", sectr2);
        try sl.addChild("sectorLimitOne", one.build());
        try sl.addChild("sectorLimitTwo", two.build());
        try ls.addChild("sectorLimit", sl.build());
    } else { // directional
        var dc = NodeBuilder{ .a = a };
        var o = NodeBuilder{ .a = a };
        try o.addSimple("orientationValue", orient);
        try dc.addChild("orientation", o.build());
        try ls.addChild("directionalCharacter", dc.build());
    }

    try sc.addChild("lightSector", ls.build());
    try appendChild(a, children, "sectorCharacteristics", sc.build());
}

/// Synthesize the rhythmOfLight complex (lightCharacteristic / signalGroup /
/// signalPeriod) LITDSN02 reads to build a light's characteristic text, from the S-57
/// LITCHR / SIGGRP / SIGPER. Built whenever any of the three is present. Port of
/// complex.go buildRhythmOfLight.
fn buildRhythmOfLight(a: std.mem.Allocator, children: *std.ArrayList(ChildEntry), f: s57.Feature) !void {
    const litchr = attrTrim(f, s57.ATTR_LITCHR);
    const siggrp = attrTrim(f, s57.ATTR_SIGGRP);
    const sigper = attrTrim(f, s57.ATTR_SIGPER);
    if (litchr.len == 0 and siggrp.len == 0 and sigper.len == 0) return;
    var rol = NodeBuilder{ .a = a };
    try rol.addSimple("lightCharacteristic", litchr);
    try rol.addSimple("signalGroup", siggrp);
    try rol.addSimple("signalPeriod", sigper);
    try appendChild(a, children, "rhythmOfLight", rol.build());
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
        // S-57 object class -> S-101 feature class, including the attribute-dependent
        // aliases (LIGHTS, MORFAC, ADMARE, TSELNE/TSEZNE) and the meta classes (M_*);
        // an unmapped class is skipped.
        const code = resolveClass(f) orelse continue;
        const prim = primitiveName(f.prim);
        if (prim.len == 0) continue;
        var attrs = std.ArrayList(NameVal).empty;
        var children = std.ArrayList(ChildEntry).empty;
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
            try appendChild(a, &children, "featureName", .{ .simple = subs });
        }
        // zoneOfConfidence[1].categoryOfZoneOfConfidenceInData from M_QUAL CATZOC,
        // so QualityOfBathymetricData reads the data-quality zone (S-57 stores it
        // flat). The optional nested fixedDateRange (DATSTA/DATEND) is not
        // synthesized — it's not needed to pick the DQUAL fill pattern.
        if (catzoc.len > 0) {
            const subs = try a.alloc(NameVal, 1);
            subs[0] = .{ .name = "categoryOfZoneOfConfidenceInData", .value = catzoc };
            try appendChild(a, &children, "zoneOfConfidence", .{ .simple = subs });
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
            try appendChild(a, &children, m.complex, .{ .simple = subs });
        }
        // SpanOpening (opening bridges) indexes feature.verticalClearanceClosed
        // unconditionally (a draft-rule bug), so guarantee the complex exists —
        // empty when the bridge carries no VERCCL — and the rule reads a nil value
        // instead of crashing on a nil complex.
        if (std.mem.eql(u8, code, "SpanOpening")) {
            const vc = f.attr(s57.ATTR_VERCCL);
            const present = vc != null and std.mem.trim(u8, vc.?, " ").len > 0;
            if (!present) try appendChild(a, &children, "verticalClearanceClosed", .{});
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
                    try appendChild(a, &children, "topmark", .{ .simple = subs.items });
                }
            }
        }

        // LIGHTS sector tree + rhythm of light: the LightSectored rule reads the
        // nested sectorCharacteristics (sectored/directional lights); LITDSN02 reads
        // rhythmOfLight for every light's characteristic text. Synthesized from the
        // S-57 LIGHTS simple attributes (port of complex.go buildLightSectors /
        // buildRhythmOfLight). Gated on the S-57 LIGHTS object class (OBJL 75).
        if (f.objl == 75) {
            try buildLightSectors(a, &children, f);
            try buildRhythmOfLight(a, &children, f);
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

        try out.append(a, .{ .feature_index = i, .code = code, .primitive = prim, .root = .{ .simple = attrs.items, .children = children.items }, .points = points });
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
    try std.testing.expectEqual(@as(usize, 2), adapted[0].root.simple.len);
    try std.testing.expectEqualStrings("depthRangeMinimumValue", adapted[0].root.simple[0].name);
    try std.testing.expectEqualStrings("5", adapted[0].root.simple[0].value);
    // resolve("") returns the root itself; depthRangeMinimumValue reads back.
    try std.testing.expectEqualStrings("5", adapted[0].root.resolve("").?.simpleValue("depthRangeMinimumValue").?);
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
    // The topmark complex resolves through the tree: feature.topmark[1].topmarkDaymarkShape.
    const root = &adapted[0].root;
    try std.testing.expectEqual(@as(usize, 1), root.childCount("topmark"));
    const tm = root.resolve("topmark:1").?;
    try std.testing.expectEqualStrings("2", tm.simpleValue("topmarkDaymarkShape").?);
}

test "resolveLightClass routes by sector limits / CATLIT" {
    const mk = struct {
        fn f(attrs: []const s57.Attr) s57.Feature {
            return .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 75, .attrs = attrs };
        }
    }.f;
    try std.testing.expectEqualStrings("LightSectored", resolveLightClass(mk(&.{
        .{ .code = s57.ATTR_SECTR1, .value = "045" }, .{ .code = s57.ATTR_SECTR2, .value = "090" },
    })));
    try std.testing.expectEqualStrings("LightSectored", resolveLightClass(mk(&.{.{ .code = s57.ATTR_CATLIT, .value = "1" }})));
    try std.testing.expectEqualStrings("LightAirObstruction", resolveLightClass(mk(&.{.{ .code = s57.ATTR_CATLIT, .value = "6" }})));
    try std.testing.expectEqualStrings("LightFogDetector", resolveLightClass(mk(&.{.{ .code = s57.ATTR_CATLIT, .value = "7" }})));
    try std.testing.expectEqualStrings("LightAllAround", resolveLightClass(mk(&.{})));
}

test "sectored LIGHTS adapts to LightSectored + nested sectorCharacteristics tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const light_attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_SECTR1, .value = "045" },
        .{ .code = s57.ATTR_SECTR2, .value = "090" },
        .{ .code = s57.ATTR_COLOUR, .value = "1,3" },
        .{ .code = s57.ATTR_LITCHR, .value = "2" },
        .{ .code = s57.ATTR_SIGGRP, .value = "(2)" },
        .{ .code = s57.ATTR_SIGPER, .value = "6" },
        .{ .code = s57.ATTR_VALNMR, .value = "10" },
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 10, .prim = 1, .objl = 75, .refs = &node_ref, .attrs = &light_attrs },
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
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("LightSectored", adapted[0].code);
    const root = &adapted[0].root;

    // sectorCharacteristics[1].lightSector[1] carries the colour (raw; the host splits
    // the S-57 list value) + nominal range; its sectorLimit holds the two bearings.
    try std.testing.expectEqual(@as(usize, 1), root.childCount("sectorCharacteristics"));
    const ls = root.resolve("sectorCharacteristics:1;lightSector:1").?;
    try std.testing.expectEqualStrings("1,3", ls.simpleValue("colour").?);
    try std.testing.expectEqualStrings("10", ls.simpleValue("valueOfNominalRange").?);
    const one = root.resolve("sectorCharacteristics:1;lightSector:1;sectorLimit:1;sectorLimitOne:1").?;
    try std.testing.expectEqualStrings("045", one.simpleValue("sectorBearing").?);
    const two = root.resolve("sectorCharacteristics:1;lightSector:1;sectorLimit:1;sectorLimitTwo:1").?;
    try std.testing.expectEqualStrings("090", two.simpleValue("sectorBearing").?);

    // rhythmOfLight backs the characteristic text (lightCharacteristic + signalPeriod).
    const rol = root.resolve("rhythmOfLight:1").?;
    try std.testing.expectEqualStrings("2", rol.simpleValue("lightCharacteristic").?);
    try std.testing.expectEqualStrings("6", rol.simpleValue("signalPeriod").?);
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
