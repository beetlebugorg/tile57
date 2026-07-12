//! Native S-101 assembly: turn a parsed `dataset.Dataset` into the two things the
//! rendering pipeline consumes, WITHOUT the S-57 -> S-101 adapter:
//!
//!   1. an `s57.Cell` GEOMETRY SHELL — the S-100 spatial records (point / multipoint
//!      / curve / composite-curve / surface) mapped onto the S-57 vector model
//!      (nodes / edges / sounding vectors + per-feature FSPT-style refs), so every
//!      existing geometry, masking, and boolean accessor works unchanged; and
//!   2. `[]adapter.Adapted` PORTRAYAL RECORDS built directly from the S-101 feature
//!      records — class name from the in-band FTCS table, the attribute `CNode` tree
//!      reconstructed from ATTR's PAIX parent links. The S-101 data already speaks
//!      the portrayal vocabulary, so there is nothing to translate.
//!
//! The S-57 `objl`/attribute surrogates on the shell features exist ONLY for the
//! handful of classes `scene.zig` special-cases (soundings, depth contours, dangers,
//! coastline masking, lights); general portrayal flows through the native `Adapted`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const dataset = @import("dataset.zig");
const adapter = @import("adapter.zig");

const CNode = adapter.CNode;
const NameVal = adapter.NameVal;
const ChildEntry = adapter.ChildEntry;

// Internal vector-record name codes for the shell (S-57 conventions the geometry
// accessors key on): points -> connected node (VC), multipoints -> isolated node
// (VI, which holds SG3D), curves -> edge (VE).
const VC = s57.RCNM_VC; // 120
const VI = s57.RCNM_VI; // 110
const VE = s57.RCNM_VE; // 130

pub const Loaded = struct {
    cell: s57.Cell,
    /// Native portrayal records, indexed 1:1 with `cell.features`. Lives in the
    /// cell's arena — valid for the cell's lifetime. Pass to `portray` in place of
    /// `adapter.adaptCell`.
    adapted: []const adapter.Adapted,
};

/// Detect + parse + assemble a native S-101 dataset, applying its `.001…` update
/// chain. On a non-S-101 base returns `error.NotS101` so the caller can fall through
/// to the S-57 reader.
pub fn parseDataset(gpa: Allocator, base: []const u8, updates: []const []const u8) !Loaded {
    if (!dataset.detect(base)) return error.NotS101;
    var ds = try dataset.parseWithUpdates(gpa, base, updates);
    defer ds.deinit(); // the shell dupes everything it keeps into its own arena
    return assemble(gpa, &ds);
}

fn combineOrnt(a: u8, b: u8) u8 {
    return if ((a == 2) != (b == 2)) 2 else 1;
}

/// S-101 class name -> the S-57 object class `scene.zig` keys its special-cases on
/// (soundings, depth areas/contours, dangers, coastline-masking definers, lights),
/// or 0 when the class needs no surrogate (general portrayal is class-name driven).
fn surrogateObjl(class: []const u8) u16 {
    const eql = std.mem.eql;
    if (eql(u8, class, "Sounding")) return 129; // SOUNDG (scene emits the multipoint)
    if (eql(u8, class, "DepthArea")) return 42; // DEPARE
    if (eql(u8, class, "DredgedArea")) return 46; // DRGARE
    if (eql(u8, class, "DepthContour")) return 43; // DEPCNT (VALDCO label)
    if (eql(u8, class, "Obstruction")) return 86; // OBSTRN (danger depth)
    if (eql(u8, class, "UnderwaterAwashRock")) return 153; // UWTROC
    if (eql(u8, class, "Wreck")) return 159; // WRECKS
    if (eql(u8, class, "DataCoverage")) return 302; // M_COVR (quilting)
    if (eql(u8, class, "NavigationalSystemOfMarks")) return 306; // M_NSYS
    if (eql(u8, class, "Coastline")) return 30; // COALNE (coast-coincident masking)
    if (eql(u8, class, "LandArea")) return 71; // LNDARE
    if (eql(u8, class, "ShorelineConstruction")) return 122; // SLCONS
    if (std.mem.startsWith(u8, class, "Light") and !eql(u8, class, "Lighthouse")) return 75; // LIGHTS (range rings)
    return 0;
}

/// S-101 simple-attribute name -> the S-57 attribute code `scene.zig`'s special-case
/// branches (and the danger-depth derivation) read directly, or null. General
/// portrayal reads attributes by S-101 NAME through the `CNode`; this is only the
/// bridge for the code-keyed scene branches.
fn surrogateAttr(name: []const u8) ?u16 {
    const eql = std.mem.eql;
    if (eql(u8, name, "scaleMinimum")) return 133; // SCAMIN — S-52 scale-based feature culling
    if (eql(u8, name, "valueOfSounding")) return s57.ATTR_VALSOU; // 179 (danger depth)
    if (eql(u8, name, "valueOfDepthContour")) return s57.ATTR_VALDCO; // 174 (contour label)
    if (eql(u8, name, "depthRangeMinimumValue")) return s57.ATTR_DRVAL1; // 87
    if (eql(u8, name, "depthRangeMaximumValue")) return s57.ATTR_DRVAL2; // 88
    return null;
}

fn assemble(gpa: Allocator, ds: *dataset.Dataset) !Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // --- Geometry: spatial records -> S-57 vector model -------------------
    // nodes/edges/sounding_vecs use the gpa (Cell.deinit frees them); the record
    // slices live in the arena. Mirrors s57.parseCellWithUpdates' final Cell.
    var nodes = std.AutoHashMap(u64, s57.LonLat).init(gpa);
    var edges = std.AutoHashMap(u32, usize).init(gpa);
    var sounding_vecs = std.AutoHashMap(u64, usize).init(gpa);
    errdefer {
        nodes.deinit();
        edges.deinit();
        sounding_vecs.deinit();
    }

    // Point records -> connected nodes, keyed by (VC, rcid). Serve both curve
    // endpoints and standalone point-feature geometry.
    for (ds.points) |p| {
        try nodes.put((@as(u64, VC) << 32) | p.rcid, s57.LonLat.init(p.lon, p.lat));
    }

    var vectors = std.ArrayList(s57.VectorRecord).empty;
    // Curves -> edges (begin/end nodes + interior vertices).
    for (ds.curves) |c| {
        const idx = vectors.items.len;
        try vectors.append(a, .{
            .rcnm = VE,
            .rcid = c.rcid,
            .points = try a.dupe(s57.LonLat, c.interior),
            .soundings = &.{},
            .begin_node = c.begin_rcid,
            .end_node = c.end_rcid,
        });
        try edges.put(c.rcid, idx);
    }
    // Multipoints -> sounding vectors (keyed by (VI, rcid); soundingsFor reads them).
    for (ds.multis) |m| {
        const idx = vectors.items.len;
        try vectors.append(a, .{
            .rcnm = VI,
            .rcid = m.rcid,
            .points = &.{},
            .soundings = try a.dupe(s57.Sounding, m.soundings),
        });
        try sounding_vecs.put((@as(u64, VI) << 32) | m.rcid, idx);
    }

    // Index composites + surfaces for SPAS resolution.
    var comp_index = std.AutoHashMap(u32, dataset.CompositeRec).init(gpa);
    defer comp_index.deinit();
    for (ds.composites) |c| try comp_index.put(c.rcid, c);
    var surf_index = std.AutoHashMap(u32, dataset.SurfaceRec).init(gpa);
    defer surf_index.deinit();
    for (ds.surfaces) |s| try surf_index.put(s.rcid, s);

    // --- Features -> shell features + native Adapted ----------------------
    var features = std.ArrayList(s57.Feature).empty;
    var adapted = std.ArrayList(adapter.Adapted).empty;

    for (ds.features) |fr| {
        const class = ds.featureName(fr) orelse continue; // unresolved code: skip
        const prim: u8 = if (fr.spas.len == 0) 255 else switch (fr.spas[0].rrnm) {
            dataset.RCNM_POINT, dataset.RCNM_MULTIPOINT => 1,
            dataset.RCNM_CURVE, dataset.RCNM_COMPOSITE => 2,
            dataset.RCNM_SURFACE => 3,
            else => 255,
        };

        // Resolve SPAS -> S-57 spatial refs (VC node / VI sounding / VE edges).
        var refs = std.ArrayList(s57.SpatialRef).empty;
        for (fr.spas) |sp| {
            switch (sp.rrnm) {
                dataset.RCNM_POINT => try refs.append(a, .{ .name = .{ .rcnm = VC, .rcid = sp.rrid }, .ornt = 1 }),
                dataset.RCNM_MULTIPOINT => try refs.append(a, .{ .name = .{ .rcnm = VI, .rcid = sp.rrid }, .ornt = 1 }),
                dataset.RCNM_CURVE => try refs.append(a, .{ .name = .{ .rcnm = VE, .rcid = sp.rrid }, .ornt = sp.ornt, .mask = maskFor(fr, sp.rrid) }),
                dataset.RCNM_COMPOSITE => try appendComposite(a, &refs, &comp_index, sp.rrid, sp.ornt, 0, fr),
                dataset.RCNM_SURFACE => {
                    if (surf_index.get(sp.rrid)) |surf| {
                        for (surf.rings) |ring| {
                            switch (ring.rrnm) {
                                dataset.RCNM_CURVE => try refs.append(a, .{ .name = .{ .rcnm = VE, .rcid = ring.rrid }, .ornt = ring.ornt, .usag = ring.usag, .mask = maskFor(fr, ring.rrid) }),
                                dataset.RCNM_COMPOSITE => try appendComposite(a, &refs, &comp_index, ring.rrid, ring.ornt, ring.usag, fr),
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Surrogate objl + the code-keyed attrs scene.zig reads directly.
        const objl = surrogateObjl(class);
        var s57attrs = std.ArrayList(s57.Attr).empty;
        for (fr.attrs) |at| {
            if (at.paix != 0) continue; // only top-level simple attrs surrogate
            const nm = ds.attrName(at) orelse continue;
            if (surrogateAttr(nm)) |code| {
                const v = std.mem.trim(u8, at.val, " ");
                if (v.len > 0) try s57attrs.append(a, .{ .code = code, .value = try a.dupe(u8, v) });
            }
        }
        if (objl == 302) try s57attrs.append(a, .{ .code = 18, .value = "1" }); // CATCOV=1 (coverage)

        const fi = features.items.len;
        try features.append(a, .{
            .rcnm = 100,
            .rcid = fr.rcid,
            .prim = prim,
            .objl = objl,
            .foid = (@as(u64, fr.foid.agen) << 48) | (@as(u64, fr.foid.fidn) << 16) | fr.foid.fids,
            .refs = refs.items,
            .attrs = s57attrs.items,
        });

        // Native Adapted: class name + CNode tree from ATTR (no adapter). SOUNDG
        // (objl 129) is emitted directly as a multipoint by scene, and a feature with
        // no spatial primitive can't portray — neither goes through the rules (the
        // Sounding rule would error on the multipoint the rule path doesn't model).
        const primitive = primitiveName(prim);
        if (objl != 129 and primitive.len > 0) {
            var points: []const [3]f64 = &.{};
            if (prim == 1 and fr.spas.len > 0 and fr.spas[0].rrnm == dataset.RCNM_POINT) {
                if (nodes.get((@as(u64, VC) << 32) | fr.spas[0].rrid)) |pt| {
                    const one = try a.alloc([3]f64, 1);
                    one[0] = .{ pt.lon(), pt.lat(), 0 };
                    points = one;
                }
            }
            try adapted.append(a, .{
                .feature_index = fi,
                .code = try a.dupe(u8, class),
                .primitive = primitive,
                .root = try buildNode(a, ds.*, fr.attrs, 0),
                .points = points,
            });
        }
    }

    // Coast-coincident masking set (COALNE/LNDARE/SLCONS edges).
    var coast_edges: std.AutoHashMapUnmanaged(u32, void) = .{};
    for (features.items) |f| {
        if (!s57.isCoastDefiner(f.objl)) continue;
        for (f.refs) |ref| if (ref.name.rcnm == VE) try coast_edges.put(a, ref.name.rcid, {});
    }

    // FOID -> feature index (feature-to-feature association resolution).
    var foid_index: std.AutoHashMapUnmanaged(u64, usize) = .{};
    for (features.items, 0..) |f, i| {
        if (f.foid != 0) try foid_index.put(a, f.foid, i);
    }

    const cell = s57.Cell{
        .params = .{ .comf = @intFromFloat(ds.params.cmfx), .somf = @intFromFloat(ds.params.cmfz) },
        .vectors = vectors.items,
        .features = features.items,
        .nodes = nodes,
        .edges = edges,
        .sounding_vecs = sounding_vecs,
        .coast_edges = coast_edges,
        .foid_index = foid_index,
        .native = true,
        .arena = arena,
    };
    return .{ .cell = cell, .adapted = adapted.items };
}

/// The MASK indicator (1=mask/not-drawn, else 0) a feature applies to boundary
/// spatial record `rrid`, if any.
fn maskFor(fr: dataset.FeatureRec, rrid: u32) u8 {
    for (fr.spas) |sp| if (sp.rrid == rrid and sp.mask == 1) return 1;
    return 0;
}

/// Expand a composite curve into its constituent curve edges as feature refs,
/// composing the outer orientation with each member's.
fn appendComposite(
    a: Allocator,
    refs: *std.ArrayList(s57.SpatialRef),
    comp_index: *std.AutoHashMap(u32, dataset.CompositeRec),
    comp_rcid: u32,
    ornt: u8,
    usag: u8,
    fr: dataset.FeatureRec,
) !void {
    const comp = comp_index.get(comp_rcid) orelse return;
    for (comp.members) |m| {
        try refs.append(a, .{
            .name = .{ .rcnm = VE, .rcid = m.rrid },
            .ornt = combineOrnt(ornt, m.ornt),
            .usag = usag,
            .mask = maskFor(fr, m.rrid),
        });
    }
}

fn primitiveName(prim: u8) []const u8 {
    return switch (prim) {
        1 => "Point",
        2 => "Curve",
        3 => "Surface",
        else => "",
    };
}

/// Build the `CNode` sub-tree rooted at the attribute occupying 1-based position
/// `parent_pos` (0 = the feature root). Direct children are the ATTR records whose
/// `paix == parent_pos`; a child that is itself a parent (some record's `paix`
/// equals its position) becomes a nested complex `ChildEntry`, otherwise a simple
/// `NameVal` leaf. Repeated simple values under the same name are comma-joined, so
/// the portrayal host splits them exactly as it does S-57 list attributes.
fn buildNode(a: Allocator, ds: dataset.Dataset, attrs: []const dataset.Attr, parent_pos: u16) !CNode {
    var simple = std.ArrayList(NameVal).empty;
    // Parallel insertion-ordered lists: a complex-attribute NAME and its instances.
    // A feature has only a handful of distinct complex children, so a linear scan
    // to group instances by name is cheaper than a map.
    var child_names = std.ArrayList([]const u8).empty;
    var child_lists = std.ArrayList(std.ArrayList(CNode)).empty;

    for (attrs, 0..) |at, i| {
        if (at.paix != parent_pos) continue;
        const pos: u16 = @intCast(i + 1);
        const name = ds.attrName(at) orelse continue;
        if (isParent(attrs, pos)) {
            const node = try buildNode(a, ds, attrs, pos);
            var slot: ?usize = null;
            for (child_names.items, 0..) |nm, k| if (std.mem.eql(u8, nm, name)) {
                slot = k;
            };
            if (slot) |k| {
                try child_lists.items[k].append(a, node);
            } else {
                try child_names.append(a, name);
                var list = std.ArrayList(CNode).empty;
                try list.append(a, node);
                try child_lists.append(a, list);
            }
        } else {
            const v = std.mem.trim(u8, at.val, " ");
            if (v.len == 0) continue; // a blank simple attr means "absent"
            try appendSimple(a, &simple, name, v);
        }
    }

    var children = try a.alloc(ChildEntry, child_names.items.len);
    for (child_names.items, child_lists.items, 0..) |nm, list, k| {
        children[k] = .{ .code = try a.dupe(u8, nm), .nodes = list.items };
    }
    return .{ .simple = simple.items, .children = children };
}

/// True when some ATTR record names `pos` as its parent (so `pos` is a complex
/// container, not a simple leaf).
fn isParent(attrs: []const dataset.Attr, pos: u16) bool {
    for (attrs) |at| if (at.paix == pos) return true;
    return false;
}

/// Add a simple value under `name`, comma-joining a repeated name into a list.
fn appendSimple(a: Allocator, simple: *std.ArrayList(NameVal), name: []const u8, v: []const u8) !void {
    for (simple.items) |*nv| if (std.mem.eql(u8, nv.name, name)) {
        nv.value = try std.fmt.allocPrint(a, "{s},{s}", .{ nv.value, v });
        return;
    };
    try simple.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, v) });
}

// -------------------------------------------------------------------------
test "buildNode reconstructs the complex-attribute tree from PAIX links" {
    // A minimal dataset with an attribute code table and a nested tree:
    //   pos1 simpleTop = "5"            (paix 0)
    //   pos2 container  = ""            (paix 0, complex)
    //   pos3 childA     = "1"           (paix 2)
    //   pos4 childB     = "2"           (paix 2)
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var ds: dataset.Dataset = .{ .arena = undefined };
    try ds.attr_codes.by_code.put(ar, 1, "simpleTop");
    try ds.attr_codes.by_code.put(ar, 2, "container");
    try ds.attr_codes.by_code.put(ar, 3, "childA");
    try ds.attr_codes.by_code.put(ar, 4, "childB");
    const attrs = [_]dataset.Attr{
        .{ .natc = 1, .atix = 1, .paix = 0, .atin = 1, .val = "5" },
        .{ .natc = 2, .atix = 1, .paix = 0, .atin = 1, .val = "" },
        .{ .natc = 3, .atix = 1, .paix = 2, .atin = 1, .val = "1" },
        .{ .natc = 4, .atix = 1, .paix = 2, .atin = 1, .val = "2" },
    };
    const root = try buildNode(ar, ds, &attrs, 0);
    try std.testing.expectEqualStrings("5", root.simpleValue("simpleTop").?);
    try std.testing.expectEqual(@as(usize, 1), root.childCount("container"));
    const c = root.resolve("container:1").?;
    try std.testing.expectEqualStrings("1", c.simpleValue("childA").?);
    try std.testing.expectEqualStrings("2", c.simpleValue("childB").?);
}
