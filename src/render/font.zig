//! Minimal TrueType outline reader for the render engine's label face — a
//! from-scratch parser for the subset chart labels need: `cmap` (format 4)
//! codepoint lookup, `hmtx` advances, `glyf` outlines (simple + composite)
//! with quadratic flattening. No hinting, no kerning, no CFF — the embedded
//! Noto Sans Regular is a plain glyf TrueType and chart labels are Latin.
//!
//! All outline coordinates are returned in EM units (divided by unitsPerEm),
//! y-UP as TrueType stores them — the consumer flips y when scaling into
//! canvas space. Fill rule is NONZERO (the TrueType convention).
//!
//! Pure std; parses from a borrowed byte slice (the @embedFile'd TTF).

const std = @import("std");
const Allocator = std.mem.Allocator;
const cv = @import("canvas.zig");

fn u16At(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .big);
}
fn i16At(d: []const u8, o: usize) i16 {
    return std.mem.readInt(i16, d[o..][0..2], .big);
}
fn u32At(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

pub const Font = struct {
    data: []const u8,
    upem: f32,
    ascent: f32, // em units
    descent: f32, // em units (positive value)
    long_loca: bool,
    num_glyphs: u16,
    num_hmetrics: u16,
    cmap4: usize, // offset of the format-4 cmap subtable
    loca: usize,
    glyf: usize,
    hmtx: usize,

    pub fn init(data: []const u8) !Font {
        if (data.len < 12) return error.BadFont;
        const num_tables = u16At(data, 4);
        var head: usize = 0;
        var maxp: usize = 0;
        var hhea: usize = 0;
        var hmtx: usize = 0;
        var loca: usize = 0;
        var glyf: usize = 0;
        var cmap: usize = 0;
        for (0..num_tables) |i| {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return error.BadFont;
            const tag = data[rec .. rec + 4];
            const off = u32At(data, rec + 8);
            if (std.mem.eql(u8, tag, "head")) head = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea = off;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = off;
            if (std.mem.eql(u8, tag, "loca")) loca = off;
            if (std.mem.eql(u8, tag, "glyf")) glyf = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap = off;
        }
        if (head == 0 or maxp == 0 or hhea == 0 or hmtx == 0 or loca == 0 or glyf == 0 or cmap == 0)
            return error.BadFont; // CFF fonts (no glyf) are out of scope

        const upem: f32 = @floatFromInt(u16At(data, head + 18));
        const ascent: f32 = @floatFromInt(i16At(data, hhea + 4));
        const descent: f32 = @floatFromInt(i16At(data, hhea + 6)); // typically negative

        // Pick a Unicode BMP cmap subtable, format 4: platform 3/enc 1 (Windows
        // BMP) or platform 0 (Unicode).
        var cmap4: usize = 0;
        const n_sub = u16At(data, cmap + 2);
        for (0..n_sub) |i| {
            const rec = cmap + 4 + i * 8;
            const plat = u16At(data, rec);
            const enc = u16At(data, rec + 2);
            const off = cmap + u32At(data, rec + 4);
            if (off + 2 > data.len) continue;
            const fmt = u16At(data, off);
            if (fmt != 4) continue;
            if ((plat == 3 and enc == 1) or plat == 0) cmap4 = off;
        }
        if (cmap4 == 0) return error.BadFont;

        return .{
            .data = data,
            .upem = upem,
            .ascent = ascent / upem,
            .descent = -descent / upem,
            .long_loca = i16At(data, head + 50) != 0,
            .num_glyphs = u16At(data, maxp + 4),
            .num_hmetrics = u16At(data, hhea + 34),
            .cmap4 = cmap4,
            .loca = loca,
            .glyf = glyf,
            .hmtx = hmtx,
        };
    }

    /// Codepoint -> glyph id (0 = .notdef).
    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        if (cp > 0xFFFF) return 0;
        const c: u16 = @intCast(cp);
        const d = self.data;
        const t = self.cmap4;
        const seg_x2 = u16At(d, t + 6);
        const end_codes = t + 14;
        const start_codes = end_codes + seg_x2 + 2;
        const id_deltas = start_codes + seg_x2;
        const id_ranges = id_deltas + seg_x2;
        var i: usize = 0;
        while (i < seg_x2) : (i += 2) {
            if (u16At(d, end_codes + i) >= c) break;
        }
        if (i >= seg_x2) return 0;
        if (u16At(d, start_codes + i) > c) return 0;
        const delta = u16At(d, id_deltas + i);
        const range = u16At(d, id_ranges + i);
        if (range == 0) return c +% delta;
        // range offset is self-relative within idRangeOffset[]
        const addr = id_ranges + i + range + 2 * @as(usize, c - u16At(d, start_codes + i));
        if (addr + 2 > d.len) return 0;
        const g = u16At(d, addr);
        if (g == 0) return 0;
        return g +% delta;
    }

    /// Advance width in em units.
    pub fn advance(self: *const Font, gid: u16) f32 {
        const i = @min(gid, self.num_hmetrics - 1);
        return @as(f32, @floatFromInt(u16At(self.data, self.hmtx + @as(usize, i) * 4))) / self.upem;
    }

    fn glyfRange(self: *const Font, gid: u16) ?[]const u8 {
        if (gid >= self.num_glyphs) return null;
        const d = self.data;
        var o0: usize = undefined;
        var o1: usize = undefined;
        if (self.long_loca) {
            o0 = u32At(d, self.loca + @as(usize, gid) * 4);
            o1 = u32At(d, self.loca + @as(usize, gid) * 4 + 4);
        } else {
            o0 = @as(usize, u16At(d, self.loca + @as(usize, gid) * 2)) * 2;
            o1 = @as(usize, u16At(d, self.loca + @as(usize, gid) * 2 + 2)) * 2;
        }
        if (o1 <= o0) return null; // empty glyph (e.g. space)
        return d[self.glyf + o0 .. self.glyf + o1];
    }

    /// The glyph's outline as flattened closed contours in em units (y up),
    /// allocated from `a`. Empty slice for blank glyphs. Quadratics flatten
    /// at a fixed 8 steps — ample at label sizes.
    pub fn outline(self: *const Font, a: Allocator, gid: u16) ![]const []const cv.Point {
        var out = std.ArrayList([]const cv.Point).empty;
        try self.outlineInto(a, gid, &out, 1, 0, 0, 1, 0, 0, 0);
        return out.toOwnedSlice(a);
    }

    // Append gid's contours transformed by [xx xy; yx yy] + (dx, dy) (em-unit
    // offsets), recursing into composite components. `depth` caps recursion.
    fn outlineInto(self: *const Font, a: Allocator, gid: u16, out: *std.ArrayList([]const cv.Point), xx: f32, xy: f32, yx: f32, yy: f32, dx: f32, dy: f32, depth: u8) !void {
        if (depth > 4) return;
        const g = self.glyfRange(gid) orelse return;
        const n_contours = i16At(g, 0);
        if (n_contours >= 0) {
            try self.simpleOutline(a, g, @intCast(n_contours), out, xx, xy, yx, yy, dx, dy);
            return;
        }
        // Composite glyph: a list of transformed component glyphs.
        var o: usize = 10;
        while (true) {
            const flags = u16At(g, o);
            const comp_gid = u16At(g, o + 2);
            o += 4;
            var cdx: f32 = 0;
            var cdy: f32 = 0;
            if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                if (flags & 0x0002 != 0) { // ARGS_ARE_XY_VALUES
                    cdx = @floatFromInt(i16At(g, o));
                    cdy = @floatFromInt(i16At(g, o + 2));
                }
                o += 4;
            } else {
                if (flags & 0x0002 != 0) {
                    cdx = @floatFromInt(@as(i8, @bitCast(g[o])));
                    cdy = @floatFromInt(@as(i8, @bitCast(g[o + 1])));
                }
                o += 2;
            }
            var sxx: f32 = 1;
            var sxy: f32 = 0;
            var syx: f32 = 0;
            var syy: f32 = 1;
            const f2 = 1.0 / 16384.0; // F2Dot14
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                sxx = @as(f32, @floatFromInt(i16At(g, o))) * f2;
                syy = sxx;
                o += 2;
            } else if (flags & 0x0040 != 0) { // X_AND_Y_SCALE
                sxx = @as(f32, @floatFromInt(i16At(g, o))) * f2;
                syy = @as(f32, @floatFromInt(i16At(g, o + 2))) * f2;
                o += 4;
            } else if (flags & 0x0080 != 0) { // TWO_BY_TWO
                sxx = @as(f32, @floatFromInt(i16At(g, o))) * f2;
                sxy = @as(f32, @floatFromInt(i16At(g, o + 2))) * f2;
                syx = @as(f32, @floatFromInt(i16At(g, o + 4))) * f2;
                syy = @as(f32, @floatFromInt(i16At(g, o + 6))) * f2;
                o += 8;
            }
            // Compose: component transform, then the parent's.
            const u = self.upem;
            try self.outlineInto(a, comp_gid, out, xx * sxx + xy * syx, xx * sxy + xy * syy, yx * sxx + yy * syx, yx * sxy + yy * syy, dx + (xx * cdx + xy * cdy) / u, dy + (yx * cdx + yy * cdy) / u, depth + 1);
            if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
        }
    }

    fn simpleOutline(self: *const Font, a: Allocator, g: []const u8, n_contours: u16, out: *std.ArrayList([]const cv.Point), xx: f32, xy: f32, yx: f32, yy: f32, dx: f32, dy: f32) !void {
        const end_pts = 10;
        const n_pts = @as(usize, u16At(g, end_pts + (n_contours - 1) * 2)) + 1;
        const instr_len = u16At(g, end_pts + @as(usize, n_contours) * 2);
        var o: usize = end_pts + @as(usize, n_contours) * 2 + 2 + instr_len;

        // Decode flags (with repeat runs), then the delta-coded x and y arrays.
        const flags = try a.alloc(u8, n_pts);
        defer a.free(flags);
        {
            var i: usize = 0;
            while (i < n_pts) {
                const f = g[o];
                o += 1;
                flags[i] = f;
                i += 1;
                if (f & 0x08 != 0) { // REPEAT
                    var r = g[o];
                    o += 1;
                    while (r > 0 and i < n_pts) : (r -= 1) {
                        flags[i] = f;
                        i += 1;
                    }
                }
            }
        }
        const xs = try a.alloc(f32, n_pts);
        defer a.free(xs);
        {
            var x: i32 = 0;
            for (0..n_pts) |i| {
                const f = flags[i];
                if (f & 0x02 != 0) { // x short
                    const v: i32 = g[o];
                    o += 1;
                    x += if (f & 0x10 != 0) v else -v;
                } else if (f & 0x10 == 0) {
                    x += i16At(g, o);
                    o += 2;
                }
                xs[i] = @floatFromInt(x);
            }
        }
        const ys = try a.alloc(f32, n_pts);
        defer a.free(ys);
        {
            var y: i32 = 0;
            for (0..n_pts) |i| {
                const f = flags[i];
                if (f & 0x04 != 0) { // y short
                    const v: i32 = g[o];
                    o += 1;
                    y += if (f & 0x20 != 0) v else -v;
                } else if (f & 0x20 == 0) {
                    y += i16At(g, o);
                    o += 2;
                }
                ys[i] = @floatFromInt(y);
            }
        }

        // Per contour: expand quadratic on/off runs into a flattened polygon.
        const u = self.upem;
        var start: usize = 0;
        for (0..n_contours) |c| {
            const end = @as(usize, u16At(g, end_pts + c * 2));
            const n = end - start + 1;
            if (n < 2) {
                start = end + 1;
                continue;
            }
            var pts = std.ArrayList(cv.Point).empty;
            const P = struct {
                fn at(xs_: []const f32, ys_: []const f32, flags_: []const u8, s: usize, count: usize, i: usize) struct { x: f32, y: f32, on: bool } {
                    const j = s + (i % count);
                    return .{ .x = xs_[j], .y = ys_[j], .on = flags_[j] & 0x01 != 0 };
                }
            };
            // Find a starting ON point (or synthesize one between two OFFs).
            var first_on: ?usize = null;
            for (0..n) |i| {
                if (P.at(xs, ys, flags, start, n, i).on) {
                    first_on = i;
                    break;
                }
            }
            var cur: struct { x: f32, y: f32 } = undefined;
            var start_i: usize = 0;
            if (first_on) |fo| {
                const p = P.at(xs, ys, flags, start, n, fo);
                cur = .{ .x = p.x, .y = p.y };
                start_i = fo;
            } else {
                const p0 = P.at(xs, ys, flags, start, n, 0);
                const p1 = P.at(xs, ys, flags, start, n, 1);
                cur = .{ .x = (p0.x + p1.x) / 2, .y = (p0.y + p1.y) / 2 };
            }
            try pts.append(a, .{ .x = (xx * cur.x + xy * cur.y) / u + dx, .y = (yx * cur.x + yy * cur.y) / u + dy });
            var i: usize = 1;
            while (i <= n) : (i += 1) {
                const p = P.at(xs, ys, flags, start, n, start_i + i);
                if (p.on) {
                    cur = .{ .x = p.x, .y = p.y };
                    try pts.append(a, .{ .x = (xx * cur.x + xy * cur.y) / u + dx, .y = (yx * cur.x + yy * cur.y) / u + dy });
                } else {
                    // Quadratic control point; the on-curve end is the next point
                    // (or the implied midpoint if the next is also off-curve).
                    const nx = P.at(xs, ys, flags, start, n, start_i + i + 1);
                    var ex = nx.x;
                    var ey = nx.y;
                    if (!nx.on) {
                        ex = (p.x + nx.x) / 2;
                        ey = (p.y + nx.y) / 2;
                    } else {
                        i += 1; // consumed the end point too
                    }
                    var s: usize = 1;
                    while (s <= 8) : (s += 1) {
                        const t = @as(f32, @floatFromInt(s)) / 8.0;
                        const v = 1 - t;
                        const qx = v * v * cur.x + 2 * v * t * p.x + t * t * ex;
                        const qy = v * v * cur.y + 2 * v * t * p.y + t * t * ey;
                        try pts.append(a, .{ .x = (xx * qx + xy * qy) / u + dx, .y = (yx * qx + yy * qy) / u + dy });
                    }
                    cur = .{ .x = ex, .y = ey };
                }
            }
            if (pts.items.len >= 3) try out.append(a, try pts.toOwnedSlice(a));
            start = end + 1;
        }
    }
};

// ---- tests -------------------------------------------------------------------

/// The embedded label face (Noto Sans Regular, OFL 1.1) — the render engine's
/// single font.
pub const notosans = @embedFile("font_ttf");
const noto = notosans;

test "Font: parses Noto Sans, maps ASCII, sane metrics" {
    const f = try Font.init(noto);
    try std.testing.expect(f.upem >= 1000);
    try std.testing.expect(f.ascent > 0.5 and f.ascent < 1.5);
    // Distinct glyphs for distinct chars; .notdef for unmapped.
    const gA = f.glyphIndex('A');
    const g4 = f.glyphIndex('4');
    try std.testing.expect(gA != 0 and g4 != 0 and gA != g4);
    try std.testing.expectEqual(@as(u16, 0), f.glyphIndex(0xE0000));
    // Advances are positive, sub-em for Latin.
    try std.testing.expect(f.advance(gA) > 0.3 and f.advance(gA) < 1.0);
}

test "Font: outlines flatten to closed contours in em units" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Font.init(noto);

    // 'I' — a simple glyph, at least one contour, bounded by the em box.
    const gI = try f.outline(a, f.glyphIndex('I'));
    try std.testing.expect(gI.len >= 1);
    for (gI) |c| {
        try std.testing.expect(c.len >= 3);
        for (c) |p| {
            try std.testing.expect(p.x > -0.5 and p.x < 1.5);
            try std.testing.expect(p.y > -0.7 and p.y < 1.5);
        }
    }
    // 'O' — two contours (outer + counter hole).
    const gO = try f.outline(a, f.glyphIndex('O'));
    try std.testing.expect(gO.len >= 2);
    // 'Å' — a composite (A + ring); outline resolves through components.
    const gAring = try f.outline(a, f.glyphIndex(0xC5));
    try std.testing.expect(gAring.len >= 2);
    // space — empty outline, non-zero advance.
    const gsp = try f.outline(a, f.glyphIndex(' '));
    try std.testing.expectEqual(@as(usize, 0), gsp.len);
    try std.testing.expect(f.advance(f.glyphIndex(' ')) > 0.1);
}
