//! Cell-driven S-101 portrayal. Adapts a cell's features (s101_adapt), exposes
//! them to the embedded Lua via C-ABI accessors (tgp_*), runs the rules once
//! (tg_portray_run in lua_shim.c), and returns per-feature instruction streams
//! for translation to MVT (s101_instr).
//!
//! Lib-only (links Lua via the C shim) — not part of the pure root.zig used by
//! the tests/bake exe.

const std = @import("std");
const s57 = @import("s57.zig");
const adapt = @import("s101_adapt.zig");

const Ctx = struct {
    adapted: []adapt.Adapted,
    results: [][]const u8, // per adapted index -> instruction stream (arena-owned)
    arena: std.mem.Allocator,
};

// Single in-flight portrayal (portrayal runs serially, once per cell open).
var g_ctx: ?*Ctx = null;

// Implemented in C (lua_shim.c): loads the framework + rules from `dir`,
// dispatches every feature exposed by the tgp_* accessors, and calls tgp_emit
// for each. Returns 0 on success.
extern fn tg_portray_run(dir_ptr: [*]const u8, dir_len: usize) callconv(.c) c_int;

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

/// Attribute value for adapted feature i and S-101 attribute name; null if absent.
export fn tgp_attr(i: usize, name_ptr: [*]const u8, name_len: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const name = name_ptr[0..name_len];
    for (g_ctx.?.adapted[i].attrs) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            out_len.* = a.value.len;
            return a.value.ptr;
        }
    }
    return null;
}

/// Number of instances of complex attribute `name` synthesized on feature i
/// (e.g. featureName from OBJNAM, zoneOfConfidence from M_QUAL CATZOC). Each
/// synthesized complex attribute is a single instance.
export fn tgp_complex_count(i: usize, name_ptr: [*]const u8, name_len: usize) callconv(.c) usize {
    const name = name_ptr[0..name_len];
    var n: usize = 0;
    for (g_ctx.?.adapted[i].complex) |c| {
        if (std.mem.eql(u8, c.name, name)) n += 1;
    }
    return n;
}

/// Value of simple sub-attribute `code` inside a synthesized complex instance on
/// feature i. `path` is the framework's attributePath; its leading segment names
/// the complex instance (e.g. "featureName:1", "zoneOfConfidence:1"). Null if the
/// complex/sub-attribute is absent (the caller then falls back to the flat attrs).
export fn tgp_complex_attr(i: usize, path_ptr: [*]const u8, path_len: usize, code_ptr: [*]const u8, code_len: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const path = path_ptr[0..path_len];
    const code = code_ptr[0..code_len];
    var end: usize = 0;
    while (end < path.len and path[end] != ':' and path[end] != '/') : (end += 1) {}
    const cname = path[0..end];
    for (g_ctx.?.adapted[i].complex) |c| {
        if (!std.mem.eql(u8, c.name, cname)) continue;
        for (c.subs) |s| {
            if (std.mem.eql(u8, s.name, code)) {
                out_len.* = s.value.len;
                return s.value.ptr;
            }
        }
    }
    return null;
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

/// C calls this with each feature's joined instruction stream.
export fn tgp_emit(i: usize, instr_ptr: [*]const u8, instr_len: usize) callconv(.c) void {
    const c = g_ctx orelse return;
    if (i >= c.results.len) return;
    c.results[i] = c.arena.dupe(u8, instr_ptr[0..instr_len]) catch "";
}

// ---- entry point ---------------------------------------------------------

/// Portray a cell: returns an array indexed by cell.features index, each the
/// feature's S-101 instruction stream (or null if the class is unmapped / it
/// emitted nothing). Allocates into `arena` (must outlive tile generation).
pub fn portrayCell(arena: std.mem.Allocator, cell: *const s57.Cell, rules_dir: []const u8) ![]?[]const u8 {
    const adapted = try adapt.adaptCell(arena, cell);
    const results = try arena.alloc([]const u8, adapted.len);
    for (results) |*r| r.* = "";

    var ctx = Ctx{ .adapted = adapted, .results = results, .arena = arena };
    g_ctx = &ctx;
    defer g_ctx = null;

    _ = tg_portray_run(rules_dir.ptr, rules_dir.len);

    // Re-key adapted-index results to cell feature index.
    const by_feature = try arena.alloc(?[]const u8, cell.features.len);
    for (by_feature) |*b| b.* = null;
    for (adapted, 0..) |ad, i| {
        if (results[i].len > 0) by_feature[ad.feature_index] = results[i];
    }
    return by_feature;
}
