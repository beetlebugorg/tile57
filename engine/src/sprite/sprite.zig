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

const Raster = struct {
    name: []const u8,
    w: u32,
    h: u32,
    pivot_x: f32,
    pivot_y: f32,
    rgba: [*]u8, // C-owned (tg_svg_free); freed after blit
};

const Cell = struct { x: u32, y: u32, w: u32, h: u32, pivot_x: f32, pivot_y: f32 };

fn lessByHeightDesc(_: void, a: Raster, b: Raster) bool {
    return a.h > b.h;
}

/// Build a sprite atlas from S-101 symbol SVGs and a palette stylesheet.
/// Returns sprite.json + atlas PNG bytes (allocator-owned). Mirrors the Go
/// oracle's SpriteAtlasS101FS + packInto + toJSON.
pub fn spriteAtlas(a: std.mem.Allocator, srcs: []const SvgSrc, css_data: []const u8) !Atlas {
    return buildAtlas(a, srcs, css_data, sprite_atlas_width);
}

fn buildAtlas(a: std.mem.Allocator, srcs: []const SvgSrc, css_data: []const u8, width: u32) !Atlas {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var css = try loadCss(ar, css_data);

    // Process in id order so the stable height-sort below breaks ties the same
    // way the Go oracle does (it iterates the Symbols dir alphabetically).
    const ordered = try ar.dupe(SvgSrc, srcs);
    std.mem.sort(SvgSrc, ordered, {}, struct {
        fn less(_: void, x: SvgSrc, y: SvgSrc) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);

    var rasters = std.ArrayList(Raster).empty;
    for (ordered) |s| {
        const flat = flatten(ar, s.svg, &css) catch continue;
        var w: c_int = 0;
        var h: c_int = 0;
        const px = tg_svg_rasterize(flat.svg.ptr, @floatCast(px_per_mm), &w, &h) orelse continue;
        const uw: u32 = @intCast(@max(w, 0));
        const uh: u32 = @intCast(@max(h, 0));
        if (uw == 0 or uh == 0 or uw > max_cell_side or uh > max_cell_side) {
            tg_svg_free(px);
            continue;
        }
        try rasters.append(ar, .{
            .name = s.id,
            .w = uw,
            .h = uh,
            .pivot_x = @floatCast(-flat.vb[0] * px_per_mm),
            .pivot_y = @floatCast(-flat.vb[1] * px_per_mm),
            .rgba = px,
        });
    }
    defer for (rasters.items) |r| tg_svg_free(r.rgba);

    // Shelf-pack tallest-first (stable), matching the Go packInto.
    std.sort.insertion(Raster, rasters.items, {}, lessByHeightDesc);
    var cells = std.StringHashMap(Cell).init(ar);
    var pen_x: u32 = atlas_pad;
    var pen_y: u32 = atlas_pad;
    var shelf_h: u32 = 0;
    var total_h: u32 = atlas_pad;
    for (rasters.items) |r| {
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

    // Blit cells into the atlas RGBA.
    const rgba = try ar.alloc(u8, @as(usize, width) * height * 4);
    @memset(rgba, 0);
    for (rasters.items) |r| {
        const c = cells.get(r.name).?;
        var row: u32 = 0;
        while (row < r.h) : (row += 1) {
            const src_off = @as(usize, row) * r.w * 4;
            const dst_off = (@as(usize, c.y + row) * width + c.x) * 4;
            @memcpy(rgba[dst_off .. dst_off + r.w * 4], r.rgba[src_off .. src_off + r.w * 4]);
        }
    }

    // PNG encode (C/stb).
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
