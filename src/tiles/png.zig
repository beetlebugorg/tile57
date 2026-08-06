//! Minimal PNG codec for RGBA8 buffers: 8-bit truecolor+alpha, filter 0 on every
//! encoded scanline, one zlib IDAT via the std flate compressor. Deterministic
//! bytes for a given buffer — the golden-image gate hashes the encoded file.
//!
//! WHY IT SITS WITH THE TILE FORMATS. A raster chart's tiles ARE PNGs: the RNC
//! bake writes them into a PMTiles archive and the compositor decodes them again
//! to stack two sheets across a seam. That makes PNG a tile encoding beside MVT
//! and MLT rather than a property of the pixel renderer — which still reaches it
//! under its old name (`render.png`).
//!
//! The DECODER reads what this encoder writes: 8-bit truecolor+alpha,
//! non-interlaced. That is the whole population it meets — the pictures in a
//! community MBTiles are JPEG and never reach it, and a raster chart enters the
//! compositor only when it was baked here. All five scanline filters are handled
//! anyway: they cost thirty lines, and a tile rewritten by any other tool would
//! otherwise fail for no reason worth having.
//!
//! Pure std — no libc (the vendored stb_image_write stays sprite-atlas-only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const SIGNATURE = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

fn writeChunk(a: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, @intCast(data.len), .big);
    try out.appendSlice(a, &be);
    try out.appendSlice(a, kind);
    try out.appendSlice(a, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    std.mem.writeInt(u32, &be, crc.final(), .big);
    try out.appendSlice(a, &be);
}

/// Encode a straight-alpha RGBA8 row-major buffer as a PNG. Caller owns the
/// returned bytes.
pub fn encodeRgba(a: Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    return encode(a, rgba, w, h, flate.Compress.Options.default);
}

/// The same picture, compressed for SPEED rather than size — deflate's cheapest
/// level. For a bake that writes thousands of tiles: on a 1:10,000,000 sheet the
/// default level spent more time compressing than warping, for about a fifth off
/// the archive. A view rendered to a single PNG keeps the default (and with it
/// the byte-exact output the golden-image gate hashes).
pub fn encodeRgbaFast(a: Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    return encode(a, rgba, w, h, flate.Compress.Options.fastest);
}

fn encode(a: Allocator, rgba: []const u8, w: u32, h: u32, level: flate.Compress.Options) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, w) * h * 4);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &SIGNATURE);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor + alpha
    ihdr[10] = 0; // compression: deflate
    ihdr[11] = 0; // filter method 0
    ihdr[12] = 0; // no interlace
    try writeChunk(a, &out, "IHDR", &ihdr);

    // Filter-0 scanlines: 0x00 + row bytes, zlib-compressed into one IDAT.
    var raw = try std.ArrayList(u8).initCapacity(a, (@as(usize, w) * 4 + 1) * h);
    defer raw.deinit(a);
    const stride = @as(usize, w) * 4;
    for (0..h) |y| {
        raw.appendAssumeCapacity(0);
        raw.appendSliceAssumeCapacity(rgba[y * stride ..][0..stride]);
    }
    var zout = try std.Io.Writer.Allocating.initCapacity(a, @max(64, raw.items.len / 4));
    defer zout.deinit();
    var work: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&zout.writer, &work, .zlib, level);
    try c.writer.writeAll(raw.items);
    try c.finish();
    try writeChunk(a, &out, "IDAT", zout.written());

    try writeChunk(a, &out, "IEND", "");
    return out.toOwnedSlice(a);
}

// ---- decode ------------------------------------------------------------------

pub const DecodeError = error{
    /// Not a PNG at all, or truncated before the pixels.
    NotPng,
    /// A PNG, but not 8-bit truecolor+alpha non-interlaced — the only shape the
    /// tile path produces (see the module comment).
    UnsupportedPng,
    OutOfMemory,
};

/// A decoded picture: straight-alpha RGBA8, row-major, `w * h * 4` bytes in `a`.
pub const Image = struct { w: u32, h: u32, rgba: []u8 };

/// Decode an RGBA8 PNG. Caller owns `Image.rgba`.
pub fn decodeRgba(a: Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len < SIGNATURE.len + 12 or !std.mem.eql(u8, bytes[0..SIGNATURE.len], &SIGNATURE)) return DecodeError.NotPng;

    var w: u32 = 0;
    var h: u32 = 0;
    var seen_ihdr = false;
    // IDAT is one zlib stream that MAY be split across chunks, so the parts are
    // concatenated before inflating — splitting is legal and some writers do it.
    var idat = std.ArrayList(u8).empty;
    defer idat.deinit(a);

    var p: usize = SIGNATURE.len;
    while (p + 8 <= bytes.len) {
        const len: usize = std.mem.readInt(u32, bytes[p..][0..4], .big);
        const kind = bytes[p + 4 ..][0..4];
        const body_at = p + 8;
        if (body_at + len + 4 > bytes.len) return DecodeError.NotPng; // truncated chunk (+CRC)
        const body = bytes[body_at..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return DecodeError.NotPng;
            w = std.mem.readInt(u32, body[0..4], .big);
            h = std.mem.readInt(u32, body[4..8], .big);
            // depth 8 / colour 6 / deflate / filter method 0 / no interlace.
            if (body[8] != 8 or body[9] != 6 or body[10] != 0 or body[11] != 0 or body[12] != 0) return DecodeError.UnsupportedPng;
            if (w == 0 or h == 0) return DecodeError.NotPng;
            seen_ihdr = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        p = body_at + len + 4;
    }
    if (!seen_ihdr or idat.items.len == 0) return DecodeError.NotPng;

    const stride = @as(usize, w) * 4;
    const rgba = try a.alloc(u8, stride * h);
    errdefer a.free(rgba);

    // Inflate into the filtered scanlines (each is one filter byte + a row), then
    // unfilter in place. Reading row by row keeps peak memory at one row of
    // filtered bytes rather than a second full-image buffer.
    var reader = std.Io.Reader.fixed(idat.items);
    var work: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&reader, .zlib, &work);
    const line = try a.alloc(u8, stride + 1);
    defer a.free(line);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        dec.reader.readSliceAll(line) catch return DecodeError.NotPng;
        const row = rgba[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else rgba[(y - 1) * stride ..][0..stride];
        unfilter(line[0], line[1..], row, prev) catch return DecodeError.UnsupportedPng;
    }
    return .{ .w = w, .h = h, .rgba = rgba };
}

/// One scanline out of its filter (PNG filter types 0..4), 4 bytes per pixel.
/// `src` may alias nothing; `out` is written left to right because filters 1..4
/// reference bytes already reconstructed.
fn unfilter(kind: u8, src: []const u8, out: []u8, prev: ?[]const u8) error{UnsupportedPng}!void {
    const bpp = 4;
    for (out, 0..) |*o, i| {
        const x = src[i];
        const a_: u16 = if (i >= bpp) out[i - bpp] else 0;
        const b_: u16 = if (prev) |pv| pv[i] else 0;
        const c_: u16 = if (prev) |pv| (if (i >= bpp) pv[i - bpp] else 0) else 0;
        o.* = switch (kind) {
            0 => x,
            1 => x +% @as(u8, @truncate(a_)),
            2 => x +% @as(u8, @truncate(b_)),
            3 => x +% @as(u8, @truncate((a_ + b_) / 2)),
            4 => x +% @as(u8, @truncate(paeth(a_, b_, c_))),
            else => return error.UnsupportedPng,
        };
    }
}

fn paeth(a_: u16, b_: u16, c_: u16) u16 {
    const pp: i32 = @as(i32, a_) + @as(i32, b_) - @as(i32, c_);
    const pa = @abs(pp - @as(i32, a_));
    const pb = @abs(pp - @as(i32, b_));
    const pc = @abs(pp - @as(i32, c_));
    if (pa <= pb and pa <= pc) return a_;
    if (pb <= pc) return b_;
    return c_;
}

// ---- tests -------------------------------------------------------------------

test "encodeRgba: valid structure, IDAT round-trips to filter-0 scanlines" {
    const a = std.testing.allocator;
    // 2x2: red, green / blue, half-transparent white
    const rgba = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };
    const bytes = try encodeRgba(a, &rgba, 2, 2);
    defer a.free(bytes);

    try std.testing.expectEqualSlices(u8, &SIGNATURE, bytes[0..8]);
    // IHDR directly after the signature, with the right dims + RGBA8 header.
    try std.testing.expectEqualStrings("IHDR", bytes[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[20..24], .big));
    try std.testing.expectEqual(@as(u8, 8), bytes[24]); // depth
    try std.testing.expectEqual(@as(u8, 6), bytes[25]); // RGBA
    try std.testing.expectEqualStrings("IEND", bytes[bytes.len - 8 .. bytes.len - 4]);

    // Inflate the IDAT and check the raw filter-0 scanlines round-trip.
    const idat_len = std.mem.readInt(u32, bytes[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", bytes[37..41]);
    const idat = bytes[41 .. 41 + idat_len];
    var reader = std.Io.Reader.fixed(idat);
    var work: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&reader, .zlib, &work);
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(a);
    var buf: [64]u8 = undefined;
    while (true) {
        const n = dec.reader.readSliceShort(&buf) catch break;
        if (n == 0) break;
        try raw.appendSlice(a, buf[0..n]);
    }
    const want = [_]u8{0} ++ rgba[0..8].* ++ [_]u8{0} ++ rgba[8..16].*;
    try std.testing.expectEqualSlices(u8, &want, raw.items);
}

test "decodeRgba round-trips what encodeRgba wrote" {
    const a = std.testing.allocator;
    // A gradient wide enough to cross a scanline, with varying alpha (the seam
    // stack reads alpha, so a decoder that dropped it would compose wrongly).
    var rgba: [7 * 5 * 4]u8 = undefined;
    for (0..7 * 5) |i| {
        rgba[i * 4 + 0] = @intCast(i * 3 % 256);
        rgba[i * 4 + 1] = @intCast(255 - i * 7 % 256);
        rgba[i * 4 + 2] = @intCast(i * 11 % 256);
        rgba[i * 4 + 3] = if (i % 3 == 0) 0 else 255;
    }
    const bytes = try encodeRgba(a, &rgba, 7, 5);
    defer a.free(bytes);
    const img = try decodeRgba(a, bytes);
    defer a.free(img.rgba);
    try std.testing.expectEqual(@as(u32, 7), img.w);
    try std.testing.expectEqual(@as(u32, 5), img.h);
    try std.testing.expectEqualSlices(u8, &rgba, img.rgba);
}

test "decodeRgba refuses what it cannot read" {
    const a = std.testing.allocator;
    try std.testing.expectError(DecodeError.NotPng, decodeRgba(a, "not a png at all........"));
    // A real PNG header, mutated to 8-bit greyscale: a valid PNG we do not read.
    const rgba = [_]u8{ 1, 2, 3, 4 };
    const bytes = try encodeRgba(a, &rgba, 1, 1);
    defer a.free(bytes);
    const bad = try a.dupe(u8, bytes);
    defer a.free(bad);
    bad[25] = 0; // IHDR colour type: truecolor+alpha -> greyscale
    try std.testing.expectError(DecodeError.UnsupportedPng, decodeRgba(a, bad));
}

test "encodeRgba is deterministic" {
    const a = std.testing.allocator;
    const rgba = [_]u8{ 1, 2, 3, 4 } ** 16;
    const one = try encodeRgba(a, &rgba, 4, 4);
    defer a.free(one);
    const two = try encodeRgba(a, &rgba, 4, 4);
    defer a.free(two);
    try std.testing.expectEqualSlices(u8, one, two);
}
