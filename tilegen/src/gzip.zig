//! gzip compress/decompress over the Zig 0.16 streaming flate API.
//! Used for MVT tile payloads and PMTiles directories/metadata.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

/// gzip-compress `data`. Caller owns the returned slice.
pub fn compress(gpa: Allocator, data: []const u8) ![]u8 {
    // Allocating output needs a non-trivial buffer (Compress asserts > 8).
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, @max(64, data.len / 2));
    defer out.deinit();
    var work: [flate.max_window_len]u8 = undefined; // Compress asserts >= window
    var c = try flate.Compress.init(&out.writer, &work, .gzip, flate.Compress.Options.default);
    try c.writer.writeAll(data);
    try c.finish();
    return try out.toOwnedSlice();
}

/// gzip-decompress `data`. Caller owns the returned slice.
pub fn decompress(gpa: Allocator, data: []const u8) ![]u8 {
    var in = std.Io.Reader.fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&in, .gzip, &window);
    return try d.reader.allocRemaining(gpa, .unlimited);
}

test "gzip round-trip" {
    const a = std.testing.allocator;
    const inputs = [_][]const u8{
        "",
        "hello",
        "the quick brown fox " ** 50,
    };
    for (inputs) |src| {
        const z = try compress(a, src);
        defer a.free(z);
        const back = try decompress(a, z);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, src, back);
        // gzip magic
        if (z.len >= 2) {
            try std.testing.expectEqual(@as(u8, 0x1f), z[0]);
            try std.testing.expectEqual(@as(u8, 0x8b), z[1]);
        }
    }
}
