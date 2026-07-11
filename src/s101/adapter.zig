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
    // Current velocity (knots) -> speed.speedMaximum: CurrentNonGravitational /
    // TidalStreamFloodEbb read feature.speed.speedMaximum to place the "%4.1f kn"
    // label. Same unit both sides, so a straight single-instance-complex wrap.
    .{ .code = s57.ATTR_CURVEL, .complex = "speed", .sub = "speedMaximum" },
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

    /// Whether (lon,lat) lies inside ANY indexed area (depth value irrelevant).
    /// Used for the inTheWater land/water test over the LNDARE and DEPARE indices.
    fn containsPoint(self: DepthIndex, lon: f64, lat: f64) bool {
        for (self.areas) |area| {
            if (lon < area.min_lon or lon > area.max_lon or lat < area.min_lat or lat > area.max_lat) continue;
            if (s57.pointInRingsEvenOdd(lon, lat, area.rings)) return true;
        }
        return false;
    }
};

/// Index the cell's polygons of the given S-57 object classes (rings + DRVAL1 +
/// bbox), for the shoalest-depth and point-in-area lookups. Allocates into `a`.
fn buildAreaIndex(a: std.mem.Allocator, cell: *const s57.Cell, objls: []const u16) ![]DepthArea {
    var areas = std.ArrayList(DepthArea).empty;
    for (cell.features) |f| {
        if (std.mem.indexOfScalar(u16, objls, f.objl) == null) continue;
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

// S-101 structure classes whose rule branches on feature.inTheWater (a producer-
// computed boolean with no S-57 source): a structure in the water is a navigational
// hazard (viewingGroup 12200 + AlertReference:NavHazard) rather than a land feature.
const IN_THE_WATER_CLASSES = [_][]const u8{
    "Building", "BuiltUpArea", "Crane",        "FortifiedStructure",
    "Landmark", "SiloTank",    "SlopeTopline", "WindTurbine",
};
fn readsInTheWater(code: []const u8) bool {
    return listHasStr(&IN_THE_WATER_CLASSES, code);
}
fn listHasStr(list: []const []const u8, want: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, want)) return true;
    return false;
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

// --- S-65 Annex B value-level conversion (Gap A) ----------------------------
// The adapter forwards attribute VALUES verbatim (name-translated only), but S-65
// prohibits or remaps some raw S-57 enumerate values in S-101. Applied per S-57
// attribute code so it covers every feature class that reads the attribute.
//
//   TECSOU (§2.2.3.5): 6 (swept by wire-drag) and 7 (found by laser) are prohibited
//     in S-101 -> drop; 14 (computer generated) -> 17 (hyperspectral imagery). Every
//     surviving S-57 value is already in the S-101 techniqueOfVerticalMeasurement list.
//   QUASOU (§2.2.3.3): 5 (no bottom found) is prohibited for quality of vertical
//     measurement -> drop. (On SOUNDG proper, S-65 re-routes the feature to
//     DepthNoBottomFound; SOUNDG is emitted as a multipoint upstream of this adapter,
//     so here — Wreck/Obstruction/UnderwaterAwashRock — the attribute simply drops.)
//
// TECSOU is an S-57 list, so map element-wise and rejoin; an all-dropped list (or a
// single dropped value) yields "" and the caller omits the attribute.
fn s65RemapValue(a: std.mem.Allocator, code: u16, v: []const u8) ![]const u8 {
    if (code != s57.ATTR_TECSOU and code != s57.ATTR_QUASOU) return v;
    var out = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        if (t.len == 0) continue;
        const n = std.fmt.parseInt(i64, t, 10) catch {
            if (out.items.len > 0) try out.append(a, ',');
            try out.appendSlice(a, t); // non-numeric (unexpected): forward verbatim
            continue;
        };
        const mapped: ?i64 = switch (code) {
            s57.ATTR_TECSOU => switch (n) {
                6, 7 => null, // prohibited in S-101
                14 => 17, // computer generated -> hyperspectral imagery
                else => n,
            },
            s57.ATTR_QUASOU => switch (n) {
                5 => null, // "no bottom found" prohibited for quality of vertical measurement
                else => n,
            },
            else => n,
        };
        if (mapped) |m| {
            if (out.items.len > 0) try out.append(a, ',');
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{m}));
        }
    }
    return out.items;
}

/// S-65 §2.2.3 QUAPOS -> qualityOfHorizontalMeasurement value map (Gap A.1). The raw
/// S-57 QUAPOS enumerate is NOT a valid S-101 value as-is: 3/6/7/8/9/11 collapse to 4
/// (approximate), 4 and 5 pass through unchanged, and 1 (surveyed) / 2 (unsurveyed) /
/// 10 (precisely known) have no S-101 quality-of-horizontal-measurement equivalent and
/// drop (null, as does the 0 "absent" aggregate). Applied to the featureQuapos
/// aggregate; the low-accuracy dashed-line switch reads that raw aggregate directly
/// (scene), so this remap only shapes the value carried in the adapted feature model.
fn s65RemapQuapos(q: i32) ?i64 {
    return switch (q) {
        3, 4, 6, 7, 8, 9, 11 => 4,
        5 => 5,
        else => null, // 0 absent; 1/2/10 have no S-101 equivalent
    };
}

/// Drop enumerate values not on the S-101 per-class permitted list (FeatureCatalogue
/// attributeBinding <permittedValues>; S-65 Table A-2 "restricted allowable values").
/// List-valued attributes filter element-wise; a fully-emptied list returns "" and the
/// caller omits the attribute. Attributes with no per-class restriction pass through,
/// as do non-numeric elements (defensive — permitted lists only bind enumerations).
/// Runs AFTER s65RemapValue, so a remapped value (TECSOU 14->17) is checked as 17.
fn filterPermitted(a: std.mem.Allocator, class: []const u8, attr: []const u8, v: []const u8) ![]const u8 {
    const allowed = catalogue.permittedValues(class, attr) orelse return v;
    var out = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        if (t.len == 0) continue;
        const n = std.fmt.parseInt(i64, t, 10) catch {
            if (out.items.len > 0) try out.append(a, ',');
            try out.appendSlice(a, t);
            continue;
        };
        if (std.mem.indexOfScalar(i64, allowed, n) == null) continue; // off-list -> drop
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, t);
    }
    return out.items;
}

// --- S-65 Annex B §E per-object whole-attribute drop-list (Gap E) -----------
// S-65 lists attributes that "will not be converted" for a given S-57 object: the
// S-101 feature class either prohibits the attribute or has no home for it. The
// generic attribute loop translates by NAME only, so absent this filter it would
// forward the attribute and the adapted model would carry a value S-101 rejects for
// that class (a rule reading it then renders a plausible-but-wrong chart). This is
// the write-side analog of filterPermitted — that drops off-list VALUES, this drops
// the whole ATTRIBUTE. Keyed by the raw S-57 (object acronym, attribute acronym)
// pair, matching S-65 §E and tools/s101_coverage.zig's `DROP` table (keep the two in
// sync: the coverage tool reports the read-side at-risk view, this enforces the write
// side). SOUNDG/EXPSOU never fires here (SOUNDG is skipped upstream as a multipoint);
// it is kept for a 1:1 correspondence with the coverage table.
const AttrDrop = struct { obj: []const u8, acr: []const u8 };
const DROP_ATTRS = [_]AttrDrop{
    .{ .obj = "DEPARE", .acr = "QUASOU" },
    .{ .obj = "CBLSUB", .acr = "DRVAL1" },
    .{ .obj = "CBLSUB", .acr = "DRVAL2" },
    .{ .obj = "CONZNE", .acr = "STATUS" },
    .{ .obj = "BOYINB", .acr = "MARSYS" },
    .{ .obj = "BOYINB", .acr = "VERLEN" },
    .{ .obj = "PONTON", .acr = "NATCON" },
    .{ .obj = "LNDRGN", .acr = "NATQUA" },
    .{ .obj = "OFSPLF", .acr = "NATCON" },
    .{ .obj = "RADSTA", .acr = "DATEND" },
    .{ .obj = "RADSTA", .acr = "DATSTA" },
    .{ .obj = "RDOSTA", .acr = "ORIENT" },
    .{ .obj = "MAGVAR", .acr = "DATEND" },
    .{ .obj = "MAGVAR", .acr = "DATSTA" },
    .{ .obj = "SWPARE", .acr = "QUASOU" },
    .{ .obj = "SWPARE", .acr = "SOUACC" },
    .{ .obj = "SWPARE", .acr = "TECSOU" },
    .{ .obj = "SOUNDG", .acr = "EXPSOU" },
    .{ .obj = "DRYDOC", .acr = "HORACC" },
    .{ .obj = "FLODOC", .acr = "HORACC" },
    .{ .obj = "OBSTRN", .acr = "NATCON" },
    .{ .obj = "OBSTRN", .acr = "NATQUA" },
    // techniqueOfVerticalMeasurement is prohibited for Quality of Bathymetric Data
    // (S-65 §2.2.3.1); producers wanting to keep it re-encode it on the individual
    // dangers or a Quality of Survey. NOT dropped for M_SREL: S-101 *allows* it on
    // Quality of Survey (S-57 prohibits TECSOU on M_SREL anyway, so it never occurs).
    .{ .obj = "M_QUAL", .acr = "TECSOU" },
};

/// Whether S-65 Annex B §E says S-57 attribute `attl` "will not convert" for S-57
/// object `objl` — i.e. drop the whole attribute from the adapted feature model.
/// Resolves both codes to their S-57 acronyms (the DROP_ATTRS key); an unknown code
/// yields no acronym and so no drop (fail-open: never drop an attribute we can't name).
fn isDroppedAttr(objl: u16, attl: u16) bool {
    const obj = catalogue.acronymByObjl(objl) orelse return false;
    const acr = catalogue.attrAcronym(attl) orelse return false;
    for (DROP_ATTRS) |d|
        if (std.mem.eql(u8, d.obj, obj) and std.mem.eql(u8, d.acr, acr)) return true;
    return false;
}

/// First integer in the S-57 comma-separated list `csv`, or 0 if none.
/// Port of complex.go firstListVal.
fn firstListVal(csv: []const u8) i64 {
    var it = std.mem.splitScalar(u8, csv, ',');
    const first = it.next() orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, first, " "), 10) catch 0;
}

// S-101 natureOfSurface allowable enumerate list (FeatureCatalogue.xml). S-57
// NATSUR can carry values off this list (10 marsh, 12/13, 15/16); S-65 Annex B
// says off-list values "will not convert" — and SeabedArea.lua's abbrev table
// (keyed by exactly this set) would nil-concat and error under pcall on one, so
// dropping them is both conformance-correct and crash-safe.
const NATURE_OF_SURFACE_ALLOWED = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 14, 17, 18 };

/// NATSUR (nature of surface) is an S-57 list; S-101 models each value as its own
/// surfaceCharacteristics complex instance carrying one natureOfSurface (shared
/// enum, no value remap). SeabedArea's rule iterates feature.surfaceCharacteristics
/// and reads [i].natureOfSurface for the SEABED abbreviation text and rock-ledge
/// fill; without this it silent-defaults to the plain fill. Off-list values drop.
fn buildSurfaceCharacteristics(a: std.mem.Allocator, children: *std.ArrayList(ChildEntry), f: s57.Feature) !void {
    const natsur = attrTrim(f, s57.ATTR_NATSUR);
    if (natsur.len == 0) return;
    var it = std.mem.splitScalar(u8, natsur, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        const n = std.fmt.parseInt(i64, t, 10) catch continue;
        if (std.mem.indexOfScalar(i64, &NATURE_OF_SURFACE_ALLOWED, n) == null) continue;
        const subs = try a.alloc(NameVal, 1);
        subs[0] = .{ .name = "natureOfSurface", .value = t };
        try appendChild(a, children, "surfaceCharacteristics", .{ .simple = subs });
    }
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

        // CTRPNT (control point) has no S-101 class of its own; S-65 §4.3 re-models it
        // to Landmark (its categoryOfLandmark is synthesized from CATCTR in adaptCell).
        // Without this it resolves to null and the feature is dropped entirely.
        s57.OBJL_CTRPNT => if (catalogue.hasFeature("Landmark")) return "Landmark",
        // BRIDGE aliases three S-101 classes (Bridge/SpanFixed/SpanOpening); the
        // catalogue's last-alias-wins map resolves objl 11 to SpanOpening, which draws
        // EVERY bridge as an opening span (BRIDGE01 symbol) and leaves the primary
        // Bridge structure rule dead. Route to the primary Bridge class (S-57 has no
        // per-span object to fan out to); openingBridge is synthesized from CATBRG in
        // adaptCell. A point bridge has no Bridge/Span primitive (Bridge.lua errors on
        // Point), so re-model it to Landmark per S-65 §4.8.15.
        s57.OBJL_BRIDGE => {
            if (f.prim == 1) {
                if (catalogue.hasFeature("Landmark")) return "Landmark";
            } else if (catalogue.hasFeature("Bridge")) return "Bridge";
        },
        // DAMCON (dam) aliases the S-101 Dam class, whose rule handles only Curve/Surface
        // and errors on a Point (Dam.lua:55). A point dam therefore has no valid Dam
        // portrayal, so S-65 §4.8.15 re-models it to Landmark (the generic point-structure
        // fallback, as for point BRIDGE). Line/area DAMCON stays Dam. Any CONVIS flows
        // through the generic loop as visualProminence; categoryOfLandmark isn't sourced
        // (DAMCON has no CATLMK) so Landmark draws its generic POSGEN01 mark. Note: CRANES
        // and VEGATN are NOT re-modelled — Crane.lua / Vegetation.lua handle Point natively.
        s57.OBJL_DAMCON => {
            if (f.prim == 1) {
                if (catalogue.hasFeature("Landmark")) return "Landmark";
            } else if (catalogue.hasFeature("Dam")) return "Dam";
        },
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

/// Build the S-101 `information` complex (alias INFORM) that ProcessNauticalInformation
/// reads for the "information available" (VG 90020) / "file available" (VG 90021)
/// indicators — and that pick reports surface. One instance per present source: INFORM
/// -> {language, text}; TXTDSC -> {language, fileReference} (the external text file).
/// `language` is mandatory on the complex (FC multiplicity [1,1]); NOAA text is English.
/// National NINFOM/NTXTDS are deferred. Runs for every feature (any class can carry it).
fn buildInformation(a: std.mem.Allocator, children: *std.ArrayList(ChildEntry), f: s57.Feature) !void {
    const inform = attrTrim(f, s57.ATTR_INFORM);
    if (inform.len > 0) {
        const subs = try a.alloc(NameVal, 2);
        subs[0] = .{ .name = "language", .value = "eng" };
        subs[1] = .{ .name = "text", .value = inform };
        try appendChild(a, children, "information", .{ .simple = subs });
    }
    const txtdsc = attrTrim(f, s57.ATTR_TXTDSC);
    if (txtdsc.len > 0) {
        const subs = try a.alloc(NameVal, 2);
        subs[0] = .{ .name = "language", .value = "eng" };
        subs[1] = .{ .name = "fileReference", .value = txtdsc };
        try appendChild(a, children, "information", .{ .simple = subs });
    }
}

/// Position/depth accuracy a ZOC category asserts, per the ZOC table (S-57 App. A
/// Ch. 2, as amended by Supplement 3): ±(fixed + factor·depth) metres. D (5) and
/// U (6) are unquantified ("worse than ZOC C" / "unassessed") — no row, so no
/// uncertainty is emitted for them. An empty factor means the row has no
/// depth-dependent term (addSimple drops empties).
const ZocAccuracy = struct { hfix: []const u8, hvar: []const u8, vfix: []const u8, vvar: []const u8 };
fn zocAccuracy(catzoc: i64) ?ZocAccuracy {
    return switch (catzoc) {
        1 => .{ .hfix = "5", .hvar = "0.05", .vfix = "0.5", .vvar = "0.01" }, // A1
        2 => .{ .hfix = "20", .hvar = "", .vfix = "1.0", .vvar = "0.02" }, // A2
        3 => .{ .hfix = "50", .hvar = "", .vfix = "1.0", .vvar = "0.02" }, // B
        4 => .{ .hfix = "500", .hvar = "", .vfix = "2.0", .vvar = "0.05" }, // C
        else => null,
    };
}

/// M_QUAL -> Quality of Bathymetric Data (S-65 §2.2.3.1, "one of the most significant
/// changes from S-57 to S-101"): deconstruct CATZOC into its component parts, per the
/// ZOC table each category encodes. categoryOfZoneOfConfidenceInData stays identical
/// to CATZOC — ECDIS portrayal derives from it (the dual-fuel discipline) — and the
/// deconstructed mandatory components ride alongside:
///   - dataAssessment: 1 (assessed) for ZOC A1..D; 3 (unassessed) for U or absent.
///     (2 "assessed (oceanic)" needs a producer decision no converter can make.)
///   - categoryOfTemporalVariation: 5 (unlikely to change), or 6 (unassessed) for U.
///   - fullSeafloorCoverageAchieved + featuresDetected: A1/A2 = full area search with
///     significant features detected and least depths measured (true); B/C/D = not
///     (false — that IS the ZOC row's assertion, not an invention); U/absent = omitted
///     (unassessed; "populated as empty (null)" per the guidance).
///   - zoneOfConfidence[1].horizontal/verticalUncertainty from the ZOC row's accuracy
///     formula; a populated POSACC/SOUACC (a measured accuracy) overrides the row's
///     class bound (§2.2.3.1).
///   - surveyDateRange{dateStart<-SURSTA, dateEnd<-SUREND} when populated (dateEnd is
///     mandatory in S-101 but stays null when SUREND is absent, per the guidance).
/// zoneOfConfidence itself is ALWAYS emitted for this class: the rule draws the
/// NODATA03 "quality unknown" fill from an entry with no category
/// (QualityOfBathymetricData.lua:57, mirroring S-52's bare-M_QUAL lookup line), so
/// omitting the entry when CATZOC is absent rendered nothing at all — a silent miss.
/// An off-list CATZOC (outside 1..6) is treated as absent: the rule would
/// concatenate a nil symbol name and error.
fn buildQualityOfBathymetricData(a: std.mem.Allocator, attrs: *std.ArrayList(NameVal), children: *std.ArrayList(ChildEntry), f: s57.Feature) !void {
    const catzoc_raw = attrTrim(f, s57.ATTR_CATZOC);
    const catzoc = firstListVal(catzoc_raw);
    const assessed = catzoc >= 1 and catzoc <= 5;
    try attrs.append(a, .{ .name = "dataAssessment", .value = if (assessed) "1" else "3" });
    try attrs.append(a, .{ .name = "categoryOfTemporalVariation", .value = if (assessed) "5" else "6" });
    if (assessed) {
        const full = catzoc <= 2; // A1/A2: full area search undertaken
        const fv = if (full) "true" else "false";
        try attrs.append(a, .{ .name = "fullSeafloorCoverageAchieved", .value = fv });
        var fd = NodeBuilder{ .a = a };
        try fd.addSimple("significantFeaturesDetected", fv);
        try fd.addSimple("leastDepthOfDetectedFeaturesMeasured", fv);
        try appendChild(a, children, "featuresDetected", fd.build());
    }

    var zoc = NodeBuilder{ .a = a };
    if (catzoc >= 1 and catzoc <= 6) try zoc.addSimple("categoryOfZoneOfConfidenceInData", catzoc_raw);
    const acc = zocAccuracy(catzoc);
    const posacc = attrTrim(f, s57.ATTR_POSACC);
    if (posacc.len > 0 or acc != null) {
        var h = NodeBuilder{ .a = a };
        if (posacc.len > 0) {
            try h.addSimple("uncertaintyFixed", posacc);
        } else {
            try h.addSimple("uncertaintyFixed", acc.?.hfix);
            try h.addSimple("uncertaintyVariableFactor", acc.?.hvar);
        }
        try zoc.addChild("horizontalPositionUncertainty", h.build());
    }
    const souacc = attrTrim(f, s57.ATTR_SOUACC);
    if (souacc.len > 0 or acc != null) {
        var vu = NodeBuilder{ .a = a };
        if (souacc.len > 0) {
            try vu.addSimple("uncertaintyFixed", souacc);
        } else {
            try vu.addSimple("uncertaintyFixed", acc.?.vfix);
            try vu.addSimple("uncertaintyVariableFactor", acc.?.vvar);
        }
        try zoc.addChild("verticalUncertainty", vu.build());
    }
    try appendChild(a, children, "zoneOfConfidence", zoc.build());

    try buildSurveyDateRange(a, children, f);
}

/// surveyDateRange{dateStart<-SURSTA, dateEnd<-SUREND} for the quality meta classes
/// (dateEnd is mandatory in S-101 for both Quality of Bathymetric Data and Quality of
/// Survey, but stays null when SUREND is absent, per the conversion guidance).
fn buildSurveyDateRange(a: std.mem.Allocator, children: *std.ArrayList(ChildEntry), f: s57.Feature) !void {
    const sursta = attrTrim(f, s57.ATTR_SURSTA);
    const surend = attrTrim(f, s57.ATTR_SUREND);
    if (sursta.len > 0 or surend.len > 0) {
        var sdr = NodeBuilder{ .a = a };
        try sdr.addSimple("dateStart", sursta);
        try sdr.addSimple("dateEnd", surend);
        try appendChild(a, children, "surveyDateRange", sdr.build());
    }
}

/// Adapt all mappable features of a cell. Allocates into `a` (use an arena).
pub fn adaptCell(a: std.mem.Allocator, cell: *const s57.Cell) ![]Adapted {
    var out = std.ArrayList(Adapted).empty;
    const depth_index = DepthIndex{ .areas = try buildAreaIndex(a, cell, &.{ 42, 46 }) }; // DEPARE / DRGARE = water
    // Land areas, for the inTheWater test: a structure is "in the water" when its
    // representative point is over a depth area AND over no LNDARE (S-65 §4.8.15).
    const land_index = DepthIndex{ .areas = try buildAreaIndex(a, cell, &.{s57.OBJL_LNDARE}) };
    // TOPMAR features (built from the FULL feature set) fold into co-located
    // buoys/beacons below; the standalone features are then skipped.
    var topmark_index = try buildTopmarkIndex(a, cell);
    for (cell.features, 0..) |f, i| {
        // SOUNDG (objl 129) is emitted directly as a multipoint by scene
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
        // S-65 Annex B §10.1.1: surface is NOT an allowable geometric primitive for
        // Recommended Track, so "RECTRC of geometric primitive area will not be converted
        // across to S-101" (the producer should have re-encoded it as FAIRWY/TWRTPT/DWRTPT
        // or a line RECTRC). Converting it anyway routes to the Curve-only RecommendedTrack
        // rule and paints QUESMRK1, so skip it here — it is simply not carried into S-101.
        if (f.prim == 3 and std.mem.eql(u8, code, "RecommendedTrack")) continue;
        var attrs = std.ArrayList(NameVal).empty;
        var children = std.ArrayList(ChildEntry).empty;
        var name: []const u8 = "";
        // M_QUAL deconstructs (S-65 §2.2.3.1): five S-57 attributes feed the proper
        // S-101 complexes below instead of the generic name-for-name loop. M_SREL ->
        // Quality of Survey shares the surveyDateRange piece (§2.2.3.2).
        const qobd = std.mem.eql(u8, code, "QualityOfBathymetricData");
        const qos = std.mem.eql(u8, code, "QualityOfSurvey");
        for (f.attrs) |at| {
            // A present-but-blank S-57 attribute (e.g. an unknown VALSOU, all
            // spaces) means "absent": serving "" would make the framework build a
            // malformed ScaledDecimal{Value=nil} for a 'real' attr (tonumber("")
            // == nil), which crashes the danger depth comparison. Skip it, and
            // serve the trimmed value so numeric strings parse cleanly.
            const v = std.mem.trim(u8, at.value, " ");
            if (v.len == 0) continue;
            if (at.code == s57.ATTR_OBJNAM) name = v; // OBJNAM -> featureName
            // Consumed by buildQualityOfBathymetricData: forwarding them flat would be
            // model-noise (SOUACC aliases the *complex* verticalUncertainty itself,
            // SURSTA/SUREND the bare dateStart/dateEnd, CATZOC the bare category).
            if (qobd) switch (at.code) {
                s57.ATTR_CATZOC, s57.ATTR_POSACC, s57.ATTR_SOUACC, s57.ATTR_SURSTA, s57.ATTR_SUREND => continue,
                else => {},
            };
            // Quality of Survey likewise consumes SURSTA/SUREND into its mandatory
            // surveyDateRange complex (S-65 §2.2.3.2) instead of flat dateStart/dateEnd.
            if (qos) switch (at.code) {
                s57.ATTR_SURSTA, s57.ATTR_SUREND => continue,
                else => {},
            };
            // INFORM/TXTDSC feed the `information` COMPLEX (buildInformation below);
            // forwarding them flat would mis-model a complex as a simple attr the
            // framework then ignores (isComplex("information")).
            switch (at.code) {
                s57.ATTR_INFORM, s57.ATTR_TXTDSC => continue,
                else => {},
            }
            if (catalogue.resolveAttrByCode(at.code)) |aname| {
                // S-65 Annex B §E: some attributes "will not convert" for this S-57
                // object (S-101 prohibits them for the class) — drop the whole
                // attribute so the adapted model never carries a value the class
                // rejects. Precedes the value-level filters below.
                if (isDroppedAttr(f.objl, at.code)) continue;
                // S-65 Annex B value-level conversion: some raw S-57 values are
                // invalid in S-101 and must be dropped or remapped before the rule
                // reads them. First the global value remaps (TECSOU/QUASOU), then the
                // per-class permitted-value restriction. "" => every value dropped, so
                // omit the attribute.
                const tv = try s65RemapValue(a, at.code, v);
                const pv = try filterPermitted(a, code, aname, tv);
                if (pv.len > 0) try attrs.append(a, .{ .name = aname, .value = pv });
            }
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
        // M_QUAL -> Quality of Bathymetric Data: deconstruct CATZOC into the
        // mandatory S-101 components + POSACC/SOUACC/SURSTA/SUREND (S-65 §2.2.3.1).
        if (qobd) try buildQualityOfBathymetricData(a, &attrs, &children, f);
        // M_SREL -> Quality of Survey: the mandatory surveyDateRange from SURSTA/
        // SUREND (§2.2.3.2). SURATH/SURTYP flow the generic loop (FC aliases).
        if (qos) try buildSurveyDateRange(a, &children, f);
        // orientation / clearance complexes from their S-57 simple attrs, so the
        // route + bridge rules (NavigationLine, RecommendedTrack, SpanOpening) can
        // index feature.<complex>.<value> instead of erroring on a nil complex.
        for (complex_from_simple) |m| {
            // Gate binds horizontalClearanceOpen, not …Fixed (handled just below), so
            // don't wrap its HORCLR into the class-invalid Fixed complex.
            if (m.code == s57.ATTR_HORCLR and std.mem.eql(u8, code, "Gate")) continue;
            // S-65 Annex B §E also drops these source attrs for some classes (e.g.
            // RDOSTA drops ORIENT), so don't synthesize their complex either.
            if (isDroppedAttr(f.objl, m.code)) continue;
            const raw = f.attr(m.code) orelse continue;
            const v = std.mem.trim(u8, raw, " ");
            if (v.len == 0) continue;
            const subs = try a.alloc(NameVal, 1);
            subs[0] = .{ .name = m.sub, .value = v };
            try appendChild(a, &children, m.complex, .{ .simple = subs });
        }
        // Gate's HORCLR is a movable gate's clearance-when-open: its S-101 FeatureCatalogue
        // binding permits horizontalClearanceOpen only (Canal/DockArea/Span… bind …Fixed,
        // covered above). S-57 has a single HORCLR — no fixed/open split — so this is a
        // class-keyed route, not a value split. Without it the framework drops the
        // class-invalid Fixed complex and the "H.clr op" label never draws.
        if (std.mem.eql(u8, code, "Gate")) {
            const hc = attrTrim(f, s57.ATTR_HORCLR);
            if (hc.len > 0) {
                const subs = try a.alloc(NameVal, 1);
                subs[0] = .{ .name = "horizontalClearanceValue", .value = hc };
                try appendChild(a, &children, "horizontalClearanceOpen", .{ .simple = subs });
            }
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

        // SeabedArea reads feature.surfaceCharacteristics[i].natureOfSurface; split
        // the S-57 NATSUR list into per-value complex instances (off-list values drop).
        if (std.mem.eql(u8, code, "SeabedArea")) try buildSurfaceCharacteristics(a, &children, f);

        // Dolphin reads feature.categoryOfDolphin to pick the deviation (2) vs
        // mooring symbol. S-101 categoryOfDolphin shares CATMOR's 1=mooring /
        // 2=deviation coding and the class only exists for CATMOR in {1,2}
        // (resolveMooringClass), so forward the value directly — no S-57 alias
        // maps to categoryOfDolphin, so it is synthesized here rather than sourced.
        if (std.mem.eql(u8, code, "Dolphin")) {
            const cm = attrTrim(f, s57.ATTR_CATMOR);
            if (cm.len > 0) try attrs.append(a, .{ .name = "categoryOfDolphin", .value = cm });
        }

        // Bridge.lua branches on feature.openingBridge to add the opening-bridge symbol
        // (BRIDGE01). It has no S-57 alias (a producer boolean), so derive it from CATBRG
        // per S-52 (Bridge.lua:55): categories 2..8 (opening / swing / lifting / bascule /
        // pontoon / draw / transporter) are opening; 1 (fixed) is not. S-57 BRIDGE carries
        // a single CATBRG. (categoryOfOpeningBridge, which aliases CATBRG, flows through the
        // generic loop + filterPermitted [3,4,5,7] for a valid model, but no rule reads it.)
        if (std.mem.eql(u8, code, "Bridge")) {
            const cb = firstListVal(attrTrim(f, s57.ATTR_CATBRG));
            if (cb >= 2 and cb <= 8) try attrs.append(a, .{ .name = "openingBridge", .value = "true" });
        }

        // CTRPNT -> Landmark reads feature.categoryOfLandmark to pick its symbol. That
        // attribute aliases CATLMK (not CATCTR), so the generic attribute loop never
        // sources it for a control point; synthesize it from CATCTR per S-65 §4.3:
        // 1 (triangulation point) -> 22 (triangulation mark), 5 (boundary mark) -> 23
        // (boundary mark). Other CATCTR values have no S-101 landmark category and stay
        // absent (Landmark.lua's generic POSGEN01 default). Gated on CTRPNT so a native
        // LNDMRK's CATLMK-sourced categoryOfLandmark is untouched.
        if (f.objl == s57.OBJL_CTRPNT) {
            const mapped: ?[]const u8 = switch (firstListVal(attrTrim(f, s57.ATTR_CATCTR))) {
                1 => "22",
                5 => "23",
                else => null,
            };
            if (mapped) |m| try attrs.append(a, .{ .name = "categoryOfLandmark", .value = m });
        }

        // LocalMagneticAnomaly reads feature.valueOfLocalMagneticAnomaly[1].magneticAnomalyValue
        // to place the "(N°)" deviation label. S-57 VALLMA maps 1:1 to magneticAnomalyValue
        // (same real degrees; FC alias), so wrap it as a single-instance complex. The
        // optional referenceDirection (E/W) has no S-57 source and stays absent — the rule
        // then formats the bare "(%.0f°)" branch.
        if (std.mem.eql(u8, code, "LocalMagneticAnomaly")) {
            const vlma = attrTrim(f, s57.ATTR_VALLMA);
            if (vlma.len > 0) {
                const subs = try a.alloc(NameVal, 1);
                subs[0] = .{ .name = "magneticAnomalyValue", .value = vlma };
                try appendChild(a, &children, "valueOfLocalMagneticAnomaly", .{ .simple = subs });
            }
        }

        // inTheWater (S-65 §4.8.15): a structure over a depth area and over no land
        // area is a navigational hazard, not a land feature. No S-57 source exists —
        // it's a producer spatial computation — so derive it from the water/land
        // indices. Emit true only when confidently in the water; otherwise leave the
        // attribute absent (the rule's land-plane default). Never emit false: a false
        // value would still be a positive assertion the ENC did not make.
        if (readsInTheWater(code)) {
            if (representativePoint(a, cell, f)) |pt| {
                if (depth_index.containsPoint(pt.lon(), pt.lat()) and !land_index.containsPoint(pt.lon(), pt.lat()))
                    try attrs.append(a, .{ .name = "inTheWater", .value = "true" });
            }
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
        // information complex (INFORM/TXTDSC) — nautical-info indicators + pick text.
        try buildInformation(a, &children, f);

        if (f.objl == 75) {
            try buildLightSectors(a, &children, f);
            try buildRhythmOfLight(a, &children, f);
            // majorLight: LightAllAround draws the range ring (ArcByRadius 0,0,26,0,360 —
            // a full circle stroked black + the light colour) ONLY when feature.majorLight
            // is set. It has no S-57 source; the FC calls it a compiler cartographic hint
            // ("a cartographic attribute to aid the compiler ... not ... a formal
            // classification method for lights"), so the S-57->S-101 conversion derives it:
            // a light of nominal range >= 10 M is a major light (the paper-chart cutoff).
            // LightAllAround itself re-excludes aero (CATLIT 5) and Morse (LITCHR 12) lights
            // (notAeroLight / notMorseCodeLight), so only the range test is supplied here.
            const valnmr = std.fmt.parseFloat(f64, attrTrim(f, s57.ATTR_VALNMR)) catch -1.0;
            if (valnmr >= 10.0) try attrs.append(a, .{ .name = "majorLight", .value = "true" });
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

        // Low-accuracy geometry (QUAPOS): expose the per-feature aggregate as the
        // S-101 qualityOfHorizontalMeasurement, remapped per S-65 §2.2.3 (the raw
        // S-57 QUAPOS enumerate is not a valid S-101 value — s65RemapQuapos drops
        // 1/2/10 and collapses 3/6/7/8/9/11 to 4). The approximate-position dashed
        // line style is applied separately in the instruction-translation layer,
        // which reads the raw aggregate directly (scene cell.featureQuapos), so it
        // is unaffected by this remap. The per-class permitted list still applies —
        // Quality of Survey allows only 4 (§2.2.3.2), so a doubtful-position 5 drops.
        if (s65RemapQuapos(cell.featureQuapos(f))) |m| {
            const qv = try std.fmt.allocPrint(a, "{d}", .{m});
            const pv = try filterPermitted(a, code, "qualityOfHorizontalMeasurement", qv);
            if (pv.len > 0) try attrs.append(a, .{ .name = "qualityOfHorizontalMeasurement", .value = pv });
        }

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

test "Gap E: isDroppedAttr matches the S-65 §E per-object drop-list" {
    // On the list -> dropped (S-57 object / attribute numeric codes; see DROP_ATTRS).
    try std.testing.expect(isDroppedAttr(42, 125)); // DEPARE / QUASOU
    try std.testing.expect(isDroppedAttr(134, 125)); // SWPARE / QUASOU
    try std.testing.expect(isDroppedAttr(134, 144)); // SWPARE / SOUACC
    try std.testing.expect(isDroppedAttr(134, 156)); // SWPARE / TECSOU
    try std.testing.expect(isDroppedAttr(22, 87)); // CBLSUB / DRVAL1
    try std.testing.expect(isDroppedAttr(22, 88)); // CBLSUB / DRVAL2
    try std.testing.expect(isDroppedAttr(105, 117)); // RDOSTA / ORIENT
    try std.testing.expect(isDroppedAttr(86, 112)); // OBSTRN / NATCON
    // Off the list -> kept.
    try std.testing.expect(!isDroppedAttr(42, 87)); // DEPARE / DRVAL1 (kept: depth range)
    try std.testing.expect(!isDroppedAttr(134, 87)); // SWPARE / DRVAL1 (not on the list)
    try std.testing.expect(!isDroppedAttr(86, 156)); // OBSTRN / TECSOU (OBSTRN drops NATCON/NATQUA only)
    try std.testing.expect(!isDroppedAttr(9999, 125)); // unknown object -> no acronym -> kept
    try std.testing.expect(!isDroppedAttr(42, 9999)); // unknown attribute -> no acronym -> kept
}

test "Gap E: DepthArea drops QUASOU but keeps DRVAL1 through the adapter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // DEPARE carrying DRVAL1 (kept -> depthRangeMinimumValue) and QUASOU (S-65 §E:
    // dropped for DEPARE). QUASOU=1 is a valid value with no per-class permitted
    // restriction (permitted[DepthArea][qualityOfVerticalMeasurement] is absent), so
    // absent the §E drop it WOULD be forwarded — this pins the drop, not filterPermitted.
    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "5" },
        .{ .code = s57.ATTR_QUASOU, .value = "1" },
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &attrs }, // DEPARE
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
    const root = &adapted[0].root;
    try std.testing.expectEqualStrings("5", root.simpleValue("depthRangeMinimumValue").?);
    try std.testing.expect(root.simpleValue("qualityOfVerticalMeasurement") == null);
}

test "Gap E: SWPARE (HighConfidenceDepthArea) drops QUASOU/SOUACC/TECSOU, keeps DRVAL1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // SWPARE: S-65 §E drops QUASOU, SOUACC, TECSOU. Non-remapped/permitted values
    // (QUASOU=1 not the =5 drop; TECSOU=4 not a prohibited value) so the §E drop is
    // what removes them. DRVAL1 stays as the least-depth control.
    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "7" },
        .{ .code = s57.ATTR_QUASOU, .value = "1" },
        .{ .code = 144, .value = "0.5" }, // SOUACC -> verticalUncertainty
        .{ .code = s57.ATTR_TECSOU, .value = "4" },
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 134, .attrs = &attrs }, // SWPARE
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
    try std.testing.expectEqualStrings("HighConfidenceDepthArea", adapted[0].code); // IHO rename of SweptArea
    const root = &adapted[0].root;
    try std.testing.expectEqualStrings("7", root.simpleValue("depthRangeMinimumValue").?);
    try std.testing.expect(root.simpleValue("qualityOfVerticalMeasurement") == null);
    try std.testing.expect(root.simpleValue("verticalUncertainty") == null);
    try std.testing.expect(root.simpleValue("techniqueOfVerticalMeasurement") == null);
}

test "Gap B: point DAMCON re-models to Landmark; line/area DAMCON stays Dam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Dam.lua has no Point branch (errors on Point), so S-65 §4.8.15 routes a point
    // dam to Landmark; a line/area dam stays Dam (which handles Curve/Surface).
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = s57.OBJL_DAMCON }, // point -> Landmark
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = s57.OBJL_DAMCON }, // line  -> Dam
        .{ .rcnm = 100, .rcid = 3, .prim = 3, .objl = s57.OBJL_DAMCON }, // area  -> Dam
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
    try std.testing.expectEqual(@as(usize, 3), adapted.len);
    try std.testing.expectEqualStrings("Landmark", adapted[0].code); // point
    try std.testing.expectEqualStrings("Point", adapted[0].primitive);
    try std.testing.expectEqualStrings("Dam", adapted[1].code); // line
    try std.testing.expectEqualStrings("Dam", adapted[2].code); // area
}

test "TS_FEB (objl 160) resolves to TidalStreamFloodEbb with synthesized attrs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // objl 160 = TS_FEB (tidal stream flood/ebb): was missing from s57codes.json's
    // object map, so it resolved to null and rendered as the QUESMRK1 unknown mark.
    // With the code added it routes to TidalStreamFloodEbb, whose rule reads
    // categoryOfTidalStream (CAT_TS), orientationValue (ORIENT), speed.speedMaximum
    // (CURVEL) — all synthesized by the adapter.
    const attrs = [_]s57.Attr{
        .{ .code = 188, .value = "1" }, // CAT_TS -> categoryOfTidalStream (1 = flood)
        .{ .code = s57.ATTR_ORIENT, .value = "195" }, // ORIENT -> orientationValue
        .{ .code = s57.ATTR_CURVEL, .value = "1.5" }, // CURVEL -> speed.speedMaximum
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 160, .attrs = &attrs },
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
    try std.testing.expectEqualStrings("TidalStreamFloodEbb", adapted[0].code);
    const root = &adapted[0].root;
    try std.testing.expectEqualStrings("1", root.simpleValue("categoryOfTidalStream").?);
    try std.testing.expectEqualStrings("195", root.simpleValue("orientationValue").?);
    // speed complex from CURVEL: feature.speed.speedMaximum
    try std.testing.expectEqualStrings("1.5", root.resolve("speed:1").?.simpleValue("speedMaximum").?);
}

test "S-65 10.1.1: area RECTRC is not converted; line RECTRC becomes RecommendedTrack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // RECTRC (objl 109) is L,A in S-57 but Curve-only in S-101. S-65 Annex B 10.1.1: a surface
    // (area) RECTRC "will not be converted across to S-101" — the producer should have re-encoded
    // it (FAIRWY/TWRTPT/DWRTPT or a line RECTRC). So the adapter DROPS the area one rather than
    // routing it to the Curve-only rule (which would paint QUESMRK1); the line one converts.
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 109 }, // area RECTRC -> dropped
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = 109 }, // line RECTRC -> RecommendedTrack
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
    try std.testing.expectEqual(@as(usize, 1), adapted.len); // only the line RECTRC survives
    try std.testing.expectEqualStrings("RecommendedTrack", adapted[0].code);
    try std.testing.expectEqualStrings("Curve", adapted[0].primitive);
    try std.testing.expectEqual(@as(usize, 1), adapted[0].feature_index); // = feats[1], the line one
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

test "CURVEL synthesizes the speed complex (speed.speedMaximum)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const cur_attrs = [_]s57.Attr{.{ .code = s57.ATTR_CURVEL, .value = "2.5" }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 36, .refs = &node_ref, .attrs = &cur_attrs }, // CURENT
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
    try std.testing.expectEqualStrings("CurrentNonGravitational", adapted[0].code);
    // feature.speed[1].speedMaximum resolves to the raw CURVEL value.
    const root = &adapted[0].root;
    try std.testing.expectEqual(@as(usize, 1), root.childCount("speed"));
    try std.testing.expectEqualStrings("2.5", root.resolve("speed:1").?.simpleValue("speedMaximum").?);
}

test "NATSUR splits into surfaceCharacteristics instances, off-list values drop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // NATSUR "4,10,9": 4 (sand) and 9 (rock) are S-101-allowable; 10 (marsh) is not.
    const attrs = [_]s57.Attr{.{ .code = s57.ATTR_NATSUR, .value = "4,10,9" }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 121, .attrs = &attrs }, // SBDARE surface
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
    try std.testing.expectEqualStrings("SeabedArea", adapted[0].code);
    const root = &adapted[0].root;
    // 10 dropped -> exactly two instances, order preserved (4 then 9).
    try std.testing.expectEqual(@as(usize, 2), root.childCount("surfaceCharacteristics"));
    try std.testing.expectEqualStrings("4", root.resolve("surfaceCharacteristics:1").?.simpleValue("natureOfSurface").?);
    try std.testing.expectEqualStrings("9", root.resolve("surfaceCharacteristics:2").?.simpleValue("natureOfSurface").?);
}

test "MORFAC CATMOR=2 routes to Dolphin carrying categoryOfDolphin=2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const attrs = [_]s57.Attr{.{ .code = s57.ATTR_CATMOR, .value = "2" }}; // deviation dolphin
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = s57.OBJL_MORFAC, .refs = &node_ref, .attrs = &attrs },
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
    try std.testing.expectEqualStrings("Dolphin", adapted[0].code);
    try std.testing.expectEqualStrings("2", adapted[0].root.resolve("").?.simpleValue("categoryOfDolphin").?);
}

test "VALLMA synthesizes valueOfLocalMagneticAnomaly[1].magneticAnomalyValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const attrs = [_]s57.Attr{.{ .code = s57.ATTR_VALLMA, .value = "7" }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 78, .refs = &node_ref, .attrs = &attrs }, // LOCMAG
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
    try std.testing.expectEqualStrings("LocalMagneticAnomaly", adapted[0].code);
    const root = &adapted[0].root;
    try std.testing.expectEqual(@as(usize, 1), root.childCount("valueOfLocalMagneticAnomaly"));
    try std.testing.expectEqualStrings("7", root.resolve("valueOfLocalMagneticAnomaly:1").?.simpleValue("magneticAnomalyValue").?);
}

test "CTRPNT routes to Landmark with categoryOfLandmark synthesized from CATCTR (S-65 §4.3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    // CATCTR=1 (triangulation point) -> categoryOfLandmark 22; CATCTR=3 (fixed point)
    // has no S-101 landmark category -> absent. Two co-located control points.
    const attrs_a = [_]s57.Attr{.{ .code = s57.ATTR_CATCTR, .value = "1" }};
    const attrs_b = [_]s57.Attr{.{ .code = s57.ATTR_CATCTR, .value = "3" }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = s57.OBJL_CTRPNT, .refs = &node_ref, .attrs = &attrs_a },
        .{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = s57.OBJL_CTRPNT, .refs = &node_ref, .attrs = &attrs_b },
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
    try std.testing.expectEqual(@as(usize, 2), adapted.len);
    try std.testing.expectEqualStrings("Landmark", adapted[0].code);
    try std.testing.expectEqualStrings("22", adapted[0].root.resolve("").?.simpleValue("categoryOfLandmark").?);
    // CATCTR=3 -> no categoryOfLandmark (generic landmark default in the rule).
    try std.testing.expectEqual(@as(?[]const u8, null), adapted[1].root.resolve("").?.simpleValue("categoryOfLandmark"));
}

test "Gate routes HORCLR to horizontalClearanceOpen, not horizontalClearanceFixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const attrs = [_]s57.Attr{.{ .code = s57.ATTR_HORCLR, .value = "12.5" }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 61, .refs = &node_ref, .attrs = &attrs }, // GATCON -> Gate
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
    try std.testing.expectEqualStrings("Gate", adapted[0].code);
    const root = &adapted[0].root;
    // HORCLR -> horizontalClearanceOpen[1].horizontalClearanceValue (the bound attr)…
    try std.testing.expectEqual(@as(usize, 1), root.childCount("horizontalClearanceOpen"));
    try std.testing.expectEqualStrings("12.5", root.resolve("horizontalClearanceOpen:1").?.simpleValue("horizontalClearanceValue").?);
    // …and NOT the class-invalid horizontalClearanceFixed.
    try std.testing.expectEqual(@as(usize, 0), root.childCount("horizontalClearanceFixed"));
}

test "BRIDGE re-models: line -> Bridge (openingBridge from CATBRG), point -> Landmark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const opening = [_]s57.Attr{.{ .code = s57.ATTR_CATBRG, .value = "2" }}; // opening
    const fixed = [_]s57.Attr{.{ .code = s57.ATTR_CATBRG, .value = "1" }}; // fixed
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 2, .objl = s57.OBJL_BRIDGE, .attrs = &opening }, // line, opening
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = s57.OBJL_BRIDGE, .attrs = &fixed }, // line, fixed
        .{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = s57.OBJL_BRIDGE, .refs = &node_ref }, // point
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
    try std.testing.expectEqual(@as(usize, 3), adapted.len);
    // CATBRG=2 (opening): Bridge with openingBridge=true (drives the BRIDGE01 symbol).
    try std.testing.expectEqualStrings("Bridge", adapted[0].code);
    try std.testing.expectEqualStrings("true", adapted[0].root.resolve("").?.simpleValue("openingBridge").?);
    // CATBRG=1 (fixed): Bridge, no openingBridge (drawn as a plain fixed bridge).
    try std.testing.expectEqualStrings("Bridge", adapted[1].code);
    try std.testing.expectEqual(@as(?[]const u8, null), adapted[1].root.resolve("").?.simpleValue("openingBridge"));
    // Point bridge -> Landmark (Bridge.lua has no Point branch; S-65 §4.8.15).
    try std.testing.expectEqualStrings("Landmark", adapted[2].code);
}

test "LIGHTS: majorLight synthesized from VALNMR >= 10 M (drives the LightAllAround range ring)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    // white all-around light, nominal range 15 M (>= 10) -> majorLight
    const major = [_]s57.Attr{
        .{ .code = s57.ATTR_COLOUR, .value = "1" },
        .{ .code = s57.ATTR_LITCHR, .value = "2" },
        .{ .code = s57.ATTR_VALNMR, .value = "15" },
    };
    // same but range 5 M (< 10) -> no majorLight
    const minor = [_]s57.Attr{
        .{ .code = s57.ATTR_COLOUR, .value = "1" },
        .{ .code = s57.ATTR_LITCHR, .value = "2" },
        .{ .code = s57.ATTR_VALNMR, .value = "5" },
    };
    // absent VALNMR -> no majorLight (e.g. a co-located reduced-intensity standby)
    const norange = [_]s57.Attr{
        .{ .code = s57.ATTR_COLOUR, .value = "1" },
        .{ .code = s57.ATTR_LITCHR, .value = "2" },
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 75, .attrs = &major, .refs = &node_ref },
        .{ .rcnm = 100, .rcid = 2, .prim = 1, .objl = 75, .attrs = &minor, .refs = &node_ref },
        .{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 75, .attrs = &norange, .refs = &node_ref },
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
    try cell.nodes.put((@as(u64, s57.RCNM_VI) << 32) | 1, s57.LonLat.init(-74.0, 40.5));

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 3), adapted.len);
    // VALNMR 15 -> LightAllAround carrying majorLight=true (the yellow range ring)
    try std.testing.expectEqualStrings("LightAllAround", adapted[0].code);
    try std.testing.expectEqualStrings("true", adapted[0].root.resolve("").?.simpleValue("majorLight").?);
    // VALNMR 5 -> below the cutoff, no majorLight
    try std.testing.expectEqual(@as(?[]const u8, null), adapted[1].root.resolve("").?.simpleValue("majorLight"));
    // no VALNMR -> no majorLight
    try std.testing.expectEqual(@as(?[]const u8, null), adapted[2].root.resolve("").?.simpleValue("majorLight"));
}

test "s65RemapValue: TECSOU/QUASOU S-65 value conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Non-remapped code passes through untouched.
    try std.testing.expectEqualStrings("5", try s65RemapValue(a, s57.ATTR_VALSOU, "5"));
    // TECSOU: 6/7 drop, 14->17, list order preserved, in-list values kept.
    try std.testing.expectEqualStrings("3", try s65RemapValue(a, s57.ATTR_TECSOU, "3,6"));
    try std.testing.expectEqualStrings("17", try s65RemapValue(a, s57.ATTR_TECSOU, "14"));
    try std.testing.expectEqualStrings("3,17", try s65RemapValue(a, s57.ATTR_TECSOU, "3,7,14"));
    try std.testing.expectEqualStrings("", try s65RemapValue(a, s57.ATTR_TECSOU, "6,7")); // all dropped -> omit
    // QUASOU: 5 dropped, others kept.
    try std.testing.expectEqualStrings("", try s65RemapValue(a, s57.ATTR_QUASOU, "5"));
    try std.testing.expectEqualStrings("6", try s65RemapValue(a, s57.ATTR_QUASOU, "6"));
}

test "s65RemapQuapos: S-65 §2.2.3 QUAPOS -> qualityOfHorizontalMeasurement map" {
    // 3/6/7/8/9/11 -> 4 (approximate); 4 and 5 pass through; 1/2/10 (+ 0 absent) drop.
    try std.testing.expectEqual(@as(?i64, 4), s65RemapQuapos(3));
    try std.testing.expectEqual(@as(?i64, 4), s65RemapQuapos(4));
    try std.testing.expectEqual(@as(?i64, 5), s65RemapQuapos(5));
    for ([_]i32{ 6, 7, 8, 9, 11 }) |q| try std.testing.expectEqual(@as(?i64, 4), s65RemapQuapos(q));
    for ([_]i32{ 0, 1, 2, 10 }) |q| try std.testing.expectEqual(@as(?i64, null), s65RemapQuapos(q));
}

test "low-accuracy QUAPOS remaps to qualityOfHorizontalMeasurement=4 through the adapter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One drawn VE edge carrying QUAPOS=3 (inadequately surveyed) -> featureQuapos
    // returns 3 -> S-65 remaps to qualityOfHorizontalMeasurement "4".
    const vectors = try a.alloc(s57.VectorRecord, 1);
    vectors[0] = .{ .rcnm = s57.RCNM_VE, .rcid = 10, .points = &.{}, .soundings = &.{}, .quapos = 3 };
    var edges = std.AutoHashMap(u32, usize).init(a);
    try edges.put(10, 0);

    const refs = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 10 }, .ornt = 1 }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 2, .objl = 22, .refs = &refs }, // CBLSUB -> CableSubmarine (Curve)
    };
    var cell = s57.Cell{
        .params = .{},
        .vectors = vectors,
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = edges,
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("CableSubmarine", adapted[0].code);
    try std.testing.expectEqualStrings("4", adapted[0].root.resolve("").?.simpleValue("qualityOfHorizontalMeasurement").?);

    // A surveyed edge (QUAPOS=1) is not low-accuracy: featureQuapos returns 0, so
    // the attribute is absent (no positive S-101 assertion).
    const vectors2 = try a.alloc(s57.VectorRecord, 1);
    vectors2[0] = .{ .rcnm = s57.RCNM_VE, .rcid = 20, .points = &.{}, .soundings = &.{}, .quapos = 1 };
    var edges2 = std.AutoHashMap(u32, usize).init(a);
    try edges2.put(20, 0);
    const refs2 = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 20 }, .ornt = 1 }};
    const feats2 = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = 22, .refs = &refs2 },
    };
    var cell2 = s57.Cell{
        .params = .{},
        .vectors = vectors2,
        .features = &feats2,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = edges2,
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell2.arena.deinit();

    const adapted2 = try adaptCell(a, &cell2);
    try std.testing.expectEqual(@as(usize, 1), adapted2.len);
    try std.testing.expectEqual(@as(?[]const u8, null), adapted2[0].root.resolve("").?.simpleValue("qualityOfHorizontalMeasurement"));
}

test "prohibited QUASOU=5 is dropped from an adapted Wreck" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_ref = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 1 }, .ornt = 255 }};
    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_QUASOU, .value = "5" }, // prohibited -> dropped
        .{ .code = s57.ATTR_TECSOU, .value = "3,6" }, // 6 dropped -> "3"
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 1, .objl = 159, .refs = &node_ref, .attrs = &attrs }, // WRECKS
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
    try std.testing.expectEqualStrings("Wreck", adapted[0].code);
    const root = adapted[0].root.resolve("").?;
    try std.testing.expect(root.simpleValue("qualityOfVerticalMeasurement") == null); // dropped
    try std.testing.expectEqualStrings("3", root.simpleValue("techniqueOfVerticalMeasurement").?);
}

test "off-list enum values drop per the FC permitted-value list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // CableArea (CBLARE) permits categoryOfCable in {1,7,10}; "2,7" -> "7".
    const attrs = [_]s57.Attr{.{ .code = 11, .value = "2,7" }}; // 11 = CATCBL
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 20, .attrs = &attrs }, // CBLARE surface
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
    try std.testing.expectEqualStrings("CableArea", adapted[0].code);
    // 2 is off the CableArea permitted list and drops; 7 survives.
    try std.testing.expectEqualStrings("7", adapted[0].root.resolve("").?.simpleValue("categoryOfCable").?);
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
        s57.LonLat.init(0, 0),   s57.LonLat.init(10, 0),
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

test "inTheWater predicate: containsPoint over water and land indices" {
    const t = std.testing;
    // Water = a 10x10 box; land = a 2..8 island nested inside it (overlapping ENC).
    var water_ring = [_]s57.LonLat{
        s57.LonLat.init(0, 0),   s57.LonLat.init(10, 0),
        s57.LonLat.init(10, 10), s57.LonLat.init(0, 10),
    };
    var land_ring = [_]s57.LonLat{
        s57.LonLat.init(2, 2), s57.LonLat.init(8, 2),
        s57.LonLat.init(8, 8), s57.LonLat.init(2, 8),
    };
    var wparts = [_][]s57.LonLat{water_ring[0..]};
    var lparts = [_][]s57.LonLat{land_ring[0..]};
    const water = DepthIndex{ .areas = &[_]DepthArea{
        .{ .drval1 = 0, .has_drval1 = false, .rings = wparts[0..], .min_lon = 0, .min_lat = 0, .max_lon = 10, .max_lat = 10 },
    } };
    const land = DepthIndex{ .areas = &[_]DepthArea{
        .{ .drval1 = 0, .has_drval1 = false, .rings = lparts[0..], .min_lon = 2, .min_lat = 2, .max_lon = 8, .max_lat = 8 },
    } };
    // (1,1): in water, not on land -> in the water.
    try t.expect(water.containsPoint(1, 1) and !land.containsPoint(1, 1));
    // (5,5): in water AND on the nested island -> NOT in the water.
    try t.expect(!(water.containsPoint(5, 5) and !land.containsPoint(5, 5)));
    // (20,20): no water coverage -> not in the water (attribute stays absent).
    try t.expect(!water.containsPoint(20, 20));
}

test "inTheWater end-to-end: a LNDMRK over DEPARE geometry gets inTheWater=true (land excludes)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // DEPARE triangle A(0,0) B(10,0) C(5,10) via edges 10/11/12; a small LNDARE wedge
    // G(0,0) H(3,0) I(0,3) via edges 20/21/22 (overlapping ENC, near the origin corner).
    var nodes = std.AutoHashMap(u64, s57.LonLat).init(a);
    try nodes.put((@as(u64, s57.RCNM_VC) << 32) | 1, s57.LonLat.init(0, 0));
    try nodes.put((@as(u64, s57.RCNM_VC) << 32) | 2, s57.LonLat.init(10, 0));
    try nodes.put((@as(u64, s57.RCNM_VC) << 32) | 3, s57.LonLat.init(5, 10));
    try nodes.put((@as(u64, s57.RCNM_VC) << 32) | 4, s57.LonLat.init(0, 0));
    try nodes.put((@as(u64, s57.RCNM_VC) << 32) | 5, s57.LonLat.init(3, 0));
    try nodes.put((@as(u64, s57.RCNM_VC) << 32) | 6, s57.LonLat.init(0, 3));
    // Isolated (VI) nodes for the three structure points.
    try nodes.put((@as(u64, s57.RCNM_VI) << 32) | 100, s57.LonLat.init(5, 3)); // in water, not land
    try nodes.put((@as(u64, s57.RCNM_VI) << 32) | 101, s57.LonLat.init(1, 1)); // in water AND land
    try nodes.put((@as(u64, s57.RCNM_VI) << 32) | 102, s57.LonLat.init(20, 20)); // no coverage

    const vecs = try a.alloc(s57.VectorRecord, 6);
    vecs[0] = .{ .rcnm = s57.RCNM_VE, .rcid = 10, .points = &.{}, .soundings = &.{}, .begin_node = 1, .end_node = 2 };
    vecs[1] = .{ .rcnm = s57.RCNM_VE, .rcid = 11, .points = &.{}, .soundings = &.{}, .begin_node = 2, .end_node = 3 };
    vecs[2] = .{ .rcnm = s57.RCNM_VE, .rcid = 12, .points = &.{}, .soundings = &.{}, .begin_node = 3, .end_node = 1 };
    vecs[3] = .{ .rcnm = s57.RCNM_VE, .rcid = 20, .points = &.{}, .soundings = &.{}, .begin_node = 4, .end_node = 5 };
    vecs[4] = .{ .rcnm = s57.RCNM_VE, .rcid = 21, .points = &.{}, .soundings = &.{}, .begin_node = 5, .end_node = 6 };
    vecs[5] = .{ .rcnm = s57.RCNM_VE, .rcid = 22, .points = &.{}, .soundings = &.{}, .begin_node = 6, .end_node = 4 };
    var edges = std.AutoHashMap(u32, usize).init(a);
    inline for (.{ .{ 10, 0 }, .{ 11, 1 }, .{ 12, 2 }, .{ 20, 3 }, .{ 21, 4 }, .{ 22, 5 } }) |e| try edges.put(e[0], e[1]);

    const depare_refs = [_]s57.SpatialRef{
        .{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 10 }, .ornt = 1 },
        .{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 11 }, .ornt = 1 },
        .{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 12 }, .ornt = 1 },
    };
    const lndare_refs = [_]s57.SpatialRef{
        .{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 20 }, .ornt = 1 },
        .{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 21 }, .ornt = 1 },
        .{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 22 }, .ornt = 1 },
    };
    const depare_attrs = [_]s57.Attr{.{ .code = s57.ATTR_DRVAL1, .value = "5" }};
    const s1 = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 100 }, .ornt = 255 }};
    const s2 = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 101 }, .ornt = 255 }};
    const s3 = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VI, .rcid = 102 }, .ornt = 255 }};
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .refs = &depare_refs, .attrs = &depare_attrs }, // DEPARE
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = s57.OBJL_LNDARE, .refs = &lndare_refs }, // LNDARE
        .{ .rcnm = 100, .rcid = 3, .prim = 1, .objl = 74, .refs = &s1 }, // LNDMRK in water
        .{ .rcnm = 100, .rcid = 4, .prim = 1, .objl = 74, .refs = &s2 }, // LNDMRK over land
        .{ .rcnm = 100, .rcid = 5, .prim = 1, .objl = 74, .refs = &s3 }, // LNDMRK no coverage
    };
    var cell = s57.Cell{
        .params = .{},
        .vectors = vecs,
        .features = &feats,
        .nodes = nodes,
        .edges = edges,
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(t.allocator),
    };
    defer cell.arena.deinit();

    const adapted = try adaptCell(a, &cell);
    var seen: usize = 0;
    for (adapted) |ad| {
        const itw = ad.root.resolve("").?.simpleValue("inTheWater");
        switch (ad.feature_index) {
            2 => { // over DEPARE, not over LNDARE -> in the water
                try t.expectEqualStrings("Landmark", ad.code);
                try t.expectEqualStrings("true", itw.?);
                seen += 1;
            },
            3 => { // over DEPARE AND LNDARE -> land excludes, absent
                try t.expectEqual(@as(?[]const u8, null), itw);
                seen += 1;
            },
            4 => { // no water coverage -> absent
                try t.expectEqual(@as(?[]const u8, null), itw);
                seen += 1;
            },
            else => {},
        }
    }
    try t.expectEqual(@as(usize, 3), seen); // all three structures were adapted and checked
}

/// Minimal geometry-less cell over `feats` for adapter-only tests.
fn testCell(a: std.mem.Allocator, feats: []const s57.Feature) s57.Cell {
    return .{
        .params = .{},
        .vectors = &.{},
        .features = feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = std.AutoHashMap(u32, usize).init(a),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

test "Gap D: CATZOC=1 (ZOC A1) deconstructs into the full Quality of Bathymetric Data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_CATZOC, .value = "1" },
        .{ .code = s57.ATTR_SUREND, .value = "20230415" },
        .{ .code = s57.ATTR_SURSTA, .value = "20220101" },
        .{ .code = s57.ATTR_TECSOU, .value = "3" }, // prohibited for QoBD -> dropped
        .{ .code = s57.ATTR_DRVAL1, .value = "10" }, // still flows the generic loop
    };
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 308, .attrs = &attrs }, // M_QUAL (Surface)
    };
    var cell = testCell(a, &feats);
    defer cell.arena.deinit();

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("QualityOfBathymetricData", adapted[0].code);
    const root = &adapted[0].root;

    // Deconstructed mandatory components (ZOC A1 row).
    try std.testing.expectEqualStrings("1", root.simpleValue("dataAssessment").?);
    try std.testing.expectEqualStrings("5", root.simpleValue("categoryOfTemporalVariation").?);
    try std.testing.expectEqualStrings("true", root.simpleValue("fullSeafloorCoverageAchieved").?);
    const fd = root.resolve("featuresDetected:1").?;
    try std.testing.expectEqualStrings("true", fd.simpleValue("significantFeaturesDetected").?);
    try std.testing.expectEqualStrings("true", fd.simpleValue("leastDepthOfDetectedFeaturesMeasured").?);

    // zoneOfConfidence carries the identical category + the A1 accuracy formula.
    const zoc = root.resolve("zoneOfConfidence:1").?;
    try std.testing.expectEqualStrings("1", zoc.simpleValue("categoryOfZoneOfConfidenceInData").?);
    const hpu = root.resolve("zoneOfConfidence:1;horizontalPositionUncertainty:1").?;
    try std.testing.expectEqualStrings("5", hpu.simpleValue("uncertaintyFixed").?);
    try std.testing.expectEqualStrings("0.05", hpu.simpleValue("uncertaintyVariableFactor").?);
    const vu = root.resolve("zoneOfConfidence:1;verticalUncertainty:1").?;
    try std.testing.expectEqualStrings("0.5", vu.simpleValue("uncertaintyFixed").?);
    try std.testing.expectEqualStrings("0.01", vu.simpleValue("uncertaintyVariableFactor").?);

    // surveyDateRange from SURSTA/SUREND.
    const sdr = root.resolve("surveyDateRange:1").?;
    try std.testing.expectEqualStrings("20220101", sdr.simpleValue("dateStart").?);
    try std.testing.expectEqualStrings("20230415", sdr.simpleValue("dateEnd").?);

    // Consumed/prohibited attributes do NOT forward flat.
    try std.testing.expectEqual(@as(?[]const u8, null), root.simpleValue("techniqueOfVerticalMeasurement"));
    try std.testing.expectEqual(@as(?[]const u8, null), root.simpleValue("categoryOfZoneOfConfidenceInData"));
    try std.testing.expectEqual(@as(?[]const u8, null), root.simpleValue("dateEnd"));
    try std.testing.expectEqual(@as(?[]const u8, null), root.simpleValue("dateStart"));
    // DRVAL1 is not consumed by the deconstruction: the rule reads it for the
    // safety-contour intersection, via the generic loop.
    try std.testing.expectEqualStrings("10", root.simpleValue("depthRangeMinimumValue").?);
}

test "Gap D: CATZOC=6 / absent M_QUAL is unassessed; zoneOfConfidence still draws NODATA03" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ZOC U: unassessed - no coverage/features/uncertainty assertions.
    const attrs_u = [_]s57.Attr{.{ .code = s57.ATTR_CATZOC, .value = "6" }};
    const feats_u = [_]s57.Feature{.{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 308, .attrs = &attrs_u }};
    var cell_u = testCell(a, &feats_u);
    defer cell_u.arena.deinit();
    const root_u = &(try adaptCell(a, &cell_u))[0].root;
    try std.testing.expectEqualStrings("3", root_u.simpleValue("dataAssessment").?);
    try std.testing.expectEqualStrings("6", root_u.simpleValue("categoryOfTemporalVariation").?);
    try std.testing.expectEqual(@as(?[]const u8, null), root_u.simpleValue("fullSeafloorCoverageAchieved"));
    try std.testing.expectEqual(@as(usize, 0), root_u.childCount("featuresDetected"));
    const zoc_u = root_u.resolve("zoneOfConfidence:1").?;
    try std.testing.expectEqualStrings("6", zoc_u.simpleValue("categoryOfZoneOfConfidenceInData").?);
    try std.testing.expectEqual(@as(usize, 0), zoc_u.childCount("horizontalPositionUncertainty"));
    try std.testing.expectEqual(@as(usize, 0), zoc_u.childCount("verticalUncertainty"));

    // No CATZOC at all: the zoneOfConfidence entry must still exist (category absent)
    // so the rule's NODATA03 "quality unknown" branch fires instead of rendering nothing.
    const feats_n = [_]s57.Feature{.{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 308 }};
    var cell_n = testCell(a, &feats_n);
    defer cell_n.arena.deinit();
    const root_n = &(try adaptCell(a, &cell_n))[0].root;
    try std.testing.expectEqual(@as(usize, 1), root_n.childCount("zoneOfConfidence"));
    const zoc_n = root_n.resolve("zoneOfConfidence:1").?;
    try std.testing.expectEqual(@as(?[]const u8, null), zoc_n.simpleValue("categoryOfZoneOfConfidenceInData"));
    try std.testing.expectEqualStrings("3", root_n.simpleValue("dataAssessment").?);
}

test "Gap D: POSACC/SOUACC override the ZOC-derived uncertainties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ZOC A2 would give h=20 / v=1.0+0.02d; measured POSACC/SOUACC replace both.
    const attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_CATZOC, .value = "2" },
        .{ .code = s57.ATTR_POSACC, .value = "10" },
        .{ .code = s57.ATTR_SOUACC, .value = "0.3" },
    };
    const feats = [_]s57.Feature{.{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 308, .attrs = &attrs }};
    var cell = testCell(a, &feats);
    defer cell.arena.deinit();
    const root = &(try adaptCell(a, &cell))[0].root;
    const hpu = root.resolve("zoneOfConfidence:1;horizontalPositionUncertainty:1").?;
    try std.testing.expectEqualStrings("10", hpu.simpleValue("uncertaintyFixed").?);
    try std.testing.expectEqual(@as(?[]const u8, null), hpu.simpleValue("uncertaintyVariableFactor"));
    const vu = root.resolve("zoneOfConfidence:1;verticalUncertainty:1").?;
    try std.testing.expectEqualStrings("0.3", vu.simpleValue("uncertaintyFixed").?);
    try std.testing.expectEqual(@as(?[]const u8, null), vu.simpleValue("uncertaintyVariableFactor"));
    // The flat SOUACC alias (verticalUncertainty is itself the alias target) must not
    // double-emit at the root.
    try std.testing.expectEqual(@as(usize, 0), root.childCount("verticalUncertainty"));
    try std.testing.expectEqual(@as(?[]const u8, null), root.simpleValue("verticalUncertainty"));
}

test "Gap D: M_SREL adapts to QualityOfSurvey with surveyDateRange (render-neutral NullInstruction rule)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const attrs = [_]s57.Attr{
        .{ .code = 150, .value = "NOAA" }, // SURATH -> surveyAuthority
        .{ .code = 153, .value = "1" }, // SURTYP -> surveyType (1 = reconnaissance)
        .{ .code = s57.ATTR_SUREND, .value = "19950601" },
    };
    const feats = [_]s57.Feature{.{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 310, .attrs = &attrs }}; // M_SREL
    var cell = testCell(a, &feats);
    defer cell.arena.deinit();

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("QualityOfSurvey", adapted[0].code);
    const root = &adapted[0].root;
    try std.testing.expectEqualStrings("NOAA", root.simpleValue("surveyAuthority").?);
    try std.testing.expectEqualStrings("1", root.simpleValue("surveyType").?);
    const sdr = root.resolve("surveyDateRange:1").?;
    try std.testing.expectEqualStrings("19950601", sdr.simpleValue("dateEnd").?);
    // SUREND no longer forwards as a flat dateEnd.
    try std.testing.expectEqual(@as(?[]const u8, null), root.simpleValue("dateEnd"));
}

test "Gap D: QualityOfSurvey restricts qualityOfHorizontalMeasurement to 4 (doubtful 5 drops)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A drawn VE edge with QUAPOS=5 (position doubtful): the aggregate remaps to 5,
    // which the Quality of Survey permitted list [4] rejects — attribute absent.
    const vectors = try a.alloc(s57.VectorRecord, 1);
    vectors[0] = .{ .rcnm = s57.RCNM_VE, .rcid = 10, .points = &.{}, .soundings = &.{}, .quapos = 5 };
    var edges = std.AutoHashMap(u32, usize).init(a);
    try edges.put(10, 0);
    const refs = [_]s57.SpatialRef{.{ .name = .{ .rcnm = s57.RCNM_VE, .rcid = 10 }, .ornt = 1 }};
    const feats = [_]s57.Feature{.{ .rcnm = 100, .rcid = 1, .prim = 2, .objl = 310, .refs = &refs }}; // M_SREL line
    var cell = s57.Cell{
        .params = .{},
        .vectors = vectors,
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = edges,
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    const adapted = try adaptCell(a, &cell);
    try std.testing.expectEqual(@as(usize, 1), adapted.len);
    try std.testing.expectEqualStrings("QualityOfSurvey", adapted[0].code);
    try std.testing.expectEqual(@as(?[]const u8, null), adapted[0].root.simpleValue("qualityOfHorizontalMeasurement"));
}
