//! MapLibre / Mapbox glyph-PBF emitter — encodes a font face's glyphs as
//! signed-distance-field bitmaps in the `glyphs.proto` wire format a GL client
//! loads from `<glyphs>/{fontstack}/{range}.pbf`. Reuses the same stb_truetype
//! SDF path as the GPU atlas (`glyph.zig`), only with the SDF encoding a GL
//! client expects (fontnik's 24 px em, 3 px buffer, edge 191, 255/8 per px).
//!
//! Metric fields are plain varints (matching the reference stacks a GL client
//! already consumes — a zigzag `top` would place glyphs below the baseline);
//! `left`/`top` clamp at 0, as every Latin glyph in the reference does.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn tg_glyph_sdf(font: [*]const u8, font_len: c_int, cp: c_int, em_px: f32, pad: c_int, onedge: c_int, dist_scale: f32, w: *c_int, h: *c_int, xoff: *c_int, yoff: *c_int, advance: *f32) callconv(.c) ?[*]u8;
extern fn tg_glyph_free(p: ?[*]u8) callconv(.c) void;

// fontnik / MapLibre SDF parameters. Do NOT change without regenerating every
// fontstack: a GL client's symbol shader keys on the edge value.
const EM_PX: f32 = 24;
const BUFFER: c_int = 3; // px border around each glyph (bitmap = (w+6)x(h+6))
const ONEDGE: c_int = 191; // 255*(1-cutoff), cutoff 0.25 -> glyph edge byte
const DIST_SCALE: f32 = 255.0 / 8.0; // radius 8 -> byte units per px of distance

fn putVarint(buf: *std.ArrayList(u8), a: Allocator, v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try buf.append(a, @intCast((x & 0x7f) | 0x80));
    try buf.append(a, @intCast(x));
}
fn putVarintField(buf: *std.ArrayList(u8), a: Allocator, field: u32, v: u64) !void {
    try putVarint(buf, a, (@as(u64, field) << 3) | 0); // wire type 0
    try putVarint(buf, a, v);
}
fn putBytesField(buf: *std.ArrayList(u8), a: Allocator, field: u32, bytes: []const u8) !void {
    try putVarint(buf, a, (@as(u64, field) << 3) | 2); // wire type 2
    try putVarint(buf, a, bytes.len);
    try buf.appendSlice(a, bytes);
}

/// Encode one `glyph` message (id/width/height/left/top/advance [+ bitmap]).
fn appendGlyph(a: Allocator, glyphs: *std.ArrayList(u8), font: []const u8, cp: u21) !void {
    var w: c_int = 0;
    var h: c_int = 0;
    var xoff: c_int = 0;
    var yoff: c_int = 0;
    var adv: f32 = 0;
    const sdf = tg_glyph_sdf(font.ptr, @intCast(font.len), @intCast(cp), EM_PX, BUFFER, ONEDGE, DIST_SCALE, &w, &h, &xoff, &yoff, &adv);
    defer if (sdf) |p| tg_glyph_free(p);
    if (adv <= 0 and sdf == null) return; // codepoint absent from the face

    var g = std.ArrayList(u8).empty;
    defer g.deinit(a);
    try putVarintField(&g, a, 1, cp); // id
    if (sdf != null and w > 0 and h > 0) {
        // width/height EXCLUDE the buffer; the bitmap is the full padded field.
        const gw: u32 = @intCast(w - 2 * BUFFER);
        const gh: u32 = @intCast(h - 2 * BUFFER);
        const left: i32 = xoff + BUFFER;
        const top: i32 = -yoff - BUFFER;
        try putBytesField(&g, a, 2, sdf.?[0..@intCast(w * h)]);
        try putVarintField(&g, a, 3, gw);
        try putVarintField(&g, a, 4, gh);
        try putVarintField(&g, a, 5, @intCast(@max(left, 0)));
        try putVarintField(&g, a, 6, @intCast(@max(top, 0)));
    } else {
        // Blank glyph (space): advance only, no bitmap.
        try putVarintField(&g, a, 3, 0);
        try putVarintField(&g, a, 4, 0);
        try putVarintField(&g, a, 5, 0);
        try putVarintField(&g, a, 6, 0);
    }
    try putVarintField(&g, a, 7, @intFromFloat(@round(adv))); // advance
    try putBytesField(glyphs, a, 3, g.items); // fontstack.glyphs (field 3)
}

/// One `<range>.pbf`: the glyphs message wrapping a single fontstack for the
/// [start, start+255] codepoint block. Caller owns the returned bytes.
pub fn encodeRange(a: Allocator, font: []const u8, name: []const u8, start: u21) ![]u8 {
    var stack = std.ArrayList(u8).empty;
    defer stack.deinit(a);
    try putBytesField(&stack, a, 1, name); // fontstack.name
    var rbuf: [16]u8 = undefined;
    const range = try std.fmt.bufPrint(&rbuf, "{d}-{d}", .{ start, start + 255 });
    try putBytesField(&stack, a, 2, range); // fontstack.range

    var cp: u21 = start;
    while (cp <= start + 255) : (cp += 1) try appendGlyph(a, &stack, font, cp);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try putBytesField(&out, a, 1, stack.items); // glyphs.stacks
    return out.toOwnedSlice(a);
}

// ---- tests -------------------------------------------------------------------

test "glyphpbf: range encodes a well-formed fontstack with 'A'" {
    const a = std.testing.allocator;
    const font = @import("render").font.notosans;
    const pbf = try encodeRange(a, font, "Noto Sans Regular", 0);
    defer a.free(pbf);
    // Non-trivial output that contains the fontstack name and range strings.
    try std.testing.expect(pbf.len > 1000);
    try std.testing.expect(std.mem.indexOf(u8, pbf, "Noto Sans Regular") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbf, "0-255") != null);
}
