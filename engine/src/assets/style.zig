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
// SCAMIN display-scale denominator at z0 (physical 512-tile scale).
const DENOM_Z0 = 279541132.0;
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

// Show a SCAMIN feature only at/above its 1:N display zoom.
const SCAMIN_GATE = .{ ">=", .{"zoom"}, .{ "log2", .{ "/", DENOM_Z0, .{ "coalesce", .{ "get", "scamin" }, DENOM_Z0 } } } };

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
};

fn isScamin(sl: []const u8) bool {
    return std.mem.endsWith(u8, sl, "_scamin");
}

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

// `,"filter": base` — or `["all", base, SCAMIN_GATE]` when gated. (all_of)
fn gatedFilter(js: *Stringify, base: anytype, gated: bool) !void {
    try js.objectField("filter");
    if (gated) {
        try js.beginArray();
        try js.write("all");
        try js.write(base);
        try js.write(SCAMIN_GATE);
        try js.endArray();
    } else {
        try js.write(base);
    }
}

fn lineLayer(js: *Stringify, palette: std.json.ObjectMap, sl: []const u8, name: []const u8, filt: anytype, dash: ?[2]i64, gated: bool) !void {
    var buf: [64]u8 = undefined;
    const id = try std.fmt.bufPrint(&buf, "{s}-{s}", .{ sl, name });
    try js.beginObject();
    try layerHead(js, id, "line", sl);
    try gatedFilter(js, filt, gated);
    try js.objectField("paint");
    try linePaint(js, palette, dash);
    try js.endObject();
}

// solid / dashed / dotted line layers for one source-layer.
fn lineLayers(js: *Stringify, palette: std.json.ObjectMap, sl: []const u8, gated: bool) !void {
    try lineLayer(js, palette, sl, "solid", FILT_SOLID, null, gated);
    try lineLayer(js, palette, sl, "dashed", FILT_DASHED, .{ 4, 3 }, gated);
    try lineLayer(js, palette, sl, "dotted", FILT_DOTTED, .{ 1, 2 }, gated);
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

fn pointSymbolLayers(js: *Stringify, sl: []const u8, gated: bool) !void {
    var buf: [64]u8 = undefined;
    // viewport-aligned (screen-up)
    try js.beginObject();
    try layerHead(js, sl, "symbol", sl);
    try gatedFilter(js, .{ "!=", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }, gated);
    try js.objectField("layout");
    try pointLayout(js, "viewport");
    try js.endObject();
    // map-aligned (true-north)
    const nid = try std.fmt.bufPrint(&buf, "{s}-north", .{sl});
    try js.beginObject();
    try layerHead(js, nid, "symbol", sl);
    try gatedFilter(js, .{ "==", .{ "coalesce", .{ "get", "rot_north" }, 0 }, 1 }, gated);
    try js.objectField("layout");
    try pointLayout(js, "map");
    try js.endObject();
}

fn textLayers(js: *Stringify, scheme: []const u8, palette: std.json.ObjectMap, sl: []const u8, gated: bool) !void {
    var buf: [64]u8 = undefined;
    const suffix = if (std.mem.eql(u8, sl, "text")) "" else "-scamin";

    // light-text<suffix> — always-on LIGHTS characteristics, top-anchored.
    const lid = try std.fmt.bufPrint(&buf, "light-text{s}", .{suffix});
    try js.beginObject();
    try layerHead(js, lid, "symbol", sl);
    try gatedFilter(js, .{ "==", .{ "get", "class" }, "LIGHTS" }, gated);
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

    // text<suffix> — general collidable labels.
    var buf2: [64]u8 = undefined;
    const tid = try std.fmt.bufPrint(&buf2, "text{s}", .{suffix});
    try js.beginObject();
    try layerHead(js, tid, "symbol", sl);
    try gatedFilter(js, .{ "!=", .{ "get", "class" }, "LIGHTS" }, gated);
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
    const sea = if (palette.get("DEPDW")) |v| v.string else "#93aebb";

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var stringify: Stringify = .{ .writer = &aw.writer };
    const js = &stringify;

    try js.beginObject();
    try js.objectField("version");
    try js.write(8);
    var namebuf: [64]u8 = undefined;
    try js.objectField("name");
    try js.write(try std.fmt.bufPrint(&namebuf, "chartplotter-native ({s}, M2)", .{opts.scheme}));

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

    // 2. area fills + SCAMIN clone
    for ([_][]const u8{ "areas", "areas_scamin" }) |sl| {
        var buf: [64]u8 = undefined;
        try js.beginObject();
        try layerHead(js, try std.fmt.bufPrint(&buf, "fill-{s}", .{sl}), "fill", sl);
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
        if (isScamin(sl)) {
            try js.objectField("filter");
            try js.write(SCAMIN_GATE);
        }
        try js.endObject();
    }

    // 3. area fill patterns (sprite required)
    if (sprite_on) {
        for ([_][]const u8{ "area_patterns", "area_patterns_scamin" }) |sl| {
            var buf: [64]u8 = undefined;
            try js.beginObject();
            try layerHead(js, try std.fmt.bufPrint(&buf, "fillpat-{s}", .{sl}), "fill", sl);
            try js.objectField("paint");
            try js.beginObject();
            try js.objectField("fill-pattern");
            try js.write(.{ "concat", "pat:", .{ "coalesce", .{ "get", "pattern_name" }, "" } });
            try js.endObject();
            if (isScamin(sl)) {
                try js.objectField("filter");
                try js.write(SCAMIN_GATE);
            }
            try js.endObject();
        }
    }

    // 4. lines: solid/dashed/dotted over base + _scamin
    for ([_][]const u8{ "lines", "lines_scamin" }) |sl| {
        try lineLayers(js, palette, sl, isScamin(sl));
    }

    // 5. complex (symbolised) lines
    for ([_][]const u8{ "complex_lines", "complex_lines_scamin" }) |sl| {
        var buf: [64]u8 = undefined;
        try js.beginObject();
        try layerHead(js, try std.fmt.bufPrint(&buf, "complex-{s}", .{sl}), "line", sl);
        try js.objectField("paint");
        try linePaint(js, palette, null);
        if (isScamin(sl)) {
            try js.objectField("filter");
            try js.write(SCAMIN_GATE);
        }
        try js.endObject();
    }

    // 6. light sector limit lines
    try lineLayers(js, palette, "sector_lines", false);

    // 7. contour value labels (DEPCNT VALDCO)
    for ([_][]const u8{ "lines", "lines_scamin" }) |sl| {
        var buf: [64]u8 = undefined;
        try js.beginObject();
        try layerHead(js, try std.fmt.bufPrint(&buf, "contour-labels-{s}", .{sl}), "symbol", sl);
        try gatedFilter(js, .{ "has", "valdco" }, isScamin(sl));
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
        try contourLabelColor(js, opts.scheme, palette);
        try js.objectField("text-halo-color");
        try js.write(haloColor(opts.scheme));
        try js.objectField("text-halo-width");
        try js.write(1.2);
        try js.objectField("text-halo-blur");
        try js.write(0.5);
        try js.endObject();
        try js.endObject();
    }

    // 8. point symbols + soundings (sprite required)
    if (sprite_on) {
        try pointSymbolLayers(js, "point_symbols", false);
        try pointSymbolLayers(js, "point_symbols_scamin", true);
        try js.beginObject();
        try layerHead(js, "soundings", "symbol", "soundings");
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

    // 9. text labels
    try textLayers(js, opts.scheme, palette, "text", false);
    try textLayers(js, opts.scheme, palette, "text_scamin", true);

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
        .source_tiles = "zigtiles://{z}/{x}/{y}",
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
