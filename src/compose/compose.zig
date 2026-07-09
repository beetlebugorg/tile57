//! compose — the runtime tile compositor. Given N per-cell PMTiles archives plus
//! an ownership partition, it serves any (z, x, y) tile ON DEMAND by clipping each
//! owning cell's tile to the face it owns and stitching the result. Separate from
//! baking: it reads already-baked archives and never parses S-57 or runs
//! portrayal, so it depends only on the tile/geometry/coverage leaves.
//!
//!   ComposeSource          — resident compositor over mmap'd archives + a partition
//!   composeTile            — compose one tile (the stateless core ComposeSource uses)
//!   openComposeSourceFiles — open archives from disk, load or build the partition
//!   clip                   — the per-face clip-to-owned-geometry core (submodule)

const std = @import("std");
const pmtiles = @import("tiles").pmtiles;
const mvt = @import("tiles").mvt;
const mlt = @import("tiles").mlt;
const gzip = @import("tiles").gzip;
const tile = @import("tiles").tile;
const band = @import("tiles").band;
const geometry = @import("geometry");
const coverage = @import("coverage");
const s57 = @import("s57");

/// The per-face clip-to-owned-geometry core: project an owned face to tile space
/// and clip each feature to it. Pure over tiles + geometry.
pub const clip = @import("clip.zig");

pub const LoadedCov = struct {
    name: []const u8, // DSNM stem
    date: []const u8, // DSID issue/update date (YYYYMMDD)
    cscl: i32, // compilation scale (1:N)
    coverage: []const []const []const s57.LonLat, // M_COVR(CATCOV=1) rings
    bounds: [4]f64, // [w,s,e,n] over the coverage
};

pub fn toPlaneCells(a: std.mem.Allocator, loaded: []const LoadedCov) ![]geometry.plane.Cell {
    const n = loaded.len;
    const rank = try a.alloc(usize, n);
    for (rank, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, rank, loaded, struct {
        fn lt(ls: []const LoadedCov, x: usize, y: usize) bool {
            return geometry.partition.ordersBeforeKeys(ls[x].date, ls[x].name, ls[y].date, ls[y].name);
        }
    }.lt);
    const order = try a.alloc(u64, n);
    for (rank, 0..) |ci, r| order[ci] = r;

    const cells = try a.alloc(geometry.plane.Cell, n);
    for (loaded, 0..) |lc, i| {
        const out = try a.alloc(geometry.plane.Poly, lc.coverage.len);
        for (lc.coverage, 0..) |feat, fi| {
            const rings = try a.alloc([]const geometry.plane.Pt, feat.len);
            for (feat, 0..) |ring, ri| {
                const pts = try a.alloc(geometry.plane.Pt, ring.len);
                for (ring, 0..) |p, pi| pts[pi] = .{ .x = p.lon_e7, .y = p.lat_e7 };
                rings[ri] = pts;
            }
            out[fi] = rings;
        }
        cells[i] = .{
            .cscl = lc.cscl,
            .band_floor = band.bandZooms(band.bandOf(lc.cscl)).min,
            .order = order[i],
            .cov1 = out,
        };
    }
    return cells;
}

// A normalised web-mercator world axis coordinate ([0,1]) -> tile index at `scale`
// (= 2^z), clamped to [0, scale-1].
pub fn worldAxisToTile(w: f64, scale: f64) u32 {
    const f = @floor(w * scale);
    if (f < 0) return 0;
    return @intFromFloat(@min(f, scale - 1));
}

// ===========================================================================
// Per-cell composite — the on-demand tile compositor
// ===========================================================================
//
// Combine N per-cell PMTiles (each native-band-scale, its M_COVR coverage embedded in the
// metadata) into ONE merged PMTiles driven by the ownership partition. At every output tile,
// each owning cell's decoded features are clipped to the ground it OWNS (partition.ownedFace,
// projected into the tile) and concatenated per layer. The faces are a disjoint partition, so
// there is no double-draw at a seam and no z-order re-sort — S-52 draw priority rides the
// per-feature `draw_prio` property, which the style sorts client-side (so feature order within
// a tile is cosmetic). This retires the streaming in-bake cross-cell combiner: the per-cell
// bakes stay dumb + cacheable, and all cross-cell logic is precomputed as the partition.

const N_COMPOSE_LAYERS = mvt.VECTOR_LAYERS.len;

// The tile-index cover (nw..se) of an owner face's lon/lat bbox at zoom `scale = 1<<z`. The
// on-demand composeTile culls candidate tiles through this exact box.
const TileBBox = struct { tx0: u32, tx1: u32, ty0: u32, ty1: u32 };
fn faceTileBBox(face: geometry.plane.OwnedCell, scale: f64) TileBBox {
    var fb = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
    for (face.owned) |ring| for (ring) |p| {
        const lon = @as(f64, @floatFromInt(p.x)) / 1e7;
        const lat = @as(f64, @floatFromInt(p.y)) / 1e7;
        fb[0] = @min(fb[0], lon);
        fb[1] = @min(fb[1], lat);
        fb[2] = @max(fb[2], lon);
        fb[3] = @max(fb[3], lat);
    };
    const w_tl = tile.lonLatToWorld(fb[0], fb[3]); // NW: min lon, max lat
    const w_br = tile.lonLatToWorld(fb[2], fb[1]); // SE: max lon, min lat
    return .{
        .tx0 = worldAxisToTile(w_tl[0], scale),
        .tx1 = worldAxisToTile(w_br[0], scale),
        .ty0 = worldAxisToTile(w_tl[1], scale),
        .ty1 = worldAxisToTile(w_br[1], scale),
    };
}

// The classifier's owned-face grid cell width at zoom z, in integer lon/lat (deg × 1e7).
fn tileWidthE7(z: u8) i64 {
    return @max(1, @divFloor(@as(i64, 3_600_000_000), @as(i64, 1) << @intCast(z)));
}

// The (z,tx,ty) box expanded by the render BUFFER, in integer lon/lat — the region a verbatim
// passthrough must fully own (tile AND its buffer) before it fires.
fn tileClassifyBox(z: u8, tx: u32, ty: u32) geometry.plane.Box {
    const tb = tile.tileBoundsLonLat(z, tx, ty); // [min_lon, min_lat, max_lon, max_lat]
    const lon0: i64 = @intFromFloat(@round(tb[0] * 1e7));
    const lat0: i64 = @intFromFloat(@round(tb[1] * 1e7));
    const lon1: i64 = @intFromFloat(@round(tb[2] * 1e7));
    const lat1: i64 = @intFromFloat(@round(tb[3] * 1e7));
    const bufx = @divTrunc((lon1 - lon0) * @as(i64, tile.BUFFER), @as(i64, tile.EXTENT));
    const bufy = @divTrunc((lat1 - lat0) * @as(i64, tile.BUFFER), @as(i64, tile.EXTENT));
    return .{ .min_x = lon0 - bufx, .min_y = lat0 - bufy, .max_x = lon1 + bufx, .max_y = lat1 + bufy };
}

// Compose one seam/overscale tile from its contributing owner slots (in face order) into raw MLT
// bytes, or null if nothing survives the clip. Decode each owner's tile (native or overscaled
// ancestor), clip its features to the owner's projected owned face, per-layer concat in
// VECTOR_LAYERS order, re-orient polygons, encode. `ta` is a per-tile scratch allocator. Shared by
// the batch pass 2 and the on-demand composeTile, so both emit byte-identical tiles.
fn composeSeamTile(ta: std.mem.Allocator, part: *const geometry.partition.Partition, map: *const geometry.partition.BandMap, readers: []const *pmtiles.Reader, slots: []const u32, z: u8, tx: u32, ty: u32) !?[]u8 {
    const compose = clip;
    var buckets: [N_COMPOSE_LAYERS]std.ArrayList(mvt.Feature) = undefined;
    for (&buckets) |*b| b.* = std.ArrayList(mvt.Feature).empty;
    for (slots) |slot| {
        const face = map.faces[slot];
        const ci = face.index;
        const layers = (try ownerTile(ta, readers[ci], part.cells[ci].cscl, z, tx, ty)) orelse continue;
        const face_px = try compose.projectFace(ta, face.owned, z, tx, ty);
        if (face_px.len == 0) continue;
        for (layers) |layer| {
            const li = layerIndex(layer.name) orelse continue;
            for (layer.features) |feat| try compose.clipFeatureToFace(ta, &buckets[li], feat, face_px);
        }
    }
    var out_layers = std.ArrayList(mvt.Layer).empty;
    for (&buckets, 0..) |*bucket, li| {
        if (bucket.items.len == 0) continue;
        const feats = try orientPolys(ta, bucket.items);
        try out_layers.append(ta, .{ .name = mvt.VECTOR_LAYERS[li], .features = feats });
    }
    if (out_layers.items.len == 0) return null;
    return try mlt.encode(ta, .{ .layers = out_layers.items });
}

/// Compose ONE tile on demand from a resident partition + mmap'd per-cell `readers` (cell index ==
/// reader index, exactly as openComposeSourceFiles aligns them). `gzip` = true returns the gzipped MLT the
/// batch archive stores (byte-identical to it — a verbatim owner blob copied verbatim, or a freshly
/// composed seam tile re-gzipped); `gzip` = false returns the raw decompressed MLT (what a live tile
/// server wants — the HTTP layer gzips on the wire). gpa-owned; null if no cell owns this tile. This
/// is the runtime compositor: with the partition loaded once, serving a tile is a classify plus
/// either one memcpy/decompress or one decode/clip/encode, not a whole-district pass.
pub fn composeTile(gpa: std.mem.Allocator, part: *const geometry.partition.Partition, readers: []const *pmtiles.Reader, z: u8, tx: u32, ty: u32, want_gzip: bool) !TileResult {
    const compose = clip;
    const map = part.mapForZoom(z) orelse return .{ .tile = null, .owned = false };
    const scale: f64 = @floatFromInt(@as(u64, 1) << @intCast(z));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ta = arena.allocator();

    // Pass-1-equivalent for this one tile: walk owners in face order (the batch's tie order), cull
    // by face bbox, classify. The FIRST owner that fully owns the tile (buffer included) and has a
    // native blob wins the verbatim copy — faces are a disjoint partition, so that owner is unique.
    // Every other contributing owner (seam, or fully-owned-but-no-native) is collected in face order.
    // `owned` = at least one cell's coverage face covers this tile (the partition says it SHOULD
    // render here) — so a caller can tell a transient/erroneous empty from true empty ocean.
    var owned = false;
    var slots = std.ArrayList(u32).empty;
    for (map.faces, 0..) |face, slot| {
        if (face.owned.len == 0) continue;
        const ci = face.index;
        const cscl = part.cells[ci].cscl;
        const bb = faceTileBBox(face, scale);
        if (tx < bb.tx0 or tx > bb.tx1 or ty < bb.ty0 or ty > bb.ty1) continue;

        var grid = try geometry.plane.EdgeGrid.init(ta, face.owned, tileWidthE7(z));
        defer grid.deinit();
        switch (grid.classify(tileClassifyBox(z, tx, ty))) {
            .full => continue, // owns none of this tile
            .empty => { // owns the whole tile: verbatim blob if present, else fall through
                owned = true;
                if (want_gzip) {
                    if (try readers[ci].getCompressed(z, tx, ty)) |blob| return .{ .tile = try gpa.dupe(u8, blob), .owned = true };
                } else if (try readers[ci].getTile(ta, z, tx, ty)) |raw| return .{ .tile = try gpa.dupe(u8, raw), .owned = true };
            },
            .seam => owned = true,
        }
        if (!(try ownerHasTile(readers[ci], cscl, z, tx, ty))) continue;
        const face_px = try compose.projectFace(ta, face.owned, z, tx, ty);
        if (face_px.len == 0) continue;
        try slots.append(ta, @intCast(slot));
    }
    if (slots.items.len == 0) return .{ .tile = null, .owned = owned };

    const enc = (try composeSeamTile(ta, part, map, readers, slots.items, z, tx, ty)) orelse return .{ .tile = null, .owned = owned };
    // want_gzip → match the archive's stored (gzipped) bytes; else hand back the raw MLT.
    const bytes = if (want_gzip) try pmtiles.StreamWriter.gzipTile(gpa, enc) else try gpa.dupe(u8, enc);
    return .{ .tile = bytes, .owned = true };
}

/// The outcome of composing one tile: its bytes (null if nothing rendered) and whether the ownership
/// partition says a cell SHOULD render here. `tile == null and owned` = expected-but-empty (a cell
/// owns the ground but produced nothing — transient during a bake, suspect once a bake is done);
/// `tile == null and !owned` = true empty (no cell owns this ground — open ocean, safe to cache).
pub const TileResult = struct { tile: ?[]u8, owned: bool };

/// A resident compositor: the per-cell archives held mmap'd and the ownership partition built once
/// (or loaded from a sidecar), so `serve` composes any tile without a whole-district pass. Open once,
/// serve many, deinit. Only coverage-carrying archives are kept; cell index == reader index. This is
/// the runtime backing for on-demand serving — the batch is for producing a full archive; this is for
/// a camera asking for tiles.
pub const ComposeSource = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator, // owns the readers/maps arrays + adapted cells (borrowed by part)
    maps: []const []align(std.heap.page_size_min) const u8,
    readers: []const *pmtiles.Reader,
    part: geometry.partition.Partition,
    minz: u8,
    maxz: u8,
    loop_max: u8, // deepest zoom the sources can serve (native windows + one fill-up overscale zoom)
    bounds: [4]f64, // union coverage [west, south, east, north] in degrees

    /// Compose one tile → raw (decompressed) MLT + the ownership flag (gpa-owned bytes; null when
    /// nothing rendered — `owned` then says whether a cell SHOULD have). This is what a live tile
    /// server hands its HTTP layer, which gzips on the wire. Byte-faithful to the batch.
    pub fn serve(self: *ComposeSource, gpa: std.mem.Allocator, z: u8, tx: u32, ty: u32) !TileResult {
        return composeTile(gpa, &self.part, self.readers, z, tx, ty, false);
    }
    /// Serialize the resident ownership partition to a sidecar blob (gpa-owned) a later open can
    /// load to skip the owned-face build.
    pub fn serializePartition(self: *ComposeSource, gpa: std.mem.Allocator) ![]u8 {
        return geometry.partition.serialize(gpa, &self.part);
    }
    pub fn deinit(self: *ComposeSource) void {
        const gpa = self.gpa;
        self.part.deinit();
        for (self.readers) |rp| rp.deinit();
        for (self.maps) |m| std.posix.munmap(m);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Open a resident ComposeSource over per-cell PMTiles at `paths` (mmap'd, so the cell set is never
/// fully resident). If `load_partition` is non-null and valid for this cell set the partition is
/// loaded (no build); else it is built. Returns null if no archive carries coverage. Free with
/// `ComposeSource.deinit`.
pub fn openComposeSourceFiles(io: std.Io, gpa: std.mem.Allocator, paths: []const []const u8, load_partition: ?[]const u8) !?*ComposeSource {
    const src = try gpa.create(ComposeSource);
    src.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .maps = &.{}, .readers = &.{}, .part = undefined, .minz = 0, .maxz = 0, .loop_max = 0, .bounds = .{ 0, 0, 0, 0 } };
    errdefer {
        src.arena.deinit();
        gpa.destroy(src);
    }
    const a = src.arena.allocator();

    // mmap + open each archive; keep only those carrying coverage, so readers/maps/shims stay
    // aligned (cell index == reader index) for composeTile.
    var readers = std.ArrayList(*pmtiles.Reader).empty;
    var maps = std.ArrayList([]align(std.heap.page_size_min) const u8).empty;
    var shims = std.ArrayList(LoadedCov).empty;
    var built_part = false;
    errdefer {
        for (readers.items) |rp| rp.deinit();
        for (maps.items) |m| std.posix.munmap(m);
        if (built_part) src.part.deinit();
    }
    var minz: u8 = 255;
    var maxz: u8 = 0;
    var ubox = [4]f64{ 1e9, 1e9, -1e9, -1e9 }; // union coverage [w, s, e, n]
    for (paths) |path| {
        var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        const st = f.stat(io) catch {
            f.close(io);
            continue;
        };
        const len: usize = @intCast(st.size);
        if (len == 0) {
            f.close(io);
            continue;
        }
        const map = std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0) catch {
            f.close(io);
            continue;
        };
        f.close(io);
        const rp = a.create(pmtiles.Reader) catch {
            std.posix.munmap(map);
            continue;
        };
        rp.* = pmtiles.Reader.init(gpa, map) catch {
            std.posix.munmap(map);
            continue;
        };
        const meta = readMetaJson(a, rp) orelse {
            rp.deinit();
            std.posix.munmap(map);
            continue;
        };
        const cc = (coverage.decodeFromMetadata(a, meta) catch null) orelse {
            rp.deinit();
            std.posix.munmap(map);
            continue;
        };
        const bz = band.bandZooms(band.bandOf(cc.cscl));
        minz = @min(minz, bz.min);
        maxz = @max(maxz, bz.max);
        const b = [4]f64{
            @as(f64, @floatFromInt(cc.bbox[0])) / 1e7, @as(f64, @floatFromInt(cc.bbox[1])) / 1e7,
            @as(f64, @floatFromInt(cc.bbox[2])) / 1e7, @as(f64, @floatFromInt(cc.bbox[3])) / 1e7,
        };
        ubox[0] = @min(ubox[0], b[0]);
        ubox[1] = @min(ubox[1], b[1]);
        ubox[2] = @max(ubox[2], b[2]);
        ubox[3] = @max(ubox[3], b[3]);
        try maps.append(a, map);
        try readers.append(a, rp);
        try shims.append(a, .{ .name = cc.name, .date = cc.date, .cscl = cc.cscl, .coverage = cc.cov1, .bounds = b });
    }
    if (readers.items.len == 0) {
        src.arena.deinit();
        gpa.destroy(src);
        return null;
    }

    const cells = try toPlaneCells(a, shims.items);
    for (cells, readers.items) |*c, rp| c.reach = @max(bandReach(c.cscl), rp.header.max_zoom);

    var loaded = false;
    if (load_partition) |bytes| {
        if (geometry.partition.deserialize(gpa, bytes, cells)) |p| {
            src.part = p;
            loaded = true;
        } else |err| std.debug.print("  partition sidecar unusable ({s}); building\n", .{@errorName(err)});
    }
    if (!loaded) src.part = try geometry.partition.build(gpa, cells);
    built_part = true;

    const fill_max = @min(maxz + band.FILLUP_DZ, band.FILLUP_CEIL);
    src.maps = maps.items;
    src.readers = readers.items;
    src.minz = minz;
    src.maxz = maxz;
    src.loop_max = @max(maxz, fill_max);
    src.bounds = ubox;
    return src;
}

// The output-layer slot for a decoded layer name (one of mvt.VECTOR_LAYERS), or null to drop.
fn layerIndex(name: []const u8) ?usize {
    for (mvt.VECTOR_LAYERS, 0..) |ln, i| {
        if (std.mem.eql(u8, ln, name)) return i;
    }
    return null;
}

// Decode a per-cell tile by its stored type (.mlt for our bakes, .mvt otherwise).
fn decodeTile(a: std.mem.Allocator, tt: pmtiles.TileType, raw: []const u8) ![]mvt.DecodedLayer {
    return switch (tt) {
        .mlt => mlt.decode(a, raw),
        else => mvt.decode(a, raw),
    };
}

// The decoded layers cell `r` contributes at (z,tx,ty): its native tile if it has one, else —
// when z is within the fill-up window just past the cell's band native max — its deepest native
// ancestor tile with the features scaled up into this descendant (overscale). null = nothing
// reachable (below native, or a coarse-only zoom beyond the fill-up window, where the client
// camera + MapLibre overzoom take over). Everything is arena-allocated in `a`.
fn ownerTile(a: std.mem.Allocator, r: *pmtiles.Reader, cscl: i32, z: u8, tx: u32, ty: u32) !?[]mvt.DecodedLayer {
    const tt = r.header.tile_type;
    if (try r.getTile(a, z, tx, ty)) |raw| return try decodeTile(a, tt, raw);

    const nmax = band.bandZooms(band.bandOf(cscl)).max;
    if (z <= nmax or z > nmax + band.FILLUP_DZ or z > band.FILLUP_CEIL) return null;
    const shift: u5 = @intCast(z - nmax);
    const anc = (try r.getTile(a, nmax, tx >> shift, ty >> shift)) orelse return null;
    const layers = try decodeTile(a, tt, anc);
    scaleUpTile(layers, shift, tx, ty);
    return layers;
}

// The deepest zoom a cell's band ladder can serve — its native window max, or the fill-up
// overscale window just past it (`ownerTile`'s window, which FILLUP_CEIL can pull BELOW the
// native max for the finest bands — hence the @max). The band terms of `plane.Cell.reach`.
pub fn bandReach(cscl: i32) u8 {
    const nmax = band.bandZooms(band.bandOf(cscl)).max;
    return @max(nmax, @min(nmax + band.FILLUP_DZ, band.FILLUP_CEIL));
}

// Cheap existence mirror of `ownerTile` (directory probes only — no decompress, no decode):
// would it return content for cell `r` at (z,tx,ty)? Must stay in lockstep with it — the
// tile-major compositor's discovery pass uses this to reproduce the compose predicate, and
// the two passes must agree on which tiles compose.
fn ownerHasTile(r: *pmtiles.Reader, cscl: i32, z: u8, tx: u32, ty: u32) !bool {
    if ((try r.getCompressed(z, tx, ty)) != null) return true;
    const nmax = band.bandZooms(band.bandOf(cscl)).max;
    if (z <= nmax or z > nmax + band.FILLUP_DZ or z > band.FILLUP_CEIL) return false;
    const shift: u5 = @intCast(z - nmax);
    return (try r.getCompressed(nmax, tx >> shift, ty >> shift)) != null;
}

// Scale an ancestor tile's features up into descendant (tx,ty) — the sub-cell `shift` levels
// finer: pixel (px,py) → (px<<shift − sx·EXTENT, py<<shift − sy·EXTENT), where (sx,sy) is the
// descendant's position in the ancestor's 2^shift grid. Out-of-sub-cell geometry lands outside
// the tile box and is dropped by the later clip-to-owned-face. In place; `shift` is bounded by
// FILLUP_DZ so the scaled coordinates stay within i32.
fn scaleUpTile(layers: []mvt.DecodedLayer, shift: u5, tx: u32, ty: u32) void {
    const E: i64 = tile.EXTENT;
    const scale: i64 = @as(i64, 1) << @as(u6, shift);
    const mask: u32 = (@as(u32, 1) << shift) - 1;
    const sx: i64 = @intCast(tx & mask);
    const sy: i64 = @intCast(ty & mask);
    for (layers) |layer| for (layer.features) |feat| for (feat.parts) |part| for (part) |*p| {
        p.x = @intCast(@as(i64, p.x) * scale - sx * E);
        p.y = @intCast(@as(i64, p.y) * scale - sy * E);
    };
}

// Re-orient each polygon feature's rings (the sole MVT winding authority). Non-area features
// pass through; the input `properties` are borrowed unchanged (draw_prio et al. survive).
fn orientPolys(a: std.mem.Allocator, feats: []const mvt.Feature) ![]const mvt.Feature {
    const out = try a.alloc(mvt.Feature, feats.len);
    for (feats, 0..) |f, i| {
        out[i] = if (f.geom_type == .polygon)
            .{ .id = f.id, .geom_type = .polygon, .parts = try mvt.orientAreaRings(a, f.parts), .properties = f.properties }
        else
            f;
    }
    return out;
}

// The metadata JSON of an archive (decompressed), borrowed from the reader (or `a` if gzipped),
// or null if absent/unreadable.
fn readMetaJson(a: std.mem.Allocator, r: *pmtiles.Reader) ?[]const u8 {
    const h = r.header;
    if (h.metadata_length == 0) return null;
    const raw = r.bytes[@intCast(h.metadata_offset)..][0..@intCast(h.metadata_length)];
    return switch (h.internal_compression) {
        .none => raw,
        .gzip => gzip.decompress(a, raw) catch return null,
        else => null,
    };
}

// The "scamin" ladder from an archive's metadata JSON, or empty if absent/unparseable.
fn parseScamin(a: std.mem.Allocator, meta: []const u8) []const u32 {
    const Dto = struct { scamin: []const u32 = &.{} };
    const v = std.json.parseFromSliceLeaky(Dto, a, meta, .{ .ignore_unknown_fields = true }) catch return &.{};
    return v.scamin;
}
