//! style.zig — MapLibre GL style.json generation for the chart bundle. A faithful
//! Zig port of style/build_style.py (itself a port of the web s52-style.mjs /
//! chart-style.mjs): resolve each S-52 colour token to hex for a palette and emit
//! the fill / line / symbol / text layer set. Output is minified JSON; it is
//! compared layer-for-layer against build_style.py in the differential test
//! (scripts/check-style-parity.sh). Part of the `assets` module; retires
//! style/build_style.py. See ../../../specs/bundle-bake.md.

const std = @import("std");

const FALLBACK = "#ff00ff";
// Default mariner depth contours (S-52): shallow=2, safety=10, deep=30 m.
const DPC = "30";
const SFC = "10";
const SHC = "2";
// SCAMIN display-scale denominator at z0 (physical 512-tile scale); see build_style.py.
const DENOM_Z0 = "279541132.0";
const FONT = "[\"Noto Sans Regular\"]";

// ["coalesce",["get","drval1"],-1] / ["coalesce",["get","drval2"],0]
const D1 = "[\"coalesce\",[\"get\",\"drval1\"],-1]";
const D2 = "[\"coalesce\",[\"get\",\"drval2\"],0]";
fn band(comptime x: []const u8) []const u8 {
    return "[\"all\",[\">=\"," ++ D1 ++ "," ++ x ++ "],[\">\"," ++ D2 ++ "," ++ x ++ "]]";
}
// SEABED01 depth-band token (deepest first; case: first match wins).
const SEABED = "[\"case\"," ++ band(DPC) ++ ",\"DEPDW\"," ++ band(SFC) ++ ",\"DEPMD\"," ++
    band(SHC) ++ ",\"DEPMS\"," ++ band("0") ++ ",\"DEPVS\",\"DEPIT\"]";

const SCAMIN_FILTER = "[\">=\",[\"zoom\"],[\"log2\",[\"/\"," ++ DENOM_Z0 ++
    ",[\"coalesce\",[\"get\",\"scamin\"]," ++ DENOM_Z0 ++ "]]]]";

const FILL_SORT = "[\"-\",[\"*\",[\"coalesce\",[\"get\",\"draw_prio\"],0],1000],[\"coalesce\",[\"get\",\"drval1\"],0]]";

// OBSTRN/WRECKS danger swap + pivot_center "ctr:" variant (s52-style pointSymbolImage).
const SYM_NAME = "[\"case\",[\"all\",[\"has\",\"sym_deep\"],[\">\",[\"coalesce\",[\"get\",\"danger_depth\"],0]," ++
    SFC ++ "]],[\"get\",\"sym_deep\"],[\"get\",\"symbol_name\"]]";
const PSI = "[\"case\",[\"==\",[\"coalesce\",[\"get\",\"pivot_center\"],0],1],[\"concat\",\"ctr:\"," ++
    SYM_NAME ++ "]," ++ SYM_NAME ++ "]";
const ICON_SIZE = "[\"/\",[\"coalesce\",[\"get\",\"scale\"],0.08],0.08]";
const SOUNDINGS_IMG = "[\"case\",[\"has\",\"sym_s\"],[\"case\",[\"<=\",[\"coalesce\",[\"get\",\"depth\"],0]," ++
    SFC ++ "],[\"get\",\"sym_s\"],[\"get\",\"sym_g\"]],[\"get\",\"symbol_names\"]]";

const VROW = "[\"match\",[\"coalesce\",[\"get\",\"valign\"],\"middle\"],\"top\",\"top\",\"bottom\",\"bottom\",\"center\"]";
const TEXT_ANCHOR = "[\"match\",[\"concat\"," ++ VROW ++ ",\"|\",[\"coalesce\",[\"get\",\"halign\"],\"center\"]]," ++
    "\"center|left\",\"left\",\"center|right\",\"right\",\"center|center\",\"center\"," ++
    "\"top|center\",\"top\",\"bottom|center\",\"bottom\"," ++
    "\"top|left\",\"top-left\",\"top|right\",\"top-right\"," ++
    "\"bottom|left\",\"bottom-left\",\"bottom|right\",\"bottom-right\",\"center\"]";
const TEXT_SORT_KEY = "[\"-\",[\"match\",[\"coalesce\",[\"get\",\"tgrp\"],-1],11,0,[21,26,29],100,23,50,150]," ++
    "[\"coalesce\",[\"get\",\"font_size_px\"],10]]";

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

// Minimal append-only JSON writer over an ArrayList(u8).
const W = struct {
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    fn s(w: W, t: []const u8) !void {
        try w.out.appendSlice(w.a, t);
    }
};

fn isScamin(sl: []const u8) bool {
    return std.mem.endsWith(u8, sl, "_scamin");
}

fn emitPalettePairs(w: W, palette: std.json.ObjectMap) !void {
    for (palette.keys()) |k| {
        try w.s(",\"");
        try w.s(k);
        try w.s("\",\"");
        try w.s(palette.get(k).?.string);
        try w.s("\"");
    }
}

// ["match",<token_expr>, TOK,hex, …, fallback]
fn emitColorMatch(w: W, token_expr: []const u8, palette: std.json.ObjectMap, fallback: []const u8) !void {
    try w.s("[\"match\",");
    try w.s(token_expr);
    try emitPalettePairs(w, palette);
    try w.s(",\"");
    try w.s(fallback);
    try w.s("\"]");
}

// color_expr(prop): match over ["coalesce",["get",prop],""]
fn emitColorExpr(w: W, prop: []const u8, palette: std.json.ObjectMap, fallback: []const u8) !void {
    var buf: [64]u8 = undefined;
    const te = try std.fmt.bufPrint(&buf, "[\"coalesce\",[\"get\",\"{s}\"],\"\"]", .{prop});
    try emitColorMatch(w, te, palette, fallback);
}

fn emitAreasFillColor(w: W, palette: std.json.ObjectMap) !void {
    try w.s("[\"case\",[\"has\",\"drval1\"],");
    try emitColorMatch(w, SEABED, palette, FALLBACK);
    try w.s(",");
    try emitColorExpr(w, "color_token", palette, FALLBACK);
    try w.s("]");
}

fn emitLinePaint(w: W, palette: std.json.ObjectMap, dash: ?[]const u8) !void {
    try w.s("{\"line-color\":");
    try emitColorExpr(w, "color_token", palette, FALLBACK);
    try w.s(",\"line-width\":[\"coalesce\",[\"get\",\"width_px\"],1]");
    if (dash) |d| {
        try w.s(",\"line-dasharray\":");
        try w.s(d);
    }
    try w.s("}");
}

// Emit `,"filter":<expr>` for all_of(f1, f2): nothing if both null, the lone one
// if one is null, else ["all",f1,f2]. Mirrors build_style.py's all_of/scamin_gate.
fn emitFilter(w: W, f1: ?[]const u8, f2: ?[]const u8) !void {
    if (f1 == null and f2 == null) return;
    try w.s(",\"filter\":");
    if (f1 != null and f2 != null) {
        try w.s("[\"all\",");
        try w.s(f1.?);
        try w.s(",");
        try w.s(f2.?);
        try w.s("]");
    } else {
        try w.s(f1 orelse f2.?);
    }
}

fn haloColor(scheme: []const u8) []const u8 {
    return if (std.mem.eql(u8, scheme, "day")) "\"rgba(255,255,255,0.9)\"" else "\"rgba(0,0,0,0.85)\"";
}

fn emitTextColor(w: W, scheme: []const u8, palette: std.json.ObjectMap) !void {
    if (std.mem.eql(u8, scheme, "day")) {
        try emitColorExpr(w, "color_token", palette, "#000000");
    } else if (std.mem.eql(u8, scheme, "night")) {
        try w.s("\"#aab7bf\"");
    } else {
        try w.s("\"#dde7ec\"");
    }
}

fn emitContourLabelColor(w: W, scheme: []const u8, palette: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, scheme, "day")) return emitTextColor(w, scheme, palette);
    const c = if (palette.get("CHGRD")) |v|
        v.string
    else if (palette.get("CHBLK")) |v|
        v.string
    else
        "#000000";
    try w.s("\"");
    try w.s(c);
    try w.s("\"");
}

fn emitPointSymbolLayers(w: W, sl: []const u8, extra: ?[]const u8) !void {
    const common = ",\"icon-size\":" ++ ICON_SIZE ++ ",\"icon-rotate\":[\"coalesce\",[\"get\",\"rotation_deg\"],0]," ++
        "\"icon-allow-overlap\":true,\"icon-ignore-placement\":true,\"symbol-z-order\":\"source\"";
    try w.s(",{\"id\":\"");
    try w.s(sl);
    try w.s("\",\"type\":\"symbol\",\"source\":\"chart\",\"source-layer\":\"");
    try w.s(sl);
    try w.s("\"");
    try emitFilter(w, "[\"!=\",[\"coalesce\",[\"get\",\"rot_north\"],0],1]", extra);
    try w.s(",\"layout\":{\"icon-image\":" ++ PSI ++ common ++ ",\"icon-rotation-alignment\":\"viewport\"}}");
    try w.s(",{\"id\":\"");
    try w.s(sl);
    try w.s("-north\",\"type\":\"symbol\",\"source\":\"chart\",\"source-layer\":\"");
    try w.s(sl);
    try w.s("\"");
    try emitFilter(w, "[\"==\",[\"coalesce\",[\"get\",\"rot_north\"],0],1]", extra);
    try w.s(",\"layout\":{\"icon-image\":" ++ PSI ++ common ++ ",\"icon-rotation-alignment\":\"map\"}}");
}

fn emitTextLayers(w: W, scheme: []const u8, palette: std.json.ObjectMap, sl: []const u8, extra: ?[]const u8) !void {
    const suffix = if (std.mem.eql(u8, sl, "text")) "" else "-scamin";
    // light-text<suffix>
    try w.s(",{\"id\":\"light-text");
    try w.s(suffix);
    try w.s("\",\"type\":\"symbol\",\"source\":\"chart\",\"source-layer\":\"");
    try w.s(sl);
    try w.s("\"");
    try emitFilter(w, "[\"==\",[\"get\",\"class\"],\"LIGHTS\"]", extra);
    try w.s(",\"layout\":{\"text-field\":[\"coalesce\",[\"get\",\"text\"],\"\"],\"text-font\":" ++ FONT ++
        ",\"text-size\":[\"coalesce\",[\"get\",\"font_size_px\"],10],\"text-anchor\":\"top\",\"text-offset\":[0,0.4]," ++
        "\"text-justify\":\"left\",\"symbol-sort-key\":[\"-\",0,[\"coalesce\",[\"get\",\"font_size_px\"],10]]," ++
        "\"text-allow-overlap\":false,\"text-optional\":true},\"paint\":{\"text-color\":");
    try emitTextColor(w, scheme, palette);
    try w.s(",\"text-halo-color\":");
    try w.s(haloColor(scheme));
    try w.s(",\"text-halo-width\":1.4,\"text-halo-blur\":0.5}}");
    // text<suffix>
    try w.s(",{\"id\":\"text");
    try w.s(suffix);
    try w.s("\",\"type\":\"symbol\",\"source\":\"chart\",\"source-layer\":\"");
    try w.s(sl);
    try w.s("\"");
    try emitFilter(w, "[\"!=\",[\"get\",\"class\"],\"LIGHTS\"]", extra);
    try w.s(",\"layout\":{\"text-field\":[\"coalesce\",[\"get\",\"text\"],\"\"],\"text-font\":" ++ FONT ++
        ",\"text-size\":[\"coalesce\",[\"get\",\"font_size_px\"],11],\"text-anchor\":" ++ TEXT_ANCHOR ++
        ",\"symbol-sort-key\":" ++ TEXT_SORT_KEY ++ ",\"text-allow-overlap\":false,\"text-optional\":true}," ++
        "\"paint\":{\"text-color\":");
    try emitTextColor(w, scheme, palette);
    try w.s(",\"text-halo-color\":");
    try w.s(haloColor(scheme));
    try w.s(",\"text-halo-width\":1.4,\"text-halo-blur\":0.5}}");
}

const LineSpec = struct { name: []const u8, filt: []const u8, dash: ?[]const u8 };
const line_specs = [_]LineSpec{
    .{ .name = "solid", .filt = "[\"==\",[\"coalesce\",[\"get\",\"dash\"],\"solid\"],\"solid\"]", .dash = null },
    .{ .name = "dashed", .filt = "[\"==\",[\"get\",\"dash\"],\"dashed\"]", .dash = "[4,3]" },
    .{ .name = "dotted", .filt = "[\"==\",[\"get\",\"dash\"],\"dotted\"]", .dash = "[1,2]" },
};

/// Emit a MapLibre style.json (minified) for `opts.scheme`. Returns owned bytes.
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

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = W{ .out = &out, .a = alloc };

    const sea = if (palette.get("DEPDW")) |v| v.string else "#93aebb";

    try w.s("{\"version\":8,\"name\":\"chartplotter-native (");
    try w.s(opts.scheme);
    try w.s(", M2)\",\"sources\":{\"chart\":");
    if (opts.source_tiles) |t| {
        try w.s("{\"type\":\"vector\",\"tiles\":[\"");
        try w.s(t);
        var zb: [64]u8 = undefined;
        try w.s(try std.fmt.bufPrint(&zb, "\"],\"minzoom\":{d},\"maxzoom\":{d}}}", .{ opts.minzoom, opts.maxzoom }));
    } else {
        try w.s("{\"type\":\"vector\",\"url\":\"");
        try w.s(opts.pmtiles_url);
        try w.s("\"}");
    }
    try w.s("},\"layers\":[");

    // 1. background
    try w.s("{\"id\":\"background\",\"type\":\"background\",\"paint\":{\"background-color\":\"");
    try w.s(sea);
    try w.s("\"}}");

    // 2. area fills + SCAMIN clone
    for ([_][]const u8{ "areas", "areas_scamin" }) |sl| {
        const gate: ?[]const u8 = if (isScamin(sl)) SCAMIN_FILTER else null;
        try w.s(",{\"id\":\"fill-");
        try w.s(sl);
        try w.s("\",\"type\":\"fill\",\"source\":\"chart\",\"source-layer\":\"");
        try w.s(sl);
        try w.s("\",\"layout\":{\"fill-sort-key\":" ++ FILL_SORT ++ "},\"paint\":{\"fill-color\":");
        try emitAreasFillColor(w, palette);
        try w.s(",\"fill-antialias\":true}");
        try emitFilter(w, gate, null);
        try w.s("}");
    }

    // 3. area fill patterns (sprite required)
    if (sprite_on) {
        for ([_][]const u8{ "area_patterns", "area_patterns_scamin" }) |sl| {
            const gate: ?[]const u8 = if (isScamin(sl)) SCAMIN_FILTER else null;
            try w.s(",{\"id\":\"fillpat-");
            try w.s(sl);
            try w.s("\",\"type\":\"fill\",\"source\":\"chart\",\"source-layer\":\"");
            try w.s(sl);
            try w.s("\",\"paint\":{\"fill-pattern\":[\"concat\",\"pat:\",[\"coalesce\",[\"get\",\"pattern_name\"],\"\"]]}");
            try emitFilter(w, gate, null);
            try w.s("}");
        }
    }

    // 4. lines: solid/dashed/dotted over base + _scamin
    for ([_][]const u8{ "lines", "lines_scamin" }) |sl| {
        const gate: ?[]const u8 = if (isScamin(sl)) SCAMIN_FILTER else null;
        for (line_specs) |ls| {
            try w.s(",{\"id\":\"");
            try w.s(sl);
            try w.s("-");
            try w.s(ls.name);
            try w.s("\",\"type\":\"line\",\"source\":\"chart\",\"source-layer\":\"");
            try w.s(sl);
            try w.s("\"");
            try emitFilter(w, ls.filt, gate);
            try w.s(",\"paint\":");
            try emitLinePaint(w, palette, ls.dash);
            try w.s("}");
        }
    }

    // 5. complex (symbolised) lines
    for ([_][]const u8{ "complex_lines", "complex_lines_scamin" }) |sl| {
        const gate: ?[]const u8 = if (isScamin(sl)) SCAMIN_FILTER else null;
        try w.s(",{\"id\":\"complex-");
        try w.s(sl);
        try w.s("\",\"type\":\"line\",\"source\":\"chart\",\"source-layer\":\"");
        try w.s(sl);
        try w.s("\",\"paint\":");
        try emitLinePaint(w, palette, null);
        try emitFilter(w, gate, null);
        try w.s("}");
    }

    // 6. light sector limit lines
    for (line_specs) |ls| {
        try w.s(",{\"id\":\"sector_lines-");
        try w.s(ls.name);
        try w.s("\",\"type\":\"line\",\"source\":\"chart\",\"source-layer\":\"sector_lines\"");
        try emitFilter(w, ls.filt, null);
        try w.s(",\"paint\":");
        try emitLinePaint(w, palette, ls.dash);
        try w.s("}");
    }

    // 7. contour value labels (DEPCNT VALDCO)
    for ([_][]const u8{ "lines", "lines_scamin" }) |sl| {
        const gate: ?[]const u8 = if (isScamin(sl)) SCAMIN_FILTER else null;
        try w.s(",{\"id\":\"contour-labels-");
        try w.s(sl);
        try w.s("\",\"type\":\"symbol\",\"source\":\"chart\",\"source-layer\":\"");
        try w.s(sl);
        try w.s("\"");
        try emitFilter(w, "[\"has\",\"valdco\"]", gate);
        try w.s(",\"layout\":{\"symbol-placement\":\"line-center\",\"text-field\":[\"to-string\",[\"get\",\"valdco\"]]," ++
            "\"text-font\":" ++ FONT ++ ",\"text-size\":10,\"text-max-angle\":30,\"text-allow-overlap\":false," ++
            "\"text-optional\":true},\"paint\":{\"text-color\":");
        try emitContourLabelColor(w, opts.scheme, palette);
        try w.s(",\"text-halo-color\":");
        try w.s(haloColor(opts.scheme));
        try w.s(",\"text-halo-width\":1.2,\"text-halo-blur\":0.5}}");
    }

    // 8. point symbols + soundings (sprite required)
    if (sprite_on) {
        try emitPointSymbolLayers(w, "point_symbols", null);
        try emitPointSymbolLayers(w, "point_symbols_scamin", SCAMIN_FILTER);
        try w.s(",{\"id\":\"soundings\",\"type\":\"symbol\",\"source\":\"chart\",\"source-layer\":\"soundings\"," ++
            "\"layout\":{\"icon-image\":" ++ SOUNDINGS_IMG ++ ",\"icon-size\":" ++ ICON_SIZE ++
            ",\"icon-allow-overlap\":false}}");
    }

    // 9. text labels
    try emitTextLayers(w, opts.scheme, palette, "text", null);
    try emitTextLayers(w, opts.scheme, palette, "text_scamin", SCAMIN_FILTER);

    try w.s("]");
    if (opts.glyphs) |g| {
        try w.s(",\"glyphs\":\"");
        try w.s(g);
        try w.s("\"");
    }
    if (opts.sprite) |sp| {
        try w.s(",\"sprite\":\"");
        try w.s(sp);
        try w.s("\"");
    }
    try w.s("}");
    return out.toOwnedSlice(alloc);
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
    // background uses the DEPDW sea colour
    try std.testing.expectEqualStrings("background", layers.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("#c9edff", layers.items[0].object.get("paint").?.object.get("background-color").?.string);
    // sprite/glyphs present (enabled)
    try std.testing.expect(parsed.value.object.get("sprite") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"fill-areas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"#c9edff\"") != null);
}
