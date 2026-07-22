//! compose — the runtime tile compositor. Given N per-cell PMTiles archives plus
//! an ownership partition, it serves any (z, x, y) tile ON DEMAND by clipping each
//! owning cell's tile to the face it owns and stitching the result. Separate from
//! baking: it reads already-baked archives and never parses S-57 or runs
//! portrayal, so it depends only on the tile/geometry/coverage leaves.
//!
//!   ComposeSource           — resident compositor over mmap'd archives + a partition
//!   composeTile             — compose one tile (the stateless core ComposeSource uses)
//!   openComposeSourceFiles  — open archives from disk, load or build the partition
//!   openComposeSourceCharts — same, borrowing already-open charts' readers + coverage
//!   clip                    — the per-face clip-to-owned-geometry core (submodule)

const std = @import("std");
const pmtiles = @import("tiles").pmtiles;
const mvt = @import("tiles").mvt;
const mlt = @import("tiles").mlt;
const gzip = @import("tiles").gzip;
const tile = @import("tiles").tile;
const band = @import("tiles").band;
const filemap = @import("tiles").filemap;
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
    light_reach: ?coverage.LightReach = null, // sector-figure reach ("light_reach" metadata)
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
            .light_bbox = if (lc.light_reach) |lr| lr.bbox else null,
            .light_range_m = if (lc.light_reach) |lr| lr.range_m else 0,
        };
    }
    return cells;
}

/// Even-odd ray cast: is (px,py) inside the coverage `polys` (a bag of polygons,
/// each outer ring + holes)? Crossing every ring with one XOR accumulator means a
/// point inside a hole reads as outside, exactly as CATCOV=1 minus its holes.
fn pointInCoverage(px: i64, py: i64, polys: []const geometry.plane.Poly) bool {
    var inside = false;
    for (polys) |poly| {
        for (poly) |ring| {
            if (ring.len < 3) continue;
            var j = ring.len - 1;
            for (ring, 0..) |p, i| {
                const q = ring[j];
                if ((p.y > py) != (q.y > py)) {
                    const dy: f64 = @floatFromInt(q.y - p.y);
                    const t: f64 = @as(f64, @floatFromInt(py - p.y)) / dy;
                    const xint = @as(f64, @floatFromInt(p.x)) + t * @as(f64, @floatFromInt(q.x - p.x));
                    if (@as(f64, @floatFromInt(px)) < xint) inside = !inside;
                }
                j = i;
            }
        }
    }
    return inside;
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
// per-feature `display_priority` property, which the style sorts client-side (so feature order within
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
fn composeSeamTile(ta: std.mem.Allocator, part: *const geometry.partition.Partition, map: *const geometry.partition.BandMap, readers: []const *pmtiles.Reader, slots: []const u32, reach_cells: []const u32, z: u8, tx: u32, ty: u32) !?[]u8 {
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
    // Reach-ring cells: no owned ground in this tile, but their light sector
    // figures sweep in (the bake addressed the tile for exactly that reach).
    // Contribute ONLY the constructed LIGHTS figures, whole — the same
    // clipFeatureToFace exception, minus a face. Everything else in the tile
    // (ground the cell doesn't own here) stays with its owners.
    for (reach_cells) |ci| {
        const layers = (try ownerTile(ta, readers[ci], part.cells[ci].cscl, z, tx, ty)) orelse continue;
        for (layers) |layer| {
            const li = layerIndex(layer.name) orelse continue;
            for (layer.features) |feat| {
                if (feat.geom_type != .linestring or !compose.isLightFigure(feat)) continue;
                const parts = try ta.alloc([]const mvt.Point, feat.parts.len);
                for (feat.parts, 0..) |p, i| parts[i] = try ta.dupe(mvt.Point, p);
                try buckets[li].append(ta, .{ .geom_type = .linestring, .parts = parts, .properties = feat.properties });
            }
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
    // by face bbox, classify. An owner that fully owns the tile (buffer included) is the verbatim
    // candidate — faces are a disjoint partition, so that owner is unique — but the copy is
    // deferred until the reach scan below proves no neighbouring cell's sector figures sweep in.
    // Every other contributing owner (seam, or fully-owned-but-no-native) is collected in face order.
    // `owned` = at least one cell's coverage face covers this tile (the partition says it SHOULD
    // render here) — so a caller can tell a transient/erroneous empty from true empty ocean.
    var owned = false;
    var slots = std.ArrayList(u32).empty;
    var verbatim: ?usize = null; // cell index of the unique tile+buffer-owning cell
    for (map.faces, 0..) |face, slot| {
        if (face.owned.len == 0) continue;
        const ci = face.index;
        const cscl = part.cells[ci].cscl;
        const bb = faceTileBBox(face, scale);
        if (tx < bb.tx0 or tx > bb.tx1 or ty < bb.ty0 or ty > bb.ty1) continue;

        var grid = try geometry.plane.EdgeGrid.init(ta, face.owned, tileWidthE7(z));
        defer grid.deinit();
        const cls = grid.classify(tileClassifyBox(z, tx, ty));
        if (cls == .full) continue; // owns none of this tile
        owned = true;
        if (!(try ownerHasTile(readers[ci], cscl, z, tx, ty))) continue;
        if (cls == .empty) { // owns the whole tile: its face projection can't be empty
            verbatim = ci;
            try slots.append(ta, @intCast(slot));
            continue;
        }
        const face_px = try compose.projectFace(ta, face.owned, z, tx, ty);
        if (face_px.len == 0) continue;
        try slots.append(ta, @intCast(slot));
    }

    // Reach ring (spec §2.3, the cross-TILE half): a cell owning ground at this
    // tier — just none in this tile — can still have light sector figures
    // sweeping in, and the bake addressed this tile for exactly that reach
    // (buildTileMap's lightReachTiles ring around the cell's light_bbox). Apply
    // the SAME ring here: consult each such cell's archive and let
    // composeSeamTile take only its constructed LIGHTS figures, whole.
    // Without this the figures amputate exactly at the composed-tile boundary.
    var reach = std.ArrayList(u32).empty;
    {
        var contributed = try ta.alloc(bool, part.cells.len);
        @memset(contributed, false);
        for (slots.items) |slot| contributed[map.faces[slot].index] = true;
        var seen = try ta.alloc(bool, part.cells.len);
        @memset(seen, false);
        for (map.faces) |face| {
            if (face.owned.len == 0) continue;
            const ci = face.index;
            if (contributed[ci] or seen[ci]) continue;
            seen[ci] = true;
            const c = part.cells[ci];
            const lb = c.light_bbox orelse continue;
            const r = tile.lightReachTiles(c.light_range_m, z, (lb[1] + lb[3]) * 0.5);
            const w_tl = tile.lonLatToWorld(lb[0], lb[3]);
            const w_br = tile.lonLatToWorld(lb[2], lb[1]);
            const fx: f64 = @floatFromInt(tx);
            const fy: f64 = @floatFromInt(ty);
            if (fx + 1.0 <= w_tl[0] * scale - r or fx >= w_br[0] * scale + r or
                fy + 1.0 <= w_tl[1] * scale - r or fy >= w_br[1] * scale + r) continue;
            if (!(try ownerHasTile(readers[ci], c.cscl, z, tx, ty))) continue;
            try reach.append(ta, @intCast(ci));
        }
    }

    // Verbatim fast path: only when no reach cell contributes (else the figures
    // must merge, so the tile seam-composes; content-identical for the owner).
    if (reach.items.len == 0) if (verbatim) |ci| {
        if (want_gzip) {
            if (try readers[ci].getCompressed(z, tx, ty)) |blob| return .{ .tile = try gpa.dupe(u8, blob), .owned = true };
        } else if (try readers[ci].getTile(ta, z, tx, ty)) |raw| return .{ .tile = try gpa.dupe(u8, raw), .owned = true };
    };
    if (slots.items.len == 0 and reach.items.len == 0) return .{ .tile = null, .owned = owned };

    const enc = (try composeSeamTile(ta, part, map, readers, slots.items, reach.items, z, tx, ty)) orelse return .{ .tile = null, .owned = owned };
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
    // A files-open owns its readers + mmaps (deinit closes them); a charts-open
    // borrows them from the charts, which must outlive this source.
    owns_archives: bool = true,
    part: geometry.partition.Partition,
    /// False when the partition had to be BUILT (no sidecar, or one that no
    /// longer matches this cell set). The C layer uses it to refresh the cache
    /// on disk, so a stale sidecar heals itself instead of costing every open.
    part_loaded: bool = false,
    minz: u8,
    maxz: u8,
    loop_max: u8, // deepest zoom the sources can serve (native windows + one fill-up overscale zoom)
    bounds: [4]f64, // union coverage [west, south, east, north] in degrees

    // A RENDER-layer cache hung off this source for its lifetime — today the per-tile
    // label-candidate memo the view label pass resolves from (render/labelcache.zig).
    // The compositor reads baked archives and nothing else — it sits below the render
    // path as a dependency leaf — so it cannot NAME that type: it holds the slot
    // opaquely and releases it at deinit through the free function the render layer
    // installs alongside it. Set both fields together or neither.
    render_cache: ?*anyopaque = null,
    render_cache_free: ?*const fn (*anyopaque) void = null,

    /// Compose one tile → raw (decompressed) MLT + the ownership flag (gpa-owned bytes; null when
    /// nothing rendered — `owned` then says whether a cell SHOULD have). This is what a live tile
    /// server hands its HTTP layer, which gzips on the wire. Byte-faithful to the batch.
    pub fn tile(self: *ComposeSource, gpa: std.mem.Allocator, z: u8, tx: u32, ty: u32) !TileResult {
        return composeTile(gpa, &self.part, self.readers, z, tx, ty, false);
    }
    /// Serialize the resident ownership partition to a sidecar blob (gpa-owned) a later open can
    /// load to skip the owned-face build.
    pub fn serializePartition(self: *ComposeSource, gpa: std.mem.Allocator) ![]u8 {
        return geometry.partition.serialize(gpa, &self.part);
    }

    /// The deepest zoom any cell COVERING (lon,lat) can serve — `reach` (its native
    /// window + overscale fill-up). Zooming past this over that ground hits nodata:
    /// a host caps its zoom-in here, per view, instead of at the library-wide max
    /// (which a distant deep chart inflates). Returns loop_max when the point lies
    /// outside every cell's coverage (no cell to restrict against). Coverage points
    /// are lon_e7/lat_e7 (see toPlaneCells), so the test is a plain lon/lat ray cast.
    pub fn maxZoomAt(self: *const ComposeSource, lon: f64, lat: f64) u8 {
        const px: i64 = @intFromFloat(lon * 1e7);
        const py: i64 = @intFromFloat(lat * 1e7);
        var best: u8 = 0;
        for (self.part.cells) |c| {
            if (c.reach <= best) continue; // can't beat what we already have
            if (pointInCoverage(px, py, c.cov1)) best = c.reach;
        }
        return if (best == 0) self.loop_max else best;
    }
    pub fn deinit(self: *ComposeSource) void {
        const gpa = self.gpa;
        if (self.render_cache) |p| {
            if (self.render_cache_free) |f| f(p);
        }
        self.part.deinit();
        if (self.owns_archives) {
            for (self.readers) |rp| rp.deinit();
            for (self.maps) |m| filemap.unmap(m);
        }
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Open over per-chart PMTiles paths (mmap'd; the chart set is never fully
    /// resident). Null when no archive carries coverage.
    pub const openFiles = openSourceFiles;
    /// Open over already-open charts' archives (everything is BORROWED — the
    /// charts must outlive this source). Null when no archive carries coverage.
    pub const open = openSourceCharts;
};

/// Open a resident ComposeSource over per-cell PMTiles at `paths` (mmap'd, so the cell set is never
/// fully resident). If `load_partition` is non-null and valid for this cell set the partition is
/// loaded (no build); else it is built. Returns null if no archive carries coverage. Free with
/// `ComposeSource.deinit`.
fn openSourceFiles(io: std.Io, gpa: std.mem.Allocator, paths: []const []const u8, load_partition: ?[]const u8) !?*ComposeSource {
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
    errdefer {
        for (readers.items) |rp| rp.deinit();
        for (maps.items) |m| filemap.unmap(m);
    }
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
        const map = filemap.mapReadonly(f.handle, len) catch {
            f.close(io);
            continue;
        };
        f.close(io);
        const rp = a.create(pmtiles.Reader) catch {
            filemap.unmap(map);
            continue;
        };
        rp.* = pmtiles.Reader.init(gpa, map) catch {
            filemap.unmap(map);
            continue;
        };
        const meta = readMetaJson(a, rp) orelse {
            rp.deinit();
            filemap.unmap(map);
            continue;
        };
        const cc = (coverage.decodeFromMetadata(a, meta) catch null) orelse {
            rp.deinit();
            filemap.unmap(map);
            continue;
        };
        try maps.append(a, map);
        try readers.append(a, rp);
        try shims.append(a, .{ .name = cc.name, .date = cc.date, .cscl = cc.cscl, .coverage = cc.cov1, .bounds = covDegBounds(cc), .light_reach = cc.light_reach });
    }
    if (readers.items.len == 0) {
        src.arena.deinit();
        gpa.destroy(src);
        return null;
    }
    return try finishOpen(gpa, src, readers.items, maps.items, shims.items, load_partition, true);
}

/// One already-open per-cell archive for a compositor to compose over: the archive's
/// PMTiles reader plus the per-cell coverage embedded in its metadata. The compositor
/// BORROWS both — whatever owns them (a chart handle) must outlive the source.
pub const ChartArchive = struct {
    reader: *pmtiles.Reader,
    cov: coverage.ChartCoverage,
};

/// Open a resident ComposeSource over already-open charts' archives. Nothing is
/// opened or mmap'd here and deinit closes none of it: every archive is borrowed,
/// so the charts must OUTLIVE this source. Archives without coverage rings are
/// skipped (they can own no ground); returns null if none carries coverage.
/// `load_partition` as in `openFiles`.
fn openSourceCharts(gpa: std.mem.Allocator, archives: []const ChartArchive, load_partition: ?[]const u8) !?*ComposeSource {
    const src = try gpa.create(ComposeSource);
    src.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .maps = &.{}, .readers = &.{}, .part = undefined, .minz = 0, .maxz = 0, .loop_max = 0, .bounds = .{ 0, 0, 0, 0 } };
    errdefer {
        src.arena.deinit();
        gpa.destroy(src);
    }
    const a = src.arena.allocator();
    var readers = std.ArrayList(*pmtiles.Reader).empty;
    var shims = std.ArrayList(LoadedCov).empty;
    for (archives) |ar| {
        if (ar.cov.cov1.len == 0) continue;
        try readers.append(a, ar.reader);
        try shims.append(a, .{ .name = ar.cov.name, .date = ar.cov.date, .cscl = ar.cov.cscl, .coverage = ar.cov.cov1, .bounds = covDegBounds(ar.cov), .light_reach = ar.cov.light_reach });
    }
    if (readers.items.len == 0) {
        src.arena.deinit();
        gpa.destroy(src);
        return null;
    }
    return try finishOpen(gpa, src, readers.items, &.{}, shims.items, load_partition, false);
}

// The coverage bbox (integer lon/lat e7) as degree bounds [w, s, e, n].
fn covDegBounds(cc: coverage.ChartCoverage) [4]f64 {
    return .{
        @as(f64, @floatFromInt(cc.bbox[0])) / 1e7, @as(f64, @floatFromInt(cc.bbox[1])) / 1e7,
        @as(f64, @floatFromInt(cc.bbox[2])) / 1e7, @as(f64, @floatFromInt(cc.bbox[3])) / 1e7,
    };
}

// Shared open tail over aligned (readers, shims): build (or load) the ownership
// partition, derive the zoom range + union bounds, and finish `src`. The arrays
// already live in src.arena; on error the caller's errdefer tears down whatever
// it owns per `owns_archives`.
/// Put the cell set in ONE canonical order, whatever order the caller handed the
/// archives over in.
///
/// The partition's input key (geometry.partition.inputKey) hashes the cells in
/// sequence, and its ownership tie-break falls back to input order — so the order
/// is part of the artifact's identity. That used to make the sidecar depend on the
/// CALLER: `tile57 bake` sorted its archive paths, while a host that walked a
/// directory handed them over in readdir order, and the two disagreed. The bake's
/// partition then failed to load with StalePartition and every open rebuilt an
/// identical copy from scratch.
///
/// Sorting on the coverage NAME (the file basename stem — already the ownership
/// tie-break name) rather than on the path makes this independent of the caller's
/// order AND of the directory layout, so a flat `<out>/tiles/*.pmtiles` bake and a
/// host mirroring `d1/`, `d5/` subdirs produce the same key. `date` breaks ties
/// between two archives of the same cell.
///
/// readers/maps/shims are index-aligned (cell index == reader index, relied on by
/// composeTile), so all three are permuted together. maps is empty when the
/// archives are borrowed from open charts.
fn canonicalizeCellOrder(
    readers: []const *pmtiles.Reader,
    maps: []const []align(std.heap.page_size_min) const u8,
    shims: []const LoadedCov,
) void {
    const n = shims.len;
    if (n < 2) return;
    // Insertion sort: the arrays are index-aligned and small (a library is
    // hundreds of cells), and it is stable, so equal (name, date) keeps arrival
    // order rather than shuffling.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and cellOrderLt(shims[j], shims[j - 1])) : (j -= 1) {
            std.mem.swap(LoadedCov, @constCast(&shims[j]), @constCast(&shims[j - 1]));
            std.mem.swap(*pmtiles.Reader, @constCast(&readers[j]), @constCast(&readers[j - 1]));
            if (maps.len == n) std.mem.swap([]align(std.heap.page_size_min) const u8, @constCast(&maps[j]), @constCast(&maps[j - 1]));
        }
    }
}

fn cellOrderLt(x: LoadedCov, y: LoadedCov) bool {
    return switch (std.mem.order(u8, x.name, y.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, x.date, y.date) == .lt,
    };
}

fn finishOpen(
    gpa: std.mem.Allocator,
    src: *ComposeSource,
    readers: []const *pmtiles.Reader,
    maps: []const []align(std.heap.page_size_min) const u8,
    shims: []const LoadedCov,
    load_partition: ?[]const u8,
    owns_archives: bool,
) !*ComposeSource {
    const a = src.arena.allocator();
    canonicalizeCellOrder(readers, maps, shims);
    var minz: u8 = 255;
    var maxz: u8 = 0;
    var ubox = [4]f64{ 1e9, 1e9, -1e9, -1e9 }; // union coverage [w, s, e, n]
    // The floor is what the archives actually carry (a fill-up bake starts at z0;
    // an archive baked before fill-up starts at its band floor), not the band model.
    for (readers) |rp| minz = @min(minz, rp.header.min_zoom);
    for (shims) |sh| {
        const bz = band.bandZooms(band.bandOf(sh.cscl));
        minz = @min(minz, bz.min);
        maxz = @max(maxz, bz.max);
        ubox[0] = @min(ubox[0], sh.bounds[0]);
        ubox[1] = @min(ubox[1], sh.bounds[1]);
        ubox[2] = @max(ubox[2], sh.bounds[2]);
        ubox[3] = @max(ubox[3], sh.bounds[3]);
    }

    const cells = try toPlaneCells(a, shims);
    for (cells, readers) |*c, rp| c.reach = @max(bandReach(c.cscl), rp.header.max_zoom);

    var loaded = false;
    if (load_partition) |bytes| {
        if (geometry.partition.deserialize(gpa, bytes, cells)) |p| {
            src.part = p;
            loaded = true;
        } else |err| std.debug.print("  partition sidecar unusable ({s}); building\n", .{@errorName(err)});
    }
    if (!loaded) src.part = try geometry.partition.build(gpa, cells);
    src.part_loaded = loaded;

    const fill_max = @min(maxz + band.FILLUP_DZ, band.FILLUP_CEIL);
    src.maps = maps;
    src.readers = readers;
    src.owns_archives = owns_archives;
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
// pass through; the input `properties` are borrowed unchanged (display_priority et al. survive).
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

// A one-tile in-memory archive carrying `feats` in `point_symbols` at (z,tx,ty) —
// the fixture the SCAMIN passthrough test composes over. gpa-owned bytes.
fn testArchiveBytes(gpa: std.mem.Allocator, z: u8, tx: u32, ty: u32, feats: []const mvt.Feature) ![]u8 {
    const layers = [_]mvt.Layer{.{ .name = "point_symbols", .features = feats }};
    const enc = try mlt.encode(gpa, .{ .layers = &layers });
    defer gpa.free(enc);
    var w = pmtiles.StreamWriter.init(gpa);
    defer w.deinit();
    try w.add(z, tx, ty, enc);
    return w.finishBytes(.{ .tile_type = .mlt });
}

// A rectangular CATCOV=1 coverage feature (one ring) over [w,s]..[e,n] degrees.
fn testCovRect(a: std.mem.Allocator, w: f64, s: f64, e: f64, n: f64) ![]const []const []const s57.LonLat {
    const ring = try a.alloc(s57.LonLat, 5);
    const corners = [5][2]f64{ .{ w, s }, .{ e, s }, .{ e, n }, .{ w, n }, .{ w, s } };
    for (corners, 0..) |c, i| ring[i] = .{
        .lon_e7 = @intFromFloat(@round(c[0] * 1e7)),
        .lat_e7 = @intFromFloat(@round(c[1] * 1e7)),
    };
    const rings = try a.alloc([]const s57.LonLat, 1);
    rings[0] = ring;
    const feat = try a.alloc([]const []const s57.LonLat, 1);
    feat[0] = rings;
    return feat;
}

// A composed tile must carry the per-feature `scamin` property through UNCHANGED.
// SCAMIN is a plain per-feature MVT/MLT property (scene.zig emits it; replay.zig
// reads it back as FeatureMeta.scamin), NOT something encoded in the layer name —
// the scamin BUCKET layers are folded into the base layers at emit, so the layer
// name carries nothing and the property is the only channel. The compositor is
// therefore only correct if decode -> clip -> re-encode is property-transparent:
// drop it and every scale-based thinning downstream (geometry cull AND label
// declutter, which gates candidates on it before the collision pool) silently
// stops working, with no error anywhere. Two cells split this tile, so the
// VERBATIM byte-copy fast path cannot fire and the real seam path runs.
test "composeTile carries per-feature SCAMIN through the seam clip + re-encode" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const z: u8 = 13; // harbor band (cscl 20k) native window is z13..16
    const tx: u32 = 2355;
    const ty: u32 = 3131;
    const cscl: i32 = 20_000;

    // The tile's ground box, and its mid meridian: cell A owns the west half,
    // cell B the east. Mercator x is linear in lon, so a tile-pixel x of 1000 /
    // 3000 (of EXTENT 4096) lands west / east of the split.
    const tb = tile.tileBoundsLonLat(z, tx, ty); // [min_lon, min_lat, max_lon, max_lat]
    const mid_lon = (tb[0] + tb[2]) / 2;
    const pad = (tb[3] - tb[1]) * 0.25; // latitude margin so the faces span the tile

    // One point per cell, each well inside its owner's half, each carrying a
    // DISTINCT scamin the assertions below match by geometry.
    const west_pt = [_]mvt.Point{.{ .x = 1000, .y = 2000 }};
    const east_pt = [_]mvt.Point{.{ .x = 3000, .y = 2000 }};
    const west_parts = [_][]const mvt.Point{&west_pt};
    const east_parts = [_][]const mvt.Point{&east_pt};
    const west_props = [_]mvt.Prop{
        .{ .key = "class", .value = .{ .string = "BOYLAT" } },
        .{ .key = "scamin", .value = .{ .int = 22_000 } },
    };
    const east_props = [_]mvt.Prop{
        .{ .key = "class", .value = .{ .string = "BCNLAT" } },
        .{ .key = "scamin", .value = .{ .int = 45_000 } },
    };
    const west_feat = [_]mvt.Feature{.{ .geom_type = .point, .parts = &west_parts, .properties = &west_props }};
    const east_feat = [_]mvt.Feature{.{ .geom_type = .point, .parts = &east_parts, .properties = &east_props }};

    const arc_w = try testArchiveBytes(gpa, z, tx, ty, &west_feat);
    defer gpa.free(arc_w);
    const arc_e = try testArchiveBytes(gpa, z, tx, ty, &east_feat);
    defer gpa.free(arc_e);

    var rd_w = try pmtiles.Reader.init(gpa, arc_w);
    defer rd_w.deinit();
    var rd_e = try pmtiles.Reader.init(gpa, arc_e);
    defer rd_e.deinit();
    const readers = [_]*pmtiles.Reader{ &rd_w, &rd_e };

    const loaded = [_]LoadedCov{
        .{
            .name = "TESTW",
            .date = "20240101",
            .cscl = cscl,
            .coverage = try testCovRect(a, tb[0], tb[1] - pad, mid_lon, tb[3] + pad),
            .bounds = .{ tb[0], tb[1] - pad, mid_lon, tb[3] + pad },
        },
        .{
            .name = "TESTE",
            .date = "20240101",
            .cscl = cscl,
            .coverage = try testCovRect(a, mid_lon, tb[1] - pad, tb[2], tb[3] + pad),
            .bounds = .{ mid_lon, tb[1] - pad, tb[2], tb[3] + pad },
        },
    };
    const cells = try toPlaneCells(a, &loaded);
    for (cells) |*c| c.reach = bandReach(cscl);
    var part = try geometry.partition.build(gpa, cells);
    defer part.deinit();

    const res = try composeTile(gpa, &part, &readers, z, tx, ty, false);
    const bytes = res.tile orelse return error.NothingComposed;
    defer gpa.free(bytes);
    try std.testing.expect(res.owned);

    // Both cells' points must be in the composed tile, each still carrying ITS
    // OWN scamin — the property survives the clip AND the concat/re-encode.
    const out = try mlt.decode(a, bytes);
    var seen_west = false;
    var seen_east = false;
    for (out) |layer| {
        if (!std.mem.eql(u8, layer.name, "point_symbols")) continue;
        for (layer.features) |f| {
            try std.testing.expect(f.parts.len == 1 and f.parts[0].len == 1);
            const sc = propInt(f.properties, "scamin") orelse return error.ScaminDropped;
            if (f.parts[0][0].x == 1000) {
                try std.testing.expectEqual(@as(i64, 22_000), sc);
                seen_west = true;
            } else if (f.parts[0][0].x == 3000) {
                try std.testing.expectEqual(@as(i64, 45_000), sc);
                seen_east = true;
            }
        }
    }
    try std.testing.expect(seen_west);
    try std.testing.expect(seen_east);
}

// The integer value of `key` on a decoded feature, or null if absent.
fn propInt(props: []const mvt.Prop, key: []const u8) ?i64 {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return switch (p.value) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => null,
    };
    return null;
}
