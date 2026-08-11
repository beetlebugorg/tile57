//! Bake a BSB/KAP sheet into the per-chart archive shape — an RNC as a raster
//! chart.
//!
//! WHAT COMES OUT. Exactly what the ENC bake writes, with pictures instead of
//! features: one PMTiles archive per sheet, PNG tiles, and the chart's own
//! coverage + compilation scale + date embedded in the metadata JSON under the
//! same "coverage" key. That is the whole of the quilting story — the ownership
//! partition reads coverage and scale and nothing else, so a folder of sheets
//! composes the way a folder of cells does and `partition.zig` never learns that
//! raster charts exist.
//!
//! THE THREE FACTS AN RNC CARRIES that a community MBTiles does not:
//!   `PLY` — the border polygon, which stands in for M_COVR. It cuts the paper
//!           collar off, so quilted sheets butt at their neat lines instead of
//!           overprinting each other's margins.
//!   `SC`  — the compilation scale, which places the sheet in a band.
//!   `CED` — the edition date and revision, the partition's tie-break between
//!           two sheets of the same scale.
//!
//! THE WARP. The sheet is fitted through its own control points (`bsb.fitRefs`)
//! rather than through the published pixel polynomial, and the fit is refused
//! when it cannot reproduce the points the hydrographic office published: a bake
//! that misses its own control points has no business warping the pixels. Every
//! output pixel then samples back through the fit — nearest neighbour, super-
//! sampled where one output pixel covers more than one source pixel — and the
//! coarser zooms are box-averaged from the level below rather than resampled
//! from the source, so the pyramid mips cleanly at every level for one warp.
//!
//! THE DATUM. `KNP/GD` names the horizontal datum and `DTM` carries the shift to
//! WGS84 in ARC SECONDS. Applying it is not optional: a NAD27 sheet is roughly
//! 40 m from WGS84 on the US east coast, and a mariner comparing that sheet
//! against a GPS position reads the offset as a chart error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bsb = @import("bsb.zig");
const tiles = @import("tiles");
const pmtiles = tiles.pmtiles;
const png = tiles.png;
const band = tiles.band;
const coverage = @import("coverage");
const s57 = @import("s57");
const rasterchart = @import("rasterchart.zig");

/// Every tile is 256 px square — the size every raster chart in the corpus uses,
/// and what `RasterChart.Info.tile_size` reports.
pub const TILE_PX: usize = 256;

/// The deepest zoom any sheet may bake to, however fine its pixels. A hard stop
/// so a malformed `REF` set cannot ask for a 2^30 pyramid.
pub const ZOOM_CEIL: u8 = 22;

/// How far the fit may miss the sheet's OWN control points, in SOURCE PIXELS,
/// before the bake refuses the sheet. Pixels rather than degrees because the
/// tolerance that matters is "does the picture land where the chart says", which
/// is scale-free: the same 0.02 deg that is three pixels on a 1:10,000,000 ocean
/// sheet is a mile of error on a harbour plan. Measured across the nine sheets of
/// NOAA_RNC_5, eight fit inside 0.7 px and the antimeridian sheet lands at 6.7 —
/// so the gate is set well clear of a sheet that is merely awkward, and catches
/// the failure that matters: a fit that is BROKEN (a mis-parsed control point, a
/// projection the header lied about) misses by thousands of pixels, never by
/// tens.
pub const MAX_FIT_PX: f64 = 32.0;

pub const Error = bsb.Error || error{
    /// Fewer than three usable `REF` control points: the sheet has not said
    /// where it is.
    NoGeoreference,
    /// The fit cannot reproduce the sheet's own control points (see MAX_FIT_PX).
    FitResidual,
    /// No `PLY` border polygon, so there is no neat line to clip to and no
    /// coverage to quilt on.
    NoBorder,
    /// The warp produced no tile at all — the sheet's raster and its stated
    /// position do not overlap.
    Empty,
};

/// What one baked sheet turned out to be. `bytes` is the archive (caller frees).
pub const Baked = struct {
    bytes: []u8,
    /// `KNP/SC`, the compilation scale denominator.
    scale: u32,
    /// The archive's zoom window: z0 up to the sheet's own resolution.
    min_zoom: u8,
    max_zoom: u8,
    tiles: u32,
    /// The largest residual the fit left against the sheet's control points, in
    /// source pixels — what MAX_FIT_PX gates on, reported so a bake log can show
    /// how much room a sheet had.
    fit_px: f64,
};

/// Bake one KAP's bytes to a per-chart PMTiles archive. `name` is the chart's
/// identity for the ownership tie-break and the archive metadata — the file stem,
/// matching what the ENC bake passes for a cell.
pub fn bakeBytes(gpa: Allocator, kap: []const u8, name: []const u8) Error!Baked {
    var chart = try bsb.decode(gpa, kap);
    defer chart.deinit();
    const h = chart.header;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (h.border.len < 3) return Error.NoBorder;
    const fit = bsb.fitRefs(h, a) orelse return Error.NoGeoreference;

    // The fit maps source pixel -> (lon, ellipsoidal mercator); the warp needs it
    // the other way round. Both are affine, so one 2x2 inverse serves every pixel
    // of every tile.
    const inv = inverseFit(fit) orelse return Error.NoGeoreference; // degenerate points
    const ix = inv[0];
    const iy = inv[1];

    // The residual gate, converted from degrees to source pixels through the same
    // inverse: a degree of longitude moves the sample by (ix[1], iy[1]) pixels,
    // and a unit of mercator ordinate by (ix[2], iy[2]).
    const lat_mid = fit.latAt(@as(f64, @floatFromInt(h.width)) / 2, @as(f64, @floatFromInt(h.height)) / 2);
    const dmer = std.math.degreesToRadians(fit.max_dlat) / @max(0.05, @cos(std.math.degreesToRadians(lat_mid)));
    const fit_px = @max(
        fit.max_dlon * std.math.hypot(ix[1], iy[1]),
        dmer * std.math.hypot(ix[2], iy[2]),
    );
    if (!(fit_px <= MAX_FIT_PX)) return Error.FitResidual; // NaN fails too

    var c = Ctx{
        .gpa = gpa,
        .chart = &chart,
        .ix = ix,
        .iy = iy,
        // Longitudes are unwrapped about the sheet's own first control point, as
        // the fit was: an Aleutian sheet straddling the antimeridian is one
        // continuous span in the fit's domain and must be queried in that domain.
        .lon_ref = fit.lon_c[0] + fit.lon_c[1] * @as(f64, @floatFromInt(h.width)) / 2 +
            fit.lon_c[2] * @as(f64, @floatFromInt(h.height)) / 2,
        .dtm_lat = h.dtm_lat / 3600.0,
        .dtm_lon = h.dtm_lon / 3600.0,
        .zmax = 0,
        .ss = 1,
        .sw = undefined,
        .border_px = undefined,
        .bbox = undefined,
    };

    // The neat line, in SOURCE PIXELS. Clipping there costs one polygon test per
    // sample and no projection at all — the border is a property of the sheet,
    // not of the tile being written.
    const border_px = try a.alloc([2]f64, h.border.len);
    for (h.border, 0..) |p, i| {
        const mer = bsb.mercY(p[1]);
        const lon = unwrap(p[0], c.lon_ref);
        border_px[i] = .{ ix[0] + ix[1] * lon + ix[2] * mer, iy[0] + iy[1] * lon + iy[2] * mer };
    }
    c.border_px = border_px;

    // The same border in WGS84 degrees: the tile-tree prune, the archive header
    // bounds, and the coverage the partition resolves on. Longitudes stay
    // UNWRAPPED here so an antimeridian sheet has a bbox that is a span rather
    // than the whole world.
    var bbox = [4]f64{ 1e9, 1e9, -1e9, -1e9 };
    const border_ll = try a.alloc([2]f64, h.border.len);
    for (h.border, 0..) |p, i| {
        const lon = unwrap(p[0], c.lon_ref) + c.dtm_lon;
        const lat = p[1] + c.dtm_lat;
        border_ll[i] = .{ lon, lat };
        bbox[0] = @min(bbox[0], lon);
        bbox[1] = @min(bbox[1], lat);
        bbox[2] = @max(bbox[2], lon);
        bbox[3] = @max(bbox[3], lat);
    }
    c.bbox = bbox;

    c.zmax = @min(ZOOM_CEIL, nativeZoom(fit));
    // One output pixel covers `r` source pixels at the native zoom (1..2 by the
    // definition of nativeZoom, more only when ZOOM_CEIL clamped it). Sample the
    // whole footprint instead of one point of it: a nearest-neighbour warp that
    // drops half the source pixels turns a soundings field into noise.
    const r = 1.0 / (@as(f64, @floatFromInt(@as(u64, 1) << @intCast(c.zmax))) * @as(f64, @floatFromInt(TILE_PX)) * worldPerPixel(fit));
    c.ss = @intCast(std.math.clamp(@as(i64, @intFromFloat(@ceil(r))), 1, 4));

    var sw = pmtiles.StreamWriter.init(gpa);
    defer sw.deinit();
    // A PNG is already a deflate stream. Store the tiles as they are, so the
    // bake compresses each tile once and a host serves it with no gunzip.
    sw.compress_tiles = false;
    c.sw = &sw;

    const root = try emit(&c, 0, 0, 0);
    if (root) |b| gpa.free(b);
    if (c.tiles == 0) return Error.Empty;

    // The coverage sidecar the compositor reads back: the neat line as the one
    // coverage polygon, `SC` as the compilation scale, `CED` as the date.
    const date = try editionKey(a, h.edition, h.revision);
    const cov = coverage.ChartCoverage{
        .name = name,
        .date = date,
        .cscl = @intCast(@min(h.scale, @as(u32, std.math.maxInt(i32)))),
        .band = @intFromEnum(band.bandOf(@intCast(@min(h.scale, @as(u32, std.math.maxInt(i32)))))),
        .bbox = .{ lonE7(bbox[0]), latE7(bbox[1]), lonE7(bbox[2]), latE7(bbox[3]) },
        .cov1 = try covRings(a, border_ll),
    };
    const cov_json = try coverage.encodeJson(a, cov);
    const meta = try metadataJson(a, name, h.name, cov_json);

    const bytes = try sw.finishBytes(.{
        .metadata_json = meta,
        .min_lon_e7 = lonE7(bbox[0]),
        .min_lat_e7 = latE7(bbox[1]),
        .max_lon_e7 = lonE7(bbox[2]),
        .max_lat_e7 = latE7(bbox[3]),
        .tile_type = .png,
    });
    return .{
        .bytes = bytes,
        .scale = h.scale,
        .min_zoom = 0,
        .max_zoom = c.zmax,
        .tiles = c.tiles,
        .fit_px = fit_px,
    };
}

/// The fit, the other way round: `px = ix[0] + ix[1]*lon + ix[2]*mer`, and `py`
/// likewise, both in the sheet's own datum. The fit is affine, so one 2x2
/// inverse serves every pixel of every tile. Null when the control points are
/// degenerate (collinear, or all the same place).
fn inverseFit(fit: bsb.Fit) ?[2][3]f64 {
    const det = fit.lon_c[1] * fit.mer_c[2] - fit.lon_c[2] * fit.mer_c[1];
    if (@abs(det) < 1e-30) return null;
    var ix = [3]f64{ 0, fit.mer_c[2] / det, -fit.lon_c[2] / det };
    var iy = [3]f64{ 0, -fit.mer_c[1] / det, fit.lon_c[1] / det };
    // The fit's own constant terms fold into the inverse's, so a query is one
    // multiply-add per axis with nothing to subtract first.
    ix[0] = -(ix[1] * fit.lon_c[0] + ix[2] * fit.mer_c[0]);
    iy[0] = -(iy[1] * fit.lon_c[0] + iy[2] * fit.mer_c[0]);
    return .{ ix, iy };
}

// ---- the zoom range -------------------------------------------------------

/// Normalised web-mercator world units spanned by ONE source pixel, along
/// whichever pixel axis spans more. Both pixel axes feed both outputs (a skewed
/// sheet has real cross terms), so each axis is a vector and the answer is the
/// longer of the two.
fn worldPerPixel(fit: bsb.Fit) f64 {
    // World x is lon/360; world y is the mercator ordinate over 2*pi. The fit's
    // ordinate is ellipsoidal and web mercator's is spherical, which differ by
    // well under a percent — far inside the rounding a zoom choice does.
    const ux = fit.lon_c[1] / 360.0;
    const uy = fit.mer_c[1] / (2.0 * std.math.pi);
    const vx = fit.lon_c[2] / 360.0;
    const vy = fit.mer_c[2] / (2.0 * std.math.pi);
    return @max(std.math.hypot(ux, uy), std.math.hypot(vx, vy));
}

/// The deepest zoom whose ground resolution is still no finer than the sheet's
/// own pixel. Baking past it would invent detail the survey never had; a host
/// that wants to zoom closer overzooms the top level, which is honest about what
/// it is doing.
fn nativeZoom(fit: bsb.Fit) u8 {
    const w = worldPerPixel(fit);
    if (!(w > 0)) return 0;
    // The epsilon is not slop, it is the common case: a community sheet cut from
    // web-mercator tiles (the OSM/OpenCPN KAP sets are, by the thousand) has a
    // pixel that IS a tile pixel at some zoom, and this log lands on that integer
    // to within a rounding error. Without it half of them would floor one level
    // down and throw away half the resolution the file actually holds.
    const z = @log2(1.0 / (@as(f64, @floatFromInt(TILE_PX)) * w)) + 1e-6;
    if (!(z > 0)) return 0;
    return @intFromFloat(@min(@floor(z), @as(f64, ZOOM_CEIL)));
}

// ---- the warp -------------------------------------------------------------

const Ctx = struct {
    gpa: Allocator,
    chart: *bsb.Chart,
    /// Source pixel from (lon, mercator), both in the sheet's own datum:
    /// `px = ix[0] + ix[1]*lon + ix[2]*mer`, `py` likewise.
    ix: [3]f64,
    iy: [3]f64,
    /// Longitudes are queried unwrapped about this, the fit's own domain.
    lon_ref: f64,
    /// The datum shift in DEGREES: WGS84 = sheet + this.
    dtm_lat: f64,
    dtm_lon: f64,
    /// The neat line in source pixels, and in WGS84 degrees (lon unwrapped).
    border_px: [][2]f64,
    bbox: [4]f64,
    zmax: u8,
    ss: u8,
    sw: *pmtiles.StreamWriter,
    tiles: u32 = 0,
};

/// Write tile (z,x,y) and every tile under it, returning this tile's RGBA (caller
/// frees) or null when nothing in this subtree carries a pixel.
///
/// Depth first, bottom up: the native level warps from the source and every
/// coarser level box-averages the four tiles below it. That mips cleanly for one
/// warp, and holds one tile per level rather than a level of tiles — a 10,000 px
/// sheet's native level alone would be hundreds of megabytes resident.
fn emit(c: *Ctx, z: u8, x: u32, y: u32) Error!?[]u8 {
    if (!intersects(c, z, x, y)) return null;

    var buf: ?[]u8 = null;
    errdefer if (buf) |b| c.gpa.free(b);
    if (z >= c.zmax) {
        buf = try warpTile(c, z, x, y);
    } else {
        for (0..4) |q| {
            const kid = (try emit(c, z + 1, x * 2 + @as(u32, @intCast(q & 1)), y * 2 + @as(u32, @intCast(q >> 1)))) orelse continue;
            defer c.gpa.free(kid);
            if (buf == null) {
                buf = try c.gpa.alloc(u8, TILE_PX * TILE_PX * 4);
                @memset(buf.?, 0);
            }
            downsampleInto(buf.?, kid, q);
        }
    }
    const b = buf orelse return null;

    // The encoder and the archive writer both write into allocating buffers, so
    // the only way either fails is out of memory — whatever they call it.
    const bytes = png.encodeRgbaFast(c.gpa, b, @intCast(TILE_PX), @intCast(TILE_PX)) catch return Error.OutOfMemory;
    defer c.gpa.free(bytes);
    c.sw.add(z, x, y, bytes) catch return Error.OutOfMemory;
    c.tiles += 1;
    return b;
}

/// Does tile (z,x,y) touch the sheet's neat line at all? The prune that keeps the
/// walk from the root proportional to the sheet rather than to the world. An
/// antimeridian sheet's bbox runs past ±180 in the fit's unwrapped domain, so the
/// tile is tested against each world copy it could belong to.
fn intersects(c: *Ctx, z: u8, x: u32, y: u32) bool {
    const tb = tiles.tile.tileBoundsLonLat(z, x, y); // [min_lon, min_lat, max_lon, max_lat]
    if (tb[3] < c.bbox[1] or tb[1] > c.bbox[3]) return false;
    var world: f64 = -360;
    while (world <= 360) : (world += 360) {
        if (tb[0] + world <= c.bbox[2] and tb[2] + world >= c.bbox[0]) return true;
    }
    return false;
}

/// Warp one native-zoom tile out of the source raster, or null when every sample
/// falls outside the sheet.
fn warpTile(c: *Ctx, z: u8, x: u32, y: u32) Error!?[]u8 {
    const k: usize = c.ss;
    const ns = TILE_PX * k;
    const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));

    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Longitude varies only along the tile's x axis and latitude only along its y
    // axis, so the transcendentals (and the datum shift, which is a lat/lon
    // quantity and must be applied before the projection) are per-row and
    // per-column work, not per-pixel.
    const lons = try sa.alloc(f64, ns);
    const mers = try sa.alloc(f64, ns);
    for (lons, 0..) |*lon, i| {
        const wx = (@as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(ns))) / n;
        lon.* = unwrap(wx * 360.0 - 180.0 - c.dtm_lon, c.lon_ref);
    }
    for (mers, 0..) |*mer, j| {
        const wy = (@as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(j)) + 0.5) / @as(f64, @floatFromInt(ns))) / n;
        const lat = std.math.radiansToDegrees(std.math.atan(std.math.sinh(std.math.pi * (1.0 - 2.0 * wy))));
        mer.* = bsb.mercY(lat - c.dtm_lat);
    }

    // Where the tile lands in the source raster, as a box. The map is affine, so
    // the corners bound every sample — which answers both "is this tile off the
    // sheet entirely" and "can the per-sample neat-line test be skipped".
    var sb = [4]f64{ 1e30, 1e30, -1e30, -1e30 };
    for ([_][2]usize{ .{ 0, 0 }, .{ ns - 1, 0 }, .{ 0, ns - 1 }, .{ ns - 1, ns - 1 } }) |cn| {
        const sx = c.ix[0] + c.ix[1] * lons[cn[0]] + c.ix[2] * mers[cn[1]];
        const sy = c.iy[0] + c.iy[1] * lons[cn[0]] + c.iy[2] * mers[cn[1]];
        sb[0] = @min(sb[0], sx);
        sb[1] = @min(sb[1], sy);
        sb[2] = @max(sb[2], sx);
        sb[3] = @max(sb[3], sy);
    }
    const w: f64 = @floatFromInt(c.chart.header.width);
    const hgt: f64 = @floatFromInt(c.chart.header.height);
    if (sb[2] < 0 or sb[0] > w or sb[3] < 0 or sb[1] > hgt) return null;
    const clip = boxAgainstBorder(c.border_px, sb);
    if (clip == .outside) return null;

    const out = try c.gpa.alloc(u8, TILE_PX * TILE_PX * 4);
    errdefer c.gpa.free(out);
    @memset(out, 0);
    var any = false;
    const src = c.chart.pixels;
    const pal = c.chart.header.palette;
    const base = c.chart.header.palette_base;
    const stride: usize = c.chart.header.width;

    var j: usize = 0;
    while (j < TILE_PX) : (j += 1) {
        var i: usize = 0;
        while (i < TILE_PX) : (i += 1) {
            var rs: u32 = 0;
            var gs: u32 = 0;
            var bs: u32 = 0;
            var hits: u32 = 0;
            var sj: usize = 0;
            while (sj < k) : (sj += 1) {
                const mer = mers[j * k + sj];
                var si: usize = 0;
                while (si < k) : (si += 1) {
                    const lon = lons[i * k + si];
                    const sx = c.ix[0] + c.ix[1] * lon + c.ix[2] * mer;
                    const sy = c.iy[0] + c.iy[1] * lon + c.iy[2] * mer;
                    if (sx < 0 or sy < 0 or sx >= w or sy >= hgt) continue;
                    if (clip == .straddle and !inBorder(c.border_px, sx, sy)) continue;
                    // Indexed straight rather than through `Chart.rgbAt`, which
                    // takes the chart BY VALUE: at a hundred million samples a
                    // bake, copying the header and its arena per sample was most
                    // of the warp's time.
                    const idx = src[@as(usize, @intFromFloat(sy)) * stride + @as(usize, @intFromFloat(sx))];
                    // The format numbers its palette from 1; 0 and anything past
                    // the end is a malformed run, which shows as black.
                    const at = if (idx >= base) idx - base else 255;
                    const rgb = if (at < pal.len) pal[at] else bsb.Rgb{ .r = 0, .g = 0, .b = 0 };
                    rs += rgb.r;
                    gs += rgb.g;
                    bs += rgb.b;
                    hits += 1;
                }
            }
            if (hits == 0) continue;
            const o = (j * TILE_PX + i) * 4;
            out[o + 0] = @intCast(rs / hits);
            out[o + 1] = @intCast(gs / hits);
            out[o + 2] = @intCast(bs / hits);
            // Partial coverage at the neat line becomes partial alpha, so two
            // sheets meeting at a border blend across one pixel instead of
            // showing a stepped white seam.
            out[o + 3] = @intCast(@min(255, hits * 255 / (k * k)));
            any = true;
        }
    }
    if (!any) {
        c.gpa.free(out);
        return null;
    }
    return out;
}

/// Average child quadrant `q` (0=NW, 1=NE, 2=SW, 3=SE) into the parent buffer.
/// Averaged with alpha as the weight: a transparent pixel outside the neat line
/// carries no colour, and letting its (black) RGB into the mean would fringe
/// every border dark.
fn downsampleInto(parent: []u8, kid: []const u8, q: usize) void {
    const ox = (q & 1) * (TILE_PX / 2);
    const oy = (q >> 1) * (TILE_PX / 2);
    var j: usize = 0;
    while (j < TILE_PX / 2) : (j += 1) {
        var i: usize = 0;
        while (i < TILE_PX / 2) : (i += 1) {
            var rs: u32 = 0;
            var gs: u32 = 0;
            var bs: u32 = 0;
            var as_: u32 = 0;
            for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
                const s = ((j * 2 + d[1]) * TILE_PX + (i * 2 + d[0])) * 4;
                const al: u32 = kid[s + 3];
                rs += @as(u32, kid[s + 0]) * al;
                gs += @as(u32, kid[s + 1]) * al;
                bs += @as(u32, kid[s + 2]) * al;
                as_ += al;
            }
            const o = ((oy + j) * TILE_PX + (ox + i)) * 4;
            parent[o + 3] = @intCast(as_ / 4);
            if (as_ == 0) continue;
            parent[o + 0] = @intCast(rs / as_);
            parent[o + 1] = @intCast(gs / as_);
            parent[o + 2] = @intCast(bs / as_);
        }
    }
}

// ---- the neat line --------------------------------------------------------

const BoxClip = enum { inside, outside, straddle };

/// Where a tile's source-pixel box sits relative to the neat line. A box no edge
/// crosses is wholly in or wholly out, decided by one corner — which spares the
/// interior of the sheet (nearly every tile) a per-sample polygon test.
fn boxAgainstBorder(poly: []const [2]f64, box: [4]f64) BoxClip {
    var i: usize = 0;
    var j: usize = poly.len - 1;
    while (i < poly.len) : (i += 1) {
        if (segHitsBox(poly[j], poly[i], box)) return .straddle;
        j = i;
    }
    return if (inBorder(poly, (box[0] + box[2]) / 2, (box[1] + box[3]) / 2)) .inside else .outside;
}

/// Does the segment a..b touch the axis-aligned box? Trivial rejection by side,
/// then the box's four corners against the segment's own line.
fn segHitsBox(p: [2]f64, q: [2]f64, box: [4]f64) bool {
    if (@max(p[0], q[0]) < box[0] or @min(p[0], q[0]) > box[2]) return false;
    if (@max(p[1], q[1]) < box[1] or @min(p[1], q[1]) > box[3]) return false;
    // The segment's bbox overlaps the box; it still misses when every corner of
    // the box lies on the same side of the segment's line.
    const dx = q[0] - p[0];
    const dy = q[1] - p[1];
    var neg = false;
    var pos = false;
    for ([_][2]f64{ .{ box[0], box[1] }, .{ box[2], box[1] }, .{ box[2], box[3] }, .{ box[0], box[3] } }) |cn| {
        const s = dx * (cn[1] - p[1]) - dy * (cn[0] - p[0]);
        if (s > 0) pos = true;
        if (s < 0) neg = true;
        if (s == 0) return true;
    }
    return pos and neg;
}

/// Even-odd ray cast against the neat line, in source pixels.
fn inBorder(poly: []const [2]f64, x: f64, y: f64) bool {
    var inside = false;
    var i: usize = 0;
    var j: usize = poly.len - 1;
    while (i < poly.len) : (i += 1) {
        const a = poly[j];
        const b = poly[i];
        if ((b[1] > y) != (a[1] > y)) {
            const t = (y - b[1]) / (a[1] - b[1]);
            if (x < b[0] + t * (a[0] - b[0])) inside = !inside;
        }
        j = i;
    }
    return inside;
}

// ---- metadata -------------------------------------------------------------

/// A longitude as S-57's integer degrees, NORMALISED back into [-180, 180]. The
/// warp works in the fit's unwrapped domain, where an antimeridian sheet runs to
/// 243 deg east — which does not fit in the wire format's i32 and is not what the
/// partition wants anyway: it unwraps coverage rings itself, from normalised
/// input, exactly as it does for an S-57 cell.
fn lonE7(deg: f64) i32 {
    const norm = deg - 360.0 * @round(deg / 360.0);
    return @intFromFloat(@round(std.math.clamp(norm, -180.0, 180.0) * 1e7));
}

fn latE7(deg: f64) i32 {
    return @intFromFloat(@round(std.math.clamp(deg, -90.0, 90.0) * 1e7));
}

fn unwrap(lon: f64, about: f64) f64 {
    return lon + 360.0 * @round((about - lon) / 360.0);
}

/// The neat line as the one coverage polygon, in S-57's integer lon/lat. The
/// partition compares these integers directly, so two sheets that digitised a
/// shared border to the same hundredth of a second still dissolve it exactly.
fn covRings(a: Allocator, border: []const [2]f64) ![]const []const []const s57.LonLat {
    const ring = try a.alloc(s57.LonLat, border.len);
    for (border, 0..) |p, i| ring[i] = .{ .lon_e7 = lonE7(p[0]), .lat_e7 = latE7(p[1]) };
    const rings = try a.alloc([]const s57.LonLat, 1);
    rings[0] = ring;
    const feat = try a.alloc([]const []const s57.LonLat, 1);
    feat[0] = rings;
    return feat;
}

/// `CED/ED` + `CED/RE` as the partition's date key: `YYYYMMDD` from the edition
/// date, then the two-digit revision. The partition orders these lexically and
/// newest-first, and NOAA reissues a sheet under the SAME edition date with the
/// revision bumped — so a key without the revision would leave the newer print of
/// a sheet ordered arbitrarily against the older one. Empty when `ED` says
/// nothing parseable, which orders the sheet last, as an undated cell does.
fn editionKey(a: Allocator, ed: []const u8, re: []const u8) ![]const u8 {
    // NOAA writes MM/DD/YYYY.
    var it = std.mem.splitScalar(u8, ed, '/');
    const mm = it.next() orelse return "";
    const dd = it.next() orelse return "";
    const yyyy = it.next() orelse return "";
    if (mm.len != 2 or dd.len != 2 or yyyy.len != 4) return "";
    for (ed) |ch| if (!std.ascii.isDigit(ch) and ch != '/') return "";
    var rev: [2]u8 = .{ '0', '0' };
    if (re.len >= 1 and re.len <= 2 and std.ascii.isDigit(re[re.len - 1])) {
        rev[1] = re[re.len - 1];
        rev[0] = if (re.len == 2) re[0] else '0';
    }
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ yyyy, mm, dd, &rev });
}

/// The archive metadata: the envelope the ENC bake writes, minus the vector
/// layer list (a picture has no layers) and with the tile format named — plus the
/// "coverage" object the compositor decodes to place the sheet.
fn metadataJson(a: Allocator, name: []const u8, title: []const u8, cov_json: []const u8) ![]u8 {
    var b = std.ArrayList(u8).empty;
    try b.appendSlice(a, "{\"name\":\"");
    try appendEscaped(a, &b, name);
    try b.appendSlice(a, "\",\"description\":\"");
    try appendEscaped(a, &b, title);
    try b.appendSlice(a, "\",\"format\":\"png\",\"coverage\":");
    try b.appendSlice(a, cov_json);
    try b.append(a, '}');
    return b.toOwnedSlice(a);
}

/// A chart title is free text out of somebody else's file, so it is escaped
/// rather than trusted: one stray quote would otherwise make the whole metadata
/// object unparseable, and with it the coverage the sheet quilts on.
fn appendEscaped(a: Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"', '\\' => {
            try b.append(a, '\\');
            try b.append(a, ch);
        },
        0...0x1f => try b.append(a, ' '),
        else => try b.append(a, ch),
    };
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

/// A whole synthetic KAP: a 64x64 sheet in four coloured quadrants, four control
/// points at its corners, a `PLY` around it, and whatever datum shift the caller
/// wants to test. Small enough to bake in a test, complete enough that the real
/// decode path runs.
///
/// The quadrants are the point: NW and SE red, NE and SW blue. A warp that
/// mirrored either axis, or transposed them, lands the wrong colour in the tile —
/// which a single-colour sheet could never show.
fn synthKap(a: Allocator, dtm_lat_sec: f64, dtm_lon_sec: f64) ![]u8 {
    var b = std.ArrayList(u8).empty;
    const head = try std.fmt.allocPrint(a,
        \\BSB/NA=TEST SHEET,NU=1,RA=64,64,DU=254
        \\KNP/SC=50000,GD=NAD27,PR=MERCATOR
        \\CED/SE=01,RE=02,ED=07/04/1999
        \\DTM/{d},{d}
        \\IFM/4
        \\RGB/1,255,0,0
        \\RGB/2,0,0,255
        \\REF/1,0,0,41.1000000,-70.0000000
        \\REF/2,63,0,41.1000000,-69.9000000
        \\REF/3,0,63,41.0000000,-70.0000000
        \\REF/4,63,63,41.0000000,-69.9000000
        \\PLY/1,41.1000000,-70.0000000
        \\PLY/2,41.1000000,-69.9000000
        \\PLY/3,41.0000000,-69.9000000
        \\PLY/4,41.0000000,-70.0000000
        \\
    , .{ dtm_lat_sec, dtm_lon_sec });
    try b.appendSlice(a, head);
    try b.appendSlice(a, &.{ 0x1A, 0x00, 4 }); // header terminator + 4 bits per pixel

    // Rows of eight-pixel runs: `(colour << 3) | 7` is one run of eight, and the
    // row ends at a zero byte. Both quadrant edges fall on a run boundary.
    var y: usize = 0;
    while (y < 64) : (y += 1) {
        try b.append(a, @intCast(y)); // the row number, high bit clear
        var x: usize = 0;
        while (x < 64) : (x += 8) {
            const red = (x < 32) == (y < 32);
            try b.append(a, (@as(u8, if (red) 1 else 2) << 3) | 7);
        }
        try b.append(a, 0);
    }
    return b.toOwnedSlice(a);
}

/// The WGS84 position of a source pixel, the way the bake computes it: the
/// sheet's own fit, then the datum shift.
fn wgsAt(h: bsb.Header, fit: bsb.Fit, px: f64, py: f64) [2]f64 {
    return .{ fit.lonAt(px, py) + h.dtm_lon / 3600.0, fit.latAt(px, py) + h.dtm_lat / 3600.0 };
}

test "a baked sheet carries its neat line, scale and edition as chart coverage" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const kap = try synthKap(a, 0, 0);
    var baked = try bakeBytes(gpa, kap, "TEST01");
    defer gpa.free(baked.bytes);

    try testing.expectEqual(@as(u32, 50_000), baked.scale);
    try testing.expect(baked.tiles > 0);
    try testing.expectEqual(@as(u8, 0), baked.min_zoom);
    // 64 px over 0.1 deg of longitude is ~9.8 zooms of detail; the cap never
    // rounds UP, so nothing in the archive is finer than the sheet itself.
    try testing.expectEqual(@as(u8, 9), baked.max_zoom);
    try testing.expect(baked.fit_px < 1.0);

    var rd = try pmtiles.Reader.init(gpa, baked.bytes);
    defer rd.deinit();
    try testing.expectEqual(pmtiles.TileType.png, rd.header.tile_type);

    const meta = baked.bytes[@intCast(rd.header.metadata_offset)..][0..@intCast(rd.header.metadata_length)];
    const cov = (try coverage.decodeFromMetadata(a, gpa, meta)) orelse return error.NoCoverageEmbedded;
    try testing.expectEqualStrings("TEST01", cov.name);
    try testing.expectEqual(@as(i32, 50_000), cov.cscl);
    // ED 07/04/1999 with RE 02: the date the partition orders on, revision last.
    try testing.expectEqualStrings("1999070402", cov.date);
    try testing.expectEqual(@as(usize, 1), cov.cov1.len);
    try testing.expectEqual(@as(usize, 4), cov.cov1[0][0].len);
    try testing.expectEqual(@as(i32, -700_000_000), cov.bbox[0]);
    try testing.expectEqual(@as(i32, 410_000_000), cov.bbox[1]);
}

test "the datum shift moves the sheet, in the direction the sheet declares" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A degree each way — absurd for a real datum, and unambiguous about SIGN,
    // which is the half of this that a NAD83 test archive can never check. The
    // real NAD27 case is the same code with the same sign at ~40 m.
    const shifted = try bakeBytes(gpa, try synthKap(a, 3600.0, -3600.0), "SHIFT");
    defer gpa.free(shifted.bytes);
    const plain = try bakeBytes(gpa, try synthKap(a, 0, 0), "PLAIN");
    defer gpa.free(plain.bytes);

    const cs = try covOf(a, gpa, shifted.bytes);
    const cp = try covOf(a, gpa, plain.bytes);
    // WGS84 = the sheet's own coordinates PLUS the declared shift, so a sheet
    // declaring +1 deg of latitude lands one degree north of where it plots.
    try testing.expectEqual(cp.bbox[1] + 10_000_000, cs.bbox[1]);
    try testing.expectEqual(cp.bbox[3] + 10_000_000, cs.bbox[3]);
    try testing.expectEqual(cp.bbox[0] - 10_000_000, cs.bbox[0]);
    try testing.expectEqual(cp.bbox[2] - 10_000_000, cs.bbox[2]);
}

fn covOf(a: Allocator, scratch: Allocator, archive: []const u8) !coverage.ChartCoverage {
    var rd = try pmtiles.Reader.init(scratch, archive);
    defer rd.deinit();
    const meta = archive[@intCast(rd.header.metadata_offset)..][0..@intCast(rd.header.metadata_length)];
    return (try coverage.decodeFromMetadata(a, scratch, meta)) orelse error.NoCoverageEmbedded;
}

test "every quadrant of the sheet warps to the tile pixel its position names" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A datum shift is applied here too: the picture must move WITH the
    // georeference, not stay behind it.
    const kap = try synthKap(a, 3600.0, -3600.0);
    const baked = try bakeBytes(gpa, kap, "QUADS");
    defer gpa.free(baked.bytes);

    const h = try bsb.parseHeader(a, kap);
    const fit = bsb.fitRefs(h, a).?;

    var rd = try pmtiles.Reader.init(gpa, baked.bytes);
    defer rd.deinit();

    // One well-inside sample per quadrant, and the colour the source has there.
    const probes = [_]struct { x: f64, y: f64, red: bool }{
        .{ .x = 12.5, .y = 12.5, .red = true }, // NW
        .{ .x = 51.5, .y = 12.5, .red = false }, // NE
        .{ .x = 12.5, .y = 51.5, .red = false }, // SW
        .{ .x = 51.5, .y = 51.5, .red = true }, // SE
    };
    for (probes) |p| {
        const ll = wgsAt(h, fit, p.x, p.y);
        const world = tiles.tile.lonLatToWorld(ll[0], ll[1]);
        const n: f64 = @floatFromInt(@as(u64, 1) << @intCast(baked.max_zoom));
        const tx: u32 = @intFromFloat(@floor(world[0] * n));
        const ty: u32 = @intFromFloat(@floor(world[1] * n));
        const raw = (try rd.getTile(a, baked.max_zoom, tx, ty)) orelse return error.TileMissing;
        const img = try png.decodeRgba(a, raw);
        const i: usize = @intFromFloat(@floor((world[0] * n - @floor(world[0] * n)) * 256));
        const j: usize = @intFromFloat(@floor((world[1] * n - @floor(world[1] * n)) * 256));
        const o = (j * 256 + i) * 4;
        try testing.expectEqual(@as(u8, 255), img.rgba[o + 3]); // inside the neat line
        if (p.red) {
            try testing.expect(img.rgba[o + 0] > 200 and img.rgba[o + 2] < 60);
        } else {
            try testing.expect(img.rgba[o + 2] > 200 and img.rgba[o + 0] < 60);
        }
    }
}

test "a sheet the fit cannot reproduce is refused" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // One control point moved half a degree off the grid the other three define:
    // the least-squares fit now misses every point by thousands of source pixels,
    // which is exactly the failure a bad `REF` parse produces.
    const kap = try synthKap(a, 0, 0);
    const broken = try a.dupe(u8, kap);
    const at = std.mem.indexOf(u8, broken, "REF/4,63,63,41.0000000").?;
    @memcpy(broken[at .. at + 22], "REF/4,63,63,45.0000000");
    try testing.expectError(Error.FitResidual, bakeBytes(gpa, broken, "BROKEN"));
}

test "a sheet with no PLY border cannot quilt and is refused" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const kap = try synthKap(a, 0, 0);
    const noply = try a.alloc(u8, kap.len);
    @memcpy(noply, kap);
    // Blind every PLY record: no neat line, so no coverage, so no ownership.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, noply, i, "PLY/")) |at| : (i = at + 4) @memcpy(noply[at .. at + 4], "XXX/");
    try testing.expectError(Error.NoBorder, bakeBytes(gpa, noply, "NOPLY"));
}

test "the edition key is the date the partition orders on, revision last" {
    const a = testing.allocator;
    const k1 = try editionKey(a, "12/01/2015", "01");
    defer a.free(k1);
    try testing.expectEqualStrings("2015120101", k1);
    const k2 = try editionKey(a, "12/01/2015", "2");
    defer a.free(k2);
    try testing.expectEqualStrings("2015120102", k2);
    // Same edition, later revision, orders as the newer sheet.
    try testing.expect(std.mem.lessThan(u8, k1, k2));
    // A later edition beats both, whatever their revisions.
    const k3 = try editionKey(a, "12/02/2015", "01");
    defer a.free(k3);
    try testing.expect(std.mem.lessThan(u8, k2, k3));
    try testing.expectEqualStrings("", try editionKey(a, "", ""));
    try testing.expectEqualStrings("", try editionKey(a, "SPRING 2015", "01"));
}

// The real-file test. A KAP is megabytes and cannot live in the repo, so the
// path comes from the environment: point TILE57_KAP at one.
test "bake a real NOAA sheet, open it as a raster chart, and find a known position in it" {
    const gpa = testing.allocator;
    const path = std.mem.span(std.c.getenv("TILE57_KAP") orelse return error.SkipZigTest);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const kap = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .unlimited);
    defer gpa.free(kap);
    const stem = std.fs.path.stem(std.fs.path.basename(path));
    const baked = try bakeBytes(gpa, kap, stem);
    defer gpa.free(baked.bytes);

    try testing.expect(baked.scale > 0);
    try testing.expect(baked.tiles > 0);
    try testing.expect(baked.max_zoom > 0 and baked.max_zoom <= ZOOM_CEIL);
    try testing.expect(baked.fit_px < MAX_FIT_PX);

    // Through the file, as a host meets it: written out, then opened by path.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sheet.pmtiles", .data = baked.bytes });
    const arc_path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/sheet.pmtiles", .{tmp.sub_path}, 0);

    var rc = try rasterchart.RasterChart.open(testing.io, gpa, arc_path, null);
    defer rc.close();
    const info = rc.getInfo();
    try testing.expectEqual(baked.max_zoom, info.max_zoom);
    try testing.expectEqual(rasterchart.Encoding.png, info.encoding);
    try testing.expectEqual(baked.scale, info.scale); // it can own ground
    try testing.expectEqualStrings(stem, rc.name());

    const cov = rc.decodedCoverage() orelse return error.NoCoverage;
    try testing.expect(cov.cov1.len == 1 and cov.cov1[0][0].len >= 3);

    // A KNOWN position: the middle of the sheet's own neat line, carried through
    // the sheet's fit and its datum shift. It must land in a tile the archive
    // holds, on an OPAQUE pixel — the picture is there, at the position the chart
    // says it is.
    const h = try bsb.parseHeader(a, kap);
    const fit = bsb.fitRefs(h, a) orelse return error.NoFit;
    var mid = [2]f64{ 0, 0 };
    for (h.border) |p| {
        mid[0] += unwrap(p[0], h.border[0][0]) / @as(f64, @floatFromInt(h.border.len));
        mid[1] += p[1] / @as(f64, @floatFromInt(h.border.len));
    }
    const lon = mid[0] + h.dtm_lon / 3600.0;
    const lat = mid[1] + h.dtm_lat / 3600.0;
    const world = tiles.tile.lonLatToWorld(lon - 360.0 * @round(lon / 360.0), lat);
    const n: f64 = @floatFromInt(@as(u64, 1) << @intCast(baked.max_zoom));
    const tx: u32 = @intFromFloat(@floor(world[0] * n));
    const ty: u32 = @intFromFloat(@floor(world[1] * n));
    const bytes = (try rc.tile(gpa, baked.max_zoom, tx, ty)) orelse return error.TileMissing;
    defer gpa.free(bytes);
    const img = try png.decodeRgba(a, bytes);
    try testing.expectEqual(@as(u32, 256), img.w);
    const i: usize = @intFromFloat(@floor((world[0] * n - @floor(world[0] * n)) * 256));
    const j: usize = @intFromFloat(@floor((world[1] * n - @floor(world[1] * n)) * 256));
    try testing.expectEqual(@as(u8, 255), img.rgba[(j * 256 + i) * 4 + 3]);

    // And the pixel there must be the SHEET's pixel. Compared only where the
    // source is locally flat, because one output pixel averages a small block of
    // source pixels — on a colour edge the average is legitimately neither. Flat
    // is the ordinary case (paper, or open water) and the claim is the whole of
    // the warp: this position, this colour, out of that sheet.
    var chart = try bsb.decode(gpa, kap);
    defer chart.deinit();
    const inv = inverseFit(fit).?;
    const mer = bsb.mercY(mid[1]);
    const sx = inv[0][0] + inv[0][1] * mid[0] + inv[0][2] * mer;
    const sy = inv[1][0] + inv[1][1] * mid[0] + inv[1][2] * mer;
    try testing.expect(sx >= 4 and sy >= 4 and sx < @as(f64, @floatFromInt(h.width - 4)) and sy < @as(f64, @floatFromInt(h.height - 4)));
    const want = chart.rgbAt(@intFromFloat(sx), @intFromFloat(sy));
    var flat = true;
    var dy: i32 = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: i32 = -4;
        while (dx <= 4) : (dx += 1) {
            const px: u32 = @intCast(@as(i64, @intFromFloat(sx)) + dx);
            const py: u32 = @intCast(@as(i64, @intFromFloat(sy)) + dy);
            const got = chart.rgbAt(px, py);
            if (got.r != want.r or got.g != want.g or got.b != want.b) flat = false;
        }
    }
    if (flat) {
        const o = (j * 256 + i) * 4;
        try testing.expectEqual(want.r, img.rgba[o + 0]);
        try testing.expectEqual(want.g, img.rgba[o + 1]);
        try testing.expectEqual(want.b, img.rgba[o + 2]);
    }

    // Ground the sheet does not cover has no tile at all — the neat line clip and
    // the tile-tree prune agree that the paper collar is not chart.
    var south: f64 = 90;
    for (h.border) |p| south = @min(south, p[1]);
    const off = tiles.tile.lonLatToWorld(lon - 360.0 * @round(lon / 360.0), @max(-84.0, south - 1.0));
    const ox: u32 = @intFromFloat(@floor(off[0] * n));
    const oy: u32 = @intFromFloat(@floor(off[1] * n));
    try testing.expect((try rc.tile(gpa, baked.max_zoom, ox, oy)) == null);
}
