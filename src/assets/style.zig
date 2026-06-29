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

const FALLBACK = "#ff00ff";
const FONT = .{"Noto Sans Regular"};

// ---- MapLibre expressions, as comptime tuples ----------------------------

// Depth-area band edges: coalesce(get drvalN, default).
const D1 = .{ "coalesce", .{ "get", "drval1" }, -1 };
const D2 = .{ "coalesce", .{ "get", "drval2" }, 0 };
// SEABED01 depth-band token (deepest first; case: first match wins).
const SEABED = .{
    "case",
    .{ "all", .{ ">=", D1, 30 }, .{ ">", D2, 30 } }, "DEPDW",
    .{ "all", .{ ">=", D1, 10 }, .{ ">", D2, 10 } }, "DEPMD",
    .{ "all", .{ ">=", D1, 2 },  .{ ">", D2, 2 } },  "DEPMS",
    .{ "all", .{ ">=", D1, 0 },  .{ ">", D2, 0 } },  "DEPVS",
    "DEPIT",
};

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

// OBSTRN/WRECKS danger swap (sym_deep beyond safety) + pivot_center "ctr:" variant.
const SYM_NAME = .{ "case", .{ "all", .{ "has", "sym_deep" }, .{ ">", .{ "coalesce", .{ "get", "danger_depth" }, 0 }, 10 } }, .{ "get", "sym_deep" }, .{ "get", "symbol_name" } };
const PSI = .{ "case", .{ "==", .{ "coalesce", .{ "get", "pivot_center" }, 0 }, 1 }, .{ "concat", "ctr:", SYM_NAME }, SYM_NAME };
const ICON_SIZE = .{ "/", .{ "coalesce", .{ "get", "scale" }, 0.08 }, 0.08 };
const SOUNDINGS_IMG = .{ "case", .{ "has", "sym_s" }, .{ "case", .{ "<=", .{ "coalesce", .{ "get", "depth" }, 0 }, 10 }, .{ "get", "sym_s" }, .{ "get", "sym_g" } }, .{ "get", "symbol_names" } };

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
};

// ---- colour resolution (the one runtime-variable expression) -------------

// After the array head + token expr, append TOK,hex pairs + fallback and close.
fn finishColorMatch(js: *Stringify, palette: std.json.ObjectMap, fallback: []const u8) !void {
    for (palette.keys()) |k| {
        try js.write(k);
        try js.write(palette.get(k).?.string);
    }
    try js.write(fallback);
    try js.endArray();
}

// ["match",["coalesce",["get",prop],""], TOK,hex, …, fallback]
fn colorExpr(js: *Stringify, prop: []const u8, palette: std.json.ObjectMap, fallback: []const u8) !void {
    try js.beginArray();
    try js.write("match");
    try js.write(.{ "coalesce", .{ "get", prop }, "" });
    try finishColorMatch(js, palette, fallback);
}

// Depth areas (drval1) shade via SEABED01; everything else uses its colour_token.
fn areasFillColor(js: *Stringify, palette: std.json.ObjectMap) !void {
    try js.beginArray();
    try js.write("case");
    try js.write(.{ "has", "drval1" });
    try js.beginArray(); // SEABED01 match
    try js.write("match");
    try js.write(SEABED);
    try finishColorMatch(js, palette, FALLBACK);
    try colorExpr(js, "color_token", palette, FALLBACK); // default arm
    try js.endArray();
}

fn linePaint(js: *Stringify, palette: std.json.ObjectMap, dash: ?[2]i64) !void {
    try js.beginObject();
    try js.objectField("line-color");
    try colorExpr(js, "color_token", palette, FALLBACK);
    try js.objectField("line-width");
    try js.write(.{ "coalesce", .{ "get", "width_px" }, 1 });
    if (dash) |d| {
        try js.objectField("line-dasharray");
        try js.write(d);
    }
    try js.endObject();
}

fn haloColor(scheme: []const u8) []const u8 {
    return if (std.mem.eql(u8, scheme, "day")) "rgba(255,255,255,0.9)" else "rgba(0,0,0,0.85)";
}

fn textColor(js: *Stringify, scheme: []const u8, palette: std.json.ObjectMap) !void {
    if (std.mem.eql(u8, scheme, "day")) {
        try colorExpr(js, "color_token", palette, "#000000");
    } else {
        try js.write(if (std.mem.eql(u8, scheme, "night")) "#aab7bf" else "#dde7ec");
    }
}

fn contourLabelColor(js: *Stringify, scheme: []const u8, palette: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, scheme, "day")) return textColor(js, scheme, palette);
    const c = if (palette.get("CHGRD")) |v| v.string else if (palette.get("CHBLK")) |v| v.string else "#000000";
    try js.write(c);
}

// ---- layer building blocks ----------------------------------------------

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

// Write a layer's `filter` (the `base` predicate ANDed with the bucket's scamin clause,
// or either alone) and its native `minzoom`. `has_base=false` for layers with no base
// predicate (fills/patterns/complex/soundings); a plain bucket then emits neither field.
fn applyBucket(js: *Stringify, base: anytype, has_base: bool, bkt: Bucket) !void {
    const has_clause = bkt.sm != null or bkt.no_lows != null or bkt.zoom_gate;
    if (has_base or has_clause) {
        try js.objectField("filter");
        if (has_base and has_clause) {
            try js.beginArray();
            try js.write("all");
            try js.write(base);
            try writeScaminClause(js, bkt);
            try js.endArray();
        } else if (has_clause) {
            try writeScaminClause(js, bkt);
        } else {
            try js.write(base);
        }
    }
    if (bkt.minzoom) |mz| {
        try js.objectField("minzoom");
        try js.write(mz);
    }
}

fn lineLayer(js: *Stringify, palette: std.json.ObjectMap, sl: []const u8, name: []const u8, filt: anytype, dash: ?[2]i64, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    const id = try std.fmt.bufPrint(&buf, "{s}-{s}{s}", .{ sl, name, bkt.suffix });
    try js.beginObject();
    try layerHead(js, id, "line", sl);
    try applyBucket(js, filt, true, bkt);
    try js.objectField("paint");
    try linePaint(js, palette, dash);
    try js.endObject();
}

// solid / dashed / dotted line layers for one source-layer (one SCAMIN bucket).
fn lineLayers(js: *Stringify, palette: std.json.ObjectMap, sl: []const u8, bkt: Bucket) !void {
    try lineLayer(js, palette, sl, "solid", FILT_SOLID, null, bkt);
    try lineLayer(js, palette, sl, "dashed", FILT_DASHED, .{ 4, 3 }, bkt);
    try lineLayer(js, palette, sl, "dotted", FILT_DOTTED, .{ 1, 2 }, bkt);
}

fn pointLayout(js: *Stringify, alignment: []const u8) !void {
    try js.beginObject();
    try js.objectField("icon-image");
    try js.write(PSI);
    try js.objectField("icon-size");
    try js.write(ICON_SIZE);
    try js.objectField("icon-rotate");
    try js.write(.{ "coalesce", .{ "get", "rotation_deg" }, 0 });
    try js.objectField("icon-allow-overlap");
    try js.write(true);
    try js.objectField("icon-ignore-placement");
    try js.write(true);
    try js.objectField("symbol-z-order");
    try js.write("source");
    try js.objectField("icon-rotation-alignment");
    try js.write(alignment);
    try js.endObject();
}

fn pointSymbolLayers(js: *Stringify, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    // viewport-aligned (screen-up)
    const vid = try std.fmt.bufPrint(&buf, "{s}{s}", .{ sl, bkt.suffix });
    try js.beginObject();
    try layerHead(js, vid, "symbol", sl);
    try applyBucket(js, .{ "!=", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }, true, bkt);
    try js.objectField("layout");
    try pointLayout(js, "viewport");
    try js.endObject();
    // map-aligned (true-north)
    var nbuf: [96]u8 = undefined;
    const nid = try std.fmt.bufPrint(&nbuf, "{s}-north{s}", .{ sl, bkt.suffix });
    try js.beginObject();
    try layerHead(js, nid, "symbol", sl);
    try applyBucket(js, .{ "==", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }, true, bkt);
    try js.objectField("layout");
    try pointLayout(js, "map");
    try js.endObject();
}

fn textLayers(js: *Stringify, scheme: []const u8, palette: std.json.ObjectMap, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    const sfx = if (std.mem.eql(u8, sl, "text")) "" else "-scamin";

    // light-text<sfx> — always-on LIGHTS characteristics, top-anchored.
    const lid = try std.fmt.bufPrint(&buf, "light-text{s}{s}", .{ sfx, bkt.suffix });
    try js.beginObject();
    try layerHead(js, lid, "symbol", sl);
    try applyBucket(js, .{ "==", .{ "get", "class" }, "LIGHTS" }, true, bkt);
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("text-field");
    try js.write(.{ "coalesce", .{ "get", "text" }, "" });
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try js.write(.{ "coalesce", .{ "get", "font_size_px" }, 10 });
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
    try textPaint(js, scheme, palette, 1.4);
    try js.endObject();

    // text<sfx> — general collidable labels.
    var buf2: [96]u8 = undefined;
    const tid = try std.fmt.bufPrint(&buf2, "text{s}{s}", .{ sfx, bkt.suffix });
    try js.beginObject();
    try layerHead(js, tid, "symbol", sl);
    try applyBucket(js, .{ "!=", .{ "get", "class" }, "LIGHTS" }, true, bkt);
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("text-field");
    try js.write(.{ "coalesce", .{ "get", "text" }, "" });
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try js.write(.{ "coalesce", .{ "get", "font_size_px" }, 11 });
    try js.objectField("text-anchor");
    try js.write(TEXT_ANCHOR);
    try js.objectField("symbol-sort-key");
    try js.write(TEXT_SORT_KEY);
    try js.objectField("text-allow-overlap");
    try js.write(false);
    try js.objectField("text-optional");
    try js.write(true);
    try js.endObject();
    try textPaint(js, scheme, palette, 1.4);
    try js.endObject();
}

fn textPaint(js: *Stringify, scheme: []const u8, palette: std.json.ObjectMap, halo_width: f64) !void {
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("text-color");
    try textColor(js, scheme, palette);
    try js.objectField("text-halo-color");
    try js.write(haloColor(scheme));
    try js.objectField("text-halo-width");
    try js.write(halo_width);
    try js.objectField("text-halo-blur");
    try js.write(0.5);
    try js.endObject();
}

// One area-fill layer for a source-layer + SCAMIN bucket.
fn fillLayer(js: *Stringify, palette: std.json.ObjectMap, sl: []const u8, bkt: Bucket) !void {
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
    try areasFillColor(js, palette);
    try js.objectField("fill-antialias");
    try js.write(true);
    try js.endObject();
    try applyBucket(js, .{}, false, bkt);
    try js.endObject();
}

// One area fill-pattern layer (sprite required) for a source-layer + SCAMIN bucket.
fn patternLayer(js: *Stringify, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "fillpat-{s}{s}", .{ sl, bkt.suffix }), "fill", sl);
    try js.objectField("paint");
    try js.beginObject();
    try js.objectField("fill-pattern");
    try js.write(.{ "concat", "pat:", .{ "coalesce", .{ "get", "pattern_name" }, "" } });
    try js.endObject();
    try applyBucket(js, .{}, false, bkt);
    try js.endObject();
}

// One complex (symbolised) line layer for a source-layer + SCAMIN bucket.
fn complexLineLayer(js: *Stringify, palette: std.json.ObjectMap, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "complex-{s}{s}", .{ sl, bkt.suffix }), "line", sl);
    try js.objectField("paint");
    try linePaint(js, palette, null);
    try applyBucket(js, .{}, false, bkt);
    try js.endObject();
}

// One DEPCNT contour value-label layer (glyphs required) for a source-layer + bucket.
fn contourLabelLayer(js: *Stringify, scheme: []const u8, palette: std.json.ObjectMap, sl: []const u8, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "contour-labels-{s}{s}", .{ sl, bkt.suffix }), "symbol", sl);
    try applyBucket(js, .{ "has", "valdco" }, true, bkt);
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("symbol-placement");
    try js.write("line-center");
    try js.objectField("text-field");
    try js.write(.{ "to-string", .{ "get", "valdco" } });
    try js.objectField("text-font");
    try js.write(FONT);
    try js.objectField("text-size");
    try js.write(10);
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
    try contourLabelColor(js, scheme, palette);
    try js.objectField("text-halo-color");
    try js.write(haloColor(scheme));
    try js.objectField("text-halo-width");
    try js.write(1.2);
    try js.objectField("text-halo-blur");
    try js.write(0.5);
    try js.endObject();
    try js.endObject();
}

// The soundings symbol layer (sprite required) for a SCAMIN bucket.
fn soundingsLayer(js: *Stringify, bkt: Bucket) !void {
    var buf: [96]u8 = undefined;
    try js.beginObject();
    try layerHead(js, try std.fmt.bufPrint(&buf, "soundings{s}", .{bkt.suffix}), "symbol", "soundings");
    try applyBucket(js, .{}, false, bkt);
    try js.objectField("layout");
    try js.beginObject();
    try js.objectField("icon-image");
    try js.write(SOUNDINGS_IMG);
    try js.objectField("icon-size");
    try js.write(ICON_SIZE);
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
    for (opts.scamin) |v| {
        const mz = scaminDisplayZoom(@floatFromInt(v), opts.scamin_lat);
        if (mz <= floor + 1e-6) {
            try lows.append(ba, v);
        } else {
            try his.append(ba, .{ .sm = v, .minzoom = mz, .suffix = try std.fmt.allocPrint(ba, "#sm{d}", .{v}) });
        }
    }
    const low_slice: []const u32 = lows.items;
    var allb = std.ArrayList(Bucket).empty;
    var sndb = std.ArrayList(Bucket).empty;
    if (opts.scamin.len == 0) {
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
    try fillLayer(js, palette, "areas", .{});
    for (all_buckets) |bkt| try fillLayer(js, palette, "areas_scamin", bkt);

    // 3. area fill patterns (sprite required)
    if (sprite_on) {
        try patternLayer(js, "area_patterns", .{});
        for (all_buckets) |bkt| try patternLayer(js, "area_patterns_scamin", bkt);
    }

    // 4. lines: solid/dashed/dotted over base + _scamin buckets
    try lineLayers(js, palette, "lines", .{});
    for (all_buckets) |bkt| try lineLayers(js, palette, "lines_scamin", bkt);

    // 5. complex (symbolised) lines
    try complexLineLayer(js, palette, "complex_lines", .{});
    for (all_buckets) |bkt| try complexLineLayer(js, palette, "complex_lines_scamin", bkt);

    // 6. light sector limit lines (no SCAMIN bucketing)
    try lineLayers(js, palette, "sector_lines", .{});

    // 7. contour value labels (DEPCNT VALDCO) — text, needs glyphs.
    if (glyphs_on) {
        try contourLabelLayer(js, opts.scheme, palette, "lines", .{});
        for (all_buckets) |bkt| try contourLabelLayer(js, opts.scheme, palette, "lines_scamin", bkt);
    }

    // 8. point symbols + soundings (sprite required)
    if (sprite_on) {
        try pointSymbolLayers(js, "point_symbols", .{});
        for (all_buckets) |bkt| try pointSymbolLayers(js, "point_symbols_scamin", bkt);
        for (snd_buckets) |bkt| try soundingsLayer(js, bkt);
    }

    // 9. text labels — need an SDF glyph source.
    if (glyphs_on) {
        try textLayers(js, opts.scheme, palette, "text", .{});
        for (all_buckets) |bkt| try textLayers(js, opts.scheme, palette, "text_scamin", bkt);
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
