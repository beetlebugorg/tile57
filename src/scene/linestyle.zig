//! Complex (symbolised) line tessellation (S-101 LineStyles): a named linestyle
//! (LC, or a LineInstruction whose style is not "_simple_") is walked by arc length
//! and emitted per period as dash "on" runs plus each embedded symbol as a point
//! rotated to the local tangent. The registry (id -> Info) is set once by the
//! baker before tile generation, then read-only during the parallel bake.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const tile = @import("tiles").tile;
const mvt = @import("tiles").mvt;
const style = @import("style");
const rs = @import("render").surface;
const SYMBOL_SCALE: f64 = @import("render").sndfrm.SYMBOL_SCALE;

// === Complex (symbolised) line tessellation (S-101 LineStyles) =============
// A named linestyle (LC / a LineInstruction whose style is not "_simple_") is
// tessellated per zoom: walk the line by arc length and emit, per period, the dash
// "on" runs as line segments + each embedded symbol as a point rotated to the local
// tangent. Mirrors Go bake/complexline.go + linestyle_catalog.go. The mm geometry is
// parsed by style.parseLineStyle; the baker converts it to Info at the PresLib
// FEATURE scale (ls_px_per_mm) and registers it before baking.

const ls_feature_scale: f64 = 0.01 / 0.35278; // px per 0.01-mm PresLib unit (= SYMBOL_SCALE)
const ls_px_per_mm: f64 = 100.0 * ls_feature_scale; // mm -> screen px
/// The mm->px feature scale the baker must apply when building an Info from the raw
/// millimetre LineStyles geometry (style.parseLineStyle), so the tessellator and the
/// table agree. Differs from the symbol-scale style.analysePattern uses for the
/// client linestyles.json.
pub const LINESTYLE_PX_PER_MM = ls_px_per_mm;

pub const Symbol = struct { name: []const u8, offset_px: f64 };
pub const Info = struct {
    period_px: f64,
    on_runs: []const [2]f64, // [lo,hi] screen px from period start
    symbols: []const Symbol,
    color_token: []const u8,
    width_px: f64,
};

// Set once by the baker before tile generation; read-only during the parallel bake
// (encodeTile only reads), so it needs no lock. Absent => named lines fall
// back to the generic dashed stroke (live/host path, no regression).
var g_linestyles: std.StringHashMapUnmanaged(Info) = .{};

/// Register one analysed complex linestyle (id = LineStyles file stem). `id` and the
/// Info slices must outlive the bake (embedded XML / the bake's long-lived alloc).
pub fn registerLinestyle(gpa: Allocator, id: []const u8, info: Info) void {
    g_linestyles.put(gpa, id, info) catch {};
}

/// Look up a registered complex linestyle by id (LineStyles file stem); null if
/// unregistered, so the caller falls back to a generic dashed stroke.
pub fn lookup(id: []const u8) ?Info {
    return g_linestyles.get(id);
}


/// Populate the complex-linestyle table from S-101 LineStyles XML sources
/// (id = file stem). IDEMPOTENT — a populated table is left untouched, so
/// every scene entry point (bake, lib renderView, CLI render) can call it
/// unconditionally; forgetting it silently degrades named linestyles
/// (MARSYS51, cables, pipelines, …) to generic dashed strokes. Mirrors the
/// Go lsInfoFromCatalog: mm geometry at the PresLib feature scale, S-52
/// minimum pen width. `gpa` + `srcs` must outlive all tile generation.
pub fn registerLinestylesXml(gpa: Allocator, srcs: []const style.LineStyleSrc) void {
    if (g_linestyles.count() > 0) return;
    const px = LINESTYLE_PX_PER_MM;
    for (srcs) |s| {
        const parsed = style.parseLineStyle(gpa, s.xml) catch continue;
        const period = parsed.interval_length * px;
        if (period < 0.5) continue; // no interval to tile (pure-symbol style)
        var runs = std.ArrayList([2]f64).empty;
        for (parsed.dashes) |d| {
            const lo = d.start * px;
            const hi = (d.start + d.length) * px;
            if (hi - lo > 1e-6) runs.append(gpa, .{ lo, hi }) catch {};
        }
        var syms = std.ArrayList(Symbol).empty;
        for (parsed.symbols) |sym| syms.append(gpa, .{ .name = sym.reference, .offset_px = sym.position * px }) catch {};
        var width = parsed.pen_width * px;
        if (width < 0.6) width = 0.9; // S-52 minimum pen
        registerLinestyle(gpa, s.id, .{
            .period_px = period,
            .on_runs = runs.items,
            .symbols = syms.items,
            .color_token = parsed.pen_color,
            .width_px = width,
        });
    }
}

const LsTangent = struct { p: tile.FPoint, dx: f64, dy: f64 };

/// Point at local arc `d` along rp plus the (un-normalised) tangent of its segment.
fn lsPointAndTangent(rp: []const tile.FPoint, rarc: []const f64, d_in: f64) ?LsTangent {
    const total = rarc[rarc.len - 1];
    const d = std.math.clamp(d_in, 0, total);
    var i: usize = 0;
    while (i + 1 < rp.len) : (i += 1) {
        if (d <= rarc[i + 1] or i + 2 == rp.len) {
            const seg = rarc[i + 1] - rarc[i];
            const t: f64 = if (seg > 1e-12) (d - rarc[i]) / seg else 0;
            return .{
                .p = .{ .x = rp[i].x + t * (rp[i + 1].x - rp[i].x), .y = rp[i].y + t * (rp[i + 1].y - rp[i].y) },
                .dx = rp[i + 1].x - rp[i].x,
                .dy = rp[i + 1].y - rp[i].y,
            };
        }
    }
    return null;
}

fn lsLerpArc(rp: []const tile.FPoint, rarc: []const f64, d: f64) tile.FPoint {
    return (lsPointAndTangent(rp, rarc, d) orelse LsTangent{ .p = rp[0], .dx = 0, .dy = 0 }).p;
}

/// Sub-polyline of rp between local arc distances d0..d1 (endpoints interpolated).
fn lsSubPathByArc(a: Allocator, rp: []const tile.FPoint, rarc: []const f64, d0_in: f64, d1_in: f64) ![]tile.FPoint {
    const total = rarc[rarc.len - 1];
    const d0 = std.math.clamp(d0_in, 0, total);
    const d1 = std.math.clamp(d1_in, 0, total);
    if (d1 - d0 < 1e-9) return &.{};
    var out = std.ArrayList(tile.FPoint).empty;
    try out.append(a, lsLerpArc(rp, rarc, d0));
    for (rp, 0..) |p, i| {
        if (rarc[i] > d0 and rarc[i] < d1) try out.append(a, p);
    }
    try out.append(a, lsLerpArc(rp, rarc, d1));
    return out.items;
}

/// Tessellate a complex linestyle along a feature's geometry parts into this tile.
/// `emit_symbols` is false when best-band suppression drops the coarse cell's points.
/// Stage B: walk ONE clipped tile-local run by the complex-linestyle period,
/// emitting dash "on" segments and tangent-rotated embedded symbols. Runs are
/// already tile-local (no z/x/y needed). At RENDER the period AND the px offsets
/// are multiplied by `size_scale`, so spacing and brick size both scale with the
/// display (vector.zig scales the brick to match) and the BAKED tiles stay
/// display-independent. `size_scale <= 0` (bake / CLI) collapses to 1.0.
pub fn drawComplexRun(a: Allocator, rp: []const tile.FPoint, arc0: f64, info: Info, color: []const u8, size_scale: f64, emit_symbols: bool, surf: rs.Surface) !void {
    if (rp.len < 2) return;
    const ext: f64 = @floatFromInt(tile.EXTENT);
    const px_scale = ext / 256.0; // figures are laid out in 256-px-per-tile space
    const ss = if (size_scale > 0) size_scale else 1.0;
    const period = info.period_px * px_scale * ss;
    if (period < 1e-6) return;
    const rarc = try a.alloc(f64, rp.len);
    rarc[0] = 0;
    for (1..rp.len) |i| rarc[i] = rarc[i - 1] + std.math.hypot(rp[i].x - rp[i - 1].x, rp[i].y - rp[i - 1].y);
    const g0 = arc0;
    const run_end = g0 + rarc[rp.len - 1];
    var k: i64 = @intFromFloat(@floor(g0 / period));
    while (@as(f64, @floatFromInt(k)) * period < run_end) : (k += 1) {
        const base = @as(f64, @floatFromInt(k)) * period;
        for (info.on_runs) |on| { // dash on-runs -> line segments
            const lo = @max(base + on[0] * px_scale * ss, g0);
            const hi = @min(base + on[1] * px_scale * ss, run_end);
            if (hi - lo < 1e-6) continue;
            const sub = try lsSubPathByArc(a, rp, rarc, lo - g0, hi - g0);
            if (sub.len < 2) continue;
            const seg = try a.alloc(mvt.Point, sub.len);
            for (sub, 0..) |spt, i| seg[i] = tile.quantizeF(spt);
            const segparts = try a.alloc([]const mvt.Point, 1);
            segparts[0] = seg;
            try surf.strokeLine(color, info.width_px, .solid, segparts, null);
        }
        if (!emit_symbols) continue;
        for (info.symbols) |sym| { // embedded symbols -> tangent-rotated points
            if (sym.name.len == 0) continue;
            const gp = base + sym.offset_px * px_scale * ss;
            if (gp < g0 or gp > run_end) continue;
            const tp = lsPointAndTangent(rp, rarc, gp - g0) orelse continue;
            const qp = tile.quantizeF(tp.p);
            // Own each embedded symbol by exactly ONE tile: emit it only when its
            // position lands inside the RAW tile [0,EXTENT). The dash-run lines
            // keep the buffered clip (seamless strokes across the seam), but a
            // symbol in the buffer zone would otherwise be tessellated by BOTH
            // this tile and its neighbour -> the same symbol drawn twice at every
            // tile seam (user-reported "double symbols"). Half-open so a symbol on
            // the seam belongs to exactly one side (no gap, no double).
            if (qp.x < 0 or qp.x >= tile.EXTENT or qp.y < 0 or qp.y >= tile.EXTENT) continue;
            const rot = std.math.atan2(tp.dy, tp.dx) * 180.0 / std.math.pi;
            try surf.drawSymbol(sym.name, qp, rot, SYMBOL_SCALE, true, .line, null);
        }
    }
}

/// Tessellate a complex linestyle along a feature's geometry parts into this tile.
/// `emit_symbols` is false when best-band suppression drops the coarse cell's points.
/// `style` is the linestyle id: at BAKE we store each clipped run un-tessellated
/// (tagged with the id) so replay can re-walk the period display-scaled; on a live
/// render surface we walk it here at that surface's size_scale.
pub fn drawComplexLine(a: Allocator, parts: []const []s57.LonLat, info: Info, line_style: []const u8, color: []const u8, emit_symbols: bool, z: u8, x: u32, y: u32, box: tile.Box, fmeta: *const rs.FeatureMeta, surf: rs.Surface) !void {
    const store = surf.canStoreComplexRun();
    const ss = surf.sizeScale();
    try surf.beginFeature(fmeta);
    for (parts) |part| {
        if (part.len < 2) continue;
        const fpts = try a.alloc(tile.FPoint, part.len);
        for (part, 0..) |pt, i| fpts[i] = tile.worldToTileF(tile.lonLatToWorld(pt.lon(), pt.lat()), z, x, y, tile.EXTENT);
        const arc = try a.alloc(f64, part.len);
        arc[0] = 0;
        for (1..part.len) |i| arc[i] = arc[i - 1] + std.math.hypot(fpts[i].x - fpts[i - 1].x, fpts[i].y - fpts[i - 1].y);
        for (try tile.clipLinePhased(a, fpts, arc, box)) |run| {
            if (run.points.len < 2) continue;
            if (store) {
                // BAKE: store the clipped run un-tessellated (display-independent).
                const qpts = try a.alloc(mvt.Point, run.points.len);
                for (run.points, 0..) |p, i| qpts[i] = tile.quantizeF(p);
                try surf.storeComplexRun(line_style, color, info.width_px, run.arc0, qpts);
            } else {
                // LIVE / CLI render: walk the period at this surface's display scale.
                try drawComplexRun(a, run.points, run.arc0, info, color, ss, emit_symbols, surf);
            }
        }
    }
    try surf.endFeature();
}
