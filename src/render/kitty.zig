//! Kitty graphics protocol encoder — inline raster images for terminals (the
//! `--kitty` CLI path). Takes an already-encoded PNG (the pixel surface's
//! normal output) and wraps it in chunked APC sequences:
//!
//!     ESC _ G a=T,f=100,q=2,m=1 ; <base64 ≤4096> ESC \   (continuation m=1)
//!     ESC _ G m=0 ; <last chunk> ESC \
//!
//! a=T transmits + displays at the cursor, f=100 marks PNG payload (the
//! terminal reads the dimensions from it), q=2 suppresses replies (we never
//! read the tty back). Supported by Ghostty, Kitty, WezTerm, Konsole —
//! notably NOT a sixel dependency.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Max base64 payload per APC chunk, per the protocol spec.
const CHUNK = 4096;

/// Wrap PNG bytes as a complete transmit+display sequence at the cursor.
pub fn encodePng(out: Allocator, png_bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try out.alloc(u8, enc.calcSize(png_bytes.len));
    defer out.free(b64);
    _ = enc.encode(b64, png_bytes);

    var buf = std.ArrayList(u8).empty;
    var off: usize = 0;
    var first = true;
    while (off < b64.len) {
        const end = @min(off + CHUNK, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        if (first) {
            try buf.print(out, "\x1b_Ga=T,f=100,q=2,m={c};", .{more});
            first = false;
        } else {
            try buf.print(out, "\x1b_Gm={c};", .{more});
        }
        try buf.appendSlice(out, b64[off..end]);
        try buf.appendSlice(out, "\x1b\\");
        off = end;
    }
    return buf.toOwnedSlice(out);
}

/// Delete every visible placement — emitted before each TUI frame so replaced
/// frames don't accumulate in the terminal's image store.
pub const delete_all = "\x1b_Ga=d,d=A,q=2\x1b\\";

/// Transmit PNG bytes into the terminal's image store under `id` WITHOUT
/// displaying (a=t) — the TUI's pan cache: transmit a big region once, then
/// pan with cheap `place` calls against it.
pub fn transmitPng(out: Allocator, png_bytes: []const u8, id: u32) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try out.alloc(u8, enc.calcSize(png_bytes.len));
    defer out.free(b64);
    _ = enc.encode(b64, png_bytes);
    var buf = std.ArrayList(u8).empty;
    var off: usize = 0;
    var first = true;
    while (off < b64.len) {
        const end = @min(off + CHUNK, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        if (first) {
            try buf.print(out, "\x1b_Ga=t,f=100,i={d},q=2,m={c};", .{ id, more });
            first = false;
        } else {
            try buf.print(out, "\x1b_Gm={c};", .{more});
        }
        try buf.appendSlice(out, b64[off..end]);
        try buf.appendSlice(out, "\x1b\\");
        off = end;
    }
    return buf.toOwnedSlice(out);
}

/// Display the (x, y, w, h) SOURCE rectangle of stored image `id` at the
/// cursor, without moving the cursor (C=1). ~40 bytes — this is what makes
/// panning inside a cached region instant.
pub fn place(out: Allocator, id: u32, x: u32, y: u32, w: u32, h: u32) ![]u8 {
    return std.fmt.allocPrint(out, "\x1b_Ga=p,i={d},x={d},y={d},w={d},h={d},C=1,q=2\x1b\\", .{ id, x, y, w, h });
}

test "kitty encode: chunk structure and payload round-trip" {
    const a = std.testing.allocator;
    // A payload long enough to need 2 chunks once base64-encoded.
    const png = try a.alloc(u8, 4000);
    defer a.free(png);
    for (png, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    const s = try encodePng(a, png);
    defer a.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "\x1b_Ga=T,f=100,q=2,m=1;"));
    try std.testing.expect(std.mem.endsWith(u8, s, "\x1b\\"));
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b_Gm=0;") != null);
    // Strip the escapes, concatenate payloads, decode, compare.
    var b64 = std.ArrayList(u8).empty;
    defer b64.deinit(a);
    var it = std.mem.splitSequence(u8, s, "\x1b\\");
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const semi = std.mem.indexOfScalar(u8, part, ';') orelse continue;
        try b64.appendSlice(a, part[semi + 1 ..]);
    }
    const dec = std.base64.standard.Decoder;
    const raw = try a.alloc(u8, try dec.calcSizeForSlice(b64.items));
    defer a.free(raw);
    try dec.decode(raw, b64.items);
    try std.testing.expectEqualSlices(u8, png, raw);
}
