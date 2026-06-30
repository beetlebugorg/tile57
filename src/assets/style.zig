//! style.zig — MapLibre GL style.json generation for the chart bundle. Resolves
//! each S-52 colour token to hex for a palette and emits the fill / line / symbol
//! / text layer set. Ported from the chartplotter web frontend's s52-style.mjs /
//! chart-style.mjs (and the now-removed style/build_style.py, kept in git history;
//! it was verified layer-for-layer identical during the port). The sole style
//! generator now. Part of the `assets` module. See ../../../specs/bundle-bake.md.
//!
//! MapLibre expressions are written as Zig comptime tuples — `.{ "get", "drval1" }`
//! serialises to `["get","drval1"]` — through std.json's Stringify write-stream,
//! which owns all escaping, comma, and brace handling. No raw JSON in the source;
//! the only hand-rolled fragment is the variable-length colour `match` (the palette
//! is runtime data), and that goes through the same stream.

const std = @import("std");
const Stringify = std.json.Stringify;
const chartstyle = @import("chartstyle");

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

// S-52 DrawingPriority fill order: draw_prio*1000 - drval1.
const FILL_SORT = .{ "-", .{ "*", .{ "coalesce", .{ "get", "draw_prio" }, 0 }, 1000 }, .{ "coalesce", .{ "get", "drval1" }, 0 } };

const FILT_SOLID = .{ "==", .{ "coalesce", .{ "get", "dash" }, "solid" }, "solid" };
const FILT_DASHED = .{ "==", .{ "get", "dash" }, "dashed" };
const FILT_DOTTED = .{ "==", .{ "get", "dash" }, "dotted" };

const ICON_SIZE = .{ "/", .{ "coalesce", .{ "get", "scale" }, 0.08 }, 0.08 };

const VROW = .{ "match", .{ "coalesce", .{ "get", "valign" }, "middle" }, "top", "top", "bottom", "bottom", "center" };
const TEXT_ANCHOR = .{
    "match", .{ "concat", VROW, "|", .{ "coalesce", .{ "get", "halign" }, "center" } },
    "center|left",   "left",       "center|right",  "right",        "center|center", "center",
    "top|center",    "top",        "bottom|center", "bottom",
    "top|left",      "top-left",   "top|right",     "top-right",
    "bottom|left",   "bottom-left", "bottom|right", "bottom-right", "center",
};
const TEXT_SORT_KEY = .{ "-", .{ "match", .{ "coalesce", .{ "get", "tgrp" }, -1 }, 11, 0, .{ 21, 26, 29 }, 100, 23, 50, 150 }, .{ "coalesce", .{ "get", "font_size_px" }, 10 } };

pub const StyleOpts = struct {
    scheme: []const u8, // "day" | "dusk" | "night"
    colortables_json: []const u8,
    source_tiles: ?[]const u8 = null, // tiles template; else pmtiles_url
    pmtiles_url: []const u8 = "pmtiles://tiles/chart.pmtiles",
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
};

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
    minzoom: ?f64 = null,
    suffix: []const u8 = "", // id suffix: "#sm<v>" / "#no" / "" (plain)
};

// The scamin filter clause for a bucket: `["==",["get","scamin"],v]` (per-value) or
// `["any", ["!",["has","scamin"]], ["in",["get","scamin"],["literal",[lows…]]]]` (#no).
fn writeScaminClause(js: *Stringify, bkt: Bucket) !void {
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
// zoom-gate), the shared mariner `common` filters, and a layer-specific `extra` (the
// text-group filter on text layers). All optional; a single part is written bare (no
// "all" wrapper) so a template layer is byte-identical to the pre-mariner output.
// `has_base=false` for layers with no base predicate (fills/patterns/complex/soundings).
fn applyBucket(js: *Stringify, base: anytype, has_base: bool, bkt: Bucket, common: []const std.json.Value, extra: ?std.json.Value) !void {
    const has_clause = bkt.sm != null or bkt.no_lows != null or bkt.zoom_gate;
    var n: usize = common.len;
    if (has_base) n += 1;
    if (has_clause) n += 1;
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
        for (common) |c| try js.write(c);
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
    try applyBucket(js, filt, true, bkt, s.common, null);
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

// Which classes a point-symbol layer carries. LIGHTS are split into their own pass so
// the style can emit them LAST (on top): a light and a bridge are both DrawingPriority
// 24, but they usually sit in different SCAMIN buckets (separate MapLibre layers, painted
// in emit order), so an in-layer sort-key can't keep the light on top. A dedicated lights
// pass emitted after every other point layer makes the paramount navaid always win.
const PointMode = enum { non_lights, lights_only };

// AND the per-alignment rot_north test with the mode's class clause, then emit the
// bucket filter. rot_north_eq / mode are comptime so each switch arm passes a concrete
// tuple type to the generic applyBucket.
fn applyPointBucket(js: *Stringify, s: *const SCtx, bkt: Bucket, comptime rot_north_eq: bool, comptime mode: PointMode) !void {
    const rot = if (rot_north_eq)
        .{ "==", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }
    else
        .{ "!=", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 };
    switch (mode) {
        .non_lights => try applyBucket(js, .{ "all", rot, .{ "!=", .{ "get", "class" }, "LIGHTS" } }, true, bkt, s.common, null),
        .lights_only => try applyBucket(js, .{ "all", rot, .{ "==", .{ "get", "class" }, "LIGHTS" } }, true, bkt, s.common, null),
    }
}

fn pointSymbolLayers(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket, comptime mode: PointMode) !void {
    // `-lt` infixes the lights-only layer ids so they stay distinct from the non-light set.
    const tag = switch (mode) {
        .non_lights => "",
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

    // light-text<sfx> — always-on LIGHTS characteristics, top-anchored.
    const lid = try std.fmt.bufPrint(&buf, "light-text{s}{s}", .{ sfx, bkt.suffix });
    try js.beginObject();
    try layerHead(js, lid, "symbol", sl);
    try applyBucket(js, .{ "==", .{ "get", "class" }, "LIGHTS" }, true, bkt, s.common, s.text_group);
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("text-field");
    try js.write(.{ "coalesce", .{ "get", "text" }, "" });
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try writeScaled(js, .{ "coalesce", .{ "get", "font_size_px" }, 10 }, s.size_scale);
    try js.objectField("text-anchor");
    try js.write("top");
    try js.objectField("text-offset");
    try js.write(.{ 0, 0.4 });
    try js.objectField("text-justify");
    try js.write("left");
    try js.objectField("symbol-sort-key");
    try js.write(.{ "-", 0, .{ "coalesce", .{ "get", "font_size_px" }, 10 } });
    try js.objectField("text-allow-overlap");
    try js.write(false);
    try js.objectField("text-optional");
    try js.write(true);
    try js.endObject();
    try textPaint(js, s.text_color, s.halo, 0); // S-52: solid black, no halo
    try js.endObject();

    // text<sfx> — general collidable labels.
    var buf2: [96]u8 = undefined;
    const tid = try std.fmt.bufPrint(&buf2, "text{s}{s}", .{ sfx, bkt.suffix });
    try js.beginObject();
    try layerHead(js, tid, "symbol", sl);
    try applyBucket(js, .{ "!=", .{ "get", "class" }, "LIGHTS" }, true, bkt, s.common, s.text_group);
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
    try js.objectField("symbol-sort-key");
    try js.write(TEXT_SORT_KEY);
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
    try applyBucket(js, .{}, false, bkt, s.common, null);
    try js.endObject();
}

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
    try applyBucket(js, .{}, false, bkt, s.common, null);
    try js.endObject();
}

// One complex (symbolised) line layer for a source-layer + SCAMIN bucket.
fn complexLineLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "complex-{s}{s}", .{ sl, bkt.suffix }), "line", sl);
    try js.objectField("paint");
    try linePaint(js, s.line_color, null, s.size_scale);
    try applyBucket(js, .{}, false, bkt, s.common, null);
    try js.endObject();
}

// One DEPCNT contour value-label layer (glyphs required) for a source-layer + bucket.
fn contourLabelLayer(js: *Stringify, s: *const SCtx, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "contour-labels-{s}{s}", .{ sl, bkt.suffix }), "symbol", sl);
    try applyBucket(js, .{ "has", "valdco" }, true, bkt, s.common, null);
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

// The soundings symbol layer (sprite required) for a SCAMIN bucket.
fn soundingsLayer(js: *Stringify, s: *const SCtx, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "soundings{s}", .{bkt.suffix}), "symbol", "soundings");
    try applyBucket(js, .{}, false, bkt, s.common, null);
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
    if (!opts.ignore_scamin) for (opts.scamin) |v| {
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
    try fillLayer(js, &s, "areas", .{});
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

    // 7. contour value labels (DEPCNT VALDCO) — text, needs glyphs.
    if (glyphs_on) {
        try contourLabelLayer(js, &s, "lines", .{});
        for (all_buckets) |bkt| try contourLabelLayer(js, &s, "lines_scamin", bkt);
    }

    // 8. point symbols (non-light) + soundings (sprite required)
    if (sprite_on) {
        try pointSymbolLayers(js, &s, "point_symbols", .{}, .non_lights);
        for (all_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols_scamin", bkt, .non_lights);
        for (snd_buckets) |bkt| try soundingsLayer(js, &s, bkt);
        // LIGHTS on top: emitted after every other point symbol so a light always draws
        // over a same-priority bridge that lives in a different scamin bucket layer.
        try pointSymbolLayers(js, &s, "point_symbols", .{}, .lights_only);
        for (all_buckets) |bkt| try pointSymbolLayers(js, &s, "point_symbols_scamin", bkt, .lights_only);
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
