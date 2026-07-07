//! SDF glyph atlas: rasterize the label font's glyphs as signed-distance fields
//! (via vendored stb_truetype) into one texture, so a GPU host draws text as
//! textured quads that stay crisp at any size — the MapLibre / game text path.
//! Lives in the sprite module because it shares that module's C glue (stb) and,
//! like the sprite atlas, is a baked asset the host loads once.
const std = @import("std");
const Allocator = std.mem.Allocator;

// C glue (src/sprite/svgraster.c): stb_truetype SDF + the shared PNG encoder.
extern fn tg_glyph_sdf(font: [*]const u8, font_len: c_int, cp: c_int, em_px: f32, pad: c_int, w: *c_int, h: *c_int, xoff: *c_int, yoff: *c_int, advance: *f32) callconv(.c) ?[*]u8;
extern fn tg_glyph_free(p: ?[*]u8) callconv(.c) void;
extern fn tg_png_encode(rgba: [*]const u8, w: c_int, h: c_int, out_len: *c_int) callconv(.c) ?[*]u8;
extern fn tg_svg_free(p: ?*anyopaque) callconv(.c) void;

/// Per-glyph placement in EM units relative to the pen origin (x = pen,
/// y = baseline, y DOWN), plus its atlas UV rect (normalized 0..1).
pub const GlyphInfo = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 0,
    v1: f32 = 0,
    off_x: f32 = 0,
    off_y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    advance: f32 = 0,
};

pub const Atlas = struct {
    rgba: []u8, // width*height*4, SDF replicated into RGBA
    width: u32,
    height: u32,
    em_px: f32, // px one em was rasterized at
    pad: f32, // SDF spread in px (shader edge reference = pad/em_px in EM)
    glyphs: std.AutoHashMapUnmanaged(u21, GlyphInfo) = .{},

    pub fn deinit(self: *Atlas, a: Allocator) void {
        a.free(self.rgba);
        self.glyphs.deinit(a);
    }
    pub fn info(self: *const Atlas, cp: u21) ?GlyphInfo {
        return self.glyphs.get(cp);
    }
    /// Encode the atlas as PNG (caller owns; free with std allocator). Uses the
    /// shared C encoder.
    pub fn encodePng(self: *const Atlas, a: Allocator) !?[]u8 {
        var len: c_int = 0;
        const p = tg_png_encode(self.rgba.ptr, @intCast(self.width), @intCast(self.height), &len) orelse return null;
        defer tg_svg_free(p);
        return try a.dupe(u8, p[0..@intCast(len)]);
    }
};

/// Printable ASCII + Latin-1 supplement — English labels plus common accented
/// place-names.
pub fn defaultCodepoints(a: Allocator) ![]u21 {
    var list = std.ArrayList(u21).empty;
    var c: u21 = 0x20;
    while (c <= 0x7E) : (c += 1) try list.append(a, c);
    c = 0xA0;
    while (c <= 0xFF) : (c += 1) try list.append(a, c);
    return list.toOwnedSlice(a);
}

const Cell = struct { cp: u21, w: u32, h: u32, sdf: ?[*]u8, gi: GlyphInfo };

/// Build an SDF atlas for `cps`. `em_px` sets the field resolution (px per em),
/// `pad` the spread in px.
pub fn build(a: Allocator, font: []const u8, cps: []const u21, em_px: f32, pad: u32) !Atlas {
    const atlas_w: u32 = 512;

    var cells = std.ArrayList(Cell).empty;
    defer {
        for (cells.items) |c| if (c.sdf) |p| tg_glyph_free(p);
        cells.deinit(a);
    }

    for (cps) |cp| {
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        var adv: f32 = 0;
        const sdf = tg_glyph_sdf(font.ptr, @intCast(font.len), @intCast(cp), em_px, @intCast(pad), &w, &h, &xoff, &yoff, &adv);
        const gi = GlyphInfo{
            .off_x = @as(f32, @floatFromInt(xoff)) / em_px,
            .off_y = @as(f32, @floatFromInt(yoff)) / em_px,
            .w = @as(f32, @floatFromInt(w)) / em_px,
            .h = @as(f32, @floatFromInt(h)) / em_px,
            .advance = adv / em_px,
        };
        try cells.append(a, .{ .cp = cp, .w = @intCast(@max(w, 0)), .h = @intCast(@max(h, 0)), .sdf = sdf, .gi = gi });
    }

    // Shelf-pack: rows wrap at atlas_w; compute total height.
    const gp: u32 = 1;
    var cx: u32 = gp;
    var cy: u32 = gp;
    var row_h: u32 = 0;
    var total_h: u32 = gp;
    for (cells.items) |c| {
        if (c.sdf == null or c.w == 0) continue;
        if (cx + c.w + gp > atlas_w) {
            cy += row_h + gp;
            cx = gp;
            row_h = 0;
        }
        cx += c.w + gp;
        row_h = @max(row_h, c.h);
        total_h = cy + row_h + gp;
    }
    const atlas_h = total_h;

    const rgba = try a.alloc(u8, atlas_w * atlas_h * 4);
    @memset(rgba, 0);
    var glyphs = std.AutoHashMapUnmanaged(u21, GlyphInfo){};

    cx = gp;
    cy = gp;
    row_h = 0;
    for (cells.items) |c| {
        var gi = c.gi;
        if (c.sdf) |sdf| if (c.w != 0) {
            if (cx + c.w + gp > atlas_w) {
                cy += row_h + gp;
                cx = gp;
                row_h = 0;
            }
            var yy: u32 = 0;
            while (yy < c.h) : (yy += 1) {
                var xx: u32 = 0;
                while (xx < c.w) : (xx += 1) {
                    const v = sdf[yy * c.w + xx];
                    const o = ((cy + yy) * atlas_w + (cx + xx)) * 4;
                    rgba[o] = v;
                    rgba[o + 1] = v;
                    rgba[o + 2] = v;
                    rgba[o + 3] = v;
                }
            }
            const fw: f32 = @floatFromInt(atlas_w);
            const fh: f32 = @floatFromInt(atlas_h);
            gi.u0 = @as(f32, @floatFromInt(cx)) / fw;
            gi.v0 = @as(f32, @floatFromInt(cy)) / fh;
            gi.u1 = @as(f32, @floatFromInt(cx + c.w)) / fw;
            gi.v1 = @as(f32, @floatFromInt(cy + c.h)) / fh;
            cx += c.w + gp;
            row_h = @max(row_h, c.h);
        };
        try glyphs.put(a, c.cp, gi);
    }

    return .{ .rgba = rgba, .width = atlas_w, .height = atlas_h, .em_px = em_px, .pad = @floatFromInt(pad), .glyphs = glyphs };
}

test "glyph atlas: SDF cells + metrics for ASCII" {
    const a = std.testing.allocator;
    const font = @import("render").font.notosans;
    const cps = try defaultCodepoints(a);
    defer a.free(cps);
    var atlas = try build(a, font, cps, 32.0, 6);
    defer atlas.deinit(a);

    try std.testing.expect(atlas.width == 512 and atlas.height > 0);
    const gA = atlas.info('A').?;
    try std.testing.expect(gA.advance > 0 and gA.w > 0 and gA.u1 > gA.u0);
    // edge values present (a valid field, not all-inside/outside)
    var hi = false;
    var mid = false;
    for (atlas.rgba) |v| {
        if (v > 220) hi = true;
        if (v > 40 and v < 210) mid = true;
    }
    try std.testing.expect(hi and mid);

    // The host loads a PNG of the atlas — verify the encoder produces one.
    const png = (try atlas.encodePng(a)).?;
    defer a.free(png);
    try std.testing.expect(png.len > 8 and png[0] == 0x89 and png[1] == 'P' and png[2] == 'N');
}
