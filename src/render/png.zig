//! Minimal PNG encoder for RGBA8 buffers (the RasterCanvas output): 8-bit
//! truecolor+alpha, filter 0 on every scanline, one zlib IDAT via the std
//! flate compressor. Deterministic bytes for a given buffer — the golden-image
//! gate hashes the encoded file.
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
    var c = try flate.Compress.init(&zout.writer, &work, .zlib, flate.Compress.Options.default);
    try c.writer.writeAll(raw.items);
    try c.finish();
    try writeChunk(a, &out, "IDAT", zout.written());

    try writeChunk(a, &out, "IEND", "");
    return out.toOwnedSlice(a);
}

// ---- tests -------------------------------------------------------------------

test "encodeRgba: valid structure, IDAT round-trips to filter-0 scanlines" {
    const a = std.testing.allocator;
    // 2x2: red, green / blue, half-transparent white
    const rgba = [_]u8{
        255, 0,   0,   255, 0,   255, 0,   255,
        0,   0,   255, 255, 255, 255, 255, 128,
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

test "encodeRgba is deterministic" {
    const a = std.testing.allocator;
    const rgba = [_]u8{ 1, 2, 3, 4 } ** 16;
    const one = try encodeRgba(a, &rgba, 4, 4);
    defer a.free(one);
    const two = try encodeRgba(a, &rgba, 4, 4);
    defer a.free(two);
    try std.testing.expectEqualSlices(u8, one, two);
}
