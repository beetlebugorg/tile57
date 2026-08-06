//! Composing RASTER charts — the quilt of baked RNC sheets.
//!
//! Same partition, different seam. A vector compositor clips each owner's
//! FEATURES to the ground it owns and concatenates them; there is no equivalent
//! for a picture, because a picture has no features to clip. What a raster chart
//! has instead is a bake that already cut it at its neat line: every tile is
//! transparent outside the sheet's `PLY` border. So the seam is resolved by
//! STACKING — each contributing sheet's tile painted over the one below it, best
//! last — and the partition decides only the order.
//!
//! WHY THAT IS THE SAME ANSWER the vector path gives. The ownership faces are
//! disjoint, and a sheet's face is its coverage minus every better sheet's. Where
//! the best sheet has pixels it is inside its own neat line, so it owns that
//! ground and lands on top; where it is transparent it is outside its border, so
//! the ground belongs to the next sheet down, whose pixels show through. Masking
//! each tile to its face would produce the same picture for a great deal more
//! work — and would fringe every seam with the resampling error of a polygon
//! rasterised into 256 pixels.
//!
//! THE ORDINARY CASE IS ONE SHEET, and it is served verbatim: no decode, no
//! re-encode, the archive's own bytes. Stacking happens only where sheets
//! actually overlap in a tile.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tiles = @import("tiles");
const pmtiles = tiles.pmtiles;
const png = tiles.png;
const geometry = @import("geometry");
const coverage = @import("coverage");
const compose = @import("compose.zig");

/// Every baked tile is 256 px square (bakebsb.TILE_PX). A picture of any other
/// size is not one of ours and takes no part in a stack.
pub const TILE_PX: usize = 256;

/// How far past its own top zoom a sheet may be magnified when nothing finer
/// covers the ground. This is the paper-chart behaviour — an overscaled chart is
/// still a chart, and a blank screen is not — but a picture magnified past a few
/// levels says nothing the mariner can read, so it stops well before the vector
/// path's deep overscale.
pub const OVERSCALE_DZ: u8 = 3;

/// One composed picture tile: the bytes (null when no sheet drew here) and
/// whether the partition says a sheet SHOULD have. Mirrors compose.TileResult,
/// which the compositor converts it to.
pub const Result = struct { tile: ?[]u8, owned: bool };

/// The deepest zoom a sheet can serve: its archive's own top plus the overscale
/// above. What a host's zoom cap reads, so it stops where the pictures do.
pub fn reach(r: *const pmtiles.Reader) u8 {
    return r.header.max_zoom +| OVERSCALE_DZ;
}

/// Compose one picture tile from the sheets that own it. `readers` is index-
/// aligned with `part.cells`, exactly as the vector path aligns them.
pub fn tile(gpa: Allocator, part: *const geometry.partition.Partition, readers: []const *pmtiles.Reader, z: u8, tx: u32, ty: u32) !Result {
    if (part.maps.len == 0) return .{ .tile = null, .owned = false };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ta = arena.allocator();

    // The sheets that could draw here, BEST FIRST: the band governing this zoom,
    // then each coarser band — which is the same cross-band fill the vector path
    // does, and for the same reason: where the governing band has no chart, the
    // best coarser one is what a mariner would have unfolded next.
    var stack = std.ArrayList(Contrib).empty;
    var seen = try ta.alloc(bool, part.cells.len);
    @memset(seen, false);
    var owned = false;

    var mi: usize = 0;
    while (mi < part.maps.len and part.maps[mi].tier > z) mi += 1;
    if (mi == part.maps.len) mi = part.maps.len - 1; // below every floor: the coarsest
    while (mi < part.maps.len) : (mi += 1) {
        const map = &part.maps[mi];
        for (map.faces, 0..) |face, fslot| {
            if (face.owned.len == 0) continue;
            const ci = face.index;
            if (seen[ci]) continue; // already placed, at a finer band
            if (!faceCovers(map.bbox[fslot], z, tx, ty)) continue;
            seen[ci] = true;
            owned = true;
            const src = sourceTile(readers[ci], z, tx, ty) orelse continue;
            try stack.append(ta, .{ .ci = @intCast(ci), .src = src });
        }
    }
    if (stack.items.len == 0) return .{ .tile = null, .owned = owned };

    // One sheet at its own zoom is the ordinary case: hand back the archive's
    // bytes as they are. Nothing a decode-and-re-encode could add.
    if (stack.items.len == 1 and stack.items[0].src.z == z) {
        const only = stack.items[0];
        return .{ .tile = try readers[only.ci].getTile(gpa, z, tx, ty) orelse return .{ .tile = null, .owned = owned }, .owned = true };
    }

    // Otherwise stack: worst first, so the best sheet lands on top and shows
    // through only where it has nothing.
    var out: ?[]u8 = null;
    var i: usize = stack.items.len;
    while (i > 0) {
        i -= 1;
        const px = (try pixelsOf(ta, readers[stack.items[i].ci], stack.items[i].src, z, tx, ty)) orelse continue;
        if (out) |dst| overInto(dst, px) else out = px;
    }
    const rgba = out orelse return .{ .tile = null, .owned = owned };
    return .{ .tile = try png.encodeRgbaFast(gpa, rgba, @intCast(TILE_PX), @intCast(TILE_PX)), .owned = true };
}

const Src = struct { z: u8, x: u32, y: u32 };
const Contrib = struct { ci: u32, src: Src };

/// Which tile of `r` covers (z,tx,ty): its own, or the deepest ancestor within
/// the overscale window. Null when the sheet has nothing to show here — the
/// ordinary case for a pyramid clipped to a neat line.
fn sourceTile(r: *pmtiles.Reader, z: u8, tx: u32, ty: u32) ?Src {
    if ((r.getCompressed(z, tx, ty) catch null) != null) return .{ .z = z, .x = tx, .y = ty };
    if (z <= r.header.max_zoom or z > reach(r)) return null;
    const shift: u5 = @intCast(z - r.header.max_zoom);
    const ax = tx >> shift;
    const ay = ty >> shift;
    if ((r.getCompressed(r.header.max_zoom, ax, ay) catch null) == null) return null;
    return .{ .z = r.header.max_zoom, .x = ax, .y = ay };
}

/// Does a face's lon/lat bbox reach tile (z,tx,ty)? The same cheap cull the
/// vector compositor applies before any geometry, widened by one tile because
/// the projection runs through the system libm and two platforms disagree by
/// ulps at a face edge — a cull may be generous, never tight.
fn faceCovers(fb: [4]f64, z: u8, tx: u32, ty: u32) bool {
    const scale: f64 = @floatFromInt(@as(u64, 1) << @intCast(z));
    const nw = tiles.tile.lonLatToWorld(fb[0], fb[3]);
    const se = tiles.tile.lonLatToWorld(fb[2], fb[1]);
    const x0 = @floor(nw[0] * scale) - 1;
    const x1 = @floor(se[0] * scale) + 1;
    const y0 = @floor(nw[1] * scale) - 1;
    const y1 = @floor(se[1] * scale) + 1;
    const fx: f64 = @floatFromInt(tx);
    const fy: f64 = @floatFromInt(ty);
    return fx >= x0 and fx <= x1 and fy >= y0 and fy <= y1;
}

/// One contributor's picture as RGBA, magnified out of an ancestor tile when it
/// came from one. Null when the tile is missing or is not a 256 px picture we
/// can read.
fn pixelsOf(a: Allocator, r: *pmtiles.Reader, src: Src, z: u8, tx: u32, ty: u32) !?[]u8 {
    const bytes = (try r.getTile(a, src.z, src.x, src.y)) orelse return null;
    const img = png.decodeRgba(a, bytes) catch return null;
    if (img.w != TILE_PX or img.h != TILE_PX) return null;
    if (src.z == z) return img.rgba;

    // Magnify the sub-rectangle of the ancestor this tile occupies. Nearest
    // neighbour: the picture is already past the detail it has, and smoothing it
    // would only suggest detail that is not there.
    const shift: u5 = @intCast(z - src.z);
    const mask: u32 = (@as(u32, 1) << shift) - 1;
    const step = TILE_PX >> shift; // the ancestor pixels this tile covers, per axis
    if (step == 0) return null;
    const ox = @as(usize, tx & mask) * step;
    const oy = @as(usize, ty & mask) * step;
    const out = try a.alloc(u8, TILE_PX * TILE_PX * 4);
    for (0..TILE_PX) |j| {
        const sj = oy + (j >> shift);
        for (0..TILE_PX) |i| {
            const si = ox + (i >> shift);
            const s = (sj * TILE_PX + si) * 4;
            const d = (j * TILE_PX + i) * 4;
            @memcpy(out[d..][0..4], img.rgba[s..][0..4]);
        }
    }
    return out;
}

/// Paint `src` over `dst`, in place — straight-alpha Porter-Duff "over". The
/// sheets meet at partial alpha along their neat lines (the bake anti-aliases the
/// border), so a plain copy-where-opaque would leave a hairline of the sheet
/// below showing through at every seam.
fn overInto(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 4) {
        const sa: u32 = src[i + 3];
        if (sa == 0) continue;
        if (sa == 255) {
            @memcpy(dst[i..][0..4], src[i..][0..4]);
            continue;
        }
        const da: u32 = dst[i + 3];
        const keep = da * (255 - sa) / 255;
        const oa = sa + keep;
        for (0..3) |k| {
            dst[i + k] = @intCast((@as(u32, src[i + k]) * sa + @as(u32, dst[i + k]) * keep) / oa);
        }
        dst[i + 3] = @intCast(oa);
    }
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

fn solidTile(a: Allocator, r: u8, g: u8, b: u8, alpha: u8) ![]u8 {
    const rgba = try a.alloc(u8, TILE_PX * TILE_PX * 4);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = alpha;
    }
    return rgba;
}

/// A one-tile archive holding `rgba` at (z,x,y), with `cov` embedded as the
/// chart's coverage — the shape the KAP bake writes.
fn testArchive(gpa: Allocator, z: u8, x: u32, y: u32, rgba: []const u8, cov_json: []const u8) ![]u8 {
    const bytes = try png.encodeRgbaFast(gpa, rgba, @intCast(TILE_PX), @intCast(TILE_PX));
    defer gpa.free(bytes);
    var w = pmtiles.StreamWriter.init(gpa);
    defer w.deinit();
    w.compress_tiles = false;
    try w.add(z, x, y, bytes);
    const meta = try std.fmt.allocPrint(gpa, "{{\"format\":\"png\",\"coverage\":{s}}}", .{cov_json});
    defer gpa.free(meta);
    return w.finishBytes(.{ .metadata_json = meta, .tile_type = .png });
}

test "one sheet in a tile is served verbatim; two are stacked best-on-top" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const z: u8 = 9;
    const tx: u32 = 100;
    const ty: u32 = 200;
    const tb = tiles.tile.tileBoundsLonLat(z, tx, ty);

    // Two sheets of the same scale meeting inside this tile. The newer covers the
    // west half and its picture stops at that border, exactly as a baked sheet's
    // does at its neat line; the older covers the whole tile. Stacked, the tile
    // must read newer-west / older-east — the ownership answer, reached without
    // masking anything.
    const west = [4]f64{ tb[0], tb[1], (tb[0] + tb[2]) / 2, tb[3] };
    const newer = try solidTile(a, 255, 0, 0, 255);
    for (0..TILE_PX) |j| for (TILE_PX / 2..TILE_PX) |i| {
        newer[(j * TILE_PX + i) * 4 + 3] = 0;
    };
    const older = try solidTile(a, 0, 0, 255, 255);

    const arc_new = try testArchive(gpa, z, tx, ty, newer, try covJson(a, "NEW", "20240101", west));
    defer gpa.free(arc_new);
    const arc_old = try testArchive(gpa, z, tx, ty, older, try covJson(a, "OLD", "20200101", tb));
    defer gpa.free(arc_old);

    var rd_new = try pmtiles.Reader.init(gpa, arc_new);
    defer rd_new.deinit();
    var rd_old = try pmtiles.Reader.init(gpa, arc_old);
    defer rd_old.deinit();

    // Cell order matches reader order, as the compositor aligns them; the newer
    // date orders first, which is the partition's own tie-break.
    const cells = try a.alloc(geometry.plane.Cell, 2);
    cells[0] = .{ .cscl = 80_000, .band_floor = 9, .order = 0, .reach = 12, .cov1 = try covRect(a, west) };
    cells[1] = .{ .cscl = 80_000, .band_floor = 9, .order = 1, .reach = 12, .cov1 = try covRect(a, tb) };
    var part = try geometry.partition.build(gpa, cells);
    defer part.deinit();

    const readers = [_]*pmtiles.Reader{ &rd_new, &rd_old };
    const res = try tile(gpa, &part, &readers, z, tx, ty);
    const out = res.tile orelse return error.NothingComposed;
    defer gpa.free(out);
    try testing.expect(res.owned);

    const img = try png.decodeRgba(a, out);
    // West: the newer sheet. East: through its transparent half to the older one.
    try testing.expectEqual(@as(u8, 255), img.rgba[(10 * TILE_PX + 10) * 4 + 0]);
    try testing.expectEqual(@as(u8, 0), img.rgba[(10 * TILE_PX + 10) * 4 + 2]);
    try testing.expectEqual(@as(u8, 255), img.rgba[(10 * TILE_PX + 200) * 4 + 2]);
    try testing.expectEqual(@as(u8, 0), img.rgba[(10 * TILE_PX + 200) * 4 + 0]);

    // A tile only ONE sheet reaches comes back as that sheet's own bytes.
    const solo = [_]*pmtiles.Reader{&rd_old};
    const cells1 = try a.alloc(geometry.plane.Cell, 1);
    cells1[0] = .{ .cscl = 80_000, .band_floor = 9, .order = 0, .reach = 12, .cov1 = try covRect(a, tb) };
    var part1 = try geometry.partition.build(gpa, cells1);
    defer part1.deinit();
    const one = try tile(gpa, &part1, &solo, z, tx, ty);
    const bytes = one.tile orelse return error.NothingComposed;
    defer gpa.free(bytes);
    const raw = (try rd_old.getTile(a, z, tx, ty)).?;
    try testing.expectEqualSlices(u8, raw, bytes);
}

test "a compositor refuses a chart of the other kind" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const z: u8 = 9;
    const tb = tiles.tile.tileBoundsLonLat(z, 100, 200);
    const rgba = try solidTile(a, 1, 2, 3, 255);
    const pic = try testArchive(gpa, z, 100, 200, rgba, try covJson(a, "PIC", "20240101", tb));
    defer gpa.free(pic);
    var rd = try pmtiles.Reader.init(gpa, pic);
    defer rd.deinit();

    // The archive says what it holds, and it is the only thing that does.
    try testing.expectEqual(compose.Kind.raster, compose.kindOf(&rd));

    // Offered to the compositor that clips geometry: its tiles are pictures, so
    // there is nothing to clip and nothing to answer but no.
    const cov = (try coverageOf(a, gpa, pic)) orelse return error.NoCoverage;
    const archives = [_]compose.ChartArchive{.{ .reader = &rd, .cov = cov }};
    try testing.expectError(error.MixedChartKinds, compose.ComposeSource.open(gpa, &archives, null));
}

fn coverageOf(a: Allocator, scratch: Allocator, archive: []const u8) !?coverage.ChartCoverage {
    var rd = try pmtiles.Reader.init(scratch, archive);
    defer rd.deinit();
    const meta = archive[@intCast(rd.header.metadata_offset)..][0..@intCast(rd.header.metadata_length)];
    return coverage.decodeFromMetadata(a, scratch, meta);
}

test "a tile no sheet covers is empty, and says so" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const z: u8 = 9;
    const tb = tiles.tile.tileBoundsLonLat(z, 100, 200);
    const rgba = try solidTile(a, 1, 2, 3, 255);
    const arc = try testArchive(gpa, z, 100, 200, rgba, try covJson(a, "ONE", "20240101", tb));
    defer gpa.free(arc);
    var rd = try pmtiles.Reader.init(gpa, arc);
    defer rd.deinit();

    const cells = try a.alloc(geometry.plane.Cell, 1);
    cells[0] = .{ .cscl = 80_000, .band_floor = 9, .order = 0, .reach = 12, .cov1 = try covRect(a, tb) };
    var part = try geometry.partition.build(gpa, cells);
    defer part.deinit();

    const readers = [_]*pmtiles.Reader{&rd};
    // Far outside the sheet: no owner, no tile, and not an error.
    const res = try tile(gpa, &part, &readers, z, 400, 200);
    try testing.expect(res.tile == null and !res.owned);
}

test "a sheet magnified past its top zoom keeps the pixel it had" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const z: u8 = 9;
    const tx: u32 = 100;
    const ty: u32 = 200;
    const tb = tiles.tile.tileBoundsLonLat(z, tx, ty);
    // A picture whose left half differs from its right, so a magnify that took
    // the wrong sub-rectangle shows up as the wrong colour.
    const rgba = try solidTile(a, 10, 20, 30, 255);
    for (0..TILE_PX) |j| for (TILE_PX / 2..TILE_PX) |i| {
        rgba[(j * TILE_PX + i) * 4 + 0] = 200;
    };
    const arc = try testArchive(gpa, z, tx, ty, rgba, try covJson(a, "ONE", "20240101", tb));
    defer gpa.free(arc);
    var rd = try pmtiles.Reader.init(gpa, arc);
    defer rd.deinit();

    const cells = try a.alloc(geometry.plane.Cell, 1);
    cells[0] = .{ .cscl = 80_000, .band_floor = 9, .order = 0, .reach = 12, .cov1 = try covRect(a, tb) };
    var part = try geometry.partition.build(gpa, cells);
    defer part.deinit();
    const readers = [_]*pmtiles.Reader{&rd};

    // One zoom deeper, the WEST child of that tile: every pixel comes from the
    // ancestor's left half.
    const res = try tile(gpa, &part, &readers, z + 1, tx * 2, ty * 2);
    const out = res.tile orelse return error.NothingComposed;
    defer gpa.free(out);
    const img = try png.decodeRgba(a, out);
    try testing.expectEqual(@as(u8, 10), img.rgba[(100 * TILE_PX + 250) * 4 + 0]);

    // And the EAST child comes from the right half.
    const res2 = try tile(gpa, &part, &readers, z + 1, tx * 2 + 1, ty * 2);
    const out2 = res2.tile orelse return error.NothingComposed;
    defer gpa.free(out2);
    const img2 = try png.decodeRgba(a, out2);
    try testing.expectEqual(@as(u8, 200), img2.rgba[(100 * TILE_PX + 5) * 4 + 0]);

    // Past the overscale window there is nothing to magnify from.
    const far = try tile(gpa, &part, &readers, z + OVERSCALE_DZ + 1, tx << (OVERSCALE_DZ + 1), ty << (OVERSCALE_DZ + 1));
    try testing.expect(far.tile == null);
}

/// A rectangular coverage ring over a tile's own bounds, as one plane cell.
fn covRect(a: Allocator, r: [4]f64) ![]const geometry.plane.Poly {
    const P = geometry.plane.Pt;
    const e7 = struct {
        fn f(v: f64) i64 {
            return @intFromFloat(@round(v * 1e7));
        }
    }.f;
    const ring = try a.dupe(P, &.{
        .{ .x = e7(r[0]), .y = e7(r[1]) }, .{ .x = e7(r[2]), .y = e7(r[1]) },
        .{ .x = e7(r[2]), .y = e7(r[3]) }, .{ .x = e7(r[0]), .y = e7(r[3]) },
    });
    const rings = try a.dupe([]const P, &.{ring});
    return a.dupe(geometry.plane.Poly, &.{rings});
}

/// The same rectangle as the coverage JSON a baked archive embeds.
fn covJson(a: Allocator, name: []const u8, date: []const u8, r: [4]f64) ![]const u8 {
    const e7 = struct {
        fn f(v: f64) i64 {
            return @intFromFloat(@round(v * 1e7));
        }
    }.f;
    return std.fmt.allocPrint(a,
        \\{{"v":1,"name":"{s}","date":"{s}","cscl":80000,"band":2,"bbox":[{d},{d},{d},{d}],"cov1":[[[[{d},{d}],[{d},{d}],[{d},{d}],[{d},{d}]]]],"cov2":[]}}
    , .{
        name,     date,     e7(r[0]), e7(r[1]), e7(r[2]), e7(r[3]),
        e7(r[0]), e7(r[1]), e7(r[2]), e7(r[1]), e7(r[2]), e7(r[3]),
        e7(r[0]), e7(r[3]),
    });
}
