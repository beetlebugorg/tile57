//! PdfCanvas: the vector-print Canvas — the same primitive seam RasterCanvas
//! implements, emitted as a deterministic single-page PDF 1.4. Fills become
//! PDF paths (nonzero `f` / even-odd `f*`), strokes native PDF strokes
//! (round caps/joins, dash arrays), text arrives from the PixelSurface as
//! glyph-outline fills (vector text, no font embedding), and pattern fills
//! clip the polygon and tile the cell as an RGB image XObject with an SMask.
//!
//! Determinism: no timestamps, no IDs, fixed object numbering, fixed float
//! formatting — two runs of the same scene are byte-identical (Gate 6).
//! Canvas px map 1:1 to PDF points (72 dpi page); the page is y-up, so the
//! content stream opens with a flip transform and everything else stays in
//! canvas coordinates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cv = @import("canvas.zig");

pub const PdfCanvas = struct {
    a: Allocator,
    w: u32,
    h: u32,
    content: std.ArrayList(u8) = .empty,
    /// Pattern cells used by fillPattern, deduped by pointer; each becomes an
    /// RGB image XObject (+ gray SMask) named /P0, /P1, …
    images: std.ArrayList(*const cv.Pattern) = .empty,
    /// The raw TrueType to embed for REAL text objects (selectable/searchable).
    /// null falls back to glyph-outline fills (visually identical, not text).
    font_data: ?[]const u8 = null,
    /// gid -> (advance/1000em, representative codepoint) for /W + ToUnicode.
    used_glyphs: std.AutoHashMapUnmanaged(u16, struct { w1000: u16, cp: u21 }) = .empty,

    const vtable = cv.Canvas.VTable{
        .fillPath = fillPathImpl,
        .fillPattern = fillPatternImpl,
        .strokePath = strokePathImpl,
        .drawGlyphRun = drawGlyphRunImpl,
    };

    pub fn init(a: Allocator, w: u32, h: u32) PdfCanvas {
        return .{ .a = a, .w = w, .h = h };
    }

    pub fn asCanvas(self: *PdfCanvas) cv.Canvas {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn sp(ctx: *anyopaque) *PdfCanvas {
        return @ptrCast(@alignCast(ctx));
    }

    fn num(self: *PdfCanvas, v: f32) !void {
        // Fixed 2-decimal formatting: deterministic and ample at print scale.
        try self.content.print(self.a, "{d:.2}", .{v});
    }

    fn emitPathGeometry(self: *PdfCanvas, rings: []const []const cv.Point, close: bool) !void {
        for (rings) |ring| {
            if (ring.len < 2) continue;
            for (ring, 0..) |p, i| {
                try self.num(p.x);
                try self.content.appendSlice(self.a, " ");
                try self.num(p.y);
                try self.content.appendSlice(self.a, if (i == 0) " m\n" else " l\n");
            }
            if (close) try self.content.appendSlice(self.a, "h\n");
        }
    }

    fn setColor(self: *PdfCanvas, color: cv.Color, stroke: bool) !void {
        const r = @as(f32, @floatFromInt(color.r)) / 255.0;
        const g = @as(f32, @floatFromInt(color.g)) / 255.0;
        const b = @as(f32, @floatFromInt(color.b)) / 255.0;
        try self.num(r);
        try self.content.appendSlice(self.a, " ");
        try self.num(g);
        try self.content.appendSlice(self.a, " ");
        try self.num(b);
        try self.content.appendSlice(self.a, if (stroke) " RG\n" else " rg\n");
        // Alpha below 255 uses an ExtGState; charts paint opaque, and the few
        // translucent ops degrade to opaque in print (acceptable v1).
    }

    // ---- Canvas impl --------------------------------------------------------

    fn fillPathImpl(ctx: *anyopaque, rings: []const []const cv.Point, color: cv.Color, rule: cv.FillRule) anyerror!void {
        const self = sp(ctx);
        if (color.a == 0) return;
        try self.setColor(color, false);
        try self.emitPathGeometry(rings, true);
        try self.content.appendSlice(self.a, if (rule == .even_odd) "f*\n" else "f\n");
    }

    fn strokePathImpl(ctx: *anyopaque, lines: []const []const cv.Point, width_px: f32, dash: ?[2]f32, color: cv.Color) anyerror!void {
        const self = sp(ctx);
        if (color.a == 0 or !(width_px > 0)) return;
        try self.setColor(color, true);
        try self.num(width_px);
        try self.content.appendSlice(self.a, " w\n1 J\n1 j\n"); // round cap + join
        if (dash) |d| {
            try self.content.appendSlice(self.a, "[");
            try self.num(d[0]);
            try self.content.appendSlice(self.a, " ");
            try self.num(d[1]);
            try self.content.appendSlice(self.a, "] 0 d\n");
        } else {
            try self.content.appendSlice(self.a, "[] 0 d\n");
        }
        try self.emitPathGeometry(lines, false);
        try self.content.appendSlice(self.a, "S\n");
    }

    fn fillPatternImpl(ctx: *anyopaque, rings: []const []const cv.Point, pattern: *const cv.Pattern) anyerror!void {
        const self = sp(ctx);
        if (pattern.w == 0 or pattern.h == 0) return;
        // Register (dedupe) the cell image.
        var idx: ?usize = null;
        for (self.images.items, 0..) |img, i| {
            if (img == pattern) idx = i;
        }
        if (idx == null) {
            idx = self.images.items.len;
            try self.images.append(self.a, pattern);
        }
        // Clip to the polygon, then tile the image over its bbox with the
        // same canvas-anchored phase as the raster path.
        var bb = [4]f32{ std.math.floatMax(f32), std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (rings) |ring| for (ring) |p| {
            bb[0] = @min(bb[0], p.x);
            bb[1] = @min(bb[1], p.y);
            bb[2] = @max(bb[2], p.x);
            bb[3] = @max(bb[3], p.y);
        };
        if (bb[2] <= bb[0]) return;
        try self.content.appendSlice(self.a, "q\n");
        try self.emitPathGeometry(rings, true);
        try self.content.appendSlice(self.a, "W n\n");
        const pw: f32 = @floatFromInt(pattern.w);
        const ph: f32 = @floatFromInt(pattern.h);
        const x0 = @floor(bb[0] / pw) * pw;
        const y0 = @floor(bb[1] / ph) * ph;
        var y = y0;
        while (y < bb[3]) : (y += ph) {
            var x = x0;
            while (x < bb[2]) : (x += pw) {
                // Image space is a unit square; scale to cell px. The page
                // flip is global, so flip each image back upright locally.
                try self.content.appendSlice(self.a, "q\n");
                try self.num(pw);
                try self.content.appendSlice(self.a, " 0 0 ");
                try self.num(ph);
                try self.content.appendSlice(self.a, " ");
                try self.num(x);
                try self.content.appendSlice(self.a, " ");
                try self.num(y + ph);
                try self.content.appendSlice(self.a, " cm\n1 0 0 -1 0 1 cm\n");
                try self.content.print(self.a, "/P{d} Do\nQ\n", .{idx.?});
            }
        }
        try self.content.appendSlice(self.a, "Q\n");
    }

    // Emit one BT..ET text block for the run at rendering mode `tr`.
    // Identity-H: the string is big-endian 2-byte glyph ids. The text matrix
    // uses a NEGATIVE vertical scale to counter the page's global y-flip, so
    // glyphs come out upright with the baseline at the run origin.
    fn emitTextBlock(self: *PdfCanvas, run: *const cv.GlyphRun, tr: u8) !void {
        try self.content.appendSlice(self.a, "BT\n/F1 1 Tf\n");
        try self.content.print(self.a, "{d} Tr\n", .{tr});
        try self.num(run.size);
        try self.content.appendSlice(self.a, " 0 0 ");
        try self.num(-run.size);
        try self.content.appendSlice(self.a, " ");
        try self.num(run.origin.x);
        try self.content.appendSlice(self.a, " ");
        try self.num(run.origin.y);
        try self.content.appendSlice(self.a, " Tm\n<");
        for (run.glyphs) |g| try self.content.print(self.a, "{x:0>4}", .{g.gid});
        try self.content.appendSlice(self.a, "> Tj\nET\n");
    }

    fn drawGlyphRunImpl(ctx: *anyopaque, run: *const cv.GlyphRun) anyerror!void {
        const self = sp(ctx);
        if (self.font_data == null) {
            // No font to embed: outline fills (visually identical, not text).
            if (run.halo) |hc| try strokePathImpl(ctx, run.rings, run.halo_w * 2, null, hc);
            try fillPathImpl(ctx, run.rings, run.color, .nonzero);
            return;
        }
        for (run.glyphs) |g| {
            if (!self.used_glyphs.contains(g.gid))
                try self.used_glyphs.put(self.a, g.gid, .{ .w1000 = g.w1000, .cp = g.cp });
        }
        if (run.halo) |hc| {
            try self.setColor(hc, true);
            try self.num(run.halo_w * 2);
            try self.content.appendSlice(self.a, " w\n1 J\n1 j\n[] 0 d\n");
            try self.emitTextBlock(run, 1); // stroke-only pass = the halo
        }
        try self.setColor(run.color, false);
        try self.emitTextBlock(run, 0); // fill pass
    }

    // ---- document assembly ----------------------------------------------------

    /// Assemble the single-page PDF. Caller owns the returned bytes.
    ///
    /// Object numbering: 1 Catalog, 2 Pages, 3 Page, 4 Contents, then per
    /// pattern i {5+2i image, 6+2i SMask}, then (when any text was drawn and a
    /// font was provided) F = Type0 font, F+1 CIDFontType2, F+2 FontDescriptor,
    /// F+3 FontFile2 (the raw TTF), F+4 ToUnicode CMap.
    pub fn finish(self: *PdfCanvas, out: Allocator) ![]u8 {
        var doc = std.ArrayList(u8).empty;
        errdefer doc.deinit(out);
        var offsets = std.ArrayList(usize).empty;
        defer offsets.deinit(self.a);

        try doc.appendSlice(out, "%PDF-1.4\n");

        const n_imgs = self.images.items.len;
        const has_font = self.font_data != null and self.used_glyphs.count() > 0;
        const font_obj: usize = 5 + 2 * n_imgs;

        // Used glyphs sorted by gid: deterministic /W + ToUnicode.
        var gids = std.ArrayList(u16).empty;
        defer gids.deinit(self.a);
        var git = self.used_glyphs.keyIterator();
        while (git.next()) |k| try gids.append(self.a, k.*);
        std.mem.sort(u16, gids.items, {}, std.sort.asc(u16));

        // 1: Catalog
        try offsets.append(self.a, doc.items.len);
        try doc.appendSlice(out, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        // 2: Pages
        try offsets.append(self.a, doc.items.len);
        try doc.appendSlice(out, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
        // 3: Page
        try offsets.append(self.a, doc.items.len);
        try doc.print(out, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d} {d}] /Contents 4 0 R /Resources << /XObject <<", .{ self.w, self.h });
        for (0..n_imgs) |i| try doc.print(out, " /P{d} {d} 0 R", .{ i, 5 + 2 * i });
        try doc.appendSlice(out, " >>");
        if (has_font) try doc.print(out, " /Font << /F1 {d} 0 R >>", .{font_obj});
        try doc.appendSlice(out, " >> >>\nendobj\n");
        // 4: Contents — the global y-flip, then the recorded ops.
        try offsets.append(self.a, doc.items.len);
        var flip_buf: [64]u8 = undefined;
        const flip = try std.fmt.bufPrint(&flip_buf, "1 0 0 -1 0 {d} cm\n", .{self.h});
        try doc.print(out, "4 0 obj\n<< /Length {d} >>\nstream\n", .{flip.len + self.content.items.len});
        try doc.appendSlice(out, flip);
        try doc.appendSlice(out, self.content.items);
        try doc.appendSlice(out, "endstream\nendobj\n");
        // Pattern cell images: raw RGB + gray SMask (straight alpha).
        for (self.images.items, 0..) |img, i| {
            const n = @as(usize, img.w) * img.h;
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask {d} 0 R /Length {d} >>\nstream\n", .{ 5 + 2 * i, img.w, img.h, 6 + 2 * i, n * 3 });
            for (0..n) |p| try doc.appendSlice(out, img.rgba[p * 4 ..][0..3]);
            try doc.appendSlice(out, "\nendstream\nendobj\n");
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceGray /BitsPerComponent 8 /Length {d} >>\nstream\n", .{ 6 + 2 * i, img.w, img.h, n });
            for (0..n) |p| try doc.append(out, img.rgba[p * 4 + 3]);
            try doc.appendSlice(out, "\nendstream\nendobj\n");
        }

        if (has_font) {
            const ttf = self.font_data.?;
            // F: composite Type0 font, Identity-H (2-byte glyph-id strings).
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /NotoSans /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\nendobj\n", .{ font_obj, font_obj + 1, font_obj + 4 });
            // F+1: the CIDFontType2 with per-used-glyph widths (CID == GID).
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /NotoSans /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /DW 600 /CIDToGIDMap /Identity /W [", .{ font_obj + 1, font_obj + 2 });
            for (gids.items) |gid| {
                const u = self.used_glyphs.get(gid).?;
                try doc.print(out, " {d} [{d}]", .{ gid, u.w1000 });
            }
            try doc.appendSlice(out, " ] >>\nendobj\n");
            // F+2: FontDescriptor (metrics approximate; viewers use the font).
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Type /FontDescriptor /FontName /NotoSans /Flags 32 /FontBBox [-1000 -500 2500 1500] /ItalicAngle 0 /Ascent 1069 /Descent -293 /CapHeight 714 /StemV 80 /FontFile2 {d} 0 R >>\nendobj\n", .{ font_obj + 2, font_obj + 3 });
            // F+3: the raw TrueType, whole (no subsetting v1 — deterministic
            // and simple; ~600 KB, amortized across every label).
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Length {d} /Length1 {d} >>\nstream\n", .{ font_obj + 3, ttf.len, ttf.len });
            try doc.appendSlice(out, ttf);
            try doc.appendSlice(out, "\nendstream\nendobj\n");
            // F+4: ToUnicode CMap — glyph id -> UTF-16BE (search/copy works).
            var cmap = std.ArrayList(u8).empty;
            defer cmap.deinit(self.a);
            try cmap.appendSlice(self.a, "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
            try cmap.print(self.a, "{d} beginbfchar\n", .{gids.items.len});
            for (gids.items) |gid| {
                const cp = self.used_glyphs.get(gid).?.cp;
                if (cp <= 0xFFFF) {
                    try cmap.print(self.a, "<{x:0>4}> <{x:0>4}>\n", .{ gid, cp });
                } else {
                    const v = cp - 0x10000;
                    try cmap.print(self.a, "<{x:0>4}> <{x:0>4}{x:0>4}>\n", .{ gid, 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
                }
            }
            try cmap.appendSlice(self.a, "endbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
            try offsets.append(self.a, doc.items.len);
            try doc.print(out, "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ font_obj + 4, cmap.items.len });
            try doc.appendSlice(out, cmap.items);
            try doc.appendSlice(out, "endstream\nendobj\n");
        }

        // xref + trailer
        const xref_at = doc.items.len;
        const n_objs = offsets.items.len + 1;
        try doc.print(out, "xref\n0 {d}\n0000000000 65535 f \n", .{n_objs});
        for (offsets.items) |off| try doc.print(out, "{d:0>10} 00000 n \n", .{off});
        try doc.print(out, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ n_objs, xref_at });
        return doc.toOwnedSlice(out);
    }
};

// ---- tests -------------------------------------------------------------------

test "PdfCanvas: valid skeleton, paths + strokes + pattern, deterministic" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var docs: [2][]u8 = undefined;
    const cell = [_]u8{ 255, 0, 0, 255 } ++ ([_]u8{ 0, 0, 0, 0 } ** 3);
    const pat = cv.Pattern{ .w = 2, .h = 2, .rgba = &cell };
    for (0..2) |i| {
        var pdf = PdfCanvas.init(a, 200, 100);
        const canvas = pdf.asCanvas();
        const ring = [_]cv.Point{ .{ .x = 10, .y = 10 }, .{ .x = 90, .y = 10 }, .{ .x = 90, .y = 60 }, .{ .x = 10, .y = 60 } };
        const rings = [_][]const cv.Point{&ring};
        try canvas.fillPath(&rings, .{ .r = 100, .g = 150, .b = 200 }, .nonzero);
        const line = [_]cv.Point{ .{ .x = 5, .y = 80 }, .{ .x = 195, .y = 80 } };
        const lines = [_][]const cv.Point{&line};
        try canvas.strokePath(&lines, 2, .{ 4, 3 }, .{ .r = 0, .g = 0, .b = 0 });
        try canvas.fillPattern(&rings, &pat);
        docs[i] = try pdf.finish(a);
    }
    const doc = docs[0];
    try std.testing.expect(std.mem.startsWith(u8, doc, "%PDF-1.4\n"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "/MediaBox [0 0 200 100]") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "f\n") != null); // fill
    try std.testing.expect(std.mem.indexOf(u8, doc, "[4.00 3.00] 0 d") != null); // dash
    try std.testing.expect(std.mem.indexOf(u8, doc, "/P0 Do") != null); // pattern tile
    try std.testing.expect(std.mem.indexOf(u8, doc, "%%EOF\n") != null);
    // Gate 6: two runs byte-identical.
    try std.testing.expectEqualSlices(u8, docs[0], docs[1]);
}
