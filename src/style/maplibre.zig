//! maplibre.zig — MapLibre GL style.json generation. Resolves each S-52 colour
//! token to hex for a palette and emits the fill / line / symbol / text layer
//! set. Ported from the chartplotter web frontend's s52-style.mjs /
//! chart-style.mjs, verified layer-for-layer identical during the port. The one
//! style.json generator; part of the `style` module.
//!
//! MapLibre expressions are written as Zig comptime tuples — `.{ "get", "drval1" }`
//! serialises to `["get","drval1"]` — through std.json's Stringify write-stream,
//! which owns all escaping, comma, and brace handling. No raw JSON in the source;
//! the only hand-rolled fragment is the variable-length colour `match` (the palette
//! is runtime data), and that goes through the same stream.

const std = @import("std");
const Stringify = std.json.Stringify;
const mariner = @import("mariner.zig");

const FALLBACK = "#ff00ff";
const FONT = .{"Noto Sans Regular"};
const FONT_BOLD = .{"Noto Sans Bold"};
const FONT_ITALIC = .{"Noto Sans Italic"};
// Geographic-name text-font, data-driven by the label-tier props (render.labeltier):
// bold for populated-place names, italic for hydrography, else the regular face.
// The client's glyphs endpoint serves all three Noto Sans fontstacks. Each font
// stack is wrapped in ["literal", …]: inside an expression a bare ["Noto Sans
// Bold"] parses as a function call (crashing symbol placement), not a font array.
const TEXT_FONT = .{
    "case",
    .{ "==", .{ "get", "font_weight" }, "bold" },
    .{ "literal", FONT_BOLD },
    .{ "==", .{ "get", "font_slant" }, "italic" },
    .{ "literal", FONT_ITALIC },
    .{ "literal", FONT },
};

// ---- MapLibre expressions, as comptime tuples ----------------------------
// SEABED01 depth shading, the danger-symbol swap, and the sounding bold/faint split
// are mariner-dependent and now resolve through the mariner builders (one style
// builder); only the mariner-INDEPENDENT layout exprs remain comptime tuples here.

// The static (no-manifest) SCAMIN/oscl gate is now expressed as K / 2^zoom —
// the SAME display-denominator form the bucket path uses (json computes
// K = M_PER_PX_Z0·cos(scamin_lat)/(pitch/1000) once per archive). The old hardcoded
// DENOM_Z0 (0.28 mm OGC pixel, equator) gated ~0.4 z late at mid-latitude and used
// the uncalibrated CSS pixel; K is latitude-corrected and calibrated. See
// scaminGateK() / writeScaminClause's .zoom_gate branch.

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

/// The per-archive display-denominator constant K such that the on-screen 1:N
/// denominator at Web-Mercator `zoom` is K / 2^zoom (== displayDenom). Baked into the
/// static SCAMIN/oscl gate at the archive-center latitude; the SAME constant the
/// bucket path computes (json). Replaces the old equator-only OGC DENOM_Z0.
pub fn scaminGateK(lat: f64) f64 {
    return M_PER_PX_Z0 * @cos(lat * std.math.pi / 180.0) / (DEFAULT_PX_PITCH_MM / 1000.0);
}

test "scaminGateK: K/2^zoom equals displayDenom (one gate constant)" {
    // The static gate's D(zoom) = K/2^zoom must match the physical displayDenom used
    // by the bucket path — so scamin/oscl share one latitude-correct form.
    const k = scaminGateK(38.9);
    try std.testing.expectApproxEqRel(displayDenom(9.0, 38.9), k / std.math.exp2(9.0), 1e-12);
    // Equator K is the calibrated-pixel world denominator (NOT the OGC 279.5M).
    try std.testing.expectApproxEqRel(@as(f64, 78271.516964020485 / 0.0002645), scaminGateK(0), 1e-12);
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

// S-52 DrawingPriority fill order: display_priority*1000 - drval1.
const FILL_SORT = .{ "-", .{ "*", .{ "coalesce", .{ "get", "display_priority" }, 0 }, 1000 }, .{ "coalesce", .{ "get", "drval1" }, 0 } };

// solid lines EXCLUDE the un-tessellated complex-linestyle runs (tagged ls_style):
// those get their own dasharray + line-placed symbol layers (linestyleLayers), so a
// run must not also paint as a plain solid stroke here.
const FILT_SOLID = .{ "all", .{ "==", .{ "coalesce", .{ "get", "dash" }, "solid" }, "solid" }, .{ "!", .{ "has", "ls_style" } } };
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
// S-52 splits text into IMPORTANT text (groups 10-19) and Other text, and that
// split is the WHOLE collision ladder — a label carries display priority 8 like
// every other label, so there is no second axis to rank text by. MapLibre gives
// placement precedence to UPPER symbol layers, so the two tiers become two
// layers, important on top; peers within a tier fall to feature order, which is
// the SENC sequence S-52 nominates for the arbitrary decision. The native
// surfaces resolve the identical ladder (render/declutter.zig).
const FILT_TEXT_IMPORTANT = .{ "all", .{ ">=", .{ "coalesce", .{ "get", "tgrp" }, 0 }, 10 }, .{ "<=", .{ "coalesce", .{ "get", "tgrp" }, 0 }, 19 } };
const FILT_TEXT_OTHER = .{ "any", .{ "<", .{ "coalesce", .{ "get", "tgrp" }, 0 }, 10 }, .{ ">", .{ "coalesce", .{ "get", "tgrp" }, 0 }, 19 } };

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

pub const Options = struct {
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
    // sounding-split / danger-swap baked in (the C-ABI tile57_style_build path).
    // Colour + layout always resolve through the mariner builders (default mariner
    // when null), so there is ONE style builder — the mariner builders is retired.
    mariner: ?mariner.Settings = null,
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
    // Analysed complex-linestyle patterns (the linestyles.json emitted for clients:
    // id -> {period_px, dash[], color_token, width_px, symbols[]}). When present the
    // style gains one dasharray line layer per id (+ a line-placed symbol layer per
    // embedded symbol when a sprite is wired) decorating the un-tessellated ls_style
    // runs the tiles carry, and the JSON rides the style's "tile57:linestyles" metadata
    // so a mariner rebuild from the template keeps the layers. null = ls_style runs
    // draw as plain solid lines.
    linestyles_json: ?[]const u8 = null,
};

// Precomputed, mariner-aware style expressions shared by every layer of one
// json call — the single style builder. Colours / depth shading / icon images
// resolve ONCE through the mariner builders
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
    // The overscale (oscl) clauses' gate value (writeOsclClause): the injected
    // DENOM literal under the live filter-gate, else the per-archive K/2^zoom.
    oscl_gate: DenomGate,
    show_overscale: bool, // S-52 §10.1.10 mariner toggle -> the overscale layer's visibility
};

// Display-denominator gate value for the overscale clauses.
const DenomGate = union(enum) {
    // scamin-layers.md filter-gate: the DENOM literal is the SAME injected value
    // as the scamin clause; the live client rewrites both at ladder crossings.
    denom: f64,
    // Native/bucket + zoom-gate paths: DENOM computed from ["zoom"] — K / 2^zoom,
    // K = the per-archive display denominator at z0 (physical at the style's fixed
    // latitude, scaminGateK) — the SAME constant for the bucket path AND the
    // no-manifest fallback, so scamin/oscl gate identically.
    zoom_k: f64,
};

// The overscale (oscl) clause — S-52 §10.1.10. The
// filter-gate form is EXACTLY
//   [">", ["coalesce", ["get","oscl"], 0], DENOM]
// ("the display is FINER than the cell's quantized compilation scale"), or its
// ["!", …] negation for the at-scale fill pass drawn ABOVE the hatch. It shares
// the scamin clause's injected DENOM literal — the live client pattern-matches
// the inner shape to rewrite DENOM alongside scamin (overscale contract). The
// shared boot/diff placeholder (1e12) reads as hide-the-hatch / all-fills-at-
// scale — today's rendering — until the client injects the live denominator.
// Decoupled from SCAMIN gating per spec §5: ?ignoreScamin / declutter-off no
// longer kill the hatch.
fn writeOsclClause(js: *Stringify, gate: DenomGate, negate: bool) !void {
    switch (gate) {
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

// One SCAMIN gate layer's gating (one per render family in the v2 merged schema). A
// merged layer carries EITHER the live client-driven filter-gate clause (filter_gate,
// the exact ?scaminexact mode), OR the static K/2^zoom zoom-gate (zoom_gate, the default
// self-gating "merged" mode), OR nothing (the plain `.{}` bucket, ?ignoreScamin). A
// non-SCAMIN feature coalesces past every gate (coalesce(scamin,1e12) >= D).
const Bucket = struct {
    zoom_gate: bool = false, // default merged mode: AND the static K/2^zoom SCAMIN gate
    zoom_k: f64 = 0, // zoom_gate: the per-archive display-denominator constant K (scaminGateK)
    filter_gate: bool = false, // scamin-layers.md: the live client-driven SCAMIN clause (?scaminexact)
    cur_denom: f64 = 0, // filter_gate: the current-display-scale denominator literal (client-overwritten)
    suffix: []const u8 = "", // id suffix: "#oscl" (overscaled fill pass) / "" (plain)
    // Overscale (oscl) clause role (S-52 §10.1.10) — see OverscaleRole.
    oscl: OverscaleRole = .none,
};

// Overscale (oscl) clause role a fill/pattern layer plays in the AP(OVERSC01)
// occlusion sandwich (S-52 §10.1.10):
//   .none — no oscl clause (every layer outside the sandwich).
//   .overscaled — [">", coalesce(oscl,0), DENOM]: this cell's data is displayed FINER
//     than its compilation scale (the fills under the hatch + the hatch itself).
//   .at_scale — the ["!", …] negation: at-scale fills, drawn ABOVE the hatch so finer
//     opaque data occludes a coarser cell's hatch.
const OverscaleRole = enum { none, overscaled, at_scale };

// Copy a SCAMIN bucket, adding an overscale role. The overscaled pass also gets an
// "#oscl" id suffix so it stays distinct from the at-scale pass over the same merged
// source-layer + bucket.
fn bucketWithOverscale(a: std.mem.Allocator, bkt: Bucket, role: OverscaleRole) !Bucket {
    var b = bkt;
    b.oscl = role;
    if (role == .overscaled) b.suffix = try std.fmt.allocPrint(a, "{s}#oscl", .{bkt.suffix});
    return b;
}

// coalesce fallback for a feature with no `scamin`: a denominator larger than any real
// display scale, so `scamin >= curDenom` is always true (missing SCAMIN => always shown).
const SCAMIN_COALESCE_MAX = 1000000000000; // 1e12

// The SCAMIN filter clause for a merged gate layer — either the live client-driven
// filter-gate (?scaminexact) or the static zoom-gate (the default merged mode). A
// non-SCAMIN feature coalesces to 1e12 (>= any denominator) and always passes.
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
    // zoom_gate (the only other clause-bearing mode; has_clause guarantees it): static,
    // latitude-correct gate — show a SCAMIN feature only when the display is at least as
    // fine as its 1:N, i.e. scamin >= D(zoom) with D = K/2^zoom. Shares the oscl
    // gate's K (writeSmaxClause/.zoom_k), so the three stay in lockstep.
    try js.write(.{ ">=", .{ "coalesce", .{ "get", "scamin" }, SCAMIN_COALESCE_MAX }, .{ "/", bkt.zoom_k, .{ "^", 2, .{"zoom"} } } });
}

// Write a layer's `filter`. The filter ANDs together (in order): the `base` predicate
// (when has_base), the merged layer's SCAMIN gate clause (filter-gate / zoom-gate), the
// the shared mariner `common` filters (s.common), and a layer-specific `extra` (the
// text-group filter on text layers). All optional; a single part is written bare (no
// "all" wrapper) so a template layer is byte-identical to the pre-mariner output.
// `has_base=false` for layers with no base predicate (fills/patterns/complex/soundings).
fn applyBucket(js: *Stringify, base: anytype, has_base: bool, bkt: Bucket, s: *const SCtx, extra: ?std.json.Value) !void {
    const has_clause = bkt.zoom_gate or bkt.filter_gate;
    const has_oscl = bkt.oscl != .none;
    var n: usize = s.common.len;
    if (has_base) n += 1;
    if (has_clause) n += 1;
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
        if (has_oscl) try writeOsclClause(js, s.oscl_gate, bkt.oscl == .at_scale);
        for (s.common) |c| try js.write(c);
        if (extra) |e| try js.write(e);
        if (wrap) try js.endArray();
    }
}

fn lineLayer(js: *Stringify, s: *const SCtx, sl: []const u8, name: []const u8, filt: anytype, dash: ?[2]i64, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    const id = try std.fmt.bufPrint(&buf, "{s}-{s}{s}", .{ sl, name, bkt.suffix });
    try js.beginObject();
    try layerHead(js, id, "line", sl);
    try applyBucket(js, filt, true, bkt, s, null); // line: scamin line variants band-independent
    try js.objectField("layout");
    try js.beginObject();
    // display_priority as the sole intra-layer z-order axis (mirrors fill-/symbol-sort-key),
    // so a higher-priority line paints over a lower one within a dash class.
    try js.objectField("line-sort-key");
    try js.write(.{ "coalesce", .{ "get", "display_priority" }, 0 });
    try js.endObject();
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
    // Draw point symbols in S-101 DrawingPriority order (SYMBOL_SORT: effective
    // display_priority, higher = on top), not raw tile/source order — so e.g. a light
    // (DrawingPriority 24) draws over an obstruction (12). Sorts ascending (lower drawn
    // first = underneath). display_priority is the SOLE axis; the danger-over-sounding
    // deviation is a sort VALUE (effective 19), not a class tier. z-order "auto" makes
    // the sort-key take effect. Mirrors fill-sort-key on the fill layers. NOTE: this
    // orders WITHIN one layer only; LIGHTS get their own top layer set (see json).
    try js.objectField("symbol-sort-key");
    try js.write(SYMBOL_SORT);
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

// The soundings DrawingPriority — the z-order boundary the point family partitions on.
const SOUNDINGS_PRIO = 18;

// `class in DANGER_CLASSES` — the danger-over-sounding deviation (see DANGER_CLASSES).
const IN_DANGER = .{ "in", .{ "get", "class" }, .{ "literal", DANGER_CLASSES } };

// Effective DrawingPriority = display_priority (the honest catalogue 0..30 tile property,
// NEVER bucketed) offset by the display plane (plane*64 most-significant; +1 OverRadar
// / -1 UnderRadar, inert today -> coalesce 0). This is the SOLE point z-order axis:
// no base/danger/light class TIERS. Used both as the partition threshold and, via
// SYMBOL_SORT, as the intra-layer sort key.
const EFF_PRIO = .{ "+", .{ "*", .{ "coalesce", .{ "get", "display_plane" }, 0 }, 64 }, .{ "coalesce", .{ "get", "display_priority" }, 0 } };

// symbol-sort-key: display_priority is the sole axis, EXCEPT the S-52 danger deviation is
// expressed here as a sort VALUE — a danger (OBSTRN/WRECKS/UWTROC) sorts at an
// effective 19 so it draws just above soundings (18) WITHOUT baking a fake display_priority
// into the tile (the tile keeps the honest 12, so pick/spec stay correct). A base at
// display_priority 30 still sorts above the danger's 19; a base at 5 stays under soundings.
const SYMBOL_SORT = .{ "case", IN_DANGER, 19, EFF_PRIO };

// Which slice of the point family a layer carries. z-order is display_priority ALONE: `base`
// = effective-prio under soundings (< 18), `dangers_only` = effective-prio at/over
// soundings (>= 18) PLUS the danger deviation, `lights_only` = the paramount navaid on
// top. Dangers ride the over-soundings pass via the class-membership OR (their honest
// display_priority 12 is < 18); LIGHTS keep their own top pass so the marker<digit<light
// legibility order survives across SCAMIN buckets (separate layers painted in emit order).
const PointMode = enum { base, dangers_only, lights_only };

// AND the per-alignment rot_north test with the mode's class clause, then emit the
// bucket filter. rot_north_eq / mode are comptime so each switch arm passes a concrete
// tuple type to the generic applyBucket.
fn applyPointBucket(js: *Stringify, s: *const SCtx, bkt: Bucket, comptime rot_north_eq: bool, comptime mode: PointMode) !void {
    const rot = if (rot_north_eq)
        .{ "==", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }
    else
        .{ "!=", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 };
    const not_light = .{ "!=", .{ "get", "class" }, "LIGHTS" };
    switch (mode) {
        // UNDER soundings: effective-prio < 18, and neither a danger (rides the over
        // pass via its class) nor a light (its own top pass).
        .base => try applyBucket(js, .{ "all", rot, .{ "<", EFF_PRIO, SOUNDINGS_PRIO }, not_light, .{ "!", IN_DANGER } }, true, bkt, s, null),
        // OVER soundings: effective-prio >= 18 OR a danger class (the deviation), not a light.
        .dangers_only => try applyBucket(js, .{ "all", rot, .{ "any", .{ ">=", EFF_PRIO, SOUNDINGS_PRIO }, IN_DANGER }, not_light }, true, bkt, s, null),
        // LIGHTS on top (kept a dedicated pass for legibility order).
        .lights_only => try applyBucket(js, .{ "all", rot, .{ "==", .{ "get", "class" }, "LIGHTS" } }, true, bkt, s, null),
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

// Light descriptions carry the rule's own placement — halign=left, valign=middle,
// loff="2,0", i.e. 7.02 mm (two text bodies) RIGHT of the light, clear of the
// flare. MapLibre offsets are ems OF THE TEXT SIZE, not bodies, so "2,0" em would
// overshoot by 20% — emit the mm-exact 1.66em for the characteristics. A light's
// NAME keeps the generic map, and so does everything else.
const IS_LIGHT = .{ "==", .{ "get", "class" }, "LIGHTS" };
const LIGHT_TEXT_OFFSET = .{ "match", .{ "coalesce", .{ "get", "loff" }, "0,0" }, "2,0", .{ "literal", .{ 1.66, 0 } }, TEXT_OFFSET };

/// One text layer for a tier. The tiers are separate LAYERS because MapLibre
/// resolves collisions layer by layer, top down — that is how the important tier
/// gets first claim on the space. Inside a layer there is deliberately NO
/// symbol-sort-key: peers are settled by feature order, the SENC sequence.
fn textLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket, id: []const u8, filt: anytype) !void {
    try js.beginObject();
    try layerHead(js, id, "symbol", sl);
    try applyBucket(js, filt, true, bkt, s, s.text_group); // SCAMIN text band-independent
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("text-field");
    try js.write(.{ "coalesce", .{ "get", "text" }, "" });
    try js.objectField("text-font");
    try js.write(TEXT_FONT);
    try js.objectField("text-size");
    try writeScaled(js, .{ "case", IS_LIGHT, .{ "coalesce", .{ "get", "font_size_px" }, 10 }, .{ "coalesce", .{ "get", "font_size_px" }, 11 } }, s.size_scale);
    try js.objectField("text-anchor");
    try js.write(TEXT_ANCHOR);
    try js.objectField("text-offset");
    try js.write(.{ "case", IS_LIGHT, LIGHT_TEXT_OFFSET, TEXT_OFFSET });
    try js.objectField("text-allow-overlap");
    try js.write(false);
    try js.objectField("text-optional");
    try js.write(true);
    try js.endObject();
    try textPaint(js, s.text_color, s.halo, s.size_scale); // white halo on the bold place-name tier
    try js.endObject();
}

/// White-outline halo width (px) for the bold place-name tier; every other label
/// stays solid (0).
const BOLD_HALO_PX: f64 = 1.25;

fn textLayers(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    var buf2: [96]u8 = undefined;
    // Other text FIRST, important text ABOVE it: the upper layer places first,
    // so IMPORTANT text claims its space before anything else competes for it.
    try textLayer(js, s, sl, bkt, try std.fmt.bufPrint(&buf, "text{s}", .{bkt.suffix}), FILT_TEXT_OTHER);
    try textLayer(js, s, sl, bkt, try std.fmt.bufPrint(&buf2, "text-important{s}", .{bkt.suffix}), FILT_TEXT_IMPORTANT);
}

fn textPaint(js: *Stringify, text_color: std.json.Value, halo: std.json.Value, scale: f64) !void {
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("text-color");
    try js.write(text_color);
    // S-52/S-101 text is solid colour (PortrayalModel.lua:363-365). A halo is a
    // non-spec legibility addition, applied ONLY to the bold place-name tier
    // (font_weight=bold) so major names stay readable over busy soundings; every
    // other label stays solid (width 0).
    try js.objectField("text-halo-color");
    try js.write(halo);
    try js.objectField("text-halo-width");
    try writeScaled(js, .{ "case", .{ "==", .{ "get", "font_weight" }, "bold" }, BOLD_HALO_PX, 0 }, scale);
    try js.objectField("text-halo-blur");
    try js.write(0);
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
    try applyBucket(js, .{}, false, bkt, s, null); // area fills
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
    try applyBucket(js, FILT_NOT_OVERSC, true, bkt, s, null); // area patterns stay band-quilted
    try js.endObject();
}

// The AP(OVERSC01) overscale-indication layer (S-52 §10.1.10):
// every contributing cell's M_COVR coverage polygon (baked into `area_patterns`
// as pattern OVERSC01, tagged `oscl`), shown only while the display is FINER than
// the cell's quantized compilation scale (the oscl clause). Sandwiched between
// the overscaled and at-scale fill passes (json §2), so a finer cell's
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
    try applyBucket(js, FILT_OVERSC, true, .{ .oscl = .overscaled }, s, null); // overscale hatch rides the oscl gate
    try js.endObject();
}

// Linestyle-embedded symbols draw at the engine's SYMBOL_SCALE (0.028346…, see
// scene/linestyle.zig drawComplexLine), not the 0.08 point-symbol default the sprite
// atlas is sized for. Un-tessellated ls_style runs carry no per-symbol `scale` tile
// property, so ICON_SIZE would coalesce to 0.08/0.08 = 1.0 (full atlas size, ~2.8x
// too large); this fixed ratio makes the style-placed symbols match the tessellated
// ones exactly.
const LS_ICON_SIZE: f64 = 0.02834627777338028 / 0.08;

// One decorated layer set for one analysed complex linestyle: a line layer whose
// line-dasharray is the pattern's on/off runs in line-width units, and (sprite
// permitting) a line-placed symbol layer per embedded symbol, spaced one period
// apart. Colour/width ride the run's own color_token/width_px tile properties, so
// the palette resolves exactly like every other line. The tiles carry each run
// UN-tessellated (tagged ls_style); MapLibre walks the dash rhythm + symbol
// placement at render time — the web analogue of replay.zig's drawComplexRun, and
// it scales uniformly with zoom/DPR so spacing and glyph size stay locked together.
fn linestyleLayers(js: *Stringify, s: *const SCtx, ls: std.json.Value, bkt: Bucket, sprite_on: bool) !void {
    if (ls != .object) return;
    var it = ls.object.iterator();
    while (it.next()) |e| {
        const id = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (v != .object) continue;
        const period = jsonNum(v.object.get("period_px")) orelse continue;
        const width = jsonNum(v.object.get("width_px")) orelse 1;
        const w = if (width > 0.05) width else 1.0;
        const dash_v = v.object.get("dash") orelse continue;
        if (dash_v != .array or dash_v.array.items.len == 0) continue;

        var buf: [96]u8 = undefined;
        try js.beginObject();
        try layerHead(js, try std.fmt.bufPrint(&buf, "lines-ls-{s}{s}", .{ id, bkt.suffix }), "line", "lines");
        try applyBucket(js, .{ "==", .{ "get", "ls_style" }, id }, true, bkt, s, null);
        try js.objectField("layout");
        try js.beginObject();
        try js.objectField("line-sort-key");
        try js.write(.{ "coalesce", .{ "get", "display_priority" }, 0 });
        try js.endObject();
        try js.objectField("paint");
        try js.beginObject();
        try js.objectField("line-color");
        try js.write(s.line_color);
        try js.objectField("line-width");
        try writeScaled(js, .{ "coalesce", .{ "get", "width_px" }, 1 }, s.size_scale);
        // MapLibre dasharray units are multiples of the line width.
        try js.objectField("line-dasharray");
        try js.beginArray();
        for (dash_v.array.items) |dv| {
            const px = jsonNumV(dv) orelse 0;
            try js.write(px / w);
        }
        try js.endArray();
        try js.endObject(); // paint
        try js.endObject(); // layer

        if (!sprite_on) continue;
        const syms_v = v.object.get("symbols") orelse continue;
        if (syms_v != .array) continue;
        for (syms_v.array.items, 0..) |sv, si| {
            if (sv != .object) continue;
            const name_v = sv.object.get("n") orelse continue;
            if (name_v != .string) continue;
            try js.beginObject();
            try layerHead(js, try std.fmt.bufPrint(&buf, "lines-ls-{s}-sym{d}{s}", .{ id, si, bkt.suffix }), "symbol", "lines");
            try applyBucket(js, .{ "==", .{ "get", "ls_style" }, id }, true, bkt, s, null);
            try js.objectField("layout");
            try js.beginObject();
            try js.objectField("symbol-placement");
            try js.write("line");
            try js.objectField("symbol-spacing");
            try js.write(@max(period * s.size_scale, 1.0));
            try js.objectField("icon-image");
            try js.write(name_v.string);
            try js.objectField("icon-size");
            try writeScaled(js, LS_ICON_SIZE, s.size_scale);
            try js.objectField("icon-rotation-alignment");
            try js.write("map");
            try js.objectField("icon-allow-overlap");
            try js.write(true);
            try js.objectField("icon-ignore-placement");
            try js.write(true);
            try js.endObject(); // layout
            try js.endObject(); // layer
        }
    }
}

fn jsonNum(v: ?std.json.Value) ?f64 {
    return jsonNumV(v orelse return null);
}

fn jsonNumV(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// One DEPCNT contour value-label layer (glyphs required) for a source-layer + bucket.
fn contourLabelLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "contour-labels-{s}{s}", .{ sl, bkt.suffix }), "symbol", sl);
    try applyBucket(js, .{ "has", "valdco" }, true, bkt, s, null); // contour value labels (scamin text) band-independent
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

// Soundings are SYMBOLS: the Presentation Library draws a sounding as symbol
// glyphs so it stays legible and correctly located, and every symbol must be
// drawn — S-52 defines suppression only for coincident lines and area
// boundaries. So a sounding layer never culls (icon-allow-overlap) and never
// claims space from the labels above it (icon-ignore-placement): text is drawn
// last, on top. The native surfaces hold the same line — nothing but text ever
// enters the collision pool (render/declutter.zig).
//
// The soundings source-layer still splits into two style layers, but on PAINT
// ORDER, not collision: a DANGER depth (a wreck/obstruction/rock sounding) is
// part of its S-52 symbol — WRECKS05/OBSTRN07 draw the marker, then the digits
// on top — and DANGER01/02 have an OPAQUE interior, so those digits must be
// emitted ABOVE the danger markers or the oval hides them. Spot soundings sit
// below the markers, where they belong.
const FILT_SPOT_SND = .{ "==", .{ "coalesce", .{ "get", "class" }, "SOUNDG" }, "SOUNDG" };
const FILT_DANGER_SND = .{ "!=", .{ "coalesce", .{ "get", "class" }, "SOUNDG" }, "SOUNDG" };

fn soundingsLayer(js: *Stringify, s: *const SCtx, bkt: Bucket, id: []const u8, filt: anytype) !void {
    try js.beginObject();
    try layerHead(js, id, "symbol", "soundings");
    try applyBucket(js, filt, true, bkt, s, null); // soundings (band-quilted)
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
pub fn json(alloc: std.mem.Allocator, opts: Options) ![]u8 {
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

    // The SINGLE band-independent SCAMIN gate that rides every merged source-layer (one
    // per render family). Exactly one mode, no per-value bucket layers:
    //   ignore_scamin -> a plain (ungated) gate (§2 debug toggle shows everything).
    //   filter_gate   -> the live client-driven clause (scamin-layers.md, ?scaminexact):
    //                    the client rewrites curDenom via setFilter at ladder crossings.
    //   default       -> the static K/2^zoom zoom-gate (the "merged" mode): one
    //                    self-gating zoom expression, no client setFilter, no reload.
    // A non-SCAMIN feature coalesces past the gate (coalesce(scamin,1e12) >= D). The
    // `opts.scamin` manifest no longer produces per-value layers — it only feeds the
    // TileJSON ladder (served separately) for the filter-gate client's crossings.
    var barena = std.heap.ArenaAllocator.init(alloc);
    defer barena.deinit();
    const ba = barena.allocator();
    // Analysed complex-linestyle patterns for the ls_style decoration layers (kept in
    // the bucket arena; malformed input just drops the decoration — ls_style runs then
    // fall through to lines-solid as plain strokes rather than aborting the style).
    const ls_parsed: ?std.json.Value = if (opts.linestyles_json) |lsj| blk: {
        const pv = std.json.parseFromSliceLeaky(std.json.Value, ba, lsj, .{}) catch break :blk null;
        break :blk if (pv == .object) pv else null;
    } else null;
    const gate: Bucket = if (opts.ignore_scamin)
        .{}
    else if (opts.scamin_filter_gate)
        .{ .filter_gate = true, .cur_denom = opts.scamin_cur_denom }
    else
        .{ .zoom_gate = true, .zoom_k = scaminGateK(opts.scamin_lat) };
    const scamin_buckets: []const Bucket = &.{gate};

    // The single style builder: resolve every mariner-aware colour / icon / display
    // filter ONCE through the mariner builders
    // template-patch pass). scheme always comes from opts.scheme (the bundle emits one
    // style per scheme); a null opts.mariner is a TEMPLATE — default mariner for the
    // colour/layout exprs, but NO display filters baked in (the client gates live).
    const scheme_e: mariner.Scheme = if (std.mem.eql(u8, opts.scheme, "night"))
        .night
    else if (std.mem.eql(u8, opts.scheme, "dusk")) .dusk else .day;
    var m: mariner.Settings = opts.mariner orelse .{};
    m.scheme = scheme_e;
    const filters_on = opts.mariner != null;
    const b = mariner.B{ .a = ba };
    const s = SCtx{
        .fill_color = try mariner.areasFillColor(b, &palette, &m),
        .line_color = try mariner.lineColor(b, &palette),
        .text_color = try mariner.textColor(b, m.scheme, &palette),
        .halo = mariner.textHaloColor(b, m.scheme),
        .contour_color = try mariner.contourLabelColor(b, m.scheme, &palette),
        .sound_img = try mariner.soundingsIconImage(b, &m),
        .point_img = try mariner.pointSymbolImage(b, &m),
        .contour_field = try mariner.contourLabelField(b, &m),
        .common = if (filters_on) try mariner.commonChartFilters(ba, &m, opts.enabled_bands, opts.now_unix) else &.{},
        .text_group = if (filters_on) try mariner.textGroupFilter(b, &m) else null,
        .size_scale = opts.size_scale,
        // Overscale gate mode follows the SCAMIN gating mode: the filter-gate
        // literal when the live client drives it (same injected DENOM), else the
        // per-archive K/2^zoom denominator (physical at the archive latitude,
        // scaminGateK — one constant for both the manifest bucket path and the
        // no-manifest fallback). Deliberately NOT disabled by ?ignoreScamin —
        // the overscale indication is independent of decluttering (spec §5).
        .oscl_gate = if (opts.scamin_filter_gate)
            // The boot/diff placeholder denominator is 0 — show-all for the
            // scamin clause (scamin >= 0) but show-NOTHING inverted for oscl.
            // Map the placeholder to hide-the-hatch (1e12); the client rewrites
            // the clause to the live denominator regardless.
            .{ .denom = if (opts.scamin_cur_denom == 0) 1e12 else opts.scamin_cur_denom }
        else
            .{ .zoom_k = scaminGateK(opts.scamin_lat) },
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

    // 2. area fills over the merged `areas` layer (base + folded SCAMIN fills), ONE
    // gated layer per SCAMIN bucket. With scale gating active (and a sprite to draw
    // the hatch) each bucket's fill splits around the AP(OVERSC01) overscale layer:
    // overscaled cells' fills (#oscl) UNDER the hatch, at-scale fills ABOVE it — so
    // finer opaque DEPARE/LNDARE occlude a coarser cell's hatch and it survives only
    // on coarse-only patches (S-52 §10.1.10). ignore_scamin (gate
    // off) or no sprite keeps a single plain fill layer per bucket.
    if (sprite_on) {
        for (scamin_buckets) |bkt| try fillLayer(js, &s, "areas", try bucketWithOverscale(ba, bkt, .overscaled));
        try overscaleLayer(js, &s);
        for (scamin_buckets) |bkt| try fillLayer(js, &s, "areas", try bucketWithOverscale(ba, bkt, .at_scale));
    } else {
        for (scamin_buckets) |bkt| try fillLayer(js, &s, "areas", bkt);
    }

    // 3. area fill patterns over the merged `area_patterns` layer (sprite required).
    if (sprite_on) {
        for (scamin_buckets) |bkt| try patternLayer(js, &s, "area_patterns", bkt);
    }

    // 4. lines: solid/dashed/dotted over the merged `lines` layer, one gated set per
    // SCAMIN bucket. Light sector figures fold into `lines` too (scene.zig endScene),
    // so there is NO sector_lines source-layer to draw.
    for (scamin_buckets) |bkt| try lineLayers(js, &s, "lines", bkt);

    // 4b. complex (symbolised) linestyles: the tiles carry each run UN-tessellated,
    // tagged ls_style + color_token + width_px (scene.zig storeComplexRun), and
    // lines-solid excludes ls_style so nothing double-draws. One dasharray line layer
    // per analysed LineStyles id decorates the runs, plus a line-placed symbol layer
    // per embedded symbol when a sprite is wired — MapLibre walks them at render time
    // (the OpenCPN plugin re-walks the same runs natively via replay.zig).
    if (ls_parsed) |lsv| {
        for (scamin_buckets) |bkt| try linestyleLayers(js, &s, lsv, bkt, sprite_on);
    }

    // 5. point symbols + soundings (sprite required) over the merged `point_symbols`
    // layer, stacked by z-order — display_priority is the SOLE axis, partitioned at the
    // soundings boundary (18):
    //   under-soundings symbols (effective-prio < 18) UNDER soundings,
    //   then soundings, then over-soundings symbols (effective-prio >= 18, plus the
    //   DANGER markers at effective 19 so a hazard stays on top of its own depth
    //   number), then LIGHTS on top. A base at display_priority 30 lands in the over pass and
    //   sorts above a danger's 19; a base at 5 stays under soundings. One gated layer
    //   set per SCAMIN bucket rides each pass.
    if (sprite_on) {
        for (scamin_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols", bkt, .base);
        for (scamin_buckets) |bkt| {
            var sbuf: [96]u8 = undefined;
            try soundingsLayer(js, &s, bkt, try std.fmt.bufPrint(&sbuf, "soundings{s}", .{bkt.suffix}), FILT_SPOT_SND);
        }
        // Over-soundings pass: high-priority symbols + the danger deviation (see PointMode).
        for (scamin_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols", bkt, .dangers_only);
        // Danger depths ABOVE the danger markers (see the soundings class split):
        // below the opaque DANGER01/02 ovals the depths would be invisible.
        for (scamin_buckets) |bkt| {
            var dbuf: [96]u8 = undefined;
            try soundingsLayer(js, &s, bkt, try std.fmt.bufPrint(&dbuf, "danger_soundings{s}", .{bkt.suffix}), FILT_DANGER_SND);
        }
        // LIGHTS on top: emitted after every other point symbol so a light always draws
        // over a same-priority bridge that lives in a different scamin bucket layer.
        for (scamin_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols", bkt, .lights_only);
    }

    // 8. contour value labels (DEPCNT VALDCO) over the merged `lines` layer — text,
    // needs glyphs. Emitted AFTER the point symbols + soundings (oracle layer order:
    // point_symbols, soundings, contour-labels, text), so a depth-contour value reads
    // on top of the symbol group rather than being hidden under it.
    if (glyphs_on) {
        for (scamin_buckets) |bkt| try contourLabelLayer(js, &s, "lines", bkt);
    }

    // 9. text labels over the merged `text` layer — need an SDF glyph source.
    if (glyphs_on) {
        for (scamin_buckets) |bkt| try textLayers(js, &s, "text", bkt);
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
    // Carry the analysed linestyles in the style itself, so a mariner rebuild from this
    // style-as-template (buildFromTemplateScamin) re-emits the ls_style decoration layers.
    if (ls_parsed) |lsv| {
        try js.objectField("metadata");
        try js.beginObject();
        try js.objectField("tile57:linestyles");
        try js.write(lsv);
        try js.endObject();
    }
    try js.endObject();
    return aw.toOwnedSlice();
}

/// Build a full MapLibre style from a base template + mariner settings — the single
/// builder behind the C-ABI / WASM / parity callers (replaces the mariner builders's
/// template-patch pass). The passed template carries ONLY the host's source config
/// (sprite / glyphs / chart tiles+zoom); this lifts that out and regenerates every
/// layer via json with the mariner baked in. Signature mirrors the retired
/// buildStyle so callers are a one-line change. A bad template or unusable colortables
/// returns the template bytes unchanged (alloc-owned dup), as buildStyle did.
pub fn buildFromTemplate(
    alloc: std.mem.Allocator,
    template_json: []const u8,
    m: *const mariner.Settings,
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
/// host-canonical-backend.md §"Still needed" #1 — the `tile57_style_build` runtime
/// path otherwise leaves every `_scamin` layer ungated). Empty `scamin` == the
/// plain buildFromTemplate behaviour.
pub fn buildFromTemplateScamin(
    alloc: std.mem.Allocator,
    template_json: []const u8,
    m: *const mariner.Settings,
    colortables_json: []const u8,
    enabled_bands: ?[]const i32,
    now_unix: i64,
    scamin: []const u32,
    scamin_lat: f64,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, template_json, .{}) catch
        return alloc.dupe(u8, template_json);
    defer parsed.deinit();
    // Re-serialised "tile57:linestyles" carrier lifted from the template (see json's
    // metadata block); alloc-owned so it outlives `parsed` through the json() call below.
    var lifted_ls: ?[]u8 = null;
    defer if (lifted_ls) |b| alloc.free(b);
    var opts = Options{
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
        if (root.get("metadata")) |mv| {
            if (mv == .object) if (mv.object.get("tile57:linestyles")) |lv| {
                lifted_ls = std.json.Stringify.valueAlloc(alloc, lv, .{}) catch null;
                opts.linestyles_json = lifted_ls;
            };
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
                    if (c.get("encoding")) |e| { // MLT hint rides the rebuild (tile57_style_build / style_diff)
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
    return json(alloc, opts) catch alloc.dupe(u8, template_json);
}

// ---- style diff --------------------------------------------
// Compute the minimal MapLibre style-mutation ops that turn one built style into
// another. The engine knows both styles come from json (same layer set +
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
/// built-in equal; both operands here come from the same json generator, so
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
/// serialized style `old_json` into `new_json`. Both must be json output (same
/// template/colortables/bands/scamin inputs, differing only in mariner). Returns
/// allocator-owned bytes: `"[]"` when nothing differs; one op per differing
/// `filter` / `paint.*` / `layout.*` key; `[{"op":"rebuild"}]` when the two styles
/// carry a different SET of layer ids (the host then falls back to a full setStyle).
pub fn diff(alloc: std.mem.Allocator, old_json: []const u8, new_json: []const u8) ![]u8 {
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

test "json: valid JSON, expected layers, palette-resolved colour" {
    const ct =
        \\{"day":{"DEPDW":"#c9edff","CHGRD":"#4c5b63","CHBLK":"#000000"},"dusk":{},"night":{"DEPDW":"#0a141e"}}
    ;
    const out = try json(std.testing.allocator, .{
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

test "json: ignore_scamin drops SCAMIN gating (no buckets, no zoom-gate)" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 30000, 90000 };
    const base = Options{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
    };

    // Manifest present, gating ON -> the merged zoom-gate rides every layer (per-value
    // #sm buckets are retired — a manifest never buckets now).
    const gated = try json(a, base);
    defer a.free(gated);
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],[\"/\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "#sm") == null);

    // Manifest present, ignore_scamin -> no buckets at all.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try json(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "#sm") == null);

    // No manifest, gating ON -> the static K/2^zoom SCAMIN gate is present (the
    // scamin>=D(zoom) fallback shape, no per-value buckets).
    var nomanifest = base;
    nomanifest.scamin = &.{};
    const out_fb = try json(a, nomanifest);
    defer a.free(out_fb);
    try std.testing.expect(std.mem.indexOf(u8, out_fb, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],[\"/\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_fb, "#sm") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_fb, "log2") == null); // old form retired

    // No manifest + ignore_scamin -> even the static gate is gone.
    var nm_ign = nomanifest;
    nm_ign.ignore_scamin = true;
    const out_nm_ign = try json(a, nm_ign);
    defer a.free(out_nm_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_nm_ign, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],[\"/\",") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_nm_ign, "#sm") == null);
}

fn layerIndexById(layers: []std.json.Value, id: []const u8) ?usize {
    for (layers, 0..) |l, i| if (std.mem.eql(u8, l.object.get("id").?.string, id)) return i;
    return null;
}

test "json: point z-order = display_priority alone (threshold partition + danger sort-value)" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const out = try json(a, .{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .source_tiles = "tile57://{z}/{x}/{y}",
    });
    defer a.free(out);

    // symbol-sort-key = display_priority (via plane*64 + display_priority), with dangers mapped to an
    // effective 19 as a sort VALUE — NOT a baked tile display_priority, NOT a class tier.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"symbol-sort-key\":[\"case\",[\"in\",[\"get\",\"class\"],[\"literal\",[\"OBSTRN\",\"WRECKS\",\"UWTROC\"]]],19,[\"+\",[\"*\",[\"coalesce\",[\"get\",\"display_plane\"],0],64],[\"coalesce\",[\"get\",\"display_priority\"],0]]]") != null);
    // The under-soundings pass filters on effective-prio < 18 (the threshold), not class.
    try std.testing.expect(std.mem.indexOf(u8, out, "[\"<\",[\"+\",[\"*\",[\"coalesce\",[\"get\",\"display_plane\"],0],64],[\"coalesce\",[\"get\",\"display_priority\"],0]],18]") != null);
    // The over-soundings pass = effective-prio >= 18 OR a danger class.
    try std.testing.expect(std.mem.indexOf(u8, out, "[\"any\",[\">=\",[\"+\",[\"*\",[\"coalesce\",[\"get\",\"display_plane\"],0],64],[\"coalesce\",[\"get\",\"display_priority\"],0]],18],[\"in\",[\"get\",\"class\"],[\"literal\",[\"OBSTRN\",\"WRECKS\",\"UWTROC\"]]]]") != null);
    // Lines gained a display_priority sort key.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line-sort-key\":[\"coalesce\",[\"get\",\"display_priority\"],0]") != null);

    // z-order (emit order): under-symbols < soundings < over-symbols < lights. So a
    // base at display_priority 30 (over pass, sorts 30) draws above a danger (over pass, sorts
    // 19) above soundings (18) above a base at 5 (under pass). Layer array position +
    // sort key together realise display_priority as the sole axis.
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    const layers = parsed.value.object.get("layers").?.array.items;
    const i_under = layerIndexById(layers, "point_symbols").?;
    const i_snd = layerIndexById(layers, "soundings").?;
    const i_over = layerIndexById(layers, "point_symbols-dgr").?;
    const i_lt = layerIndexById(layers, "point_symbols-lt").?;
    try std.testing.expect(i_under < i_snd);
    try std.testing.expect(i_snd < i_over);
    try std.testing.expect(i_over < i_lt);
}

test "json: size_scale wraps icon/line/text sizes in a multiplier" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const base = Options{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
    };

    // Default scale 1.0: sizes written verbatim, no multiplier wrapper.
    const def = try json(a, base);
    defer a.free(def);
    try std.testing.expect(std.mem.indexOf(u8, def, "\"line-width\":[\"coalesce\",[\"get\",\"width_px\"],1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, def, "\"line-width\":[\"*\"") == null);

    // Scaled: icon-size / line-width / text-size each wrap in ["*", scale, expr].
    var scaled = base;
    scaled.size_scale = 2.0;
    const sc = try json(a, scaled);
    defer a.free(sc);
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"line-width\":[\"*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"icon-size\":[\"*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"text-size\":[\"*\"") != null);
    // The unscaled line-width form is gone.
    try std.testing.expect(std.mem.indexOf(u8, sc, "\"line-width\":[\"coalesce\"") == null);
}

// ---- single-builder (buildFromTemplate) tests — ported from the retired
//      the mariner builders tests, now exercising the one json path. -------
const cs_template =
    \\{"version":8,"sources":{"chart":{"type":"vector","url":"pmtiles://x"}},"sprite":"x","glyphs":"x","layers":[]}
;
const cs_ct =
    \\{"day":{"DEPDW":"#c9edff","DEPMD":"#9bc4e0","DEPMS":"#6aa5cf","DEPVS":"#3a86bf","DEPIT":"#bfe6ff","CHGRD":"#5a5a44","CHBLK":"#000000"},"dusk":{"DEPDW":"#0a141e"},"night":{"DEPDW":"#050a0f"}}
;

test "buildFromTemplate: defaults bake SEABED fill + category/M_QUAL filter (single-pass)" {
    const a = std.testing.allocator;
    const m = mariner.Settings{};
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
    const m = mariner.Settings{ .scheme = .night };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#aab7bf") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rgba(0,0,0,0.85)") != null);
}

test "buildFromTemplate: feet depth unit -> contour label uses M_TO_FT" {
    const a = std.testing.allocator;
    const m = mariner.Settings{ .depth_unit = .feet };
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
    const m = mariner.Settings{};
    const bands = [_]i32{ 2, 3 };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, &bands, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"band\"") != null);
}

test "buildFromTemplate: date resolution (pinned + today + off)" {
    const a = std.testing.allocator;
    const m1 = mariner.Settings{ .date_view = "20240115" };
    const o1 = try buildFromTemplate(a, cs_template, &m1, cs_ct, null, 1700000000);
    defer a.free(o1);
    try std.testing.expect(std.mem.indexOf(u8, o1, "20240115") != null);
    try std.testing.expect(std.mem.indexOf(u8, o1, "0115") != null);

    const m2 = mariner.Settings{};
    const o2 = try buildFromTemplate(a, cs_template, &m2, cs_ct, null, 1700000000);
    defer a.free(o2);
    try std.testing.expect(std.mem.indexOf(u8, o2, "20231114") != null);

    const m3 = mariner.Settings{ .date_dependent = false };
    const o3 = try buildFromTemplate(a, cs_template, &m3, cs_ct, null, 1700000000);
    defer a.free(o3);
    try std.testing.expect(std.mem.indexOf(u8, o3, "date_recurring") == null);
}

test "buildFromTemplate: viewing-group deny-list filter gates by vg" {
    const a = std.testing.allocator;
    // A non-empty off-set hides the listed groups -> the style references the `vg`
    // property and the off ids, negated (deny-list).
    const off = [_]i32{ 26070, 27070 };
    const m = mariner.Settings{ .viewing_groups_off = &off };
    const out = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"vg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "26070") != null);
    // The filter is a deny-list: ["!",["in",...]] so the off groups are EXCLUDED.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"in\"") != null);
    // null off-set -> no vg filter at all.
    const m2 = mariner.Settings{};
    const o2 = try buildFromTemplate(a, cs_template, &m2, cs_ct, null, 1700000000);
    defer a.free(o2);
    try std.testing.expect(std.mem.indexOf(u8, o2, "\"vg\"") == null);
    // empty off-set -> also no filter (show all).
    const empty = [_]i32{};
    const m3 = mariner.Settings{ .viewing_groups_off = &empty };
    const o3 = try buildFromTemplate(a, cs_template, &m3, cs_ct, null, 1700000000);
    defer a.free(o3);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"vg\"") == null);
}

test "buildFromTemplateScamin: a manifest no longer buckets — the merged zoom-gate rides every layer" {
    const a = std.testing.allocator;
    const m = mariner.Settings{};
    // No manifest -> the static K/2^zoom SCAMIN zoom-gate, no #sm buckets.
    const plain = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],[\"/\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "#sm") == null);
    // With a manifest -> STILL the merged zoom-gate (per-value buckets retired): the
    // manifest no longer produces #sm layers, only the TileJSON ladder (served apart).
    const scamin = [_]u32{ 89999, 259999 };
    const bucketed = try buildFromTemplateScamin(a, cs_template, &m, cs_ct, null, 1700000000, &scamin, 38.0);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],[\"/\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "#sm") == null);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "log2") == null);
}

// ---- smax removal -----------------------------------------------------------

test "json: no smax clause in any gating mode (band-handoff gate retired)" {
    // The coverage-clipped composite owns cross-band occlusion geometrically, so
    // no layer carries a band-handoff smax clause in any gating mode, and the
    // overscale gate survives ?ignoreScamin (the two gates are decoupled).
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const base = Options{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
    };

    var gated_opts = base;
    gated_opts.scamin_filter_gate = true;
    gated_opts.scamin_cur_denom = 50000;
    const gated = try json(a, gated_opts);
    defer a.free(gated);
    try std.testing.expect(std.mem.indexOf(u8, gated, "smax") == null);
    // The scamin clause still gates (same injected DENOM literal).
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],50000]") != null);

    const bucketed = try json(a, base);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "smax") == null);

    var nm = base;
    nm.scamin = &.{};
    const fb = try json(a, nm);
    defer a.free(fb);
    try std.testing.expect(std.mem.indexOf(u8, fb, "smax") == null);

    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try json(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "smax") == null);
    // ignoreScamin no longer kills the overscale indication (spec §5).
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "oscl") != null);
}

// ---- overscale (oscl) gate tests -------------------------------------------

test "json: the overscale oscl clause has the EXACT client-matched shape" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const gated = try json(a, .{
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
    // (overscale contract) to rewrite DENOM beside the scamin clause. The
    // hatch + the under-hatch fill pass carry the positive clause; the at-scale
    // fill pass carries its ["!", …] negation (occlusion sandwich).
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],50000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"!\",[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],50000]]") != null);
    // Generic pattern layers exclude the hatch (it rides its own gated layer).
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"!=\",[\"get\",\"pattern_name\"],\"OVERSC01\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "[\"==\",[\"get\",\"pattern_name\"],\"OVERSC01\"]") != null);

    // The boot/diff PLACEHOLDER (cur_denom 0) maps to 1e12 — hide the hatch and
    // keep every fill in the at-scale pass (today's rendering) until the client
    // injects the live denominator (the placeholder lesson, cb91c4d).
    const boot = try json(a, .{
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

test "json: showOverscale=false hides the hatch layer; ignoreScamin keeps it (decoupled)" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const base = Options{
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
    const hidden = try json(a, off);
    defer a.free(hidden);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "\"id\":\"overscale\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "{\"visibility\":\"none\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "\"oscl\"") != null);

    // Bucket mode derives the oscl DENOM from zoom (same K as the scamin clause).
    const bucketed = try json(a, base);
    defer a.free(bucketed);
    try std.testing.expect(std.mem.indexOf(u8, bucketed, "[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],[\"/\",") != null);

    // ignore_scamin: the overscale indication is DECOUPLED from decluttering
    // (spec §5) — the oscl clauses + hatch layer survive the debug toggle.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try json(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "oscl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "\"id\":\"overscale\",") != null);

    // No sprite -> nothing can draw the hatch: single plain fill layer, no sandwich.
    var nospr = base;
    nospr.sprite = null;
    const out_ns = try json(a, nospr);
    defer a.free(out_ns);
    try std.testing.expect(std.mem.indexOf(u8, out_ns, "oscl") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_ns, "\"id\":\"overscale\",") == null);
}

// ---- diff tests ------------------------------------

test "diff: filter + paint + layout changes emit precise, scoped ops" {
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
    const ops = try diff(a, old_j, new_j);
    defer a.free(ops);
    // areas: filter, paint fill-color, layout visibility all changed -> one op each.
    try std.testing.expect(std.mem.indexOf(u8, ops, "{\"op\":\"setFilter\",\"layer\":\"areas\",\"value\":[\"==\",\"x\",2]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "{\"op\":\"setPaintProperty\",\"layer\":\"areas\",\"property\":\"fill-color\",\"value\":\"#222\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "{\"op\":\"setLayoutProperty\",\"layer\":\"areas\",\"property\":\"visibility\",\"value\":\"none\"}") != null);
    // text is byte-identical -> it must not appear in any op.
    try std.testing.expect(std.mem.indexOf(u8, ops, "\"layer\":\"text\"") == null);
}

test "diff: a removed paint key emits value:null" {
    const a = std.testing.allocator;
    const old_j = "{\"layers\":[{\"id\":\"l\",\"paint\":{\"fill-color\":\"#111\",\"fill-opacity\":0.5}}]}";
    const new_j = "{\"layers\":[{\"id\":\"l\",\"paint\":{\"fill-color\":\"#111\"}}]}";
    const ops = try diff(a, old_j, new_j);
    defer a.free(ops);
    try std.testing.expectEqualStrings(
        "[{\"op\":\"setPaintProperty\",\"layer\":\"l\",\"property\":\"fill-opacity\",\"value\":null}]",
        ops,
    );
}

test "diff: a differing layer-id set -> rebuild" {
    const a = std.testing.allocator;
    // id renamed
    const r1 = try diff(a, "{\"layers\":[{\"id\":\"x\"}]}", "{\"layers\":[{\"id\":\"y\"}]}");
    defer a.free(r1);
    try std.testing.expectEqualStrings(rebuild_ops, r1);
    // count differs
    const r2 = try diff(a, "{\"layers\":[{\"id\":\"x\"}]}", "{\"layers\":[{\"id\":\"x\"},{\"id\":\"z\"}]}");
    defer a.free(r2);
    try std.testing.expectEqualStrings(rebuild_ops, r2);
}

test "diff: same mariner -> [] (no ops)" {
    const a = std.testing.allocator;
    const m = mariner.Settings{};
    const s1 = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(s1);
    const s2 = try buildFromTemplate(a, cs_template, &m, cs_ct, null, 1700000000);
    defer a.free(s2);
    const ops = try diff(a, s1, s2);
    defer a.free(ops);
    try std.testing.expectEqualStrings("[]", ops);
}

test "diff: display_other flip emits only setFilter ops" {
    const a = std.testing.allocator;
    const base = mariner.Settings{};
    const other = mariner.Settings{ .display_other = true };
    const s1 = try buildFromTemplate(a, cs_template, &base, cs_ct, null, 1700000000);
    defer a.free(s1);
    const s2 = try buildFromTemplate(a, cs_template, &other, cs_ct, null, 1700000000);
    defer a.free(s2);
    const ops = try diff(a, s1, s2);
    defer a.free(ops);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setFilter") != null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setPaintProperty") == null);
    try std.testing.expect(std.mem.indexOf(u8, ops, "setLayoutProperty") == null);
    try std.testing.expect(!std.mem.eql(u8, ops, "[]"));
}

test "diff: day vs night emits setPaintProperty colour ops, no filter change" {
    const a = std.testing.allocator;
    const day = mariner.Settings{ .scheme = .day };
    const night = mariner.Settings{ .scheme = .night };
    const s1 = try buildFromTemplate(a, cs_template, &day, cs_ct, null, 1700000000);
    defer a.free(s1);
    const s2 = try buildFromTemplate(a, cs_template, &night, cs_ct, null, 1700000000);
    defer a.free(s2);
    const ops = try diff(a, s1, s2);
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

test "json: both merged modes (zoom-gate default, filter-gate exact) give one layer per render-type — no per-value buckets" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 3000, 8000, 12000, 22000, 45000, 90000, 180000 }; // 7 denominators
    const base = Options{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
    };

    // Default (a manifest present): the merged zoom-gate — ONE self-gating layer per
    // family, NO per-value #sm buckets, NO native minzoom.
    const merged = try json(a, base);
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "#sm") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "minzoom") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],[\"/\",") != null);

    // Filter-gate (?scaminexact): one live-clause layer per family — the SAME layer
    // set, with the client-driven curDenom clause instead of the zoom expression.
    var fg = base;
    fg.scamin_filter_gate = true;
    const gated = try json(a, fg);
    defer a.free(gated);
    try std.testing.expect(std.mem.indexOf(u8, gated, "#sm") == null); // no per-value buckets
    try std.testing.expect(std.mem.indexOf(u8, gated, "minzoom") == null); // no native minzoom gating
    try std.testing.expect(std.mem.indexOf(u8, gated, "1000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated, "\"scamin\"") != null);

    // Both merged modes collapse to the SAME one-layer-per-family set — no per-value
    // explosion in either (the 7 denominators add zero layers).
    try std.testing.expectEqual(try layerCount(a, merged), try layerCount(a, gated));
}

test "json: scamin_filter_gate honors the cur_denom literal + ignore_scamin drops the clause" {
    const a = std.testing.allocator;
    const ct =
        \\{"day":{"DEPDW":"#c9edff"},"dusk":{},"night":{}}
    ;
    const sm = [_]u32{ 45000, 90000 };
    const base = Options{
        .scheme = "day",
        .colortables_json = ct,
        .sprite = "sprite",
        .glyphs = "glyphs/{fontstack}/{range}.pbf",
        .scamin = &sm,
        .scamin_lat = 38.0,
        .scamin_filter_gate = true,
        .scamin_cur_denom = 50000,
    };
    const gated = try json(a, base);
    defer a.free(gated);
    // The baked default denominator appears in the clause.
    try std.testing.expect(std.mem.indexOf(u8, gated, "50000") != null);

    // ignore_scamin overrides filter_gate: single plain layer, no SCAMIN clause at all.
    var ign = base;
    ign.ignore_scamin = true;
    const out_ign = try json(a, ign);
    defer a.free(out_ign);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "1000000000000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_ign, "#sm") == null);
}
