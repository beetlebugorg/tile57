//! S-101 sprite/pattern atlas builder. Port of the Go oracle's
//! internal/engine/assets/sprites{,_s101}.go + pkg/s100/symbols: flatten each
//! symbol SVG (resolve its CSS colour classes against a palette stylesheet,
//! strip the .layout debug boxes, normalize the viewBox origin), rasterize it
//! (anti-aliased, even-odd) via nanosvg, shelf-pack the cells into one atlas,
//! and emit the sprite.json + atlas PNG the MapLibre client consumes.
//!
//! The AA rasterization + PNG encoding are done in C (svgraster.c, nanosvg +
//! stb_image_write); everything else — CSS, flatten, packing, JSON — is here.
//! Output is visually equivalent to the oracle (a different rasterizer/PNG
//! encoder, so not byte-identical); cell sizes, pivots, and packing match.

const std = @import("std");

extern fn tg_svg_rasterize(svg: [*:0]u8, scale: f32, out_w: *c_int, out_h: *c_int) ?[*]u8;
extern fn tg_png_encode(rgba: [*]const u8, w: c_int, h: c_int, out_len: *c_int) ?[*]u8;
extern fn tg_svg_free(p: ?*anyopaque) void;

/// device px per 0.01-mm symbol unit (matches the Go oracle's raster.go pxPerUnit).
pub const px_per_unit: f64 = 0.08;
const px_per_mm: f64 = px_per_unit * 100.0; // 8 px/mm
const atlas_pad: u32 = 1;
const max_cell_side: u32 = 640;
/// Atlas width for the ~724 S-101 symbols: wide enough that the packed height
/// stays under the 4096 WebGL texture limit (the Go oracle's s101AtlasWidth).
pub const sprite_atlas_width: u32 = 2048;

pub const SvgSrc = struct { id: []const u8, svg: []const u8 };
pub const Atlas = struct { json: []u8, png: []u8 };

// ---- CSS -----------------------------------------------------------------

/// Parse an S-100 *SvgStyle.css into class name -> declaration string (e.g.
/// "fCHYLW" -> "fill:#E1E139"). Mirrors symbols.LoadCSS: ".name { decl }",
/// declaration trimmed with any trailing ';' removed.
fn loadCss(a: std.mem.Allocator, data: []const u8) !std.StringHashMap([]const u8) {
    var out = std.StringHashMap([]const u8).init(a);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, i, '.')) |dot| {
        // class name: [A-Za-z0-9_]+ immediately after '.'
        var j = dot + 1;
        while (j < data.len and (std.ascii.isAlphanumeric(data[j]) or data[j] == '_')) j += 1;
        if (j == dot + 1) {
            i = dot + 1;
            continue;
        }
        const name = data[dot + 1 .. j];
        // optional whitespace then '{'
        var k = j;
        while (k < data.len and (data[k] == ' ' or data[k] == '\t' or data[k] == '\n' or data[k] == '\r')) k += 1;
        if (k >= data.len or data[k] != '{') {
            i = j;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, data, k, '}') orelse break;
        var decl = std.mem.trim(u8, data[k + 1 .. close], " \t\r\n");
        if (decl.len > 0 and decl[decl.len - 1] == ';') decl = decl[0 .. decl.len - 1];
        try out.put(name, decl);
        i = close + 1;
    }
    return out;
}

fn hasClass(classes: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, classes, " \t");
    while (it.next()) |c| if (std.mem.eql(u8, c, want)) return true;
    return false;
}

fn resolveStyle(a: std.mem.Allocator, classes: []const u8, css: *std.StringHashMap([]const u8)) ![]const u8 {
    if (classes.len == 0) return "";
    var decls = std.ArrayList(u8).empty;
    var it = std.mem.tokenizeAny(u8, classes, " \t");
    while (it.next()) |c| {
        if (css.get(c)) |decl| {
            if (decl.len > 0) {
                if (decls.items.len > 0) try decls.append(a, ';');
                try decls.appendSlice(a, decl);
            }
        }
    }
    return decls.items;
}

// ---- minimal XML scan (S-101 symbol SVGs are simple + machine-generated) ----

const Attr = struct { key: []const u8, value: []const u8 };

// Index of the '>' ending a tag started at `lt` ('<'), skipping quoted regions.
fn tagEnd(src: []const u8, lt: usize) ?usize {
    var i = lt + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '"' or c == '\'') {
            i = (std.mem.indexOfScalarPos(u8, src, i + 1, c) orelse return null) + 1;
            continue;
        }
        if (c == '>') return i;
        i += 1;
    }
    return null;
}

// Parse the interior of a start tag (between '<' and '>'/'/>') into a name and
// attributes. `inner` excludes the name's leading '<' and any trailing '/'.
const Tag = struct {
    name: []const u8,
    attrs: []Attr,
    fn attr(self: Tag, key: []const u8) []const u8 {
        for (self.attrs) |at| if (std.mem.eql(u8, at.key, key)) return at.value;
        return "";
    }
};

fn parseTag(a: std.mem.Allocator, inner: []const u8) !Tag {
    var i: usize = 0;
    while (i < inner.len and std.ascii.isWhitespace(inner[i])) i += 1;
    var j = i;
    while (j < inner.len and !std.ascii.isWhitespace(inner[j])) j += 1;
    const name = inner[i..j];
    var attrs = std.ArrayList(Attr).empty;
    i = j;
    while (i < inner.len) {
        while (i < inner.len and (std.ascii.isWhitespace(inner[i]) or inner[i] == '/')) i += 1;
        if (i >= inner.len) break;
        const ks = i;
        while (i < inner.len and inner[i] != '=' and !std.ascii.isWhitespace(inner[i])) i += 1;
        const key = inner[ks..i];
        while (i < inner.len and std.ascii.isWhitespace(inner[i])) i += 1;
        if (i >= inner.len or inner[i] != '=') {
            if (key.len > 0) try attrs.append(a, .{ .key = key, .value = "" });
            continue;
        }
        i += 1; // '='
        while (i < inner.len and std.ascii.isWhitespace(inner[i])) i += 1;
        if (i >= inner.len) break;
        const q = inner[i];
        if (q != '"' and q != '\'') continue;
        i += 1;
        const vs = i;
        while (i < inner.len and inner[i] != q) i += 1;
        const value = inner[vs..i];
        if (i < inner.len) i += 1; // closing quote
        if (key.len > 0) try attrs.append(a, .{ .key = key, .value = value });
    }
    return .{ .name = name, .attrs = attrs.items };
}

fn skippableName(name: []const u8) bool {
    return std.mem.eql(u8, name, "metadata") or std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "desc");
}

fn isShape(name: []const u8) bool {
    const shapes = [_][]const u8{ "path", "rect", "circle", "line", "polygon", "polyline", "ellipse" };
    for (shapes) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn writeAttrs(a: std.mem.Allocator, out: *std.ArrayList(u8), tag: Tag, style: []const u8) !void {
    for (tag.attrs) |at| {
        if (std.mem.eql(u8, at.key, "class")) continue;
        if (std.mem.eql(u8, at.key, "xmlns") or std.mem.startsWith(u8, at.key, "xmlns:")) continue;
        if (at.key.len == 0) continue;
        try out.print(a, " {s}=\"{s}\"", .{ at.key, at.value });
    }
    if (style.len > 0) try out.print(a, " style=\"{s}\"", .{style});
}

fn parseViewBox(s: []const u8) [4]f64 {
    var vb = [4]f64{ 0, 0, 0, 0 };
    var it = std.mem.tokenizeAny(u8, s, " ,\t");
    var n: usize = 0;
    while (it.next()) |f| : (n += 1) {
        if (n >= 4) break;
        vb[n] = std.fmt.parseFloat(f64, f) catch 0;
    }
    return vb;
}

const Flat = struct { svg: [:0]u8, vb: [4]f64 };

/// Flatten an S-101 symbol SVG: resolve CSS classes to inline style, drop the
/// .layout debug boxes / metadata / title / desc, and normalize the viewBox
/// origin to (0,0) by wrapping the content in a translate. Returns a NUL-
/// terminated SVG (nsvgParse mutates it in place) and the original viewBox.
fn flatten(a: std.mem.Allocator, src: []const u8, css: *std.StringHashMap([]const u8)) !Flat {
    var out = std.ArrayList(u8).empty;
    var vb = [4]f64{ 0, 0, 0, 0 };
    // Element-name stack of emitted open elements (to write their end tags).
    var stack = std.ArrayList([]const u8).empty;

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, src, i, '<')) |lt| {
        i = lt;
        if (std.mem.startsWith(u8, src[i..], "<!--")) {
            i = (std.mem.indexOfPos(u8, src, i, "-->") orelse src.len - 3) + 3;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "<?")) {
            i = (std.mem.indexOfPos(u8, src, i, "?>") orelse src.len - 2) + 2;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "<!")) {
            i = (std.mem.indexOfScalarPos(u8, src, i, '>') orelse src.len - 1) + 1;
            continue;
        }
        const gt = tagEnd(src, i) orelse break;
        if (src[i + 1] == '/') {
            // end tag
            const nm = std.mem.trim(u8, src[i + 2 .. gt], " \t\r\n");
            if (stack.items.len > 0 and std.mem.eql(u8, stack.items[stack.items.len - 1], nm)) {
                if (std.mem.eql(u8, nm, "svg")) {
                    try out.appendSlice(a, "</g></svg>");
                } else {
                    try out.print(a, "</{s}>", .{nm});
                }
                _ = stack.pop();
            }
            i = gt + 1;
            continue;
        }
        const self_close = src[gt - 1] == '/';
        const inner = src[i + 1 .. if (self_close) gt - 1 else gt];
        const tag = try parseTag(a, inner);
        i = gt + 1;

        const classes = tag.attr("class");
        if (hasClass(classes, "layout") or std.mem.eql(u8, tag.attr("display"), "none") or skippableName(tag.name)) {
            if (!self_close) skipSubtree(src, &i);
            continue;
        }
        const style = try resolveStyle(a, classes, css);

        if (std.mem.eql(u8, tag.name, "svg")) {
            vb = parseViewBox(tag.attr("viewBox"));
            try out.print(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">", .{ vb[2], vb[3], vb[2], vb[3] });
            try out.print(a, "<g transform=\"translate({d} {d})\">", .{ -vb[0], -vb[1] });
            try stack.append(a, "svg");
        } else if (std.mem.eql(u8, tag.name, "g")) {
            try out.appendSlice(a, "<g");
            try writeAttrs(a, &out, tag, style);
            try out.append(a, '>');
            if (self_close) {
                try out.appendSlice(a, "</g>");
            } else {
                try stack.append(a, "g");
            }
        } else if (isShape(tag.name)) {
            try out.print(a, "<{s}", .{tag.name});
            try writeAttrs(a, &out, tag, style);
            try out.appendSlice(a, "/>");
            if (!self_close) skipSubtree(src, &i);
        }
        // unknown elements: dropped (children still walked), matching Go.
    }

    try out.append(a, 0);
    const svgz = out.items[0 .. out.items.len - 1 :0];
    return .{ .svg = svgz, .vb = vb };
}

// Advance `i` (positioned just after a start tag's '>') past the subtree's
// matching end tag, handling nesting / self-closing / comments / PIs.
fn skipSubtree(src: []const u8, i: *usize) void {
    var depth: usize = 1;
    while (std.mem.indexOfScalarPos(u8, src, i.*, '<')) |lt| {
        if (std.mem.startsWith(u8, src[lt..], "<!--")) {
            i.* = (std.mem.indexOfPos(u8, src, lt, "-->") orelse src.len - 3) + 3;
            continue;
        }
        if (std.mem.startsWith(u8, src[lt..], "<?") or std.mem.startsWith(u8, src[lt..], "<!")) {
            i.* = (std.mem.indexOfScalarPos(u8, src, lt, '>') orelse src.len - 1) + 1;
            continue;
        }
        const gt = tagEnd(src, lt) orelse {
            i.* = src.len;
            return;
        };
        if (src[lt + 1] == '/') {
            depth -= 1;
            i.* = gt + 1;
            if (depth == 0) return;
        } else {
            if (src[gt - 1] != '/') depth += 1;
            i.* = gt + 1;
        }
    }
    i.* = src.len;
}

// ---- raster + atlas ------------------------------------------------------

// One already-rasterised, atlas-bound cell: its RGBA (Zig/arena-owned, straight
// alpha) plus the pivot the sprite anchor uses. Patterns carry pivot 0,0.
const NamedCell = struct {
    name: []const u8,
    w: u32,
    h: u32,
    pivot_x: f32 = 0,
    pivot_y: f32 = 0,
    rgba: []const u8,
};

const Cell = struct { x: u32, y: u32, w: u32, h: u32, pivot_x: f32, pivot_y: f32 };

fn lessByHeightDesc(_: void, a: NamedCell, b: NamedCell) bool {
    return a.h > b.h;
}

const RenderedSym = struct { w: u32, h: u32, pivot_x: f64, pivot_y: f64, rgba: []u8 };

// Flatten + rasterize one symbol SVG into arena-owned straight-alpha RGBA. null
// on parse/raster failure or a degenerate (zero-size) result.
fn renderSym(ar: std.mem.Allocator, svg: []const u8, css: *std.StringHashMap([]const u8)) ?RenderedSym {
    const flat = flatten(ar, svg, css) catch return null;
    var w: c_int = 0;
    var h: c_int = 0;
    const px = tg_svg_rasterize(flat.svg.ptr, @floatCast(px_per_mm), &w, &h) orelse return null;
    defer tg_svg_free(px);
    const uw: u32 = @intCast(@max(w, 0));
    const uh: u32 = @intCast(@max(h, 0));
    if (uw == 0 or uh == 0) return null;
    const n = @as(usize, uw) * uh * 4;
    const buf = ar.alloc(u8, n) catch return null;
    @memcpy(buf, px[0..n]);
    return .{ .w = uw, .h = uh, .pivot_x = -flat.vb[0] * px_per_mm, .pivot_y = -flat.vb[1] * px_per_mm, .rgba = buf };
}

/// Build a sprite atlas from S-101 symbol SVGs and a palette stylesheet.
/// Returns sprite.json + atlas PNG bytes (allocator-owned). Mirrors the Go
/// oracle's SpriteAtlasS101FS + packInto + toJSON.
pub fn spriteAtlas(a: std.mem.Allocator, srcs: []const SvgSrc, css_data: []const u8) !Atlas {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var css = try loadCss(ar, css_data);

    // Process in id order so the stable height-sort breaks ties the same way the
    // Go oracle does (it iterates the Symbols dir alphabetically).
    const ordered = try ar.dupe(SvgSrc, srcs);
    std.mem.sort(SvgSrc, ordered, {}, struct {
        fn less(_: void, x: SvgSrc, y: SvgSrc) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);

    var cells = std.ArrayList(NamedCell).empty;
    for (ordered) |s| {
        const r = renderSym(ar, s.svg, &css) orelse continue;
        if (r.w > max_cell_side or r.h > max_cell_side) continue;
        try cells.append(ar, .{
            .name = s.id,
            .w = r.w,
            .h = r.h,
            .pivot_x = @floatCast(r.pivot_x),
            .pivot_y = @floatCast(r.pivot_y),
            .rgba = r.rgba,
        });
    }
    return packAtlas(a, ar, cells.items, sprite_atlas_width);
}

/// One S-101 AreaFills/*.xml input: `id` is the file stem, `xml` the file bytes.
pub const AreaFillSrc = struct { id: []const u8, xml: []const u8 };

const AreaFill = struct { symbol_ref: []const u8, v1x: f64, v1y: f64, v2x: f64, v2y: f64 };

fn parseAreaFill(xml: []const u8) AreaFill {
    var af = AreaFill{ .symbol_ref = "", .v1x = 0, .v1y = 0, .v2x = 0, .v2y = 0 };
    if (attrAfter(xml, "<symbol", "reference")) |ref| af.symbol_ref = ref;
    if (between(xml, "<v1>", "</v1>")) |b| {
        af.v1x = tagFloat(b, "x") orelse 0;
        af.v1y = tagFloat(b, "y") orelse 0;
    }
    if (between(xml, "<v2>", "</v2>")) |b| {
        af.v2x = tagFloat(b, "x") orelse 0;
        af.v2y = tagFloat(b, "y") orelse 0;
    }
    return af;
}

fn between(s: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const rest = s[i + open.len ..];
    const e = std.mem.indexOf(u8, rest, close) orelse return null;
    return rest[0..e];
}

// Value of attribute `attr="..."` that appears after the first occurrence of `tag`.
fn attrAfter(s: []const u8, tag: []const u8, attr: []const u8) ?[]const u8 {
    const ti = std.mem.indexOf(u8, s, tag) orelse return null;
    // Build the `attr="` needle on the stack — attribute names are short, and this
    // avoids a heap alloc/free per call (was page_allocator, i.e. an mmap each time).
    var nbuf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nbuf, "{s}=\"", .{attr}) catch return null;
    const rest = s[ti..];
    const ai = std.mem.indexOf(u8, rest, needle) orelse return null;
    const after = rest[ai + needle.len ..];
    const q = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    return after[0..q];
}

fn tagFloat(s: []const u8, comptime tag: []const u8) ?f64 {
    const open = "<" ++ tag ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const rest = s[i + open.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    return std.fmt.parseFloat(f64, std.mem.trim(u8, rest[0..close], " \t\r\n")) catch null;
}

/// Build the area-fill pattern atlas from S-101 AreaFills + their referenced
/// Symbols + a palette stylesheet. Each fill tiles its symbol on the v1/v2
/// lattice into a seamless cell. Mirrors PatternAtlasS101FS + seamlessTile.
pub fn patternAtlas(a: std.mem.Allocator, fills: []const AreaFillSrc, symbols: []const SvgSrc, css_data: []const u8) !Atlas {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var css = try loadCss(ar, css_data);
    var sym_by_id = std.StringHashMap([]const u8).init(ar);
    for (symbols) |s| try sym_by_id.put(s.id, s.svg);

    const ordered = try ar.dupe(AreaFillSrc, fills);
    std.mem.sort(AreaFillSrc, ordered, {}, struct {
        fn less(_: void, x: AreaFillSrc, y: AreaFillSrc) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);

    var cells = std.ArrayList(NamedCell).empty;
    for (ordered) |f| {
        const af = parseAreaFill(f.xml);
        if (af.symbol_ref.len == 0) continue;
        const svg = sym_by_id.get(af.symbol_ref) orelse continue;
        const sym = renderSym(ar, svg, &css) orelse continue;
        const tile = seamlessTile(ar, sym, af) orelse continue;
        try cells.append(ar, .{ .name = f.id, .w = tile.w, .h = tile.h, .rgba = tile.rgba });
    }
    return packAtlas(a, ar, cells.items, sprite_atlas_width);
}

// ---- sprite-mln (the MapLibre-ready sprite) ------------------------------
//
// MapLibre always draws an icon centred on the point and consumes a sprite of
// {x,y,width,height,pixelRatio}. We build it DIRECTLY from the rendered cells
// (no raw→assemble round-trip): each symbol is pivot-centred into its cell; a
// "ctr:"-prefixed bbox-centred copy is added for the pivot_center area-symbol
// case; area-fill patterns are added as "pat:" at the tiling pixel ratio. Port
// of scripts/build_sprite.py (now removed), applied to RenderedSym in memory.

// Patterns are registered at this pixel ratio so the seamless tile repeats at the
// right on-screen density: atlasPpu / FEATURE_SCALE = 0.08 / (0.01/0.35278).
const pattern_pixel_ratio: f64 = px_per_unit / (0.01 / 0.35278); // ≈ 2.822

const MlnCell = struct { name: []const u8, w: u32, h: u32, ratio: f64, rgba: []const u8 };

/// A MapLibre sprite (sprite-mln.json + sprite-mln.png) assembled from the S-101
/// symbols + area-fill patterns + the soundings' composite glyph stacks. Returns
/// allocator-owned bytes. `soundings` are the distinct comma-joined glyph lists
/// the soundings layer references (collected from the baked tiles); pass &.{} to
/// skip them (e.g. the catalogue-only `sprite-mln` command without tiles).
pub fn spriteMln(a: std.mem.Allocator, symbols: []const SvgSrc, fills: []const AreaFillSrc, css_data: []const u8, soundings: []const []const u8) !Atlas {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var css = try loadCss(ar, css_data);

    var cells = std.ArrayList(MlnCell).empty;
    // name -> rendered symbol, for compositing sounding glyph stacks.
    var rendered = std.StringHashMap(RenderedSym).init(ar);

    // Symbols, id order (deterministic packing).
    const sym_ordered = try ar.dupe(SvgSrc, symbols);
    std.mem.sort(SvgSrc, sym_ordered, {}, struct {
        fn less(_: void, x: SvgSrc, y: SvgSrc) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);
    for (sym_ordered) |s| {
        const sym = renderSym(ar, s.svg, &css) orelse continue;
        try rendered.put(s.id, sym); // for sounding composites (any size)
        if (sym.w > max_cell_side or sym.h > max_cell_side) continue;
        const c = centredCanvas(ar, sym) orelse continue;
        try cells.append(ar, .{ .name = s.id, .w = c.w, .h = c.h, .ratio = 1, .rgba = c.rgba });
        // "ctr:" — the raw cell, bbox-centred by MapLibre (pivot ignored).
        const ctr_name = try std.fmt.allocPrint(ar, "ctr:{s}", .{s.id});
        try cells.append(ar, .{ .name = ctr_name, .w = sym.w, .h = sym.h, .ratio = 1, .rgba = sym.rgba });
    }

    // Area-fill patterns, id order, keyed "pat:<id>" at the pattern pixel ratio.
    const fill_ordered = try ar.dupe(AreaFillSrc, fills);
    std.mem.sort(AreaFillSrc, fill_ordered, {}, struct {
        fn less(_: void, x: AreaFillSrc, y: AreaFillSrc) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);
    var sym_by_id = std.StringHashMap([]const u8).init(ar);
    for (symbols) |s| try sym_by_id.put(s.id, s.svg);
    for (fill_ordered) |f| {
        const af = parseAreaFill(f.xml);
        if (af.symbol_ref.len == 0) continue;
        const svg = sym_by_id.get(af.symbol_ref) orelse continue;
        const sym = renderSym(ar, svg, &css) orelse continue;
        const t = seamlessTile(ar, sym, af) orelse continue;
        const name = try std.fmt.allocPrint(ar, "pat:{s}", .{f.id});
        try cells.append(ar, .{ .name = name, .w = t.w, .h = t.h, .ratio = pattern_pixel_ratio, .rgba = t.rgba });
    }

    // Sounding glyph stacks: composite each comma-joined list into one pivot-
    // centred image keyed by the exact string the soundings layer references.
    // Sorted for deterministic packing.
    const snd_ordered = try ar.dupe([]const u8, soundings);
    std.mem.sort([]const u8, snd_ordered, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    for (snd_ordered) |stack| {
        const t = compositeSounding(ar, &rendered, stack) orelse continue;
        try cells.append(ar, .{ .name = stack, .w = t.w, .h = t.h, .ratio = 1, .rgba = t.rgba });
    }

    return packMln(a, ar, cells.items, sprite_atlas_width);
}

// Composite a comma-joined glyph list (e.g. "SOUNDSC3,SOUNDS12,SOUNDS54") into
// one pivot-centred image — each glyph self-positions by its pivot. Port of
// build_sprite.py compositeSounding. null if no glyph is known.
fn compositeSounding(ar: std.mem.Allocator, rendered: *std.StringHashMap(RenderedSym), stack: []const u8) ?Tile {
    const Part = struct { sym: RenderedSym, left: f64, top: f64 };
    var parts = std.ArrayList(Part).empty;
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var it = std.mem.tokenizeScalar(u8, stack, ',');
    while (it.next()) |name| {
        const sym = rendered.get(name) orelse continue;
        const left = -sym.pivot_x;
        const top = -sym.pivot_y;
        parts.append(ar, .{ .sym = sym, .left = left, .top = top }) catch return null;
        min_x = @min(min_x, left);
        min_y = @min(min_y, top);
        max_x = @max(max_x, left + @as(f64, @floatFromInt(sym.w)));
        max_y = @max(max_y, top + @as(f64, @floatFromInt(sym.h)));
    }
    if (parts.items.len == 0) return null;
    const half_w = @max(-min_x, max_x);
    const half_h = @max(-min_y, max_y);
    const w: u32 = @max(1, @as(u32, @intFromFloat(@ceil(2 * half_w))));
    const h: u32 = @max(1, @as(u32, @intFromFloat(@ceil(2 * half_h))));
    const buf = ar.alloc(u8, @as(usize, w) * h * 4) catch return null;
    @memset(buf, 0);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    for (parts.items) |p| {
        const dx: i32 = @intFromFloat(@round(wf / 2 + p.left));
        const dy: i32 = @intFromFloat(@round(hf / 2 + p.top));
        blitClipped(buf, w, h, p.sym.rgba, p.sym.w, p.sym.h, dx, dy);
    }
    return .{ .w = w, .h = h, .rgba = buf };
}

// Pivot-centred canvas: move the S-52 pivot to the image centre so MapLibre's
// centre-on-point draws the symbol correctly. null on degenerate size.
const Canvas = struct { w: u32, h: u32, rgba: []u8 };
fn centredCanvas(ar: std.mem.Allocator, sym: RenderedSym) ?Canvas {
    const wf: f64 = @floatFromInt(sym.w);
    const hf: f64 = @floatFromInt(sym.h);
    const half_w = @max(sym.pivot_x, wf - sym.pivot_x);
    const half_h = @max(sym.pivot_y, hf - sym.pivot_y);
    const w: u32 = @max(1, @as(u32, @intFromFloat(@ceil(2 * half_w))));
    const h: u32 = @max(1, @as(u32, @intFromFloat(@ceil(2 * half_h))));
    const buf = ar.alloc(u8, @as(usize, w) * h * 4) catch return null;
    @memset(buf, 0);
    const ox: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) / 2 - sym.pivot_x));
    const oy: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h)) / 2 - sym.pivot_y));
    blitClipped(buf, w, h, sym.rgba, sym.w, sym.h, ox, oy);
    return .{ .w = w, .h = h, .rgba = buf };
}

// Copy a w×h RGBA cell into dst at (dx,dy), clipped (all pixels, transparent incl.).
fn blitClipped(dst: []u8, dw: u32, dh: u32, src: []const u8, sw: u32, sh: u32, dx: i32, dy: i32) void {
    var sy: u32 = 0;
    while (sy < sh) : (sy += 1) {
        const y = dy + @as(i32, @intCast(sy));
        if (y < 0 or y >= @as(i32, @intCast(dh))) continue;
        var sx: u32 = 0;
        while (sx < sw) : (sx += 1) {
            const x = dx + @as(i32, @intCast(sx));
            if (x < 0 or x >= @as(i32, @intCast(dw))) continue;
            const si = (@as(usize, sy) * sw + sx) * 4;
            const di = (@as(usize, @intCast(y)) * dw + @as(usize, @intCast(x))) * 4;
            @memcpy(dst[di .. di + 4], src[si .. si + 4]);
        }
    }
}

fn lessMlnByHeight(_: void, a: MlnCell, b: MlnCell) bool {
    return a.h > b.h;
}

// Shelf-pack MlnCells and emit the MapLibre sprite JSON {x,y,width,height,
// pixelRatio} + atlas PNG. `cells_in` must already be in id order (stable ties).
fn packMln(a: std.mem.Allocator, ar: std.mem.Allocator, cells_in: []MlnCell, width: u32) !Atlas {
    std.sort.insertion(MlnCell, cells_in, {}, lessMlnByHeight);
    const Placed = struct { x: u32, y: u32, w: u32, h: u32, ratio: f64 };
    var placed = std.StringHashMap(Placed).init(ar);
    var pen_x: u32 = 0;
    var pen_y: u32 = 0;
    var row_h: u32 = 0;
    const pad: u32 = 1;
    for (cells_in) |c| {
        if (pen_x + c.w + pad > width) {
            pen_x = 0;
            pen_y += row_h + pad;
            row_h = 0;
        }
        try placed.put(c.name, .{ .x = pen_x, .y = pen_y, .w = c.w, .h = c.h, .ratio = c.ratio });
        pen_x += c.w + pad;
        row_h = @max(row_h, c.h);
    }
    const height = pen_y + row_h + pad;

    const rgba = try ar.alloc(u8, @as(usize, width) * height * 4);
    @memset(rgba, 0);
    for (cells_in) |c| {
        const p = placed.get(c.name).?;
        var row: u32 = 0;
        while (row < c.h) : (row += 1) {
            const src_off = @as(usize, row) * c.w * 4;
            const dst_off = (@as(usize, p.y + row) * width + p.x) * 4;
            @memcpy(rgba[dst_off .. dst_off + c.w * 4], c.rgba[src_off .. src_off + c.w * 4]);
        }
    }

    var png_len: c_int = 0;
    const png_ptr = tg_png_encode(rgba.ptr, @intCast(width), @intCast(height), &png_len) orelse return error.PngEncode;
    defer tg_svg_free(png_ptr);
    const png = try a.dupe(u8, png_ptr[0..@intCast(png_len)]);

    // MapLibre sprite JSON: names sorted, {x,y,width,height,pixelRatio}.
    var names = std.ArrayList([]const u8).empty;
    var it = placed.keyIterator();
    while (it.next()) |k| try names.append(ar, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{");
    for (names.items, 0..) |n, i| {
        const p = placed.get(n).?;
        if (i > 0) try out.appendSlice(a, ", ");
        var buf: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "\"{s}\": {{\"x\": {d}, \"y\": {d}, \"width\": {d}, \"height\": {d}, \"pixelRatio\": {d}}}", .{ n, p.x, p.y, p.w, p.h, p.ratio });
        try out.appendSlice(a, s);
    }
    try out.appendSlice(a, "}\n");
    const json = try out.toOwnedSlice(a);
    return .{ .json = json, .png = png };
}

const Tile = struct { w: u32, h: u32, rgba: []u8 };

// Stamp the rendered symbol onto the v1/v2 lattice cell (px), wrapping at the
// edges. A staggered v2 (v2.x != 0) doubles the tile height and half-drops the
// second row. Mirrors the Go seamlessTile. null for a degenerate/oversized cell.
fn seamlessTile(ar: std.mem.Allocator, sym: RenderedSym, af: AreaFill) ?Tile {
    const wf = @round(af.v1x * px_per_mm);
    const row_hf = @round(af.v2y * px_per_mm);
    if (wf < 1 or row_hf < 1) return null;
    const w: u32 = @intFromFloat(wf);
    const row_h: u32 = @intFromFloat(row_hf);
    const rows: u32 = if (@abs(af.v2x) > 1e-6) 2 else 1;
    const h = row_h * rows;
    if (w > max_cell_side or h > max_cell_side) return null;

    const tile = ar.alloc(u8, @as(usize, w) * h * 4) catch return null;
    @memset(tile, 0);

    var centres: [2][2]f64 = undefined;
    var nc: usize = 1;
    centres[0] = .{ @as(f64, @floatFromInt(w)) / 2.0, @as(f64, @floatFromInt(row_h)) / 2.0 };
    if (rows == 2) {
        centres[1] = .{ @as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(row_h)) * 1.5 };
        nc = 2;
    }
    const pw: f64 = @floatFromInt(w);
    const ph: f64 = @floatFromInt(h);
    for (centres[0..nc]) |c| {
        var jy: i32 = -1;
        while (jy <= 1) : (jy += 1) {
            var ix: i32 = -1;
            while (ix <= 1) : (ix += 1) {
                const dx: i32 = @intFromFloat(@round(c[0] + @as(f64, @floatFromInt(ix)) * pw - sym.pivot_x));
                const dy: i32 = @intFromFloat(@round(c[1] + @as(f64, @floatFromInt(jy)) * ph - sym.pivot_y));
                stampOver(tile, w, h, sym, dx, dy);
            }
        }
    }
    return .{ .w = w, .h = h, .rgba = tile };
}

// Copy sym's non-transparent pixels into dst at (dx,dy), clipped to dst.
fn stampOver(dst: []u8, dw: u32, dh: u32, sym: RenderedSym, dx: i32, dy: i32) void {
    var sy: u32 = 0;
    while (sy < sym.h) : (sy += 1) {
        const y = dy + @as(i32, @intCast(sy));
        if (y < 0 or y >= @as(i32, @intCast(dh))) continue;
        var sx: u32 = 0;
        while (sx < sym.w) : (sx += 1) {
            const x = dx + @as(i32, @intCast(sx));
            if (x < 0 or x >= @as(i32, @intCast(dw))) continue;
            const si = (@as(usize, sy) * sym.w + sx) * 4;
            if (sym.rgba[si + 3] == 0) continue;
            const di = (@as(usize, @intCast(y)) * dw + @as(usize, @intCast(x))) * 4;
            @memcpy(dst[di .. di + 4], sym.rgba[si .. si + 4]);
        }
    }
}

// Shelf-pack already-rasterised cells (tallest-first, stable) into one atlas of
// `width`, blit them, and emit { json, png }. Mirrors the Go packInto + toJSON +
// encodePNG. `cells_in` must already be in id order (for stable tie-break).
fn packAtlas(a: std.mem.Allocator, ar: std.mem.Allocator, cells_in: []NamedCell, width: u32) !Atlas {
    std.sort.insertion(NamedCell, cells_in, {}, lessByHeightDesc);
    var cells = std.StringHashMap(Cell).init(ar);
    var pen_x: u32 = atlas_pad;
    var pen_y: u32 = atlas_pad;
    var shelf_h: u32 = 0;
    var total_h: u32 = atlas_pad;
    for (cells_in) |r| {
        if (pen_x + r.w + atlas_pad > width) {
            pen_x = atlas_pad;
            pen_y += shelf_h + atlas_pad;
            shelf_h = 0;
        }
        try cells.put(r.name, .{ .x = pen_x, .y = pen_y, .w = r.w, .h = r.h, .pivot_x = r.pivot_x, .pivot_y = r.pivot_y });
        pen_x += r.w + atlas_pad;
        shelf_h = @max(shelf_h, r.h);
        total_h = @max(total_h, pen_y + r.h + atlas_pad);
    }
    const height = @max(total_h, 1);

    const rgba = try ar.alloc(u8, @as(usize, width) * height * 4);
    @memset(rgba, 0);
    for (cells_in) |r| {
        const c = cells.get(r.name).?;
        var row: u32 = 0;
        while (row < r.h) : (row += 1) {
            const src_off = @as(usize, row) * r.w * 4;
            const dst_off = (@as(usize, c.y + row) * width + c.x) * 4;
            @memcpy(rgba[dst_off .. dst_off + r.w * 4], r.rgba[src_off .. src_off + r.w * 4]);
        }
    }

    var png_len: c_int = 0;
    const png_ptr = tg_png_encode(rgba.ptr, @intCast(width), @intCast(height), &png_len) orelse return error.PngEncode;
    defer tg_svg_free(png_ptr);
    const png = try a.dupe(u8, png_ptr[0..@intCast(png_len)]);

    const json = try atlasJson(a, &cells, width, height);
    return .{ .json = json, .png = png };
}

// Render the atlas description (_meta + per-name cells), names sorted. Float
// formatting matches the Go oracle: px_per_unit "%g", pivots "%.2f".
fn atlasJson(a: std.mem.Allocator, cells: *std.StringHashMap(Cell), width: u32, height: u32) ![]u8 {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(a);
    var it = cells.keyIterator();
    while (it.next()) |k| try names.append(a, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.print(a, "{{\n  \"_meta\": {{ \"px_per_unit\": {d}, \"width\": {d}, \"height\": {d} }}", .{ px_per_unit, width, height });
    for (names.items) |n| {
        const c = cells.get(n).?;
        try out.print(a, ",\n  \"{s}\": {{ \"x\": {d}, \"y\": {d}, \"w\": {d}, \"h\": {d}, \"pivot_x\": {d:.2}, \"pivot_y\": {d:.2} }}", .{ n, c.x, c.y, c.w, c.h, c.pivot_x, c.pivot_y });
    }
    try out.appendSlice(a, "\n}\n");
    return out.toOwnedSlice(a);
}
