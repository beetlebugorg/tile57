//! assets — offline portrayal-asset generation for the chart bundle. Mirrors the
//! Go oracle's internal/engine/assets (EmitS101): the rendering half of the
//! tile/style contract, emitted from the same S-101 catalogue that drives the
//! tiles so the two can't drift. Mirrors the Go oracle's bundle assets.
//!
//! Pure Zig (no libc/fs): callers read the catalogue bytes and pass them in, the
//! same shape as s100/catalogue.zig. RGB lives ONLY in colortables.json; the
//! tiles stay colour *tokens*.
//!
//! Implemented now: colortables.json (token -> hex, per day/dusk/night palette),
//! the MapLibre style.json layer set (style.zig), and manifest.json (pins
//! schema_version; couples tiles <-> portrayal). TODO, tracked in
//! next: linestyles.json, sprite/pattern atlases (SVG raster),
//! and glyphs (SDF) — to light up the symbol/text/pattern layers.

const std = @import("std");

/// The tile-vocabulary version both halves of a bundle are stamped with: the MVT
/// layer/property set in s57_mvt.zig and the style/colortables that render it.
/// Bump on ANY change to layer names or feature property keys.
pub const SCHEMA_VERSION = "tile57/1";

// MapLibre style.json generation lives in style.zig.
pub const StyleOpts = @import("style.zig").StyleOpts;
pub const styleJson = @import("style.zig").styleJson;
pub const buildFromTemplate = @import("style.zig").buildFromTemplate;
pub const buildFromTemplateScamin = @import("style.zig").buildFromTemplateScamin;
pub const styleDiff = @import("style.zig").styleDiff;

// ---- colortables.json ----------------------------------------------------

const Palette = struct { xml_name: []const u8, key: []const u8 };

// The three S-101 palettes, emitted in this order. xml_name matches the
// <palette name="..."> in colorProfile.xml; key is the colortables.json field.
const palettes = [_]Palette{
    .{ .xml_name = "Day", .key = "day" },
    .{ .xml_name = "Dusk", .key = "dusk" },
    .{ .xml_name = "Night", .key = "night" },
};

const Entry = struct { token: []const u8, hex: [7]u8 };

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.token, b.token);
}

// Read the decimal byte inside the first <tag>NNN</tag> within `s`. Used for the
// <red>/<green>/<blue> children of an <item>'s <srgb> block — those tags are
// unique to <srgb> (the sibling <cie> block carries <x>/<y>/<L>), so a plain
// forward scan over the item is unambiguous.
fn tagByte(s: []const u8, comptime tag: []const u8) ?u8 {
    const open = "<" ++ tag ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const rest = s[i + open.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const num = std.mem.trim(u8, rest[0..close], " \t\r\n");
    return std.fmt.parseInt(u8, num, 10) catch null;
}

// Return the slice of `xml` covering one <palette name="NAME"> … </palette>.
fn findPalette(xml: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "<palette name=\"{s}\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, xml, needle) orelse return null;
    const after = xml[start..];
    const end = std.mem.indexOf(u8, after, "</palette>") orelse after.len;
    return after[0..end];
}

fn collectItems(alloc: std.mem.Allocator, block: []const u8, entries: *std.ArrayList(Entry)) !void {
    const open = "<item token=\"";
    var rest = block;
    while (std.mem.indexOf(u8, rest, open)) |ti| {
        const after = rest[ti + open.len ..];
        const q = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const token = after[0..q];
        const item_end = std.mem.indexOf(u8, after, "</item>") orelse after.len;
        const item = after[0..item_end];
        rest = after[item_end..];
        const r = tagByte(item, "red") orelse continue;
        const g = tagByte(item, "green") orelse continue;
        const b = tagByte(item, "blue") orelse continue;
        var e: Entry = .{ .token = token, .hex = undefined };
        _ = std.fmt.bufPrint(&e.hex, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch continue;
        try entries.append(alloc, e);
    }
}

/// Parse an S-101 ColorProfiles/colorProfile.xml and emit colortables.json:
///   {"day":{TOKEN:"#rrggbb",…},"dusk":{…},"night":{…}}
/// Tokens are sorted within each palette (stable, diff-friendly, matches the Go
/// oracle's reference/assets/colortables.json). Returns allocator-owned bytes.
pub fn colorTablesJson(alloc: std.mem.Allocator, xml: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\n");
    for (palettes, 0..) |p, pi| {
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(alloc);
        if (findPalette(xml, p.xml_name)) |block| try collectItems(alloc, block, &entries);
        std.mem.sort(Entry, entries.items, {}, lessEntry);

        try out.appendSlice(alloc, "  \"");
        try out.appendSlice(alloc, p.key);
        try out.appendSlice(alloc, "\": {");
        if (entries.items.len == 0) {
            try out.appendSlice(alloc, "}");
        } else {
            try out.appendSlice(alloc, "\n");
            for (entries.items, 0..) |e, ei| {
                try out.appendSlice(alloc, "    \"");
                try out.appendSlice(alloc, e.token);
                try out.appendSlice(alloc, "\": \"");
                try out.appendSlice(alloc, e.hex[0..]);
                try out.appendSlice(alloc, if (ei + 1 < entries.items.len) "\",\n" else "\"\n");
            }
            try out.appendSlice(alloc, "  }");
        }
        try out.appendSlice(alloc, if (pi + 1 < palettes.len) ",\n" else "\n");
    }
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

// ---- linestyles.json -----------------------------------------------------
//
// Port of the Go oracle's internal/engine/assets.LinestylesJSONS101 (+ the
// pkg/s100/catalog LineStyles XML loader). Parses each S-101 LineStyles/*.xml
// definition into a dash pattern + placed symbols and emits linestyles.json,
// matching the client schema: per id, period_px, a flat [on,off,…] dash array,
// the pen colour token + width, and the symbols placed along the period.
// Verified byte-identical to reference/assets/linestyles.json.

// DefaultPxPerSymbolUnit is screen px per 0.01-mm PresLib symbol unit (Go:
// internal/engine/portrayal.DefaultPxPerSymbolUnit, a float32). linestyle_px_per_mm
// converts mm dimensions to screen px (×100: 1 mm = 100 symbol units). The f32→f64
// promotion must match Go's `float64(DefaultPxPerSymbolUnit)` to stay byte-exact.
const default_px_per_symbol_unit: f32 = 0.01 / 0.26458;
const linestyle_px_per_mm: f64 = @as(f64, default_px_per_symbol_unit) * 100.0;

/// One raw LineStyles/*.xml input: `id` is the file stem, `xml` the file bytes.
pub const LineStyleSrc = struct { id: []const u8, xml: []const u8 };

// Raw (millimetre) line-style geometry from one LineStyles/*.xml, before any
// px conversion. Public so the baker can build its along-line tessellation table
// (emitComplexLine) at the PresLib feature scale, which differs from the symbol
// scale `analysePattern` applies for the client linestyles.json.
pub const Dash = struct { start: f64, length: f64 };
pub const PlacedSym = struct { reference: []const u8, position: f64 };
pub const ParsedLine = struct {
    interval_length: f64 = 0,
    pen_width: f64 = 0,
    pen_color: []const u8 = "",
    dashes: []Dash = &.{},
    symbols: []PlacedSym = &.{},
};

const OnRun = struct { lo: f64, hi: f64 };
fn lessRun(_: void, a: OnRun, b: OnRun) bool {
    return a.lo < b.lo;
}

fn clampf(v: f64, lo: f64, hi: f64) f64 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// Read the float inside the first <tag>…</tag> within `s`, or null if absent.
fn tagFloat(s: []const u8, comptime tag: []const u8) ?f64 {
    const open = "<" ++ tag ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const rest = s[i + open.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const num = std.mem.trim(u8, rest[0..close], " \t\r\n");
    return std.fmt.parseFloat(f64, num) catch null;
}

// Read the text inside the first <tag>…</tag> within `s`, or "" if absent.
fn tagText(s: []const u8, comptime tag: []const u8) []const u8 {
    const open = "<" ++ tag ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return "";
    const rest = s[i + open.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '<') orelse return "";
    return std.mem.trim(u8, rest[0..close], " \t\r\n");
}

// Read the value of attribute `attr="…"` after the first occurrence of `attr=`.
fn attrText(s: []const u8, comptime attr: []const u8) ?[]const u8 {
    const needle = attr ++ "=\"";
    const i = std.mem.indexOf(u8, s, needle) orelse return null;
    const rest = s[i + needle.len ..];
    const q = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q];
}

// The body slice of one LineStyles XML to read fields from. A simple lineStyle
// root (<ls:lineStyle …>) is bounded by its </ls:lineStyle> close — stopping
// there drops the trailing HTML-comment variants some files carry (e.g.
// CBLOHD01). A compositeLineStyle has no </ls:lineStyle>; its first component
// <lineStyle>…</lineStyle> is the primary the client schema emits, so we take
// up to the first </lineStyle> close.
fn lineBody(xml: []const u8) []const u8 {
    if (std.mem.indexOf(u8, xml, "</ls:lineStyle>")) |e| return xml[0..e];
    if (std.mem.indexOf(u8, xml, "</lineStyle>")) |e| return xml[0..e];
    return xml;
}

pub fn parseLineStyle(a: std.mem.Allocator, xml: []const u8) !ParsedLine {
    const body = lineBody(xml);
    var p = ParsedLine{
        .interval_length = tagFloat(body, "intervalLength") orelse 0,
        .pen_color = tagText(body, "color"),
    };
    if (attrText(body, "width")) |w| p.pen_width = std.fmt.parseFloat(f64, w) catch 0;

    var dashes = std.ArrayList(Dash).empty;
    var rest = body;
    while (std.mem.indexOf(u8, rest, "<dash>")) |di| {
        const after = rest[di + "<dash>".len ..];
        const end = std.mem.indexOf(u8, after, "</dash>") orelse after.len;
        const block = after[0..end];
        try dashes.append(a, .{
            .start = tagFloat(block, "start") orelse 0,
            .length = tagFloat(block, "length") orelse 0,
        });
        rest = after[end..];
    }
    p.dashes = dashes.items;

    var syms = std.ArrayList(PlacedSym).empty;
    rest = body;
    while (std.mem.indexOf(u8, rest, "<symbol ")) |si| {
        const after = rest[si..];
        const end = std.mem.indexOf(u8, after, "</symbol>") orelse after.len;
        const block = after[0..end];
        if (attrText(block, "reference")) |ref| {
            try syms.append(a, .{ .reference = ref, .position = tagFloat(block, "position") orelse 0 });
        }
        rest = after[end..];
    }
    p.symbols = syms.items;
    return p;
}

const LsPattern = struct {
    period_px: f64,
    runs: []OnRun,
    symbols: []PlacedSym,
    color_token: []const u8,
    width_px: f64,
};

// s101Pattern: convert one parsed line style into its analysed dash pattern.
// Returns null when there is no interval to tile (a pure-symbol style), matching
// the Go oracle (those ids are dropped from linestyles.json, e.g. INDHLT02).
fn analysePattern(a: std.mem.Allocator, p: ParsedLine) !?LsPattern {
    const period = p.interval_length * linestyle_px_per_mm;
    if (period < 0.5) return null;

    var runs = std.ArrayList(OnRun).empty;
    if (p.dashes.len == 0) {
        try runs.append(a, .{ .lo = 0, .hi = period }); // solid pen
    } else {
        for (p.dashes) |d| {
            const lo = clampf(d.start * linestyle_px_per_mm, 0, period);
            const hi = clampf((d.start + d.length) * linestyle_px_per_mm, 0, period);
            if (hi - lo > 1e-6) try runs.append(a, .{ .lo = lo, .hi = hi });
        }
        std.sort.insertion(OnRun, runs.items, {}, lessRun); // stable, matches SliceStable
    }
    return .{
        .period_px = period,
        .runs = runs.items,
        .symbols = p.symbols,
        .color_token = p.pen_color,
        .width_px = p.pen_width * linestyle_px_per_mm,
    };
}

// dashArray: sorted on-runs over [0, period] -> flat [on,off,on,off,…] starting
// with an "on" entry (leading 0 when the pattern opens with a gap), padded to an
// even length so it tiles cleanly. Direct port of the Go oracle.
fn dashArray(a: std.mem.Allocator, p: LsPattern) ![]f64 {
    var out = std.ArrayList(f64).empty;
    var pos: f64 = 0; // end of the last consumed run

    const Flush = struct {
        fn call(al: std.mem.Allocator, o: *std.ArrayList(f64), cur: *f64, lo: f64, hi: f64) !void {
            if (lo > cur.* + 1e-6) {
                if (o.items.len == 0) try o.append(al, 0); // leading gap -> 0 "on"
                try o.append(al, lo - cur.*); // off
            }
            try o.append(al, hi - lo); // on
            cur.* = hi;
        }
    };

    var have_prev = false;
    var prev_lo: f64 = 0;
    var prev_hi: f64 = 0;
    for (p.runs) |run| {
        if (!have_prev) {
            have_prev = true;
            prev_lo = run.lo;
            prev_hi = run.hi;
            continue;
        }
        if (run.lo <= prev_hi + 1e-6) {
            prev_hi = @max(prev_hi, run.hi); // overlap/adjacent -> merge
        } else {
            try Flush.call(a, &out, &pos, prev_lo, prev_hi);
            prev_lo = run.lo;
            prev_hi = run.hi;
        }
    }
    if (have_prev) try Flush.call(a, &out, &pos, prev_lo, prev_hi);

    if (p.period_px - pos > 1e-6) { // trailing gap to period end
        if (out.items.len == 0) try out.append(a, 0); // pure-gap pattern
        try out.append(a, p.period_px - pos); // off
    }
    if (out.items.len % 2 == 1) try out.append(a, 0); // even length tiles cleanly
    if (out.items.len == 0) {
        try out.append(a, 0);
        try out.append(a, p.period_px);
    }
    return out.items;
}

fn appendF3(out: *std.ArrayList(u8), a: std.mem.Allocator, v: f64) !void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "{d:.3}", .{v}));
}

/// Emit linestyles.json from the S-101 LineStyles XML sources. ids are sorted
/// (stable, diff-friendly); pure-symbol styles with no interval are dropped.
/// Returns allocator-owned bytes. Mirrors the Go oracle's LinestylesJSONS101.
pub fn linestylesJson(alloc: std.mem.Allocator, srcs: []const LineStyleSrc) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var ids = std.ArrayList([]const u8).empty;
    for (srcs) |s| try ids.append(a, s.id);
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\n");
    var first = true;
    for (ids.items) |id| {
        // Find the source with this id (srcs is small).
        var xml: []const u8 = "";
        for (srcs) |s| if (std.mem.eql(u8, s.id, id)) {
            xml = s.xml;
            break;
        };
        const parsed = try parseLineStyle(a, xml);
        const pat = (try analysePattern(a, parsed)) orelse continue;
        const dash = try dashArray(a, pat);

        if (!first) try out.appendSlice(alloc, ",\n");
        first = false;
        try out.appendSlice(alloc, "  \"");
        try out.appendSlice(alloc, id);
        try out.appendSlice(alloc, "\": { \"period_px\": ");
        try appendF3(&out, alloc, pat.period_px);
        try out.appendSlice(alloc, ", \"dash\": [");
        for (dash, 0..) |v, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try appendF3(&out, alloc, v);
        }
        try out.appendSlice(alloc, "], \"color_token\": \"");
        try out.appendSlice(alloc, pat.color_token);
        try out.appendSlice(alloc, "\", \"width_px\": ");
        try appendF3(&out, alloc, pat.width_px);
        try out.appendSlice(alloc, ", \"symbols\": [");
        for (pat.symbols, 0..) |sym, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, "{ \"o\": ");
            try appendF3(&out, alloc, sym.position * linestyle_px_per_mm);
            try out.appendSlice(alloc, ", \"n\": \"");
            try out.appendSlice(alloc, sym.reference);
            try out.appendSlice(alloc, "\", \"r\": ");
            try appendF3(&out, alloc, 0); // S-101 symbols carry no sub-rotation
            try out.appendSlice(alloc, " }");
        }
        try out.appendSlice(alloc, "] }");
    }
    try out.appendSlice(alloc, "\n}\n");
    return out.toOwnedSlice(alloc);
}

// ---- manifest.json -------------------------------------------------------

/// Inputs for the bundle manifest. Relative paths only (the bundle is
/// relocatable). bbox is [west, south, east, north]; anchor is [lon, lat].
pub const Manifest = struct {
    generator: []const u8,
    created: []const u8 = "", // ISO 8601; Zig has no wall clock, so passed in
    catalogue_version: []const u8 = "",
    tiles_rel: []const u8,
    colortables_rel: []const u8,
    minzoom: u8,
    maxzoom: u8,
    bbox: [4]f64,
    anchor: [2]f64,
    cells: []const []const u8,
    styles: ?Styles = null, // per-palette style.json paths, if emitted

    pub const Styles = struct { day: []const u8, dusk: []const u8, night: []const u8 };
};

/// Emit the bundle manifest.json. Loaded first by a renderer, which refuses a
/// bundle whose schema_version it doesn't speak — turning tile/style coupling
/// into a checked invariant. Returns allocator-owned bytes.
pub fn manifestJson(alloc: std.mem.Allocator, m: Manifest) ![]u8 {
    // The manifest is plain data: describe it as a value and let std.json emit it.
    // indent_2 keeps it human-readable; emit_null_optional_fields drops "styles"
    // (the one optional) when absent.
    return std.json.Stringify.valueAlloc(alloc, .{
        .bundle_version = 1,
        .schema_version = SCHEMA_VERSION,
        .generator = m.generator,
        .created = m.created,
        .catalogue_version = m.catalogue_version,
        .data = .{
            .tiles = m.tiles_rel,
            .minzoom = m.minzoom,
            .maxzoom = m.maxzoom,
            .bbox = m.bbox,
            .anchor = m.anchor,
            .cells = m.cells,
        },
        .portrayal = .{
            .colortables = m.colortables_rel,
            .styles = m.styles,
        },
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

// ---- tests ---------------------------------------------------------------

test "colorTablesJson: sorted tokens, lowercase hex, all three palettes" {
    const xml =
        \\<cp:colorProfile>
        \\  <palette name="Day" css="daySvgStyle.css">
        \\    <item token="DEPDW"><cie><xyL><x>0.28</x></xyL></cie>
        \\      <srgb><red>201</red><green>237</green><blue>255</blue></srgb></item>
        \\    <item token="CHBLK"><srgb><red>0</red><green>0</green><blue>0</blue></srgb></item>
        \\  </palette>
        \\  <palette name="Night" css="nightSvgStyle.css">
        \\    <item token="DEPDW"><srgb><red>10</red><green>20</green><blue>30</blue></srgb></item>
        \\  </palette>
        \\</cp:colorProfile>
    ;
    const out = try colorTablesJson(std.testing.allocator, xml);
    defer std.testing.allocator.free(out);
    const expected =
        \\{
        \\  "day": {
        \\    "CHBLK": "#000000",
        \\    "DEPDW": "#c9edff"
        \\  },
        \\  "dusk": {},
        \\  "night": {
        \\    "DEPDW": "#0a141e"
        \\  }
        \\}
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "linestylesJson: dash pattern + placed symbols, sorted ids, skips no-interval" {
    const achare =
        \\<ls:lineStyle xmlns:ls="http://www.iho.int/S100LineStyle/5.2">
        \\   <intervalLength>32.3</intervalLength>
        \\   <pen width="0.32"><color>CHMGD</color></pen>
        \\   <dash><start>2</start><length>6</length></dash>
        \\   <dash><start>18.2</start><length>6</length></dash>
        \\   <dash><start>26.2</start><length>6</length></dash>
        \\   <symbol reference="EMAREMG1"><position>5</position></symbol>
        \\</ls:lineStyle>
    ;
    // No <intervalLength> -> dropped from output (matches the Go oracle, e.g. INDHLT02).
    const noint =
        \\<ls:compositeLineStyle xmlns:ls="http://www.iho.int/S100LineStyle/5.2">
        \\  <lineStyle><pen width="1.28"><color>BKAJ1</color></pen></lineStyle>
        \\</ls:compositeLineStyle>
    ;
    const out = try linestylesJson(std.testing.allocator, &.{
        .{ .id = "ZZNOINT", .xml = noint },
        .{ .id = "ACHARE51", .xml = achare },
    });
    defer std.testing.allocator.free(out);
    const expected =
        "{\n" ++
        "  \"ACHARE51\": { \"period_px\": 122.080, \"dash\": [0.000, 7.559, 22.677, 38.552, 22.677, 7.559, 22.677, 0.378], \"color_token\": \"CHMGD\", \"width_px\": 1.209, \"symbols\": [{ \"o\": 18.898, \"n\": \"EMAREMG1\", \"r\": 0.000 }] }\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "manifestJson: pins schema_version and couples tiles to portrayal" {
    const out = try manifestJson(std.testing.allocator, .{
        .generator = "tile57 0.1.0",
        .created = "2026-06-27T00:00:00Z",
        .catalogue_version = "S-101 PC 1.4.0",
        .tiles_rel = "tiles/chart.pmtiles",
        .colortables_rel = "assets/colortables.json",
        .minzoom = 8,
        .maxzoom = 16,
        .bbox = .{ -76.55, 38.90, -76.40, 39.02 },
        .anchor = .{ -76.475, 38.96 },
        .cells = &.{ "US5MD1MC", "US4MD81M" },
    });
    defer std.testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("tile57/1", o.get("schema_version").?.string);
    const data = o.get("data").?.object;
    try std.testing.expectEqualStrings("tiles/chart.pmtiles", data.get("tiles").?.string);
    try std.testing.expectEqual(@as(usize, 2), data.get("cells").?.array.items.len);
    try std.testing.expectEqualStrings("US5MD1MC", data.get("cells").?.array.items[0].string);
    const portrayal = o.get("portrayal").?.object;
    try std.testing.expectEqualStrings("assets/colortables.json", portrayal.get("colortables").?.string);
    // "styles" is omitted when not provided (emit_null_optional_fields = false)
    try std.testing.expect(portrayal.get("styles") == null);
}
