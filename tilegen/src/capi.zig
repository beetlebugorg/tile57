//! C ABI for libtilegen.a — what the C++ MapLibre host links against.
//!
//! For M5 a "tile source" is backed by the Zig PMTiles reader: the C++ host
//! hands us the archive bytes (it owns file IO) and asks for tiles by (z,x,y);
//! we return decompressed MVT. At M6 the same C ABI gets a second constructor
//! that generates tiles live from S-57 cells — the host doesn't change.
//!
//! Contract: POD across the seam (ptr/len + error codes); all Zig errors,
//! slices and optionals stay inside Zig. Header: ../../include/tilegen.h.

const std = @import("std");
const pmtiles = @import("pmtiles.zig");

// page_allocator (mmap-backed) keeps the Zig static lib free of a libc
// dependency — the C++ host links libc itself. tg_free takes the slice length
// so freeing works without a managing allocator.
const gpa = std.heap.page_allocator;

const Source = struct {
    reader: pmtiles.Reader,
    data: []u8, // owned copy of the archive bytes
};

/// Open a PMTiles archive from in-memory bytes (the host reads the file).
/// Returns an opaque handle, or null on error.
export fn tg_open_bytes(data_ptr: [*]const u8, data_len: usize) callconv(.c) ?*Source {
    const copy = gpa.dupe(u8, data_ptr[0..data_len]) catch return null;
    const reader = pmtiles.Reader.init(gpa, copy) catch {
        gpa.free(copy);
        return null;
    };
    const src = gpa.create(Source) catch {
        var r = reader;
        r.deinit();
        gpa.free(copy);
        return null;
    };
    src.* = .{ .reader = reader, .data = copy };
    return src;
}

export fn tg_close(src: ?*Source) callconv(.c) void {
    const s = src orelse return;
    s.reader.deinit();
    gpa.free(s.data);
    gpa.destroy(s);
}

/// Min/max zoom of the archive (so the host can build the source's tilejson).
export fn tg_min_zoom(src: ?*Source) callconv(.c) u8 {
    return if (src) |s| s.reader.header.min_zoom else 0;
}
export fn tg_max_zoom(src: ?*Source) callconv(.c) u8 {
    return if (src) |s| s.reader.header.max_zoom else 0;
}

/// Fetch tile (z,x,y) as decompressed MVT bytes.
/// Returns 1 and sets out/out_len (caller frees with tg_free) if found;
/// 0 if the tile is absent; negative on error.
export fn tg_get_tile(
    src: ?*Source,
    z: u8,
    x: u32,
    y: u32,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const s = src orelse return -1;
    const tile = s.reader.getTile(gpa, z, x, y) catch return -2;
    const t = tile orelse return 0;
    out.* = t.ptr;
    out_len.* = t.len;
    return 1;
}

export fn tg_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}
