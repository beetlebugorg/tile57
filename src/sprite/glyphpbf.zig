//! MapLibre / Mapbox glyph-PBF emitter — encodes a font face's glyphs as
//! signed-distance-field bitmaps in the `glyphs.proto` wire format a GL client
//! loads from `<glyphs>/{fontstack}/{range}.pbf`. Reuses the same stb_truetype
//! SDF path as the GPU atlas (`glyph.zig`), only with the SDF encoding a GL
//! client expects (fontnik's 24 px em, 3 px buffer, edge 191, 255/8 per px).
//!
//! `left`/`top` are sint32 on the wire (zigzag), exactly as glyphs.proto says:
//! MapLibre Native's parser (text/glyph_pbf.cpp) reads them with get_sint32().
//! Encoding them as plain varints halves every even value and NEGATES every odd
//! one on decode, which scatters letters vertically by parity — tall glyphs land
//! below the baseline and words render with characters apparently missing.

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
fn putSintField(buf: *std.ArrayList(u8), a: Allocator, field: u32, v: i32) !void {
    const zz = (@as(u64, @bitCast(@as(i64, v))) << 1) ^ @as(u64, @bitCast(@as(i64, v) >> 63));
    try putVarintField(buf, a, field, zz);
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
        try putSintField(&g, a, 5, left);
        try putSintField(&g, a, 6, top);
    } else {
        // Blank glyph (space): advance only, no bitmap.
        try putVarintField(&g, a, 3, 0);
        try putVarintField(&g, a, 4, 0);
        try putSintField(&g, a, 5, 0);
        try putSintField(&g, a, 6, 0);
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

const TestReader = struct {
    buf: []const u8,
    i: usize = 0,

    fn varint(self: *TestReader) u64 {
        var shift: u6 = 0;
        var v: u64 = 0;
        while (true) {
            const b = self.buf[self.i];
            self.i += 1;
            v |= @as(u64, b & 0x7f) << shift;
            if (b < 0x80) return v;
            shift += 7;
        }
    }

    fn skipOrSlice(self: *TestReader, wire: u3) ?[]const u8 {
        switch (wire) {
            0 => _ = self.varint(),
            2 => {
                const len = self.varint();
                const s = self.buf[self.i .. self.i + len];
                self.i += len;
                return s;
            },
            else => unreachable,
        }
        return null;
    }
};

fn zigzagDecode(v: u64) i64 {
    return @as(i64, @intCast(v >> 1)) ^ -@as(i64, @intCast(v & 1));
}

test "glyphpbf: left/top are sint32 on the wire, as glyph_pbf.cpp decodes them" {
    // MapLibre Native reads fields 5/6 with get_sint32() (zigzag). Encoded as
    // plain varints they decode halved (even) or negated (odd) — glyphs land
    // below the baseline and letters vanish from words. Lock the wire format.
    const a = std.testing.allocator;
    const font = @import("render").font.notosans;
    const pbf = try encodeRange(a, font, "Noto Sans Regular", 0);
    defer a.free(pbf);

    var found_cap = false;
    var outer = TestReader{ .buf = pbf };
    while (outer.i < outer.buf.len) {
        const key = outer.varint();
        const stack_msg = outer.skipOrSlice(@intCast(key & 7)) orelse continue;
        if (key >> 3 != 1) continue;
        var st = TestReader{ .buf = stack_msg };
        while (st.i < st.buf.len) {
            const skey = st.varint();
            const gmsg = st.skipOrSlice(@intCast(skey & 7)) orelse continue;
            if (skey >> 3 != 3) continue;
            var g = TestReader{ .buf = gmsg };
            var id: u64 = 0;
            var left: i64 = 0;
            var top: i64 = 0;
            var adv: u64 = 0;
            while (g.i < g.buf.len) {
                const gkey = g.varint();
                switch (gkey >> 3) {
                    1 => id = g.varint(),
                    5 => left = zigzagDecode(g.varint()),
                    6 => top = zigzagDecode(g.varint()),
                    7 => adv = g.varint(),
                    else => _ = g.skipOrSlice(@intCast(gkey & 7)),
                }
            }
            if (id == 'A') {
                found_cap = true;
                // 'A' at the 24px fontnik em: cap top sits well above the
                // baseline. Decoded THROUGH ZIGZAG it must come out in a
                // plausible band; a plain-varint encoding would fail this for
                // any odd top (negative) and halve the rest.
                try std.testing.expect(top >= 10 and top <= 25);
                try std.testing.expect(left >= -5 and left <= 10);
                try std.testing.expect(adv >= 8 and adv <= 22);
            }
        }
    }
    try std.testing.expect(found_cap);
}

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
