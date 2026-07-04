//! style.zig — MapLibre GL style.json generation for the chart bundle. Resolves
//! each S-52 colour token to hex for a palette and emits the fill / line / symbol
//! / text layer set. Ported from the chartplotter web frontend's s52-style.mjs /
//! chart-style.mjs (and the now-removed style/build_style.py, kept in git history;
//! it was verified layer-for-layer identical during the port). The sole style
//! generator now. Part of the `assets` module.
//!
//! MapLibre expressions are written as Zig comptime tuples — `.{ "get", "drval1" }`
//! serialises to `["get","drval1"]` — through std.json's Stringify write-stream,
//! which owns all escaping, comma, and brace handling. No raw JSON in the source;
//! the only hand-rolled fragment is the variable-length colour `match` (the palette
//! is runtime data), and that goes through the same stream.

const std = @import("std");
const Stringify = std.json.Stringify;
const chartstyle = @import("chartstyle.zig");

const FALLBACK = "#ff00ff";
const FONT = .{"Noto Sans Regular"};

// ---- MapLibre expressions, as comptime tuples ----------------------------
// SEABED01 depth shading, the danger-symbol swap, and the sounding bold/faint split
// are mariner-dependent and now resolve through the chartstyle builders (one style
// builder); only the mariner-INDEPENDENT layout exprs remain comptime tuples here.

// SCAMIN display-scale denominator at z0 (0.28 mm OGC pixel, equator). Used by the
// zoom-filter FALLBACK gate below — applied only when no SCAMIN manifest is supplied
// (so a source without the manifest still gates by value, just at integer-zoom snap
// + the OGC scale rather than the precise per-value native buckets).
const DENOM_Z0 = 279541132.0;

// Fallback per-feature gate: show a SCAMIN feature only at/above its 1:N display zoom.
// Superseded by the native per-value minzoom buckets when the manifest is present.
const SCAMIN_GATE = .{ ">=", .{"zoom"}, .{ "log2", .{ "/", DENOM_Z0, .{ "coalesce", .{ "get", "scamin" }, DENOM_Z0 } } } };

// Physical-scale constants from the web client (web/src/lib/util.mjs), so an engine
// SCAMIN bucket's native minzoom MATCHES the JS client's scaminDisplayZoom (the §7
// render-parity gate). The client DISPLAY cutoff uses the calibrated 0.2645 mm CSS
// pixel (NOT the 0.28 mm OGC pixel the bake floor / Go scaminZoom use, ≈279.5M).
const M_PER_PX_Z0 = 78271.516964020485; // metres / CSS-px at z0, equator (512-tile)
const DEFAULT_PX_PITCH_MM = 0.2645; // calibrated CSS-pixel pitch (NOT the OGC 0.28 mm)

/// Fractional Web-Mercator display zoom at which SCAMIN 1:`scamin` reaches its 1:N
/// min display scale at `lat` — i.e. the native minzoom of that value's bucket layer.
/// Mirrors the client zoomForScalePhysical(scamin, lat, DEFAULT_PX_PITCH_MM): the
/// screen reads 1:scamin when zoom == log2(M_PER_PX_Z0·cos lat / ((pitch/1000)·scamin)).
pub fn scaminDisplayZoom(scamin: f64, lat: f64) f64 {
    if (!(scamin > 0)) return 0;
    const z = std.math.log2(M_PER_PX_Z0 * @cos(lat * std.math.pi / 180.0) /
        ((DEFAULT_PX_PITCH_MM / 1000.0) * scamin));
    return std.math.clamp(z, 0, 24);
}

test "scaminDisplayZoom matches the JS zoomForScalePhysical formula" {
    // log2(78271.516964 / (0.0002645 · 30000)) = log2(9863.83…) = 13.2685…
    try std.testing.expectApproxEqAbs(@as(f64, 13.2685), scaminDisplayZoom(30000, 0), 1e-3);
    // Latitude pulls the cutoff EARLIER (cos lat < 1): higher lat → lower zoom.
    try std.testing.expect(scaminDisplayZoom(30000, 60) < scaminDisplayZoom(30000, 10));
    // Coarser SCAMIN (bigger denominator) shows from a lower zoom.
    try std.testing.expect(scaminDisplayZoom(180000, 0) < scaminDisplayZoom(30000, 0));
    // Clamped to [0,24].
    try std.testing.expectEqual(@as(f64, 0), scaminDisplayZoom(0, 0));
}

/// Physical display-scale denominator (1:N) on screen at Web-Mercator `zoom`,
/// latitude `lat` — the exact inverse of scaminDisplayZoom (same calibrated
/// CSS-pixel pitch). The band-handoff carry-down (bake_enc / chart tileRefs)
/// compares this against a covering finer cell's compilation scale to decide
/// whether a tile's display window still needs the coarser band's content.
pub fn displayDenom(zoom: f64, lat: f64) f64 {
    return M_PER_PX_Z0 * @cos(lat * std.math.pi / 180.0) /
        ((DEFAULT_PX_PITCH_MM / 1000.0) * std.math.exp2(zoom));
}

/// displayDenom at an INTEGER Web-Mercator zoom — the engine's per-tile case
/// (a tile at zoom z displays for denominators [D(z,φ), D(z,φ)/2)). Computes 2^z
/// as an integer shift so it stays libm-free (the pure-Zig scene tests link
/// without libc; f64 exp2 would pull in ldexp).
pub fn displayDenomZ(z: u8, lat: f64) f64 {
    return M_PER_PX_Z0 * @cos(lat * std.math.pi / 180.0) /
        ((DEFAULT_PX_PITCH_MM / 1000.0) * @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z))));
}

test "displayDenom is the exact inverse of scaminDisplayZoom" {
    // Round-trip: the zoom where 1:30000 activates reads 1:30000 on screen.
    try std.testing.expectApproxEqRel(@as(f64, 30000), displayDenom(scaminDisplayZoom(30000, 38.9), 38.9), 1e-9);
    // Spec evidence anchors: D(9, 24.58°) ≈ 526k, D(9, 39.2°) ≈ 448k.
    try std.testing.expectApproxEqRel(@as(f64, 525.6e3), displayDenom(9.0, 24.58), 1e-2);
    try std.testing.expectApproxEqRel(@as(f64, 447.9e3), displayDenom(9.0, 39.2), 1e-2);
    // The integer-zoom engine variant is bit-exact with the general formula.
    try std.testing.expectEqual(displayDenom(9.0, 39.2), displayDenomZ(9, 39.2));
    try std.testing.expectEqual(displayDenom(0.0, 0.0), displayDenomZ(0, 0.0));
}

// S-52 DrawingPriority fill order: draw_prio*1000 - drval1.
const FILL_SORT = .{ "-", .{ "*", .{ "coalesce", .{ "get", "draw_prio" }, 0 }, 1000 }, .{ "coalesce", .{ "get", "drval1" }, 0 } };

const FILT_SOLID = .{ "==", .{ "coalesce", .{ "get", "dash" }, "solid" }, "solid" };
const FILT_DASHED = .{ "==", .{ "get", "dash" }, "dashed" };
const FILT_DOTTED = .{ "==", .{ "get", "dash" }, "dotted" };

const ICON_SIZE = .{ "/", .{ "coalesce", .{ "get", "scale" }, 0.08 }, 0.08 };

const VROW = .{ "match", .{ "coalesce", .{ "get", "valign" }, "middle" }, "top", "top", "bottom", "bottom", "center" };
const TEXT_ANCHOR = .{
    "match",         .{ "concat", VROW, "|", .{ "coalesce", .{ "get", "halign" }, "center" } },
    "center|left",   "left",
    "center|right",  "right",
    "center|center", "center",
    "top|center",    "top",
    "bottom|center", "bottom",
    "top|left",      "top-left",
    "top|right",     "top-right",
    "bottom|left",   "bottom-left",
    "bottom|right",  "bottom-right",
    "center",
};
const TEXT_SORT_KEY = .{ "-", .{ "match", .{ "coalesce", .{ "get", "tgrp" }, -1 }, 11, 0, .{ 21, 26, 29 }, 100, 23, 50, 150 }, .{ "coalesce", .{ "get", "font_size_px" }, 10 } };

// S-101 LocalOffset -> MapLibre text-offset (em): shifts a label clear of its symbol
// (e.g. a buoy name one text-body above the point). MVT properties are scalar and
// MapLibre can't build an [x,y] array from two of them, so the bake emits a compact
// `loff` key in text-body units (3.51 mm = 1 em; see appendTextProps) and we map it
// to a literal offset. Keys are the catalogue's LocalOffset set / 3.51; rare non-
// body-multiple offsets fall through to no shift. This COMBINES with TEXT_ANCHOR —
// the S-52 model places text via alignment AND offset (the oracle's own client drops
// the offset; we apply it for spec-compliant placement).
const TEXT_OFFSET = .{
    "match",                   .{ "coalesce", .{ "get", "loff" }, "0,0" },
    "1,1",                     .{ "literal", .{ 1, 1 } },
    "0,1",                     .{ "literal", .{ 0, 1 } },
    "-1,1",                    .{ "literal", .{ -1, 1 } },
    "1,0",                     .{ "literal", .{ 1, 0 } },
    "2,0",                     .{ "literal", .{ 2, 0 } },
    "1,-1",                    .{ "literal", .{ 1, -1 } },
    "0,-1",                    .{ "literal", .{ 0, -1 } },
    "-1,-2",                   .{ "literal", .{ -1, -2 } },
    "0,2",                     .{ "literal", .{ 0, 2 } },
    "2,1",                     .{ "literal", .{ 2, 1 } },
    "-2,0",                    .{ "literal", .{ -2, 0 } },
    "-1,2",                    .{ "literal", .{ -1, 2 } },
    "3,-1",                    .{ "literal", .{ 3, -1 } },
    .{ "literal", .{ 0, 0 } },
};

pub const StyleOpts = struct {
    scheme: []const u8, // "day" | "dusk" | "night"
    colortables_json: []const u8,
    source_tiles: ?[]const u8 = null, // tiles template; else pmtiles_url
    pmtiles_url: []const u8 = "pmtiles://tiles/chart.pmtiles",
    // Chart-source tile encoding hint: "mlt" switches maplibre-gl (>=5.12) to its
    // native MLT decoder via the vector-source `encoding` option. null/"mvt" =
    // MVT (the MapLibre default; nothing is emitted, keeping MVT styles
    // byte-identical). No transcode anywhere — the wire format IS the bake format.
    encoding: ?[]const u8 = null,
    sprite: ?[]const u8 = null, // sprite base; enables symbol/pattern layers
    glyphs: ?[]const u8 = null, // glyphs template; enables text/labels
    minzoom: u32 = 9,
    maxzoom: u32 = 16,
    // SCAMIN manifest: the distinct SCAMIN denominators present (the PMTiles metadata
    // "scamin" array). Each becomes a per-value bucket layer with a native minzoom of
    // scaminDisplayZoom(value, scamin_lat). Empty -> the *_scamin layers fall back to a
    // single ungated layer (features still render; no scale gating without the manifest).
    scamin: []const u32 = &.{},
    // Representative latitude for the bucket minzooms (the archive's center). SCAMIN
    // cutoffs are latitude-dependent (cos lat); a baked style fixes them at one lat.
    scamin_lat: f64 = 0,
    // S-52 mariner display options. null = a TEMPLATE (no client display filters
    // baked in — the bundle + tile57_style_template path; the client gates live).
    // Non-null = the full style with the mariner's display filters + depth shading /
    // sounding-split / danger-swap baked in (the C-ABI tile57_build_style path).
    // Colour + layout always resolve through the chartstyle builders (default mariner
    // when null), so there is ONE style builder — chartstyle.buildStyle is retired.
    mariner: ?chartstyle.MarinerSettings = null,
    enabled_bands: ?[]const i32 = null, // mariner NOAA-band filter (null = all bands)
    now_unix: i64 = 0, // host wall-clock (epoch s) for the date filter's "today"
    // §2 ?ignoreScamin host debug toggle: when true, disable SCAMIN scale-gating
    // entirely — every *_scamin layer collapses to a single plain (ungated) layer,
    // so all features show in-band regardless of their SCAMIN denominator (and
    // regardless of whether a manifest is present). Default off = normal gating.
    ignore_scamin: bool = false,
    // §4 physical-scale multiplier applied to icon-size / line-width / text-size
    // (the host's _featureSizeScale from its calibrated CSS-pixel pitch). 1.0 = the
    // catalogue sizes verbatim (byte-identical output); other values wrap each size
    // expression in ["*", size_scale, expr].
    size_scale: f64 = 1.0,
    // scamin-layers.md: gate SCAMIN with a live client-updated filter literal instead
    // of per-value bucket layers. When true, each *_scamin source-layer emits ONE layer
    // (no #sm buckets, no minzoom) carrying the clause
    //   [">=", ["coalesce", ["get","scamin"], 1e12], scamin_cur_denom]
    // — "show a feature when the current display scale is at least as fine as its SCAMIN".
    // The live client recomputes the literal and setFilter's it only at the ~19 discrete
    // SCAMIN boundary crossings (fractional-exact, ~1 layer/type instead of ~19). Overrides
    // the manifest bucket path (scamin/scamin_lat unused). Default off = per-value buckets.
    scamin_filter_gate: bool = false,
    // The SCAMIN denominator baked into the filter-gate clause. The live client overwrites
    // it via setFilter; this is only the standalone default (0 = show all, client-owned).
    scamin_cur_denom: f64 = 0,
};

// Precomputed, mariner-aware style expressions shared by every layer of one
// styleJson call — the single style builder. Colours / depth shading / icon images
// resolve ONCE through the chartstyle builders (so chartstyle.buildStyle's patch pass
// is retired); `common`/`text_group` are the S-52 display filters, empty/null in
// template mode (opts.mariner == null) so a template renders without baked gating.
const SCtx = struct {
    fill_color: std.json.Value, // areas fill (SEABED01 depth shading)
    line_color: std.json.Value,
    text_color: std.json.Value,
    halo: std.json.Value,
    contour_color: std.json.Value,
    sound_img: std.json.Value, // soundings icon-image (SNDFRM04 safety split)
    point_img: std.json.Value, // point icon-image (OBSTRN/WRECKS danger swap + ctr:)
    contour_field: std.json.Value, // DEPCNT label text-field (SAFCON01 unit)
    common: []const std.json.Value, // filters AND-ed onto every chart layer ([] = template)
    text_group: ?std.json.Value, // extra filter for text layers (null = template)
    size_scale: f64, // §4 physical-scale multiplier for icon/line/text sizes (1.0 = verbatim)
    smax: SmaxGate, // band-handoff gate AND-ed onto every chart layer (see SmaxGate)
    // The overscale clauses (writeOsclClause) reuse `smax` as their gate value —
    // same modes, same injected DENOM literal, same show-all placeholder mapping.
    show_overscale: bool, // S-52 §10.1.10 mariner toggle -> the overscale layer's visibility
};

// Band-handoff (smax) gate: a coarser-band feature carried down past a finer
// band's coverage (bake_enc carryGate) is tagged with its handoff denominator
// `smax` and must hide once the display is FINER than 1:smax — untagged features
// always pass (coalesce -> 0 < any denominator). The gate rides EVERY chart layer
// (base + _scamin + soundings): carried copies of ungated features (fills, plain
// symbols) land in the base layers too.
const SmaxGate = union(enum) {
    off, // ignore_scamin: no scale gating at all (§2 debug toggle)
    // scamin-layers.md filter-gate: the DENOM literal is the SAME injected value
    // as the scamin clause; the live client rewrites both at ladder crossings.
    denom: f64,
    // Native/bucket + zoom-gate paths: DENOM computed from ["zoom"] — K / 2^zoom,
    // K = the world denominator at z0 (physical at the style's fixed latitude for
    // the bucket path, the OGC DENOM_Z0 for the no-manifest fallback).
    zoom_k: f64,
};

// The smax filter clause. The filter-gate form is EXACTLY
//   ["<", ["coalesce", ["get","smax"], 0], DENOM]
// — the live client pattern-matches this shape to rewrite DENOM alongside the
// scamin clause, so keep the two in lockstep (band-handoff contract).
fn writeSmaxClause(js: *Stringify, gate: SmaxGate) !void {
    switch (gate) {
        .off => {},
        .denom => |d| try js.write(.{ "<", .{ "coalesce", .{ "get", "smax" }, 0 }, d }),
        .zoom_k => |k| try js.write(.{ "<", .{ "coalesce", .{ "get", "smax" }, 0 }, .{ "/", k, .{ "^", 2, .{"zoom"} } } }),
    }
}

// The overscale (oscl) clause — S-52 §10.1.10 (specs/overscale.md). The
// filter-gate form is EXACTLY
//   [">", ["coalesce", ["get","oscl"], 0], DENOM]
// ("the display is FINER than the cell's quantized compilation scale"), or its
// ["!", …] negation for the at-scale fill pass drawn ABOVE the hatch. It rides
// the SAME gate value (and injected DENOM literal) as the smax clause — the live
// client pattern-matches the inner shape to rewrite DENOM alongside scamin/smax,
// so keep the three in lockstep (overscale contract). The shared boot/diff
// placeholder (1e12) reads as hide-the-hatch / all-fills-at-scale — today's
// rendering — until the client injects the live denominator.
fn writeOsclClause(js: *Stringify, gate: SmaxGate, negate: bool) !void {
    switch (gate) {
        .off => {},
        .denom => |d| if (negate)
            try js.write(.{ "!", .{ ">", .{ "coalesce", .{ "get", "oscl" }, 0 }, d } })
        else
            try js.write(.{ ">", .{ "coalesce", .{ "get", "oscl" }, 0 }, d }),
        .zoom_k => |k| if (negate)
            try js.write(.{ "!", .{ ">", .{ "coalesce", .{ "get", "oscl" }, 0 }, .{ "/", k, .{ "^", 2, .{"zoom"} } } } })
        else
            try js.write(.{ ">", .{ "coalesce", .{ "get", "oscl" }, 0 }, .{ "/", k, .{ "^", 2, .{"zoom"} } } }),
    }
}

// ---- layer building blocks ----------------------------------------------

// Write a size expression scaled by the physical-scale multiplier (host §4). At the
// default scale (1.0) the expression is written verbatim — byte-identical to the
// pre-size_scale output (so the bundle's served style.json never drifts); otherwise
// it is wrapped in `["*", scale, expr]`. Applies to icon-size / line-width / text-size.
fn writeScaled(js: *Stringify, expr: anytype, scale: f64) !void {
    if (scale == 1.0) {
        try js.write(expr);
    } else {
        try js.write(.{ "*", scale, expr });
    }
}

fn linePaint(js: *Stringify, line_color: std.json.Value, dash: ?[2]i64, scale: f64) !void {
    try js.beginObject();
    try js.objectField("line-color");
    try js.write(line_color);
    try js.objectField("line-width");
    try writeScaled(js, .{ "coalesce", .{ "get", "width_px" }, 1 }, scale);
    if (dash) |d| {
        try js.objectField("line-dasharray");
        try js.write(d);
    }
    try js.endObject();
}

fn layerHead(js: *Stringify, id: []const u8, kind: []const u8, source_layer: []const u8) !void {
    try js.objectField("id");
    try js.write(id);
    try js.objectField("type");
    try js.write(kind);
    try js.objectField("source");
    try js.write("chart");
    try js.objectField("source-layer");
    try js.write(source_layer);
}

// One SCAMIN bucket layer's gating: a per-value layer (`sm`) gets a native fractional
// `minzoom` (scaminDisplayZoom) + a `["==",scamin,v]` filter; the catch-all `#no` layer
// (`no_lows` set) takes features WITHOUT scamin plus the folded below-floor values. The
// default (`.{}`) is the unbucketed layer — no clause, no minzoom, no suffix — so a
// non-SCAMIN layer renders byte-identically to before. Replaces the old per-feature
// `zoom`-filter (SCAMIN_GATE) with host-canonical native minzoom buckets (§2).
const Bucket = struct {
    sm: ?u32 = null, // per-value bucket: filter scamin == sm
    no_lows: ?[]const u32 = null, // #no bucket: !has(scamin) OR scamin in these folded low values
    zoom_gate: bool = false, // no-manifest fallback: AND the per-feature SCAMIN_GATE zoom filter
    filter_gate: bool = false, // scamin-layers.md: the live client-driven SCAMIN clause (no minzoom, no suffix)
    cur_denom: f64 = 0, // filter_gate: the current-display-scale denominator literal (client-overwritten)
    minzoom: ?f64 = null,
    suffix: []const u8 = "", // id suffix: "#sm<v>" / "#no" / "" (plain)
    // Overscale (oscl) clause role (S-52 §10.1.10, specs/overscale.md):
    //   .none — no oscl clause (every layer outside the overscale sandwich).
    //   .overscaled — [">", coalesce(oscl,0), DENOM]: this cell's data is displayed
    //     FINER than its compilation scale (the fills under the hatch + the hatch).
    //   .at_scale — the ["!", …] negation: at-scale fills, drawn ABOVE the hatch so
    //     finer opaque data occludes a coarser cell's hatch.
    oscl: enum { none, overscaled, at_scale } = .none,
};

// coalesce fallback for a feature with no `scamin`: a denominator larger than any real
// display scale, so `scamin >= curDenom` is always true (missing SCAMIN => always shown).
const SCAMIN_COALESCE_MAX = 1000000000000; // 1e12

// The scamin filter clause for a bucket: `["==",["get","scamin"],v]` (per-value) or
// `["any", ["!",["has","scamin"]], ["in",["get","scamin"],["literal",[lows…]]]]` (#no).
fn writeScaminClause(js: *Stringify, bkt: Bucket) !void {
    if (bkt.filter_gate) {
        // scamin-layers.md: [">=", ["coalesce", ["get","scamin"], 1e12], curDenom].
        // The live client rewrites curDenom via setFilter at the discrete SCAMIN boundary
        // crossings; the emitted literal is the standalone default (0 => show all).
        try js.beginArray();
        try js.write(">=");
        try js.beginArray();
        try js.write("coalesce");
        try js.write(.{ "get", "scamin" });
        try js.write(SCAMIN_COALESCE_MAX);
        try js.endArray();
        try js.write(bkt.cur_denom);
        try js.endArray();
        return;
    }
    if (bkt.zoom_gate) {
        try js.write(SCAMIN_GATE);
        return;
    }
    if (bkt.sm) |v| {
        try js.beginArray();
        try js.write("==");
        try js.write(.{ "get", "scamin" });
        try js.write(v);
        try js.endArray();
        return;
    }
    try js.beginArray();
    try js.write("any");
    try js.write(.{ "!", .{ "has", "scamin" } });
    try js.beginArray();
    try js.write("in");
    try js.write(.{ "get", "scamin" });
    try js.beginArray();
    try js.write("literal");
    try js.beginArray();
    if (bkt.no_lows) |lows| for (lows) |v| try js.write(v);
    try js.endArray();
    try js.endArray();
    try js.endArray();
    try js.endArray();
}

// Write a layer's `filter` and native `minzoom`. The filter ANDs together (in order):
// the `base` predicate (when has_base), the bucket's SCAMIN clause (per-value / #no /
// zoom-gate), the band-handoff smax clause (s.smax), the shared mariner `common`
// filters (s.common), and a layer-specific `extra` (the text-group filter on text
// layers). All optional; a single part is written bare (no "all" wrapper) so a
// template layer is byte-identical to the pre-mariner output. `has_base=false` for
// layers with no base predicate (fills/patterns/complex/soundings).
fn applyBucket(js: *Stringify, base: anytype, has_base: bool, bkt: Bucket, s: *const SCtx, drop_smax: bool, extra: ?std.json.Value) !void {
    const has_clause = bkt.sm != null or bkt.no_lows != null or bkt.zoom_gate or bkt.filter_gate;
    // scamin-standalone.md §0/§3: the SCAMIN POINT/TEXT/LINE layers (point_symbols_scamin,
    // text-scamin, the scamin line variants) are band-INDEPENDENT — their whole display
    // lifecycle is the scamin gate, so the band-handoff `smax` carry-down clause does NOT
    // apply (a SCAMIN feature "should just exist regardless of band"). `drop_smax` is true
    // only from those layer functions; it takes effect solely on the _scamin variant (the
    // one carrying a scamin clause). smax STAYS on areas/patterns (§46 "area/line only" —
    // fills need scale-appropriate generalization + occlusion), on SOUNDINGS ("stay
    // as-is"), and on the carried plain (non-scamin) points/lines (has_clause=false).
    const has_smax = s.smax != .off and !(has_clause and drop_smax);
    const has_oscl = bkt.oscl != .none and s.smax != .off; // oscl rides the smax gate value
    var n: usize = s.common.len;
    if (has_base) n += 1;
    if (has_clause) n += 1;
    if (has_smax) n += 1;
    if (has_oscl) n += 1;
    if (extra != null) n += 1;
    if (n > 0) {
        try js.objectField("filter");
        const wrap = n > 1;
        if (wrap) {
            try js.beginArray();
            try js.write("all");
        }
        if (has_base) try js.write(base);
        if (has_clause) try writeScaminClause(js, bkt);
        if (has_smax) try writeSmaxClause(js, s.smax);
        if (has_oscl) try writeOsclClause(js, s.smax, bkt.oscl == .at_scale);
        for (s.common) |c| try js.write(c);
        if (extra) |e| try js.write(e);
        if (wrap) try js.endArray();
    }
    if (bkt.minzoom) |mz| {
        try js.objectField("minzoom");
        try js.write(mz);
    }
}

fn lineLayer(js: *Stringify, s: *const SCtx, sl: []const u8, name: []const u8, filt: anytype, dash: ?[2]i64, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    const id = try std.fmt.bufPrint(&buf, "{s}-{s}{s}", .{ sl, name, bkt.suffix });
    try js.beginObject();
    try layerHead(js, id, "line", sl);
    try applyBucket(js, filt, true, bkt, s, true, null); // line: scamin line variants band-independent
    try js.objectField("paint");
    try linePaint(js, s.line_color, dash, s.size_scale);
    try js.endObject();
}

// solid / dashed / dotted line layers for one source-layer (one SCAMIN bucket).
fn lineLayers(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    try lineLayer(js, s, sl, "solid", FILT_SOLID, null, bkt);
    try lineLayer(js, s, sl, "dashed", FILT_DASHED, .{ 4, 3 }, bkt);
    try lineLayer(js, s, sl, "dotted", FILT_DOTTED, .{ 1, 2 }, bkt);
}

fn pointLayout(js: *Stringify, alignment: []const u8, icon: std.json.Value, scale: f64) !void {
    try js.beginObject();
    try js.objectField("icon-image");
    try js.write(icon);
    try js.objectField("icon-size");
    try writeScaled(js, ICON_SIZE, scale);
    try js.objectField("icon-rotate");
    try js.write(.{ "coalesce", .{ "get", "rotation_deg" }, 0 });
    try js.objectField("icon-allow-overlap");
    try js.write(true);
    try js.objectField("icon-ignore-placement");
    try js.write(true);
    // Draw point symbols in S-101 DrawingPriority order (the `draw_prio` tile property,
    // higher = on top), not raw tile/source order — so e.g. a light (DrawingPriority 24)
    // draws over an obstruction (12). symbol-sort-key sorts ascending (lower drawn first
    // = underneath), so the key IS draw_prio. z-order "auto" makes the sort-key take
    // effect (was "source", which ignored it). Mirrors fill-sort-key on the fill layers.
    // NOTE: this orders WITHIN one layer only; LIGHTS get their own top layer set (see
    // styleJson) so they beat same-priority bridges that sit in a different scamin bucket.
    try js.objectField("symbol-sort-key");
    try js.write(.{ "coalesce", .{ "get", "draw_prio" }, 0 });
    try js.objectField("symbol-z-order");
    try js.write("auto");
    try js.objectField("icon-rotation-alignment");
    try js.write(alignment);
    try js.endObject();
}

// The S-57 danger point classes whose symbol must stay visible OVER its own depth
// sounding: an obstruction / wreck / rock marker is the hazard, and a recreational
// chartplotter keeps it on top of the depth number (a deliberate deviation from the
// strict S-52 DrawingPriority, which is 12 for these vs 18 for soundings — so by the
// book the sounding would cover them).
const DANGER_CLASSES = .{ "OBSTRN", "WRECKS", "UWTROC" };

// Which classes a point-symbol layer carries, so the style can stack three passes in
// the right z-order: `base` (everything else) UNDER soundings; `dangers_only` (the
// hazard markers) OVER soundings; `lights_only` (the paramount navaid) over all. LIGHTS
// and dangers need their own passes because a light/danger and a same-or-higher-priority
// neighbour usually sit in different SCAMIN buckets (separate MapLibre layers painted in
// emit order), so an in-layer sort-key can't reorder across them.
const PointMode = enum { base, dangers_only, lights_only };

// AND the per-alignment rot_north test with the mode's class clause, then emit the
// bucket filter. rot_north_eq / mode are comptime so each switch arm passes a concrete
// tuple type to the generic applyBucket.
fn applyPointBucket(js: *Stringify, s: *const SCtx, bkt: Bucket, comptime rot_north_eq: bool, comptime mode: PointMode) !void {
    const rot = if (rot_north_eq)
        .{ "==", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }
    else
        .{ "!=", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 };
    const in_danger = .{ "in", .{ "get", "class" }, .{ "literal", DANGER_CLASSES } };
    switch (mode) {
        // base = not a light AND not a danger (those ride their own over-soundings passes).
        .base => try applyBucket(js, .{ "all", rot, .{ "!=", .{ "get", "class" }, "LIGHTS" }, .{ "!", in_danger } }, true, bkt, s, true, null),
        .dangers_only => try applyBucket(js, .{ "all", rot, in_danger }, true, bkt, s, true, null),
        .lights_only => try applyBucket(js, .{ "all", rot, .{ "==", .{ "get", "class" }, "LIGHTS" } }, true, bkt, s, true, null),
    }
}

fn pointSymbolLayers(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket, comptime mode: PointMode) !void {
    // Infix the over-soundings passes' layer ids so they stay distinct from the base set.
    const tag = switch (mode) {
        .base => "",
        .dangers_only => "-dgr",
        .lights_only => "-lt",
    };
    var buf: [96]u8 = undefined;
    // viewport-aligned (screen-up)
    const vid = try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ sl, tag, bkt.suffix });
    try js.beginObject();
    try layerHead(js, vid, "symbol", sl);
    try applyPointBucket(js, s, bkt, false, mode);
    try js.objectField("layout");
    try pointLayout(js, "viewport", s.point_img, s.size_scale);
    try js.endObject();
    // map-aligned (true-north)
    var nbuf: [96]u8 = undefined;
    const nid = try std.fmt.bufPrint(&nbuf, "{s}{s}-north{s}", .{ sl, tag, bkt.suffix });
    try js.beginObject();
    try layerHead(js, nid, "symbol", sl);
    try applyPointBucket(js, s, bkt, true, mode);
    try js.objectField("layout");
    try pointLayout(js, "map", s.point_img, s.size_scale);
    try js.endObject();
}

fn textLayers(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    const sfx = if (std.mem.eql(u8, sl, "text")) "" else "-scamin";

    // text<sfx> — general collidable labels. Emitted BELOW light-text: MapLibre
    // gives collision precedence to UPPER symbol layers, and S-52 wants the
    // (high drawing-priority) light characteristics to win placement over
    // names — the within-layer sort key already ranks tgrp 23 above names,
    // but that only applies inside one layer.
    var buf2: [96]u8 = undefined;
    const tid = try std.fmt.bufPrint(&buf2, "text{s}{s}", .{ sfx, bkt.suffix });
    try js.beginObject();
    try layerHead(js, tid, "symbol", sl);
    try applyBucket(js, .{ "!=", .{ "get", "class" }, "LIGHTS" }, true, bkt, s, true, s.text_group); // text-scamin band-independent
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("text-field");
    try js.write(.{ "coalesce", .{ "get", "text" }, "" });
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try writeScaled(js, .{ "coalesce", .{ "get", "font_size_px" }, 11 }, s.size_scale);
    try js.objectField("text-anchor");
    try js.write(TEXT_ANCHOR);
    try js.objectField("text-offset");
    try js.write(TEXT_OFFSET);
    try js.objectField("symbol-sort-key");
    try js.write(TEXT_SORT_KEY);
    try js.objectField("text-allow-overlap");
    try js.write(false);
    try js.objectField("text-optional");
    try js.write(true);
    try js.endObject();
    try textPaint(js, s.text_color, s.halo, 0); // S-52: solid black, no halo
    try js.endObject();

    // light-text<sfx> — LIGHTS characteristics, top-anchored. Above `text`
    // so light descriptions take collision precedence over names.
    const lid = try std.fmt.bufPrint(&buf, "light-text{s}{s}", .{ sfx, bkt.suffix });
    try js.beginObject();
    try layerHead(js, lid, "symbol", sl);
    try applyBucket(js, .{ "==", .{ "get", "class" }, "LIGHTS" }, true, bkt, s, true, s.text_group); // light-text-scamin band-independent
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("text-field");
    try js.write(.{ "coalesce", .{ "get", "text" }, "" });
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try writeScaled(js, .{ "coalesce", .{ "get", "font_size_px" }, 10 }, s.size_scale);
    // The rule's OWN placement: light descriptions carry halign=left,
    // valign=middle, loff="2,0" — 7.02 mm (two text bodies) RIGHT of the
    // light, clear of the flare (LightAllAround.lua LocalOffset:7.02,0). The
    // old hardcoded top/[0,0.4] dropped the label onto the flare. MapLibre
    // offsets are ems OF THE TEXT SIZE (12px here), not bodies (10px), so
    // "2,0" em would overshoot the spec by 20% — emit the mm-exact 1.66em
    // for the characteristics; a light's NAME keeps the generic map.
    try js.objectField("text-anchor");
    try js.write(TEXT_ANCHOR);
    try js.objectField("text-offset");
    try js.write(.{ "match", .{ "coalesce", .{ "get", "loff" }, "0,0" }, "2,0", .{ "literal", .{ 1.66, 0 } }, TEXT_OFFSET });
    try js.objectField("symbol-sort-key");
    try js.write(.{ "-", 0, .{ "coalesce", .{ "get", "font_size_px" }, 10 } });
    try js.objectField("text-allow-overlap");
    try js.write(false);
    try js.objectField("text-optional");
    try js.write(true);
    try js.endObject();
    try textPaint(js, s.text_color, s.halo, 0); // S-52: solid black, no halo
    try js.endObject();
}

fn textPaint(js: *Stringify, text_color: std.json.Value, halo: std.json.Value, halo_width: f64) !void {
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("text-color");
    try js.write(text_color);
    // S-52/S-101 text is solid colour with FontBackgroundColor transparent (no halo) —
    // PortrayalModel.lua:363-365. A halo is a non-spec legibility addition; omit it when
    // width <= 0 so navaid/label text matches the official chart's solid look.
    if (halo_width > 0) {
        try js.objectField("text-halo-color");
        try js.write(halo);
        try js.objectField("text-halo-width");
        try js.write(halo_width);
        try js.objectField("text-halo-blur");
        try js.write(0.5);
    }
    try js.endObject();
}

// One area-fill layer for a source-layer + SCAMIN bucket.
fn fillLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "fill-{s}{s}", .{ sl, bkt.suffix }), "fill", sl);
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("fill-sort-key");
    try js.write(FILL_SORT);
    try js.endObject();
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("fill-color");
    try js.write(s.fill_color);
    try js.objectField("fill-antialias");
    try js.write(true);
    try js.endObject();
    try applyBucket(js, .{}, false, bkt, s, false, null); // area fills stay band-quilted (keep smax)
    try js.endObject();
}

// The S-52 §10.1.10 overscale hatch is NOT a generic area pattern: it rides its
// own sandwiched layer (overscaleLayer) with the oscl gate, so the generic
// pattern layers must exclude it or it would paint ungated above everything.
const FILT_OVERSC = .{ "==", .{ "get", "pattern_name" }, "OVERSC01" };
const FILT_NOT_OVERSC = .{ "!=", .{ "get", "pattern_name" }, "OVERSC01" };

// One area fill-pattern layer (sprite required) for a source-layer + SCAMIN bucket.
fn patternLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "fillpat-{s}{s}", .{ sl, bkt.suffix }), "fill", sl);
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("fill-pattern");
    try js.write(.{ "concat", "pat:", .{ "coalesce", .{ "get", "pattern_name" }, "" } });
    try js.endObject();
    try applyBucket(js, FILT_NOT_OVERSC, true, bkt, s, false, null); // area patterns stay band-quilted
    try js.endObject();
}

// The AP(OVERSC01) overscale-indication layer (S-52 §10.1.10, specs/overscale.md):
// every contributing cell's M_COVR coverage polygon (baked into `area_patterns`
// as pattern OVERSC01, tagged `oscl`), shown only while the display is FINER than
// the cell's quantized compilation scale (the oscl clause). Sandwiched between
// the overscaled and at-scale fill passes (styleJson §2), so a finer cell's
// opaque fills occlude a coarser cell's hatch — the hatch survives only on
// coarse-only patches. The showOverscale mariner toggle drives layout.visibility
// alone (layer set unchanged -> a one-op style diff).
fn overscaleLayer(js: *Stringify, s: *const SCtx) !void {
    try js.beginObject();
    try layerHead(js, "overscale", "fill", "area_patterns");
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("visibility");
    try js.write(if (s.show_overscale) "visible" else "none");
    try js.endObject();
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("fill-pattern");
    try js.write("pat:OVERSC01");
    try js.endObject();
    try applyBucket(js, FILT_OVERSC, true, .{ .oscl = .overscaled }, s, false, null); // overscale hatch rides the smax/oscl gate
    try js.endObject();
}

// One complex (symbolised) line layer for a source-layer + SCAMIN bucket.
fn complexLineLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "complex-{s}{s}", .{ sl, bkt.suffix }), "line", sl);
    try js.objectField("paint");
    try linePaint(js, s.line_color, null, s.size_scale);
    try applyBucket(js, .{}, false, bkt, s, true, null); // complex (symbolised) scamin lines band-independent
    try js.endObject();
}

// One DEPCNT contour value-label layer (glyphs required) for a source-layer + bucket.
fn contourLabelLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "contour-labels-{s}{s}", .{ sl, bkt.suffix }), "symbol", sl);
    try applyBucket(js, .{ "has", "valdco" }, true, bkt, s, true, null); // contour value labels (scamin text) band-independent
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("symbol-placement");
    try js.write("line-center");
    try js.objectField("text-field");
    try js.write(s.contour_field);
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try writeScaled(js, 10, s.size_scale);
    try js.objectField("text-max-angle");
    try js.write(30);
    try js.objectField("text-allow-overlap");
    try js.write(false);
    try js.objectField("text-optional");
    try js.write(true);
    try js.endObject();
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("text-color");
    try js.write(s.contour_color);
    try js.objectField("text-halo-color");
    try js.write(s.halo);
    try js.objectField("text-halo-width");
    try js.write(1.2);
    try js.objectField("text-halo-blur");
    try js.write(0.5);
    try js.endObject();
    try js.endObject();
}

// The soundings source-layer splits into two style layers by feature class.
// Spot soundings (SOUNDG) are collision-culled (icon-allow-overlap false): the
// dense spot field thins under MapLibre placement, a legibility trade. A DANGER
// depth — a wreck/obstruction/rock sounding the baker routed here — is PART of
// its S-52 symbol (WRECKS05/OBSTRN07 draw the digits with the DANGER01/02 mark),
// so it is NEVER culled and rides its own always-on layer. With one shared
// culled layer, a dense wreck field dropped most danger depths (observed: 33 of
// 140 wreck digits surviving one Jamaica Bay creek view) and the bare danger
// ovals read as "unknown hazard".
const FILT_SPOT_SND = .{ "==", .{ "coalesce", .{ "get", "class" }, "SOUNDG" }, "SOUNDG" };
const FILT_DANGER_SND = .{ "!=", .{ "coalesce", .{ "get", "class" }, "SOUNDG" }, "SOUNDG" };

// The spot-soundings symbol layer (sprite required) for a SCAMIN bucket.
fn soundingsLayer(js: *Stringify, s: *const SCtx, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "soundings{s}", .{bkt.suffix}), "symbol", "soundings");
    try applyBucket(js, FILT_SPOT_SND, true, bkt, s, false, null); // soundings stay as-is (band-quilted, keep smax)
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("icon-image");
    try js.write(s.sound_img);
    try js.objectField("icon-size");
    try writeScaled(js, ICON_SIZE, s.size_scale);
    try js.objectField("icon-allow-overlap");
    try js.write(false);
    try js.endObject();
    try js.endObject();
}

// The danger-depths symbol layer (see the class split above): same glyph
// expression as spot soundings, but never collision-culled.
fn dangerSoundingsLayer(js: *Stringify, s: *const SCtx, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "danger_soundings{s}", .{bkt.suffix}), "symbol", "soundings");
    try applyBucket(js, FILT_DANGER_SND, true, bkt, s, false, null); // danger soundings stay as-is (band-quilted)
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("icon-image");
    try js.write(s.sound_img);
    try js.objectField("icon-size");
    try writeScaled(js, ICON_SIZE, s.size_scale);
    try js.objectField("icon-allow-overlap");
    try js.write(true);
    try js.objectField("icon-ignore-placement");
    try js.write(true);
    try js.endObject();
    try js.endObject();
}

/// Emit a MapLibre style.json for `opts.scheme`. Returns allocator-owned bytes.
pub fn styleJson(alloc: std.mem.Allocator, opts: StyleOpts) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, opts.colortables_json, .{}) catch
        return error.BadColortables;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadColortables,
    };
    const palette = switch (root.get(opts.scheme) orelse return error.UnknownScheme) {
        .object => |o| o,
        else => return error.BadColortables,
    };
    const sprite_on = opts.sprite != null;
    // Text + contour-label layers need an SDF glyph source; emit them only when
    // glyphs are available, so a sprite-only bundle still renders (a missing
    // glyph source otherwise aborts the whole style load in MapLibre).
    const glyphs_on = opts.glyphs != null;
    const sea = if (palette.get("DEPDW")) |v| v.string else "#93aebb";

    // SCAMIN buckets (host §2): split the manifest into below-source-floor values
    // (folded into the catch-all #no bucket — they show from the floor anyway) and
    // above-floor values (one #sm<v> bucket each, native minzoom = scaminDisplayZoom
    // at the representative lat). `all_buckets` drives the all-SCAMIN *_scamin layers;
    // `snd_buckets` drives the mixed `soundings` layer (always a #no for its bare
    // non-SCAMIN soundings). An empty manifest -> a single plain (ungated) layer.
    var barena = std.heap.ArenaAllocator.init(alloc);
    defer barena.deinit();
    const ba = barena.allocator();
    const floor: f64 = @floatFromInt(opts.minzoom);
    var lows = std.ArrayList(u32).empty;
    var his = std.ArrayList(Bucket).empty;
    // The per-value bucket split is only needed for the manifest bucket path; skip it
    // for ignore_scamin (single plain bucket) and filter_gate (single live-clause layer).
    if (!opts.ignore_scamin and !opts.scamin_filter_gate) for (opts.scamin) |v| {
        const mz = scaminDisplayZoom(@floatFromInt(v), opts.scamin_lat);
        if (mz <= floor + 1e-6) {
            try lows.append(ba, v);
        } else {
            try his.append(ba, .{ .sm = v, .minzoom = mz, .suffix = try std.fmt.allocPrint(ba, "#sm{d}", .{v}) });
        }
    };
    const low_slice: []const u32 = lows.items;
    var allb = std.ArrayList(Bucket).empty;
    var sndb = std.ArrayList(Bucket).empty;
    if (opts.ignore_scamin) {
        // §2 ?ignoreScamin: no scale gating — every *_scamin layer is a single plain
        // (ungated) bucket, so all features show in-band regardless of SCAMIN (this
        // overrides both the per-value buckets and the no-manifest zoom-gate fallback).
        try allb.append(ba, .{});
        try sndb.append(ba, .{});
    } else if (opts.scamin_filter_gate) {
        // scamin-layers.md: ONE layer per *_scamin render-type carrying the live
        // client-driven SCAMIN clause — no per-value buckets, no minzoom. Collapses
        // ~19×types bucket layers to ~1×type.
        try allb.append(ba, .{ .filter_gate = true, .cur_denom = opts.scamin_cur_denom });
        try sndb.append(ba, .{ .filter_gate = true, .cur_denom = opts.scamin_cur_denom });
    } else if (opts.scamin.len == 0) {
        // No manifest -> the per-feature zoom-filter fallback (still gates by value,
        // integer-zoom snap) on every SCAMIN-bearing layer, incl. soundings.
        try allb.append(ba, .{ .zoom_gate = true });
        try sndb.append(ba, .{ .zoom_gate = true });
    } else {
        if (low_slice.len > 0) try allb.append(ba, .{ .no_lows = low_slice, .suffix = "#no" });
        try allb.appendSlice(ba, his.items);
        try sndb.append(ba, .{ .no_lows = low_slice, .suffix = "#no" });
        try sndb.appendSlice(ba, his.items);
    }
    const all_buckets: []const Bucket = allb.items;
    const snd_buckets: []const Bucket = sndb.items;

    // The single style builder: resolve every mariner-aware colour / icon / display
    // filter ONCE through the chartstyle builders (retiring chartstyle.buildStyle's
    // template-patch pass). scheme always comes from opts.scheme (the bundle emits one
    // style per scheme); a null opts.mariner is a TEMPLATE — default mariner for the
    // colour/layout exprs, but NO display filters baked in (the client gates live).
    const scheme_e: chartstyle.Scheme = if (std.mem.eql(u8, opts.scheme, "night"))
        .night
    else if (std.mem.eql(u8, opts.scheme, "dusk")) .dusk else .day;
    var m: chartstyle.MarinerSettings = opts.mariner orelse .{};
    m.scheme = scheme_e;
    const filters_on = opts.mariner != null;
    const b = chartstyle.B{ .a = ba };
    const s = SCtx{
        .fill_color = try chartstyle.areasFillColor(b, &palette, &m),
        .line_color = try chartstyle.lineColor(b, &palette),
        .text_color = try chartstyle.textColor(b, m.scheme, &palette),
        .halo = chartstyle.textHaloColor(b, m.scheme),
        .contour_color = try chartstyle.contourLabelColor(b, m.scheme, &palette),
        .sound_img = try chartstyle.soundingsIconImage(b, &m),
        .point_img = try chartstyle.pointSymbolImage(b, &m),
        .contour_field = try chartstyle.contourLabelField(b, &m),
        .common = if (filters_on) try chartstyle.commonChartFilters(ba, &m, opts.enabled_bands, opts.now_unix) else &.{},
        .text_group = if (filters_on) try chartstyle.textGroupFilter(b, &m) else null,
        .size_scale = opts.size_scale,
        // Band-handoff gate mode follows the SCAMIN gating mode: the filter-gate
        // literal when the live client drives it (same injected DENOM), a
        // zoom-derived denominator otherwise (physical at the manifest latitude
        // for the bucket path, OGC z0 for the no-manifest fallback), and nothing
        // under ?ignoreScamin (the debug toggle shows everything).
        .smax = if (opts.ignore_scamin)
            .off
        else if (opts.scamin_filter_gate)
            // The boot/diff placeholder denominator is 0 — show-all for the
            // scamin clause (scamin >= 0) but show-NOTHING for this one
            // (smax < 0 fails every feature), which blanked the chart between
            // a style diff landing and the client's live injection. Map the
            // placeholder to this clause's own show-all literal; the client
            // rewrites both clauses to the live denominator regardless.
            .{ .denom = if (opts.scamin_cur_denom == 0) 1e12 else opts.scamin_cur_denom }
        else if (opts.scamin.len > 0)
            .{ .zoom_k = M_PER_PX_Z0 * @cos(opts.scamin_lat * std.math.pi / 180.0) / (DEFAULT_PX_PITCH_MM / 1000.0) }
        else
            .{ .zoom_k = DENOM_Z0 },
        .show_overscale = m.show_overscale,
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var stringify: Stringify = .{ .writer = &aw.writer };
    const js = &stringify;

    try js.beginObject();
    try js.objectField("version");
    try js.write(8);
    var namebuf: [64]u8 = undefined;
    try js.objectField("name");
    try js.write(try std.fmt.bufPrint(&namebuf, "tile57 ({s})", .{opts.scheme}));

    try js.objectField("sources");
    try js.beginObject();
    try js.objectField("chart");
    try js.beginObject();
    try js.objectField("type");
    try js.write("vector");
    // MLT sources carry the encoding hint (maplibre-gl >=5.12 decodes MLT natively);
    // MVT (the default) emits nothing, keeping existing styles byte-identical.
    if (opts.encoding) |enc| if (std.mem.eql(u8, enc, "mlt")) {
        try js.objectField("encoding");
        try js.write("mlt");
    };
    if (opts.source_tiles) |t| {
        try js.objectField("tiles");
        try js.beginArray();
        try js.write(t);
        try js.endArray();
        try js.objectField("minzoom");
        try js.write(opts.minzoom);
        try js.objectField("maxzoom");
        try js.write(opts.maxzoom);
    } else {
        try js.objectField("url");
        try js.write(opts.pmtiles_url);
    }
    try js.endObject(); // chart
    try js.endObject(); // sources

    try js.objectField("layers");
    try js.beginArray();

    // 1. background
    try js.beginObject();
    try js.objectField("id");
    try js.write("background");
    try js.objectField("type");
    try js.write("background");
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("background-color");
    try js.write(sea);
    try js.endObject();
    try js.endObject();

    // 2. area fills — base (plain) + one SCAMIN bucket layer per manifest value.
    // With scale gating active (and a sprite to draw the hatch) the base fill
    // layer splits around the AP(OVERSC01) overscale layer: overscaled cells'
    // fills (fill-areas#oscl) UNDER the hatch, at-scale fills (fill-areas) ABOVE
    // it — so finer opaque DEPARE/LNDARE occlude a coarser cell's hatch and it
    // survives only on coarse-only patches (S-52 §10.1.10, specs/overscale.md).
    // ignore_scamin (gate off) or no sprite keeps the single plain fill layer.
    if (s.smax != .off and sprite_on) {
        try fillLayer(js, &s, "areas", .{ .oscl = .overscaled, .suffix = "#oscl" });
        try overscaleLayer(js, &s);
        try fillLayer(js, &s, "areas", .{ .oscl = .at_scale });
    } else {
        try fillLayer(js, &s, "areas", .{});
    }
    for (all_buckets) |bkt| try fillLayer(js, &s, "areas_scamin", bkt);

    // 3. area fill patterns (sprite required)
    if (sprite_on) {
        try patternLayer(js, &s, "area_patterns", .{});
        for (all_buckets) |bkt| try patternLayer(js, &s, "area_patterns_scamin", bkt);
    }

    // 4. lines: solid/dashed/dotted over base + _scamin buckets
    try lineLayers(js, &s, "lines", .{});
    for (all_buckets) |bkt| try lineLayers(js, &s, "lines_scamin", bkt);

    // 5. complex (symbolised) lines
    try complexLineLayer(js, &s, "complex_lines", .{});
    for (all_buckets) |bkt| try complexLineLayer(js, &s, "complex_lines_scamin", bkt);

    // 6. light sector limit lines (no SCAMIN bucketing)
    try lineLayers(js, &s, "sector_lines", .{});

    // 7. point symbols + soundings (sprite required), stacked by z-order:
    //   base symbols (buoys/beacons/landmarks…) UNDER soundings (S-52 priority),
    //   then soundings, then the DANGER markers (obstruction/wreck/rock) OVER soundings
    //   so the hazard stays visible on top of its own depth number, then LIGHTS on top.
    if (sprite_on) {
        try pointSymbolLayers(js, &s, "point_symbols", .{}, .base);
        for (all_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols_scamin", bkt, .base);
        for (snd_buckets) |bkt| try soundingsLayer(js, &s, bkt);
        // Danger markers over the spot soundings (hazard visibility — see DANGER_CLASSES).
        try pointSymbolLayers(js, &s, "point_symbols", .{}, .dangers_only);
        for (all_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols_scamin", bkt, .dangers_only);
        // Danger depths ABOVE the danger markers: DANGER01/02 have an OPAQUE
        // DEPVS-filled interior (the S-52 oval masks the chart under it), and the
        // rules draw the marker FIRST then the digits on top (WRECKS05/OBSTRN07
        // instruction order) — below the ovals the depths were invisible. Never
        // collision-culled (see the soundings class split).
        for (snd_buckets) |bkt| try dangerSoundingsLayer(js, &s, bkt);
        // LIGHTS on top: emitted after every other point symbol so a light always draws
        // over a same-priority bridge that lives in a different scamin bucket layer.
        try pointSymbolLayers(js, &s, "point_symbols", .{}, .lights_only);
        for (all_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols_scamin", bkt, .lights_only);
    }

    // 8. contour value labels (DEPCNT VALDCO) — text, needs glyphs. Emitted AFTER the
    // point symbols + soundings (oracle layer order: point_symbols, soundings,
    // contour-labels, text), so a depth-contour value reads on top of the symbol group
    // rather than being hidden under it. Was before the symbols (labels masked).
    if (glyphs_on) {
        try contourLabelLayer(js, &s, "lines", .{});
        for (all_buckets) |bkt| try contourLabelLayer(js, &s, "lines_scamin", bkt);
    }

    // 9. text labels — need an SDF glyph source.
    if (glyphs_on) {
        try textLayers(js, &s, "text", .{});
        for (all_buckets) |bkt| try textLayers(js, &s, "text_scamin", bkt);
    }

    try js.endArray(); // layers

    if (opts.glyphs) |g| {
        try js.objectField("glyphs");
        try js.write(g);
    }
    if (opts.sprite) |sp| {
        try js.objectField("sprite");
        try js.write(sp);
    }
    try js.endObject();
    return aw.toOwnedSlice();
}

/// Build a full MapLibre style from a base template + mariner settings — the single
/// builder behind the C-ABI / WASM / parity callers (replaces chartstyle.buildStyle's
/// template-patch pass). The passed template carries ONLY the host's source config
/// (sprite / glyphs / chart tiles+zoom); this lifts that out and regenerates every
/// layer via styleJson with the mariner baked in. Signature mirrors the retired
/// buildStyle so callers are a one-line change. A bad template or unusable colortables
/// returns the template bytes unchanged (alloc-owned dup), as buildStyle did.
pub fn buildFromTemplate(
    alloc: std.mem.Allocator,
    template_json: []const u8,
    m: *const chartstyle.MarinerSettings,
    colortables_json: []const u8,
    enabled_bands: ?[]const i32,
    now_unix: i64,
) ![]u8 {
    // No SCAMIN manifest -> the *_scamin layers fall back to a single ungated layer
    // (the template / wasm / parity callers don't carry a manifest).
    return buildFromTemplateScamin(alloc, template_json, m, colortables_json, enabled_bands, now_unix, &.{}, 0);
}

/// Same as buildFromTemplate but threading a SCAMIN manifest (the distinct
/// denominators present + a representative latitude), so the RUNTIME style gets the
/// SAME per-value native-minzoom bucket layers the offline bundle does (host
/// host-canonical-backend.md §"Still needed" #1 — the `tile57_build_style` runtime
/// path otherwise leaves every `_scamin` layer ungated). Empty `scamin` == the
/// plain buildFromTemplate behaviour.
pub fn buildFromTemplateScamin(
    alloc: std.mem.Allocator,
    template_json: []const u8,
    m: *const chartstyle.MarinerSettings,
    colortables_json: []const u8,
    enabled_bands: ?[]const i32,
    now_unix: i64,
    scamin: []const u32,
    scamin_lat: f64,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, template_json, .{}) catch
        return alloc.dupe(u8, template_json);
    defer parsed.deinit();
    var opts = StyleOpts{
        .scheme = switch (m.scheme) {
            .dusk => "dusk",
            .night => "night",
            .day => "day",
        },
        .colortables_json = colortables_json,
        .mariner = m.*,
        .enabled_bands = enabled_bands,
        .now_unix = now_unix,
        .ignore_scamin = m.ignore_scamin,
        .scamin_filter_gate = m.scamin_filter_gate,
        .size_scale = m.size_scale,
        .scamin = scamin,
        .scamin_lat = scamin_lat,
    };
    if (parsed.value == .object) {
        const root = parsed.value.object;
        if (root.get("sprite")) |v| {
            if (v == .string) opts.sprite = v.string;
        }
        if (root.get("glyphs")) |v| {
            if (v == .string) opts.glyphs = v.string;
        }
        if (root.get("sources")) |sv| {
            if (sv == .object) if (sv.object.get("chart")) |cv| {
                if (cv == .object) {
                    const c = cv.object;
                    if (c.get("url")) |u| {
                        if (u == .string) opts.pmtiles_url = u.string;
                    }
                    if (c.get("tiles")) |t| {
                        if (t == .array and t.array.items.len > 0 and t.array.items[0] == .string)
                            opts.source_tiles = t.array.items[0].string;
                    }
                    if (c.get("encoding")) |e| { // MLT hint rides the rebuild (tile57_build_style / style_diff)
                        if (e == .string) opts.encoding = e.string;
                    }
                    if (c.get("minzoom")) |z| {
                        if (z == .integer) opts.minzoom = @intCast(z.integer);
                    }
                    if (c.get("maxzoom")) |z| {
                        if (z == .integer) opts.maxzoom = @intCast(z.integer);
                    }
                }
            };
        }
    }
    return styleJson(alloc, opts) catch alloc.dupe(u8, template_json);
}

// ---- style diff (style-diff.md) --------------------------------------------
// Compute the minimal MapLibre style-mutation ops that turn one built style into
// another. The engine knows both styles come from styleJson (same layer set +
// deterministic key order), so a structural layer-by-layer compare yields exactly
// the ops MapLibre's setStyle(diff:true) would — but scoped to the chart layers and
// returned as data the host applies with setFilter / setPaintProperty /
// setLayoutProperty (never setStyle), so overlays and sources are untouched.

/// The `[{"op":"rebuild"}]` escape hatch: the two styles have a different SET of
/// layer ids (not expected for any current mariner field — a safety valve telling
/// the host to fall back to a full setStyle).
const rebuild_ops = "[{\"op\":\"rebuild\"}]";

fn layersOf(v: std.json.Value) ?std.json.Array {
    if (v != .object) return null;
    const l = v.object.get("layers") orelse return null;
    if (l != .array) return null;
    return l.array;
}

fn layerId(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const idv = v.object.get("id") orelse return null;
    if (idv != .string) return null;
    return idv.string;
}

/// Structural deep-equality for two parsed JSON values. std.json.Value has no
/// built-in equal; both operands here come from the same styleJson generator, so
/// corresponding keys share a representation (integer stays integer, object key
/// order matches) and a recursive compare is exact.
fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| b == .integer and b.integer == x,
        .float => |x| b == .float and b.float == x,
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |ai, bi| if (!jsonEql(ai, bi)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const bv = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEql(e.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn optJsonEql(a: ?std.json.Value, b: ?std.json.Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return jsonEql(a.?, b.?);
}

// {"op":op,"layer":id,"value":value}  (value null when the key was removed).
fn emitFilterOp(js: *Stringify, id: []const u8, value: ?std.json.Value) !void {
    try js.beginObject();
    try js.objectField("op");
    try js.write("setFilter");
    try js.objectField("layer");
    try js.write(id);
    try js.objectField("value");
    if (value) |v| try js.write(v) else try js.write(null);
    try js.endObject();
}

// {"op":op,"layer":id,"property":key,"value":value}  (value null when removed).
fn emitPropOp(js: *Stringify, op: []const u8, id: []const u8, key: []const u8, value: ?std.json.Value) !void {
    try js.beginObject();
    try js.objectField("op");
    try js.write(op);
    try js.objectField("layer");
    try js.write(id);
    try js.objectField("property");
    try js.write(key);
    try js.objectField("value");
    if (value) |v| try js.write(v) else try js.write(null);
    try js.endObject();
}

// Diff a layer's `paint` (or `layout`) sub-object: one prop op per key that
// changed, was added (value = new), or was removed (value = null).
fn diffSubObject(js: *Stringify, op: []const u8, id: []const u8, old_v: ?std.json.Value, new_v: ?std.json.Value) !void {
    const old_o: ?std.json.ObjectMap = if (old_v) |v| (if (v == .object) v.object else null) else null;
    const new_o: ?std.json.ObjectMap = if (new_v) |v| (if (v == .object) v.object else null) else null;
    if (new_o) |no| {
        var it = no.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            const ov: ?std.json.Value = if (old_o) |oo| oo.get(k) else null;
            if (ov == null or !jsonEql(ov.?, e.value_ptr.*))
                try emitPropOp(js, op, id, k, e.value_ptr.*);
        }
    }
    if (old_o) |oo| {
        var it = oo.iterator();
        while (it.next()) |e| {
            const present = if (new_o) |no| no.get(e.key_ptr.*) != null else false;
            if (!present) try emitPropOp(js, op, id, e.key_ptr.*, null);
        }
    }
}

/// Compute the minimal MapLibre style-mutation ops (a JSON array) to turn the
/// serialized style `old_json` into `new_json`. Both must be styleJson output (same
/// template/colortables/bands/scamin inputs, differing only in mariner). Returns
/// allocator-owned bytes: `"[]"` when nothing differs; one op per differing
/// `filter` / `paint.*` / `layout.*` key; `[{"op":"rebuild"}]` when the two styles
/// carry a different SET of layer ids (the host then falls back to a full setStyle).
pub fn styleDiff(alloc: std.mem.Allocator, old_json: []const u8, new_json: []const u8) ![]u8 {
    var old_parsed = std.json.parseFromSlice(std.json.Value, alloc, old_json, .{}) catch
        return alloc.dupe(u8, rebuild_ops);
    defer old_parsed.deinit();
    var new_parsed = std.json.parseFromSlice(std.json.Value, alloc, new_json, .{}) catch
        return alloc.dupe(u8, rebuild_ops);
    defer new_parsed.deinit();

    const old_layers = layersOf(old_parsed.value) orelse return alloc.dupe(u8, rebuild_ops);
    const new_layers = layersOf(new_parsed.value) orelse return alloc.dupe(u8, rebuild_ops);

    // Index old layers by id; a differing layer-id set -> rebuild. Equal counts
    // plus every new id present in old => the two sets are equal (no add/remove).
    var old_by_id = std.StringHashMap(std.json.Value).init(alloc);
    defer old_by_id.deinit();
    for (old_layers.items) |lyr| {
        const id = layerId(lyr) orelse continue;
        try old_by_id.put(id, lyr);
    }
    var new_count: usize = 0;
    for (new_layers.items) |lyr| {
        const id = layerId(lyr) orelse continue;
        new_count += 1;
        if (!old_by_id.contains(id)) return alloc.dupe(u8, rebuild_ops);
    }
    if (new_count != old_by_id.count()) return alloc.dupe(u8, rebuild_ops);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var stringify: Stringify = .{ .writer = &aw.writer };
    const js = &stringify;

    try js.beginArray();
    for (new_layers.items) |lyr| {
        const id = layerId(lyr) orelse continue;
        const old_obj = old_by_id.get(id).?.object; // present: set-equality checked above
        const new_obj = lyr.object;
        const old_f = old_obj.get("filter");
        const new_f = new_obj.get("filter");
        if (!optJsonEql(old_f, new_f)) try emitFilterOp(js, id, new_f);
        try diffSubObject(js, "setPaintProperty", id, old_obj.get("paint"), new_obj.get("paint"));
        try diffSubObject(js, "setLayoutProperty", id, old_obj.get("layout"), new_obj.get("layout"));
    }
    try js.endArray();
    return aw.toOwnedSlice();
}

test "styleJson: valid JSON, expected layers, palette-resolved colour" {
    const ct =
        \\{"day":{"DEPDW":"#c9edff","CHGRD":"#4c5b63","CHBLK":"#000000"},"dusk":{},"night":{"DEPDW":"#0a141e"}}
    ;
    const out = try styleJson(std.testing.allocator, .{
        .scheme = "day",
        .colortables_json = ct,
        .source_tiles = "tile57://{z}/{x}/{y}",
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
    });
    defer std.testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const layers = parsed.value.object.get("layers").?.array;
    try std.testing.expect(layers.items.len > 15);
    try std.testing.expectEqualStrings("background", layers.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("#c9edff", layers.items[0].object.get("paint").?.object.get("background-color").?.string);
    try std.testing.expect(parsed.value.object.get("sprite") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"fill-areas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#c9edff") != null);
}

test "styleJson: ignore_scamin drops SCAMIN gating (no buckets, no zoom-gate)" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 30000, 90000 };
    const base = StyleOpts{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
    };

    // Manifest present, gating ON -> per-value #sm buckets exist.
    const gated = try styleJson(a, base);
    defer a.free(gated);
    try std.testing.expect(std.mem.indexOf(u8, gated, "#sm30000") != null);

    // Manifest present, ignore_scamin -> no buckets at all.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try styleJson(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "#sm") == null);

    // No manifest, gating ON -> the per-feature zoom-gate fallback (log2) is present.
    var nomanifest = base;
    nomanifest.scamin = &.{};
    const out_fb = try styleJson(a, nomanifest);
    defer a.free(out_fb);
    try std.testing.expect(std.mem.indexOf(u8, out_fb, "log2") != null);

    // No manifest + ignore_scamin -> even the zoom-gate fallback is gone.
    var nm_ign = nomanifest;
    nm_ign.ignore_scamin = true;
    const out_nm_ign = try styleJson(a, nm_ign);
    defer a.free(out_nm_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_nm_ign, "log2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_nm_ign, "#sm") == null);
}

test "styleJson: size_scale wraps icon/line/text sizes in a multiplier" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const base = StyleOpts{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
    };

    // Default scale 1.0: sizes written verbatim, no multiplier wrapper.
    const def = try styleJson(a, base);
    defer a.free(def);
    try std.testing.expect(std.mem.indexOf(u8, def, "\"line-width\":[\"coalesce\",[\"get\",\"width_px\"],1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, def, "\"line-width\":[\"*\"") == null);

    // Scaled: icon-size / line-width / text-size each wrap in ["*", scale, expr].
    var scaled = base;
    scaled.size_scale = 2.0;
    const sc = try styleJson(a, scaled);
    defer a.free(sc);
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"line-width\":[\"*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"icon-size\":[\"*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"text-size\":[\"*\"") != null);
    // The unscaled line-width form is gone.
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"line-width\":[\"coalesce\"") == null);
}

// ---- single-builder (buildFromTemplate) tests — ported from the retired
//      chartstyle.buildStyle tests, now exercising the one styleJson path. -------
const cs_template =
    \\{"version":8,"sources":{"chart":{"type":"vector","url":"pmtiles://x"}},"sprite":"x","glyphs":"x","layers":[]}
;
const cs_ct =
    \\{"day":{"DEPDW":"#c9edff","DEPMD":"#9bc4e0","DEPMS":"#6aa5cf","DEPVS":"#3a86bf","DEPIT":"#bfe6ff","CHGRD":"#5a5a44","CHBLK":"#000000"},"dusk":{"DEPDW":"#0a141e"},"night":{"DEPDW":"#050a0f"}}
;

test "buildFromTemplate: defaults bake SEABED fill + category/M_QUAL filter (single-pass)" {
    const a = std.testing.allocator;
    const m = chartstyle.MarinerSettings{};
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "DEPMD") != null); // SEABED01 band
    try std.testing.expect(std.mem.indexOf(u8, out, "ISODGR01") != null); // category filter
    try std.testing.expect(std.mem.indexOf(u8, out, "M_QUAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "10.0") != null); // float depth edges
    try std.testing.expect(std.mem.indexOf(u8, out, "30.0") != null);
}

test "buildFromTemplate: night scheme -> neutral ink + dark halo" {
    const a = std.testing.allocator;
    const m = chartstyle.MarinerSettings{ .scheme = .night };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#aab7bf") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rgba(0,0,0,0.85)") != null);
}

test "buildFromTemplate: feet depth unit -> contour label uses M_TO_FT" {
    const a = std.testing.allocator;
    const m = chartstyle.MarinerSettings{ .depth_unit = .feet };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "3.280839895") != null);
}

test "buildFromTemplate: feet picks the sounding feet glyph variant; metres doesn't" {
    const a = std.testing.allocator;
    const feet = try buildFromTemplate(a, cs_template, &.{ .depth_unit = .feet }, cs_ct, null, 1700000000);
    defer a.free(feet);
    try std.testing.expect(std.mem.indexOf(u8, feet, "sym_s_ft") != null);

    // The default metres style swaps in the plain metres glyphs, not the feet variant.
    const metres = try buildFromTemplate(a, cs_template, &.{}, cs_ct, null, 1700000000);
    defer a.free(metres);
    try std.testing.expect(std.mem.indexOf(u8, metres, "sym_s_ft") == null);
    try std.testing.expect(std.mem.indexOf(u8, metres, "sym_s") != null);
}

test "buildFromTemplate: enabled bands add a band filter" {
    const a = std.testing.allocator;
    const m = chartstyle.MarinerSettings{};
    const bands = [_]i32{ 2, 3 };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, &bands, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"band\"") != null);
}

test "buildFromTemplate: date resolution (pinned + today + off)" {
    const a = std.testing.allocator;
    const m1 = chartstyle.MarinerSettings{ .date_view = "20240115" };
    const o1 = try buildFromTemplate(a, cs_template, &m1, cs_ct, null, 1700000000);
    defer a.free(o1);
    try std.testing.expect(std.mem.indexOf(u8, o1, "20240115") != null);
    try std.testing.expect(std.mem.indexOf(u8, o1, "0115") != null);

    const m2 = chartstyle.MarinerSettings{};
    const o2 = try buildFromTemplate(a, cs_template, &m2, cs_ct, null, 1700000000);
    defer a.free(o2);
    try std.testing.expect(std.mem.indexOf(u8, o2, "20231114") != null);

    const m3 = chartstyle.MarinerSettings{ .date_dependent = false };
    const o3 = try buildFromTemplate(a, cs_template, &m3, cs_ct, null, 1700000000);
    defer a.free(o3);
    try std.testing.expect(std.mem.indexOf(u8, o3, "date_recurring") == null);
}

test "buildFromTemplate: viewing-group deny-list filter gates by vg" {
    const a = std.testing.allocator;
    // A non-empty off-set hides the listed groups -> the style references the `vg`
    // property and the off ids, negated (deny-list).
    const off = [_]i32{ 26070, 27070 };
    const m = chartstyle.MarinerSettings{ .viewing_groups_off = &off };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"vg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "26070") != null);
    // The filter is a deny-list: ["!",["in",...]] so the off groups are EXCLUDED.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"in\"") != null);
    // null off-set -> no vg filter at all.
    const m2 = chartstyle.MarinerSettings{};
    const o2 = try buildFromTemplate(a, cs_template, &m2, cs_ct, null, 1700000000);
    defer a.free(o2);
    try std.testing.expect(std.mem.indexOf(u8, o2, "\"vg\"") == null);
    // empty off-set -> also no filter (show all).
    const empty = [_]i32{};
    const m3 = chartstyle.MarinerSettings{ .viewing_groups_off = &empty };
    const o3 = try buildFromTemplate(a, cs_template, &m3, cs_ct, null, 1700000000);
    defer a.free(o3);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"vg\"") == null);
}

test "buildFromTemplateScamin: a manifest emits per-value buckets, no zoom-gate" {
    const a = std.testing.allocator;
    const m = chartstyle.MarinerSettings{};
    // No manifest -> the per-feature zoom-gate fallback (log2), no #sm buckets.
    const plain = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "log2") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "#sm") == null);
    // With a manifest -> native fractional-minzoom bucket layers, no zoom-gate.
    const scamin = [_]u32{ 89999, 259999 };
    const bucketed = try buildFromTemplateScamin(a, cs_template, &m, cs_ct, null, 1700000000, &scamin, 38.0);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "#sm89999") != null);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "#sm259999") != null);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "log2") == null);
}

// ---- band-handoff smax gate tests -------------------------------------------

test "styleJson: the filter-gate smax clause has the EXACT client-matched shape" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const gated = try styleJson(a, .{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
        .scamin_filter_gate = true,
        .scamin_cur_denom = 50000,
    });
    defer a.free(gated);
    // The band-handoff gate, verbatim — chartplotter-go pattern-matches this shape
    // (band-handoff contract) to rewrite DENOM beside the scamin clause. DENOM is
    // the SAME injected literal as the scamin clause's.
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"<\",[\"coalesce\",[\"get\",\"smax\"],0],50000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],50000]") != null);

    // The boot/diff PLACEHOLDER (cur_denom 0) must be show-all for BOTH clauses:
    // scamin keeps the 0 literal (scamin >= 0 passes everything) while smax maps
    // to its own show-all end (smax < 1e12) — a 0 literal there hides every
    // feature and blanked the chart until the client's live injection.
    const boot = try styleJson(a, .{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
        .scamin_filter_gate = true,
        .scamin_cur_denom = 0,
    });
    defer a.free(boot);
    try std.testing.expect(std.mem.indexOf(u8, boot, "[\"<\",[\"coalesce\",[\"get\",\"smax\"],0],1000000000000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, boot, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],0]") != null);

    // The gate rides the BASE layers too: a carried copy of an ungated feature
    // (fills, plain symbols) lands there and must still hand off.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, gated, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("layers").?.array.items) |lyr| {
        const id = lyr.object.get("id").?.string;
        if (std.mem.eql(u8, id, "fill-areas")) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(a);
            var aw: std.Io.Writer.Allocating = .init(a);
            defer aw.deinit();
            var st: Stringify = .{ .writer = &aw.writer };
            try st.write(lyr.object.get("filter").?);
            try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "smax") != null);
        }
    }
}

test "styleJson: bucket/zoom-gate modes derive the smax denominator from zoom; ignore_scamin drops it" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const base = StyleOpts{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
    };
    // Bucket mode: DENOM = K/2^zoom at the manifest latitude (physical formula).
    const bucketed = try styleJson(a, base);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "[\"<\",[\"coalesce\",[\"get\",\"smax\"],0],[\"/\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "[\"^\",2,[\"zoom\"]]") != null);

    // No-manifest fallback: same clause with the OGC z0 denominator constant.
    var nm = base;
    nm.scamin = &.{};
    const fb = try styleJson(a, nm);
    defer a.free(fb);
    try std.testing.expect(std.mem.indexOf(u8, fb, "\"smax\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fb, "279541132") != null);

    // ignore_scamin: the debug toggle shows everything — no smax gate anywhere.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try styleJson(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "smax") == null);
}

// ---- overscale (oscl) gate tests (specs/overscale.md) -----------------------

test "styleJson: the overscale oscl clause has the EXACT client-matched shape" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const gated = try styleJson(a, .{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
        .scamin_filter_gate = true,
        .scamin_cur_denom = 50000,
    });
    defer a.free(gated);
    // The overscale gate, verbatim — chartplotter-go pattern-matches this shape
    // (overscale contract) to rewrite DENOM beside the scamin/smax clauses. The
    // hatch + the under-hatch fill pass carry the positive clause; the at-scale
    // fill pass carries its ["!", …] negation (occlusion sandwich).
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],50000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"!\",[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],50000]]") != null);
    // Generic pattern layers exclude the hatch (it rides its own gated layer).
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"!=\",[\"get\",\"pattern_name\"],\"OVERSC01\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"==\",[\"get\",\"pattern_name\"],\"OVERSC01\"]") != null);

    // The boot/diff PLACEHOLDER (cur_denom 0) maps to 1e12 — hide the hatch and
    // keep every fill in the at-scale pass (today's rendering) until the client
    // injects the live denominator (the smax placeholder lesson, cb91c4d).
    const boot = try styleJson(a, .{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
        .scamin_filter_gate = true,
        .scamin_cur_denom = 0,
    });
    defer a.free(boot);
    try std.testing.expect(std.mem.indexOf(u8, boot, "[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],1000000000000]") != null);

    // The occlusion sandwich: fill-areas#oscl (overscaled fills) UNDER the
    // `overscale` hatch layer UNDER fill-areas (at-scale fills) — a finer cell's
    // opaque fill paints over a coarser cell's hatch, so the hatch survives only
    // on coarse-only patches. Verify layer order + the hatch layer's shape.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, gated, .{});
    defer parsed.deinit();
    var i_oscl: ?usize = null;
    var i_hatch: ?usize = null;
    var i_base: ?usize = null;
    const layers = parsed.value.object.get("layers").?.array.items;
    for (layers, 0..) |lyr, i| {
        const id = lyr.object.get("id").?.string;
        if (std.mem.eql(u8, id, "fill-areas#oscl")) i_oscl = i;
        if (std.mem.eql(u8, id, "overscale")) i_hatch = i;
        if (std.mem.eql(u8, id, "fill-areas")) i_base = i;
    }
    try std.testing.expect(i_oscl.? < i_hatch.?);
    try std.testing.expect(i_hatch.? < i_base.?);
    const hatch = layers[i_hatch.?].object;
    try std.testing.expectEqualStrings("area_patterns", hatch.get("source-layer").?.string);
    try std.testing.expectEqualStrings("pat:OVERSC01", hatch.get("paint").?.object.get("fill-pattern").?.string);
    try std.testing.expectEqualStrings("visible", hatch.get("layout").?.object.get("visibility").?.string);
}

test "styleJson: showOverscale=false hides the hatch layer; ignore_scamin drops the machinery" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const base = StyleOpts{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
    };
    // The mariner toggle flips ONLY the layer's visibility (layer set unchanged,
    // so a style diff is a single setLayoutProperty op).
    var off = base;
    off.mariner = .{ .show_overscale = false };
    const hidden = try styleJson(a, off);
    defer a.free(hidden);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "\"id\":\"overscale\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "{\"visibility\":\"none\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "\"oscl\"") != null);

    // Bucket mode derives the oscl DENOM from zoom (same K as the smax clause).
    const bucketed = try styleJson(a, base);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],[\"/\",") != null);

    // ignore_scamin: no oscl clauses, no hatch layer, the single plain fill layer.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try styleJson(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "oscl") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "\"id\":\"overscale\",") == null);

    // No sprite -> nothing can draw the hatch: single plain fill layer, no sandwich.
    var nospr = base;
    nospr.sprite = null;
    const out_ns = try styleJson(a, nospr);
    defer a.free(out_ns);
    try std.testing.expect(std.mem.indexOf(u8, out_ns, "oscl") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_ns, "\"id\":\"overscale\",") == null);
}

// ---- styleDiff tests (style-diff.md §5) ------------------------------------

test "styleDiff: filter + paint + layout changes emit precise, scoped ops" {
    const a = std.testing.allocator;
    const old_j =
        \\{"layers":[
        \\{"id":"areas","type":"fill","filter":["==","x",1],"paint":{"fill-color":"#111"},"layout":{"visibility":"visible"}},
        \\{"id":"text","type":"symbol","paint":{"text-color":"#000"}}
        \\]}
    ;
    const new_j =
        \\{"layers":[
        \\{"id":"areas","type":"fill","filter":["==","x",2],"paint":{"fill-color":"#222"},"layout":{"visibility":"none"}},
        \\{"id":"text","type":"symbol","paint":{"text-color":"#000"}}
        \\]}
    ;
    const ops = try styleDiff(a, old_j, new_j);
    defer a.free(ops);
    // areas: filter, paint fill-color, layout visibility all changed -> one op each.
    try std.testing.expect(std.mem.indexOf(u8, ops, "{\"op\":\"setFilter\",\"layer\":\"areas\",\"value\":[\"==\",\"x\",2]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "{\"op\":\"setPaintProperty\",\"layer\":\"areas\",\"property\":\"fill-color\",\"value\":\"#222\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "{\"op\":\"setLayoutProperty\",\"layer\":\"areas\",\"property\":\"visibility\",\"value\":\"none\"}") != null);
    // text is byte-identical -> it must not appear in any op.
    try std.testing.expect(std.mem.indexOf(u8, ops, "\"layer\":\"text\"") == null);
}

test "styleDiff: a removed paint key emits value:null" {
    const a = std.testing.allocator;
    const old_j = "{\"layers\":[{\"id\":\"l\",\"paint\":{\"fill-color\":\"#111\",\"fill-opacity\":0.5}}]}";
    const new_j = "{\"layers\":[{\"id\":\"l\",\"paint\":{\"fill-color\":\"#111\"}}]}";
    const ops = try styleDiff(a, old_j, new_j);
    defer a.free(ops);
    try std.testing.expectEqualStrings(
        "[{\"op\":\"setPaintProperty\",\"layer\":\"l\",\"property\":\"fill-opacity\",\"value\":null}]",
        ops,
    );
}

test "styleDiff: a differing layer-id set -> rebuild" {
    const a = std.testing.allocator;
    // id renamed
    const r1 = try styleDiff(a, "{\"layers\":[{\"id\":\"x\"}]}", "{\"layers\":[{\"id\":\"y\"}]}");
    defer a.free(r1);
    try std.testing.expectEqualStrings(rebuild_ops, r1);
    // count differs
    const r2 = try styleDiff(a, "{\"layers\":[{\"id\":\"x\"}]}", "{\"layers\":[{\"id\":\"x\"},{\"id\":\"z\"}]}");
    defer a.free(r2);
    try std.testing.expectEqualStrings(rebuild_ops, r2);
}

test "styleDiff: same mariner -> [] (no ops)" {
    const a = std.testing.allocator;
    const m = chartstyle.MarinerSettings{};
    const s1 = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(s1);
    const s2 = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(s2);
    const ops = try styleDiff(a, s1, s2);
    defer a.free(ops);
    try std.testing.expectEqualStrings("[]", ops);
}

test "styleDiff: display_other flip emits only setFilter ops" {
    const a = std.testing.allocator;
    const base = chartstyle.MarinerSettings{};
    const other = chartstyle.MarinerSettings{ .display_other = true };
    const s1 = try buildFromTemplate(a, cs_template, &base, cs_ct, null, 1700000000);
    defer a.free(s1);
    const s2 = try buildFromTemplate(a, cs_template, &other, cs_ct, null, 1700000000);
    defer a.free(s2);
    const ops = try styleDiff(a, s1, s2);
    defer a.free(ops);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setFilter") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setPaintProperty") == null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setLayoutProperty") == null);
    try std.testing.expect(!std.mem.eql(u8, ops, "[]"));
}

test "styleDiff: day vs night emits setPaintProperty colour ops, no filter change" {
    const a = std.testing.allocator;
    const day = chartstyle.MarinerSettings{ .scheme = .day };
    const night = chartstyle.MarinerSettings{ .scheme = .night };
    const s1 = try buildFromTemplate(a, cs_template, &day, cs_ct, null, 1700000000);
    defer a.free(s1);
    const s2 = try buildFromTemplate(a, cs_template, &night, cs_ct, null, 1700000000);
    defer a.free(s2);
    const ops = try styleDiff(a, s1, s2);
    defer a.free(ops);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setPaintProperty") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setFilter") == null);
}

// ---- scamin_filter_gate tests (scamin-layers.md) ---------------------------

fn layerCount(a: std.mem.Allocator, style: []const u8) !usize {
    var p = try std.json.parseFromSlice(std.json.Value, a, style, .{});
    defer p.deinit();
    return p.value.object.get("layers").?.array.items.len;
}

test "styleJson: scamin_filter_gate collapses per-value buckets to one layer per render-type" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 3000, 8000, 12000, 22000, 45000, 90000, 180000 }; // 7 denominators
    const base = StyleOpts{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
    };

    // Bucketed (default): per-value #sm layers, each with a native minzoom.
    const bucketed = try styleJson(a, base);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "#sm") != null);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "minzoom") != null);

    // Filter-gate: no #sm buckets, no minzoom, the live SCAMIN clause instead.
    var fg = base;
    fg.scamin_filter_gate = true;
    const gated = try styleJson(a, fg);
    defer a.free(gated);
    try std.testing.expect(std.mem.indexOf(u8, gated, "#sm") == null); // no per-value buckets
    try std.testing.expect(std.mem.indexOf(u8, gated, "minzoom") == null); // no native minzoom gating
    // The live clause [">=",["coalesce",["get","scamin"],1e12],curDenom]. 1e12 (the coalesce
    // max) is unique to it; plain "coalesce" also appears in line-width so it isn't a marker.
    try std.testing.expect(std.mem.indexOf(u8, gated, "1000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "\"scamin\"") != null);

    // 7 denominators × ~9 SCAMIN render-types => buckets add ~7× the *_scamin layers;
    // filter-gate adds 1×. So the bucketed style has far more layers.
    const bn = try layerCount(a, bucketed);
    const gn = try layerCount(a, gated);
    try std.testing.expect(gn < bn);
    try std.testing.expect(bn > gn * 2);
}

test "styleJson: scamin_filter_gate honors the cur_denom literal + ignore_scamin drops the clause" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const base = StyleOpts{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
        .scamin_filter_gate = true,
        .scamin_cur_denom = 50000,
    };
    const gated = try styleJson(a, base);
    defer a.free(gated);
    // The baked default denominator appears in the clause.
    try std.testing.expect(std.mem.indexOf(u8, gated, "50000") != null);

    // ignore_scamin overrides filter_gate: single plain layer, no SCAMIN clause at all.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try styleJson(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "1000000000000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "#sm") == null);
}
