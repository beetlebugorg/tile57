//! Cell-driven S-101 portrayal. Adapts a cell's features (s101.adapter), exposes
//! them to the embedded Lua via C-ABI accessors (tgp_*), runs the rules once
//! (tg_portray_run in lua_shim.c), and returns per-feature instruction streams
//! for translation to MVT (s101.instructions).
//!
//! Lib-only (links Lua via the C shim) — not part of the pure root.zig used by
//! the tests/bake exe.

const std = @import("std");
const s57 = @import("s57");
const adapter = @import("s101").adapter;
const catalogue = @import("s101").catalogue; // S-57 OBJL -> acronym for the quesmrk diagnostic

// The embedded S-101 rules accessor (tg_embedded_lua) — referenced so its C-ABI
// exports land in the compiled module; the Lua `require` searcher in lua_shim.c
// calls them to load rule modules from memory.
comptime {
    _ = @import("rules_embed.zig");
}

const Ctx = struct {
    adapted: []adapter.Adapted,
    results: [][]const u8, // per adapted index -> instruction stream (arena-owned)
    arena: std.mem.Allocator,
    cell: *const s57.Cell, // for FFPT feature-to-feature association resolution
    feat_to_adapted: []const ?usize, // cell.features index -> this pass's adapted index
};

// One in-flight portrayal per thread. The tgp_* accessors below run on the same
// thread that called portrayCell (the C shim's Lua callbacks are synchronous), so
// making this thread-local lets the baker portray many cells in parallel — each
// thread its own context — while the single-threaded live path is unaffected.
threadlocal var g_ctx: ?*Ctx = null;

// Implemented in C (lua_shim.c): loads the framework + rules from `dir`,
// dispatches every feature exposed by the tgp_* accessors, and calls tgp_emit
// for each. `ctx` carries the pass's S-101 context parameters (null = the
// fixed bake context). Returns 0 on success.
extern fn tg_portray_run(dir_ptr: [*]const u8, dir_len: usize, ctx: ?*const CContext) callconv(.c) c_int;

// Mirror of lua_shim.c's tg_portray_ctx (keep field order/types in sync).
const CContext = extern struct {
    plain_boundaries: c_int,
    simplified_symbols: c_int,
    radar_overlay: c_int,
    four_shades: c_int,
    full_light_lines: c_int,
    ignore_scale_minimum: c_int,
    shallow_water_dangers: c_int,
    safety_contour: f64,
    safety_depth: f64,
    shallow_contour: f64,
    deep_contour: f64,
    safety_height: f64,
};

// Suppress the per-cell "[s101] portrayed …" stderr summary (extern in lua_shim.c).
extern fn tg_set_quiet(q: c_int) callconv(.c) void;

// TILE57_DEBUG env gate (extern in lua_shim.c), shared with the framework Debug channel —
// gates the per-feature QUESMRK1 diagnostic in tgp_emit.
extern fn tg_debug_enabled() callconv(.c) c_int;

/// Silence the per-cell portrayal stderr summary — set before a parallel bake so
/// concurrent threads don't garble progress output.
pub fn setQuiet(quiet: bool) void {
    tg_set_quiet(if (quiet) 1 else 0);
}

// ---- accessors the C Host* callbacks read --------------------------------

export fn tgp_count() callconv(.c) usize {
    return if (g_ctx) |c| c.adapted.len else 0;
}

export fn tgp_code(i: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const s = g_ctx.?.adapted[i].code;
    out_len.* = s.len;
    return s.ptr;
}

export fn tgp_primitive(i: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const s = g_ctx.?.adapted[i].primitive;
    out_len.* = s.len;
    return s.ptr;
}

/// Raw value of simple sub-attribute `code` at the synthesized-tree node addressed
/// by the framework attributePath `path` (the root when empty), on feature i. Null
/// when the node or the sub-attribute is absent. The caller (lua_shim) splits S-57
/// list values by the catalogue value type. Backs HostFeatureGetSimpleAttribute;
/// resolves the FULL path through the tree (replaces the old single-level
/// tgp_attr / tgp_complex_attr keyed only by the leading complex name).
export fn tgp_simple(i: usize, path_ptr: [*]const u8, path_len: usize, code_ptr: [*]const u8, code_len: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const c = g_ctx orelse return null;
    if (i >= c.adapted.len) return null;
    const node = c.adapted[i].root.resolve(path_ptr[0..path_len]) orelse return null;
    const v = node.simpleValue(code_ptr[0..code_len]) orelse return null;
    out_len.* = v.len;
    return v.ptr;
}

/// Number of instances of complex child `code` at the synthesized-tree node
/// addressed by the framework attributePath `path` (the root when empty), on
/// feature i. Backs HostFeatureGetComplexAttributeCount; resolves the full path
/// through the tree (the old impl ignored the path and counted only root-level
/// complexes by name).
export fn tgp_complex_count(i: usize, path_ptr: [*]const u8, path_len: usize, code_ptr: [*]const u8, code_len: usize) callconv(.c) usize {
    const c = g_ctx orelse return 0;
    if (i >= c.adapted.len) return 0;
    const node = c.adapted[i].root.resolve(path_ptr[0..path_len]) orelse return 0;
    return node.childCount(code_ptr[0..code_len]);
}

/// Number of point-geometry vertices for feature i (1 for a point feature, 0
/// otherwise). Backs `_HostFeaturePoints` so HostGetSpatial can build a real
/// Point/MultiPoint for `#P`/`#M` spatials.
export fn tgp_points_count(i: usize) callconv(.c) usize {
    const c = g_ctx orelse return 0;
    if (i >= c.adapted.len) return 0;
    return c.adapted[i].points.len;
}

/// Vertex j (lon, lat, z) of feature i's point geometry. Caller must ensure
/// j < tgp_points_count(i).
export fn tgp_point(i: usize, j: usize, x: *f64, y: *f64, z: *f64) callconv(.c) void {
    const p = g_ctx.?.adapted[i].points;
    x.* = p[j][0];
    y.* = p[j][1];
    z.* = p[j][2];
}

/// Feature indices co-located with point feature `i` (same lon/lat within ~1 cm),
/// excluding `i`. Backs HostSpatialGetAssociatedFeatureIDs for `#P` spatials so
/// LightFlareAndDescription's co-located-light rule (the 45° flare — an S-101
/// portrayal DEFAULT; S-65 does NOT derive flareBearing for this) can run. Writes up
/// to `max` indices into `out`, returns the count; 0 for a non-point feature. O(n)
/// per call, invoked only for the few white/yellow/orange all-round lights whose rule
/// reads AssociatedFeatures. NOAA co-located aids share the exact S-57 node, so a
/// tight position epsilon reconstructs the S-101 shared-spatial association.
export fn tgp_colocated(i: usize, out: [*]usize, max: usize) callconv(.c) usize {
    const c = g_ctx orelse return 0;
    if (i >= c.adapted.len) return 0;
    const pi = c.adapted[i].points;
    if (pi.len == 0) return 0;
    const lon = pi[0][0];
    const lat = pi[0][1];
    const eps: f64 = 1e-7;
    var n: usize = 0;
    for (c.adapted, 0..) |aj, j| {
        if (j == i or aj.points.len == 0) continue;
        if (@abs(aj.points[0][0] - lon) <= eps and @abs(aj.points[0][1] - lat) <= eps) {
            if (n >= max) break;
            out[n] = j;
            n += 1;
        }
    }
    return n;
}

fn eqlAny(role: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, role, n)) return true;
    return false;
}

/// True when an FFPT pointer with relationship indicator `rind` (1=master,
/// 2=slave, 3=peer) satisfies an S-101 association `roleCode`. S-57 FFPT carries
/// only the RIND, not the S-101 role, so the role of the REFERENCED feature is
/// derived from it: a master pointer means the referenced object is the
/// collection/whole/structure, a slave pointer means it is the component/part/
/// equipment. In practice NOAA encodes aids-to-navigation as the structure (beacon/
/// buoy) carrying a SLAVE pointer to its equipment (LIGHTS/DAYMAR/TOPMAR), so
/// `theEquipment`/`theComponent` map to RIND=2. An empty role (the framework's nil)
/// matches any pointer; an unrecognised role is permissive (matches any) rather than
/// silently dropping an association the caller only existence-checks.
fn roleMatchesRind(role: []const u8, rind: u8) bool {
    if (role.len == 0) return true;
    if (eqlAny(role, &.{ "theStructure", "theCollection", "thePrimaryFeature", "theRoofedStructure", "theUpdate" })) return rind == 1;
    if (eqlAny(role, &.{ "theEquipment", "theComponent", "theSupport", "theAuxiliaryFeature", "theUpdatedObject", "theCartographicText", "thePositionProvider" })) return rind == 2;
    return true;
}

/// This-pass adapted indices of the features that feature `i`'s FFPT pointers
/// reference, restricted to the `assoc` association code and filtered by `role`
/// (RIND-derived; see roleMatchesRind). Backs HostFeatureGetAssociatedFeatureIDs so the
/// framework's StructureEquipment association resolves — DistanceMark's standalone-symbol
/// suppression and the structure->equipment text-placement lookup. The returned indices
/// are the same opaque IDs lp_feature_ids/featureCache use. Writes up to `max` into `out`.
///
/// We MUST honor `assoc`: S-57 FFPT only models the structure<->equipment relationship (a
/// beacon/buoy/landmark and its LIGHTS/DAYMAR/TOPMAR) and carries no S-101 association
/// code, so StructureEquipment is the only code we can answer. The catalogue also queries
/// 'TextAssociation' (PortrayalModel), which S-57 has no representation for. Answering that
/// from FFPT returned wrong-class features, and the framework then read the
/// TextPlacement-only attribute `.textType` on a beacon ("Invalid attribute code textType")
/// -> the rule errored -> Default() painted QUESMRK1 on every FFPT-bearing aid. So any code
/// other than StructureEquipment returns empty. O(frefs), non-empty only for FFPT-bearers.
export fn tgp_assoc_features(i: usize, assoc_ptr: [*]const u8, assoc_len: usize, role_ptr: [*]const u8, role_len: usize, out: [*]usize, max: usize) callconv(.c) usize {
    const c = g_ctx orelse return 0;
    if (!std.mem.eql(u8, assoc_ptr[0..assoc_len], "StructureEquipment")) return 0;
    if (i >= c.adapted.len) return 0;
    const fi = c.adapted[i].feature_index;
    if (fi >= c.cell.features.len) return 0;
    const frefs = c.cell.features[fi].frefs;
    if (frefs.len == 0) return 0;
    const role = role_ptr[0..role_len];
    var n: usize = 0;
    for (frefs) |fr| {
        if (!roleMatchesRind(role, fr.rind)) continue;
        const tfi = c.cell.featureIndexByFoid(fr.lnam) orelse continue;
        if (tfi >= c.feat_to_adapted.len) continue;
        const aj = c.feat_to_adapted[tfi] orelse continue;
        if (aj == i) continue; // a feature never associates with itself
        if (n >= max) break;
        out[n] = aj;
        n += 1;
    }
    return n;
}

/// C calls this with each feature's joined instruction stream.
export fn tgp_emit(i: usize, instr_ptr: [*]const u8, instr_len: usize) callconv(.c) void {
    const c = g_ctx orelse return;
    if (i >= c.results.len) return;
    const instr = instr_ptr[0..instr_len];
    c.results[i] = c.arena.dupe(u8, instr) catch "";
    // Diagnostic (TILE57_DEBUG): a feature that couldn't be portrayed carries Default()'s
    // QUESMRK1 "?". Name the exact offender — cell, S-101 class, primitive, S-57 rcid,
    // position — so a "?" on the chart traces to one feature, not an anonymous rule error.
    if (tg_debug_enabled() != 0 and i < c.adapted.len and std.mem.indexOf(u8, instr, "QUESMRK1") != null) {
        const ad = c.adapted[i];
        const in_range = ad.feature_index < c.cell.features.len;
        const rcid: u32 = if (in_range) c.cell.features[ad.feature_index].rcid else 0;
        const objl: u16 = if (in_range) c.cell.features[ad.feature_index].objl else 0;
        const s57acr = catalogue.acronymByObjl(objl) orelse "?"; // S-57 source class, for mis-route triage
        const cell_name = if (c.cell.name.len > 0) c.cell.name else "?";
        if (ad.points.len > 0)
            std.debug.print("[s101:quesmrk] cell={s} class={s} s57={s} prim={s} rcid={d} lonlat={d:.6},{d:.6}\n", .{ cell_name, ad.code, s57acr, ad.primitive, rcid, ad.points[0][0], ad.points[0][1] })
        else
            std.debug.print("[s101:quesmrk] cell={s} class={s} s57={s} prim={s} rcid={d}\n", .{ cell_name, ad.code, s57acr, ad.primitive, rcid });
    }
}

// ---- entry point ---------------------------------------------------------

/// S-101 context parameters for a portrayal pass. The DEFAULTS are the fixed
/// bake context (SafetyContour/Depth 30 etc. — see live-mariner-swap: the tile
/// path bakes with this context and defers mariner choices to swappable props),
/// so `.{}` reproduces baked output exactly. A native render (render-engine
/// P1+) passes the mariner's REAL settings here — the rules then evaluate the
/// actual safety contour, boundary style, and point-symbol style, with no
/// prop-swap machinery.
pub const Context = struct {
    plain_boundaries: bool = false, // S-52 §8.6.1 boundary symbolization
    simplified_symbols: bool = false, // S-52 §11.2.2 point-symbol style
    radar_overlay: bool = false,
    four_shades: bool = true,
    full_light_lines: bool = false,
    ignore_scale_minimum: bool = false,
    shallow_water_dangers: bool = false,
    safety_contour: f64 = 30,
    safety_depth: f64 = 30,
    shallow_contour: f64 = 2,
    deep_contour: f64 = 30,
    safety_height: f64 = 0,

    fn toC(self: Context) CContext {
        return .{
            .plain_boundaries = @intFromBool(self.plain_boundaries),
            .simplified_symbols = @intFromBool(self.simplified_symbols),
            .radar_overlay = @intFromBool(self.radar_overlay),
            .four_shades = @intFromBool(self.four_shades),
            .full_light_lines = @intFromBool(self.full_light_lines),
            .ignore_scale_minimum = @intFromBool(self.ignore_scale_minimum),
            .shallow_water_dangers = @intFromBool(self.shallow_water_dangers),
            .safety_contour = self.safety_contour,
            .safety_depth = self.safety_depth,
            .shallow_contour = self.shallow_contour,
            .deep_contour = self.deep_contour,
            .safety_height = self.safety_height,
        };
    }
};

/// Run the S-101 rules over `adapted` with `ov`, returning a stream array indexed
/// by cell.features index (null where the adapted subset doesn't cover a feature,
/// or it emitted nothing). `features_len` is cell.features.len.
/// Serialize an adapted attribute node (simple sub-attrs + complex children,
/// recursively) into `kb` — the part of the dedup key that captures everything the
/// rules read via tgp_simple / tgp_complex. Byte separators (unit/record/group) keep
/// distinct trees distinct.
fn appendNode(arena: std.mem.Allocator, kb: *std.ArrayList(u8), node: adapter.CNode) !void {
    for (node.simple) |s| {
        try kb.append(arena, 0x1f);
        try kb.appendSlice(arena, s.name);
        try kb.append(arena, '=');
        try kb.appendSlice(arena, s.value);
    }
    for (node.children) |ch| {
        try kb.append(arena, 0x1e);
        try kb.appendSlice(arena, ch.code);
        try kb.append(arena, '{');
        for (ch.nodes) |n| {
            try appendNode(arena, kb, n);
            try kb.append(arena, 0x1d);
        }
        try kb.append(arena, '}');
    }
}

/// The portrayal of a Curve/Surface feature with no feature-to-feature relationship is
/// a pure function of what the rules can read for it: its class, primitive, and the
/// SYNTHESIZED attribute tree (adaptCell's output, which already folds in the S-65
/// spatial derivations — inTheWater, surroundingDepth — so two features agreeing on it
/// truly portray alike). The host serves such features NO geometry (tgp_points_count is
/// 0, so tgp_colocated finds nothing and GetSpatial is never consulted) and NO
/// associations (tgp_assoc_features is empty without FFPT). Point features are excluded
/// — they carry geometry the rules query (co-located aids, sector construction) — as are
/// FFPT sources and targets, whose portrayal folds in a related feature. Returns "" (do
/// not dedupe) for any of those.
fn dedupKey(arena: std.mem.Allocator, ad: adapter.Adapted, f: s57.Feature, referenced: *const std.AutoHashMap(u64, void)) []const u8 {
    if (std.mem.eql(u8, ad.primitive, "Point")) return "";
    if (f.frefs.len > 0) return "";
    if (f.foid != 0 and referenced.contains(f.foid)) return "";
    var kb = std.ArrayList(u8).empty;
    kb.appendSlice(arena, ad.code) catch return "";
    kb.append(arena, ':') catch return "";
    kb.appendSlice(arena, ad.primitive) catch return "";
    appendNode(arena, &kb, ad.root) catch return "";
    return kb.items;
}

fn runAdapted(arena: std.mem.Allocator, cell: *const s57.Cell, adapted: []const adapter.Adapted, rules_dir: []const u8, pctx: Context) ![]?[]const u8 {
    // Portrayal dedup: a Curve/Surface feature with no FFPT relationship portrays as a
    // pure function of (class, primitive, attributes) — see dedupKey. Run the S-101
    // rules ONCE per distinct key and fan the instruction stream out to the rest, so a
    // cell with hundreds of same-depth areas/contours evaluates the (expensive) Lua
    // rules a few dozen times instead of thousands. Point / FFPT-related features carry
    // per-instance context (co-located aids, related equipment) and always run.
    var referenced = std.AutoHashMap(u64, void).init(arena);
    for (cell.features) |cf| for (cf.frefs) |fr| try referenced.put(fr.lnam, {});

    // The reduced pass = representatives + every non-deduped feature, in original order.
    // `src` maps each original adapted index to the reduced index whose result it takes.
    var reduced = std.ArrayList(adapter.Adapted).empty;
    const src = try arena.alloc(usize, adapted.len);
    var groups = std.StringHashMap(usize).init(arena); // dedupKey -> representative's reduced index
    for (adapted, 0..) |ad, i| {
        const key = dedupKey(arena, ad, cell.features[ad.feature_index], &referenced);
        if (key.len > 0) {
            if (groups.get(key)) |ri| {
                src[i] = ri; // a later duplicate reuses the representative's result
                continue;
            }
            try groups.put(key, reduced.items.len);
        }
        src[i] = reduced.items.len;
        try reduced.append(arena, ad);
    }

    const results = try arena.alloc([]const u8, reduced.items.len);
    for (results) |*r| r.* = "";

    // Reverse index cell.features index -> reduced index, so an FFPT pointer (resolved
    // to a feature index via Cell.featureIndexByFoid) maps back to the opaque Lua
    // feature ID (the reduced index) that HostFeatureGetCode/featureCache use. Deduped
    // features are absent, but dedupKey never dedupes a referenced FOID, so nothing
    // resolves to them. Only features present in THIS pass are mapped, so a subset
    // (variant) pass resolves associations among its own features.
    const feat_to_adapted = try arena.alloc(?usize, cell.features.len);
    for (feat_to_adapted) |*x| x.* = null;
    for (reduced.items, 0..) |ad, i| {
        if (ad.feature_index < feat_to_adapted.len) feat_to_adapted[ad.feature_index] = i;
    }

    var ctx = Ctx{ .adapted = reduced.items, .results = results, .arena = arena, .cell = cell, .feat_to_adapted = feat_to_adapted };
    g_ctx = &ctx;
    defer g_ctx = null;

    const cctx = pctx.toC();
    _ = tg_portray_run(rules_dir.ptr, rules_dir.len, &cctx);

    // Re-key results to cell feature index: each original feature takes its
    // representative's (or, undeduped, its own) instruction stream.
    const by_feature = try arena.alloc(?[]const u8, cell.features.len);
    for (by_feature) |*b| b.* = null;
    for (adapted, 0..) |ad, i| {
        const r = results[src[i]];
        if (r.len > 0) by_feature[ad.feature_index] = r;
    }
    return by_feature;
}

/// Portray a cell: returns an array indexed by cell.features index, each the
/// feature's S-101 instruction stream (or null if the class is unmapped / it
/// emitted nothing). Allocates into `arena` (must outlive tile generation).
pub fn portrayCell(arena: std.mem.Allocator, cell: *const s57.Cell, rules_dir: []const u8) ![]?[]const u8 {
    const adapted = try adapter.adaptCell(arena, cell);
    return runAdapted(arena, cell, adapted, rules_dir, .{});
}

/// Portray a cell with an explicit S-101 context — the native-render entry
/// point: the mariner's REAL safety contour / depth /
/// boundary + point styles evaluate inside the rules, so the output needs none
/// of the tile path's live-swap props. One pass, one context.
pub fn portrayCellWith(arena: std.mem.Allocator, cell: *const s57.Cell, rules_dir: []const u8, ctx: Context) ![]?[]const u8 {
    return portrayCellWithAdapted(arena, cell, try adapter.adaptCell(arena, cell), rules_dir, ctx);
}

/// Like `portrayCellWith` but over a PRE-BUILT adapted set — the native-S-101 entry
/// point (skips `adapter.adaptCell`; see `portrayCellVariantsAdapted`).
pub fn portrayCellWithAdapted(arena: std.mem.Allocator, cell: *const s57.Cell, adapted: []const adapter.Adapted, rules_dir: []const u8, ctx: Context) ![]?[]const u8 {
    return runAdapted(arena, cell, adapted, rules_dir, ctx);
}

/// A cell's default portrayal plus its display-variant passes. `plain` is the
/// PlainBoundaries=true pass over AREA features only (S-52 §8.6.1 boundary
/// symbolization); `simplified` is the SimplifiedSymbols=true pass over (non-
/// SOUNDG) POINT features only (§11.2.2). Both are indexed by cell.features index
/// and non-null only for the relevant feature kind; either may be null if its pass
/// failed (the axis then degrades to the default/common pass downstream).
pub const CellPortrayal = struct {
    base: []const ?[]const u8,
    plain: ?[]const ?[]const u8 = null,
    simplified: ?[]const ?[]const u8 = null,
};

/// Portray a cell three ways so the client can toggle boundary style (areas) and
/// point-symbol style (points) live: the default pass, a PlainBoundaries pass over
/// only the area features, and a SimplifiedSymbols pass over only the point
/// features. The variant passes portray only the geometry kind whose display they
/// vary (areas for bnd, points for pts) — lines/soundings never read either
/// override — so the extra rule evaluation is bounded to the relevant features.
pub fn portrayCellVariants(arena: std.mem.Allocator, cell: *const s57.Cell, rules_dir: []const u8) !CellPortrayal {
    return portrayCellVariantsAdapted(arena, cell, try adapter.adaptCell(arena, cell), rules_dir);
}

/// Like `portrayCellVariants` but over a PRE-BUILT adapted set — the native-S-101
/// entry point. A native cell's features already carry S-101 class + attribute
/// records (`s101.native`), so this bypasses `adapter.adaptCell` entirely: the
/// dedup / three-variant machinery is identical, only the adaptation source differs.
pub fn portrayCellVariantsAdapted(arena: std.mem.Allocator, cell: *const s57.Cell, adapted: []const adapter.Adapted, rules_dir: []const u8) !CellPortrayal {
    const base = try runAdapted(arena, cell, adapted, rules_dir, .{});

    // Partition the adapted features by the variant they can contribute. "Surface"
    // → the plain-boundary variant; "Point" → the simplified-symbol variant
    // (SOUNDG is already excluded from `adapted`, and "Curve" varies under neither).
    var areas = std.ArrayList(adapter.Adapted).empty;
    var points = std.ArrayList(adapter.Adapted).empty;
    for (adapted) |ad| {
        if (std.mem.eql(u8, ad.primitive, "Surface")) {
            try areas.append(arena, ad);
        } else if (std.mem.eql(u8, ad.primitive, "Point")) {
            try points.append(arena, ad);
        }
    }

    var cp = CellPortrayal{ .base = base };
    if (areas.items.len > 0)
        cp.plain = runAdapted(arena, cell, areas.items, rules_dir, .{ .plain_boundaries = true }) catch null;
    if (points.items.len > 0)
        cp.simplified = runAdapted(arena, cell, points.items, rules_dir, .{ .simplified_symbols = true }) catch null;
    return cp;
}
