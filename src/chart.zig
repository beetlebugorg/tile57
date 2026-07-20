//! The tile57 engine API, in Zig. A `Chart` is an embeddable nautical-chart
//! tile source: open it from in-memory bytes (a PMTiles archive or raw S-57 ENC
//! cells) and it serves decompressed Mapbox Vector Tiles by (z, x, y). Multi-cell
//! ENC_ROOT sources index cells cheaply and parse + portray them lazily per
//! requested tile (LRU-bounded), so a host can open the whole NOAA catalogue
//! instantly and pay only for the cells under the current view. Baking is
//! strictly per-cell: each cell to its own PMTiles archive.
//!
//! This is the single source of truth; the C ABI (capi.zig / include/tile57.h)
//! is a thin shim over these types. The engine uses a single thread-safe
//! general-purpose allocator internally — the render / bake / JSON entry points
//! return bytes owned by it; free them with `freeBytes`.
//!
//! Threading: a Chart is NOT internally synchronized — don't call its render /
//! query methods on the same Chart from multiple threads concurrently. Distinct
//! charts are independent. `openCharts`/`bakeChartsParallel` parallelize
//! internally over cores.

const std = @import("std");
const pmtiles = @import("tiles").pmtiles;
const filemap = @import("tiles").filemap;
const mlt = @import("tiles").mlt;
const tiles_mvt = @import("tiles").mvt;
const gzip = @import("tiles").gzip;
const s57 = @import("s57");
const scene = @import("scene");
const portray = @import("portray");
const bake_enc = @import("scene").bake_enc;
const catalogue = @import("s101").catalogue;
const s101 = @import("s101");
const tile = @import("tiles").tile;
const render = @import("render");
const sprite = @import("sprite");
const embedded_assets = @import("catalog"); // S-101 portrayal assets (renderView store)
const style = @import("style"); // displayDenomZ (the physical display-scale formula)
const cell_coverage = @import("coverage"); // per-cell M_COVR coverage embedded in archive metadata
const compose_mod = @import("compose"); // the runtime compositor (compose-backed view renders)

// smp_allocator (Zig's fast thread-safe GPA), not page_allocator: the engine
// makes many small, short-lived allocations (tile cache, cell dupes, index
// lists); page_allocator would mmap each one. Matches the bake CLI + C ABI.
const gpa = std.heap.smp_allocator;

// The S-52 colour tables, parsed once per process from the embedded profile (see
// Chart.viewColorsRef). Immutable after init — every chart shares these, so the
// parse cannot be charged to a chart open. gpa is thread-safe and the tables live
// for the process, so they are deliberately never freed.
// One-shot: 0 = unparsed, 1 = a thread is parsing, 2 = ready. Zig 0.16 puts mutexes
// behind an Io (which the engine deliberately does not take), so the guard is a CAS
// plus a spin — and it can only ever contend on the very first tile of the first
// chart. After that this is one acquire load.
var colors_state: std.atomic.Value(u8) = .init(0);
var shared_colors: render.resolve.Colors = undefined;
var shared_colors_err: ?anyerror = null;

fn sharedColors() !*render.resolve.Colors {
    while (colors_state.load(.acquire) != 2) {
        if (colors_state.cmpxchgStrong(@as(u8, 0), @as(u8, 1), .acquire, .monotonic) == null) {
            // TILE57_COLORPROFILE (via the C shim) overrides the embedded profile —
            // its bytes are process-lifetime, so the Colors' token keys may slice in.
            var ov_len: usize = 0;
            const profile_xml: []const u8 = if (tg_colorprofile_override(&ov_len)) |p|
                p[0..ov_len]
            else
                embedded_assets.colorprofile[0].bytes;
            if (render.resolve.Colors.init(gpa, profile_xml)) |c| {
                shared_colors = c;
            } else |e| {
                shared_colors_err = e;
            }
            colors_state.store(2, .release);
            break;
        }
        std.atomic.spinLoopHint();
    }
    if (shared_colors_err) |e| return e;
    return &shared_colors;
}

// Process-global per-palette symbol stores — the handle-less twin of
// Chart.viewStoreFor, for a renderer that has tile bytes but no chart handle
// (renderMltTileSurface / tile57_render_mlt_tile). The SVG-catalogue parse is
// costly, so build each palette once, gpa-owned for the process lifetime. Same
// one-shot CAS+spin as sharedColors; contends only on the first tile per palette.
var store_state: [3]std.atomic.Value(u8) = .{ .init(0), .init(0), .init(0) };
var shared_stores: [3]?*sprite.CatalogStore = .{ null, null, null };
var shared_store_err: [3]?anyerror = .{ null, null, null };

fn sharedStore(palette: render.resolve.PaletteId) !*sprite.CatalogStore {
    const i: usize = @intFromEnum(palette);
    while (store_state[i].load(.acquire) != 2) {
        if (store_state[i].cmpxchgStrong(@as(u8, 0), @as(u8, 1), .acquire, .monotonic) == null) {
            if (viewSymbolStore(gpa, palette)) |st| {
                shared_stores[i] = st;
            } else |e| {
                shared_store_err[i] = e;
            }
            store_state[i].store(2, .release);
            break;
        }
        std.atomic.spinLoopHint();
    }
    if (shared_store_err[i]) |e| return e;
    return shared_stores[i].?;
}

/// Portray ONE MLT tile from CALLER-SUPPLIED bytes to a surface — the handle-less
/// twin of Chart.renderSurfaceTile, for a host holding tile bytes (e.g. fetched
/// over HTTP from a tile server) but with no chart archive open. Colours and the
/// per-palette symbol store come from the process-global caches; decluttering is
/// per-tile (as with renderSurfaceTile). `bytes` are raw (decompressed) MLT.
pub fn renderMltTileSurface(bytes: []const u8, z: u8, x: u32, y: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const colors = try sharedColors();
    const store = try sharedStore(palette);

    var vs = render.vector.VectorSurface.init(a, colors, palette, settings, cb);
    vs.store = store.asStore();
    vs.view_zoom = @floatFromInt(z); // declutter at the tile's native zoom
    const surf = vs.asSurface();

    try surf.beginScene(z);
    if (mlt.decode(a, bytes)) |layers| {
        vs.setTile(z, x, y);
        scene.replayTile(a, surf, layers) catch {};
    } else |_| {} // an undecodable tile paints nothing, not an error
    _ = try surf.endScene(a);
}

test "renderMltTileSurface: handle-less colour/store/surface setup; undecodable tile is a no-op" {
    const V = render.vector;
    const noop = struct {
        fn fill(_: ?*anyopaque, _: *const V.CFeature, _: *const V.CWorldRings, _: V.CColor, _: c_int) callconv(.c) void {}
        fn stroke(_: ?*anyopaque, _: *const V.CFeature, _: *const V.CWorldRings, _: f32, _: f32, _: f32, _: V.CColor) callconv(.c) void {}
        fn symbol(_: ?*anyopaque, _: *const V.CFeature, _: V.CWorldPt, _: *const V.CLocalRings, _: V.CColor, _: c_int, _: f32, _: V.CRotAlign) callconv(.c) void {}
        fn text(_: ?*anyopaque, _: *const V.CFeature, _: V.CWorldPt, _: *const V.CLocalRings, _: V.CColor, _: V.CColor, _: f32, _: V.CRotAlign, _: i32) callconv(.c) void {}
    };
    const cb = V.CSurface{
        .ctx = null,
        .fill_area = noop.fill,
        .stroke_line = noop.stroke,
        .draw_symbol = noop.symbol,
        .draw_text = noop.text,
    };
    const settings = render.resolve.Settings{};
    // No chart handle: this drives sharedColors + sharedStore + the whole surface
    // lifecycle. Garbage bytes fail to decode and paint nothing — still success.
    try renderMltTileSurface(&[_]u8{ 0, 1, 2, 3 }, 14, 4680, 6260, .day, &settings, &cb);
}

// Env access lives in C (Zig 0.16 puts env behind Io); returns the S-101 rules
// dir from TILE57_S101_RULES or null. Provided by the portrayal C shim.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

// TILE57_COLORPROFILE override, also via the C shim: a colorProfile.xml the host
// points at to recolour the chart (e.g. a monochrome "ink" profile) without a
// rebuild. Returns the file's bytes (process-lifetime; NULL -> use the embedded
// profile). See sharedColors().
extern fn tg_colorprofile_override(len: *usize) callconv(.c) ?[*]const u8;

/// Backend / on-disk format. `auto` sniffs PMTiles first, then S-57.
pub const Format = enum { auto, pmtiles, s57 };

/// One ENC cell: the base .000 bytes plus its sequential update files (.001…).
/// Bytes are borrowed for the duration of the call (copied where retained).
pub const ChartInput = struct {
    base: []const u8,
    updates: []const []const u8 = &.{},
    /// Source ENC cell name (dataset stem, e.g. "US4MD81M") for the pick report's
    /// "source cell" badge. "" = unknown (the `cell` prop is omitted). The eager
    /// (openCharts) path copies it; the bake path borrows it for the call.
    name: []const u8 = "",
};

/// Progress callback for `bakeArchive`: stage 0 = loading/portraying cells,
/// stage 1 = baking tiles. `band_index`/`band_count` locate the current band among
/// the bands that actually bake; `band_name` is its navigational-purpose name (a
/// static NUL-terminated string), null for stage 0. C-callconv so a C host can pass
/// one directly. See bake_enc.Progress (structurally identical).
pub const Progress = ?*const fn (user: ?*anyopaque, stage: u8, done: usize, total: usize, band_index: u8, band_count: u8, band_name: ?[*:0]const u8) callconv(.c) void;

/// Pre-peeked metadata for one cell in a streaming open: its geographic extent
/// and compilation scale (1:cscl). The host supplies these (cheap to compute, or
/// already known) so the source opens without reading any cell bytes.
pub const ChartMeta = extern struct {
    west: f64,
    south: f64,
    east: f64,
    north: f64,
    cscl: i32,
};

/// Cell bytes returned by a streaming reader. The reader transfers OWNERSHIP of
/// malloc-allocated buffers (base + each update); the engine frees them with
/// libc free() once the cell is parsed. update arrays are parallel, length
/// update_count (0 / null for a base-only cell).
pub const ChartBytes = extern struct {
    base: [*]const u8 = undefined,
    base_len: usize = 0,
    updates: ?[*]const [*]const u8 = null,
    update_lens: ?[*]const usize = null,
    update_count: usize = 0,
};

/// Streaming cell reader: fill `out` with cell `index`'s malloc'd bytes (the
/// engine frees them), returning true on success. Called on demand the first
/// time a tile needs the cell (and again after the cell is LRU-evicted), so the
/// host holds only the working set's bytes — not the whole ENC_ROOT.
pub const ChartReadFn = *const fn (user: ?*anyopaque, index: usize, out: *ChartBytes) callconv(.c) bool;

/// Free bytes returned by the render / bake / JSON entry points (page-allocator owned).
pub fn freeBytes(bytes: []u8) void {
    gpa.free(bytes);
}

// ---- backends ------------------------------------------------------------

const CellBackend = struct {
    cell: s57.Cell,
    portrayal: ?[]const ?[]const u8 = null, // per-feature default S-101 instruction stream
    portrayal_plain: ?[]const ?[]const u8 = null, // PlainBoundaries variant (areas)
    portrayal_simplified: ?[]const ?[]const u8 = null, // SimplifiedSymbols variant (points)
    portray_arena: ?*std.heap.ArenaAllocator = null,
    coverage: []const []const []const s57.LonLat = &.{}, // M_COVR (in portray_arena)
    cscl: i32 = 0, // compilation scale (DSPM CSCL, 1:N)
    // Baker-style per-cell caches (in portray_arena), built once at open so each of
    // the view's tiles reuses them instead of re-assembling geometry + re-projecting
    // + re-processing every feature every rebuild (see renderSurfaceView's .cell arm).
    geo: ?scene.GeoParts = null, // assembled ring geometry
    geo_world: ?scene.GeoWorld = null, // its web-mercator projection
    feat_bbox: ?[]const ?[4]f64 = null, // per-feature lon/lat bbox (spatial cull)
};

/// A built GPU scene and the arena its buffers live in. Handed out by
/// `renderGpuScene`, which is the only thing that constructs one; the caller
/// holds it for as long as it draws from the buffers, then deinits.
pub const GpuScene = struct {
    arena: std.heap.ArenaAllocator,
    scene: render.gpu.Scene,
    /// A cached tile's shaped label candidates (empty on assembled/label scenes),
    /// decluttered per view into the final label geometry. Arena-owned.
    candidates: []render.gpu.LabelCandidate = &.{},

    pub fn deinit(self: *GpuScene) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The live-cell backend as the scene engine's one-cell reference: the cell plus
/// the open-time portrayal streams and per-cell geometry caches the view paths
/// replay from.
fn cellRef(cb: *CellBackend) scene.CellRef {
    return .{
        .cell = &cb.cell,
        .portrayal = cb.portrayal,
        .portrayal_plain = cb.portrayal_plain,
        .portrayal_simplified = cb.portrayal_simplified,
        .geo = cb.geo,
        .geo_world = cb.geo_world,
        .feat_bbox = cb.feat_bbox,
    };
}

// One cell in the lazy ENC_ROOT index: its owned bytes + cheap metadata (bbox +
// navigational band), parsed + portrayed ON DEMAND the first time a requested tile
// needs it, then kept until evicted by the LRU.
const LazyCell = struct {
    base: []u8,
    updates: [][]u8,
    /// Source cell name for the pick report (gpa-owned copy; the host's input bytes
    /// are borrowed only for the open call). "" = unknown. Freed in lazyFreeCell.
    name: []const u8 = "",
    bbox: [4]f64, // [west, south, east, north]
    band: bake_enc.Band,
    cscl: i32 = 0, // compilation-scale denominator (peeked; 0 = unknown)
    cell: ?s57.Cell = null,
    portrayal: ?[]const ?[]const u8 = null,
    portrayal_plain: ?[]const ?[]const u8 = null,
    portrayal_simplified: ?[]const ?[]const u8 = null,
    arena: ?*std.heap.ArenaAllocator = null,
    tick: u64 = 0, // LRU: last tile that used this cell
    // M_COVR(CATCOV=1) coverage polygons, assembled once from `cell` for best-band
    // suppression. Lives in cell.arena, freed (and reset) when the cell unloads.
    coverage: ?[]const []const []const s57.LonLat = null,
    // Distinct SCAMIN denominators (cell.arena, computed on load) — the cell's
    // slice of the tilejson scamin ladder (client filter-gate crossings).
    scamins: []const u32 = &.{},
    // Sector-figure reach (scene.collectLightReach), computed on first load from
    // the portrayal streams and KEPT after eviction (plain values, no arena) so
    // tileRefs' reach candidacy doesn't have to reload the cell to test it.
    // Until the first load (light_known == false) the cell is provisionally a
    // candidate within a one-tile ring of its bbox — loading it then resolves
    // the exact reach.
    light_known: bool = false,
    light_bbox: ?[4]f64 = null,
    light_range_m: f64 = 0,
    // Streaming: when the source has a reader, `base`/`updates` are empty until the
    // cell is first needed (read on demand into gpa, freed on eviction), so only
    // the LRU working set's bytes are held. `index` is passed to the reader.
    streaming: bool = false,
    index: usize = 0,
};

const LazySource = struct {
    cells: []LazyCell,
    rules_dir: []u8, // owned (lazy portrayal needs it after open returns)
    tick: u64 = 0,
    loaded: usize = 0,
    max_loaded: usize = 256, // LRU budget on parsed+portrayed cells (wide views)
    reader: ?ChartReadFn = null, // streaming: read a cell's bytes on demand
    reader_user: ?*anyopaque = null,
    // Path-backed streaming (chart-api.md): when the chart was opened from an on-disk
    // ENC_ROOT, this owns the retained Io + Dir + per-cell paths and is the
    // reader_user; freed in deinit. null for byte/reader-supplied streaming.
    path_ctx: ?*PathCtx = null,
};

// Owned state for a path-backed streaming chart: the retained filesystem handles +
// per-cell base .000 paths (index-aligned with the LazySource cells). Lives for the
// chart's lifetime so cells can be read on demand; freed by deinit via PathCtx.deinit.
const PathCtx = struct {
    threaded: *std.Io.Threaded,
    io: std.Io,
    dir: std.Io.Dir,
    paths: [][]u8, // base .000 path per cell, relative to `dir`

    fn deinit(self: *PathCtx) void {
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
        self.dir.close(self.io);
        self.threaded.deinit();
        gpa.destroy(self.threaded);
        gpa.destroy(self);
    }
};

const Backend = union(enum) {
    reader: pmtiles.Reader,
    cell: CellBackend,
    cells: LazySource, // ENC_ROOT: lazy spatial index, parsed/portrayed on demand
};

fn bboxOverlap(a_: [4]f64, b_: [4]f64) bool {
    return a_[0] <= b_[2] and a_[2] >= b_[0] and a_[1] <= b_[3] and a_[3] >= b_[1];
}

// Free the host-malloc'd buffers a streaming reader transferred to us (libc free).
fn freeCellBytes(cb: *ChartBytes) void {
    if (cb.base_len != 0) std.c.free(@ptrCast(@constCast(cb.base)));
    if (cb.updates) |ups| {
        var k: usize = 0;
        while (k < cb.update_count) : (k += 1) std.c.free(@ptrCast(@constCast(ups[k])));
        std.c.free(@ptrCast(@constCast(ups)));
    }
    if (cb.update_lens) |ul| std.c.free(@ptrCast(@constCast(ul)));
}

// ---- path-backed streaming helpers (chart-api.md) --------------------------

fn isDirIo(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// libc-malloc'd copy of `bytes` (the streaming reader transfers ownership to the
// engine, which frees via freeCellBytes/std.c.free). null on OOM.
fn cdup(bytes: []const u8) ?[*]u8 {
    const p = std.c.malloc(bytes.len) orelse return null;
    const dst: [*]u8 = @ptrCast(p);
    @memcpy(dst[0..bytes.len], bytes);
    return dst;
}

// Peek `relpath`'s bbox+scale; on success append an index-aligned meta + a gpa-owned
// copy of the path. Cells that don't read / have no coverage bbox are skipped (both
// lists), keeping meta[i] and paths[i] aligned with the streaming cell index.
fn addPathCell(io: std.Io, dir: std.Io.Dir, relpath: []const u8, metas: *std.ArrayList(ChartMeta), paths: *std.ArrayList([]u8)) !void {
    const bytes = dir.readFileAlloc(io, relpath, gpa, .unlimited) catch return;
    defer gpa.free(bytes);
    const m = s57.peekMeta(gpa, bytes) orelse return;
    const bb = m.bounds orelse return;
    try metas.append(gpa, .{ .west = bb[0], .south = bb[1], .east = bb[2], .north = bb[3], .cscl = m.cscl });
    try paths.append(gpa, try gpa.dupe(u8, relpath));
}

// Internal ChartReadFn for a path-backed chart: read cell `index`'s base .000 + its
// sequential .001.. updates from the retained dir into libc-malloc'd buffers (the
// engine frees them via freeCellBytes). Mirrors the baker's per-cell load.
fn pathRead(user: ?*anyopaque, index: usize, out: *ChartBytes) callconv(.c) bool {
    const ctx: *PathCtx = @ptrCast(@alignCast(user orelse return false));
    if (index >= ctx.paths.len) return false;
    const bpath = ctx.paths[index];
    const base = ctx.dir.readFileAlloc(ctx.io, bpath, gpa, .unlimited) catch return false;
    defer gpa.free(base);
    const cbase = cdup(base) orelse return false;
    out.* = .{ .base = cbase, .base_len = base.len };

    var ups = std.ArrayList([*]const u8).empty;
    defer ups.deinit(gpa);
    var ulens = std.ArrayList(usize).empty;
    defer ulens.deinit(gpa);
    const stem = bpath[0 .. bpath.len - 4]; // strip ".000"
    var u: u32 = 1;
    while (u <= 999) : (u += 1) {
        const upn = std.fmt.allocPrint(gpa, "{s}.{d:0>3}", .{ stem, u }) catch break;
        defer gpa.free(upn);
        const ub = ctx.dir.readFileAlloc(ctx.io, upn, gpa, .unlimited) catch break;
        defer gpa.free(ub);
        const cub = cdup(ub) orelse break;
        ulens.append(gpa, ub.len) catch {
            std.c.free(cub);
            break;
        };
        ups.append(gpa, cub) catch {
            std.c.free(cub);
            _ = ulens.pop();
            break;
        };
    }
    if (ups.items.len > 0) {
        const uarr = std.c.malloc(ups.items.len * @sizeOf([*]const u8)) orelse return true;
        const larr = std.c.malloc(ups.items.len * @sizeOf(usize)) orelse {
            std.c.free(uarr);
            return true;
        };
        const udst: [*][*]const u8 = @ptrCast(@alignCast(uarr));
        const ldst: [*]usize = @ptrCast(@alignCast(larr));
        @memcpy(udst[0..ups.items.len], ups.items);
        @memcpy(ldst[0..ulens.items.len], ulens.items);
        out.updates = @ptrCast(udst);
        out.update_lens = ldst;
        out.update_count = ups.items.len;
    }
    return true;
}

// Read a streaming cell's bytes via the host reader into gpa-owned base/updates
// (freeing the host's originals). Returns false if the reader declines/fails.
fn streamRead(ls: *LazySource, lc: *LazyCell) bool {
    const rd = ls.reader orelse return false;
    var cb: ChartBytes = .{};
    if (!rd(ls.reader_user, lc.index, &cb)) return false;
    const base = gpa.dupe(u8, cb.base[0..cb.base_len]) catch {
        freeCellBytes(&cb);
        return false;
    };
    var ups: [][]u8 = &.{};
    if (cb.update_count > 0 and cb.updates != null and cb.update_lens != null) {
        const arr = gpa.alloc([]u8, cb.update_count) catch {
            gpa.free(base);
            freeCellBytes(&cb);
            return false;
        };
        var k: usize = 0;
        while (k < cb.update_count) : (k += 1) {
            arr[k] = gpa.dupe(u8, cb.updates.?[k][0..cb.update_lens.?[k]]) catch {
                for (arr[0..k]) |u| gpa.free(u);
                gpa.free(arr);
                gpa.free(base);
                freeCellBytes(&cb);
                return false;
            };
        }
        ups = arr;
    }
    freeCellBytes(&cb);
    lc.base = base;
    lc.updates = ups;
    return true;
}

/// A parsed .000 chart: the geometry cell plus, for a NATIVE S-101 dataset, its
/// pre-built portrayal records (so portray bypasses the S-57 -> S-101 adapter).
const CellLoad = struct { cell: s57.Cell, adapted: ?[]const s101.adapter.Adapted = null };

/// Parse a .000 chart, auto-detecting S-101 vs S-57 from the file itself, and apply
/// its sequential `.001…` update chain. A native S-101 dataset (S-100 Part 10a)
/// assembles via s101.native; an S-57 cell parses via s57. Returns null on failure.
fn parseAnyCell(base: []const u8, updates: []const []const u8) ?CellLoad {
    if (s101.dataset.detect(base)) {
        const l = s101.native.parseDataset(gpa, base, updates) catch return null;
        return .{ .cell = l.cell, .adapted = l.adapted };
    }
    const cell = s57.parseCellWithUpdates(gpa, base, updates) catch return null;
    return .{ .cell = cell };
}

/// Portray a cell three ways, using the native adapted set (S-101) when present,
/// else the S-57 adapter.
fn portrayVariantsAny(arena: std.mem.Allocator, cell: *const s57.Cell, adapted: ?[]const s101.adapter.Adapted, dir: []const u8) !portray.CellPortrayal {
    if (adapted) |ad| return portray.portrayCellVariantsAdapted(arena, cell, ad, dir);
    return portray.portrayCellVariants(arena, cell, dir);
}

// Parse + portray a lazy cell if not already loaded, and stamp its LRU tick.
fn lazyEnsureLoaded(ls: *LazySource, lc: *LazyCell) void {
    ls.tick += 1;
    lc.tick = ls.tick;
    if (lc.cell != null) return;
    if (lc.streaming and lc.base.len == 0) {
        if (!streamRead(ls, lc)) return;
    }
    const loaded = parseAnyCell(lc.base, lc.updates) orelse return;
    var cell = loaded.cell;
    cell.name = lc.name; // pick-report source-cell badge (gpa-owned, lives with the source)
    if (gpa.create(std.heap.ArenaAllocator)) |p| {
        p.* = std.heap.ArenaAllocator.init(gpa);
        if (portrayVariantsAny(p.allocator(), &cell, loaded.adapted, ls.rules_dir)) |cp| {
            lc.portrayal = cp.base;
            lc.portrayal_plain = cp.plain;
            lc.portrayal_simplified = cp.simplified;
            lc.arena = p;
        } else |_| {
            p.deinit();
            gpa.destroy(p);
        }
    } else |_| {}
    // The cell's SCAMIN ladder slice + authoritative scale (cheap feature scan;
    // cell.arena-owned, so it unloads with the cell).
    lc.scamins = bake_enc.collectScamins(cell.arena.allocator(), &cell) catch &.{};
    if (cell.params.cscl > 0) lc.cscl = cell.params.cscl;
    // Sector-figure reach from the portrayal streams — plain values kept across
    // unload so reach candidacy never needs a reload just to test it.
    const lr = scene.collectLightReach(&cell, lc.portrayal);
    lc.light_bbox = lr.bbox;
    lc.light_range_m = lr.range_m;
    lc.light_known = true;
    lc.cell = cell;
    ls.loaded += 1;
}

fn lazyUnload(lc: *LazyCell) void {
    if (lc.cell) |*c| c.deinit();
    lc.cell = null;
    lc.portrayal = null;
    lc.coverage = null; // backing memory lived in cell.arena, freed by c.deinit()
    lc.scamins = &.{}; // ditto (cell.arena)
    lc.portrayal_plain = null;
    lc.portrayal_simplified = null;
    if (lc.arena) |p| {
        p.deinit();
        gpa.destroy(p);
        lc.arena = null;
    }
    // Streaming cells free their on-demand bytes on unload (reload re-reads), so
    // only the resident working set holds bytes.
    if (lc.streaming) {
        if (lc.base.len > 0) gpa.free(lc.base);
        for (lc.updates) |u| gpa.free(u);
        if (lc.updates.len > 0) gpa.free(lc.updates);
        lc.base = &.{};
        lc.updates = &.{};
    }
}

// Evict LRU loaded cells down to budget, never touching cells used by the tile
// currently being generated (tick >= keep_from).
fn lazyEvict(ls: *LazySource, keep_from: u64) void {
    while (ls.loaded > ls.max_loaded) {
        var victim: ?*LazyCell = null;
        for (ls.cells) |*lc| {
            if (lc.cell == null or lc.tick >= keep_from) continue;
            if (victim == null or lc.tick < victim.?.tick) victim = lc;
        }
        if (victim) |v| {
            lazyUnload(v);
            ls.loaded -= 1;
        } else break;
    }
}

fn lazyFreeCell(lc: *LazyCell) void {
    lazyUnload(lc); // streaming cells are already emptied here
    if (lc.base.len > 0) gpa.free(lc.base);
    for (lc.updates) |u| gpa.free(u);
    if (lc.updates.len > 0) gpa.free(lc.updates);
    if (lc.name.len > 0) gpa.free(@constCast(lc.name));
}

// Resolve the S-101 rules dir: explicit arg, else TILE57_S101_RULES, else "" —
// which uses the rules embedded in the binary (the Lua searcher in lua_shim.c),
// so no on-disk catalogue is required. A non-empty path overrides the embedded
// copy (read from disk).
fn resolveRulesDir(rules_dir: ?[]const u8) []const u8 {
    if (rules_dir) |d| if (d.len > 0) return d;
    if (tg_env_rules()) |dirz| return std.mem.span(dirz);
    return "";
}

// Open a PMTiles archive from owned bytes (takes ownership on success, frees on
// failure). Returns null if the bytes are not a valid PMTiles archive.
fn openPmtiles(copy: []u8) ?*Chart {
    const reader = pmtiles.Reader.init(gpa, copy) catch {
        gpa.free(copy);
        return null;
    };
    const src = gpa.create(Chart) catch {
        var r = reader;
        r.deinit();
        gpa.free(copy);
        return null;
    };
    src.* = .{ .backend = .{ .reader = reader }, .data = copy, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    attachEmbeddedCoverage(src);
    return src;
}

// A per-cell bake embeds the source cell's M_COVR coverage + compilation scale in
// the archive's metadata JSON; surface them on the opened chart so coverage() and
// nativeScale() answer for a baked archive exactly as they did for the live cell.
// Best-effort: an archive without (or with unparseable) coverage attaches nothing.
fn attachEmbeddedCoverage(src: *Chart) void {
    const rd = &src.backend.reader;
    const h = rd.header;
    if (h.metadata_length == 0) return;
    const raw = rd.bytes[@intCast(h.metadata_offset)..][0..@intCast(h.metadata_length)];
    const cov_arena = gpa.create(std.heap.ArenaAllocator) catch return;
    cov_arena.* = std.heap.ArenaAllocator.init(gpa);
    const a = cov_arena.allocator();
    const drop = struct {
        fn f(ar: *std.heap.ArenaAllocator) void {
            ar.deinit();
            gpa.destroy(ar);
        }
    }.f;
    const json: []const u8 = switch (h.internal_compression) {
        .none => raw,
        .gzip => gzip.decompress(a, raw) catch return drop(cov_arena),
        else => return drop(cov_arena),
    };
    const cov = (cell_coverage.decodeFromMetadata(a, json) catch null) orelse return drop(cov_arena);
    if (cov.cscl == 0 and cov.cov1.len == 0) return drop(cov_arena);
    src.cell_cov = cov;
    src.coverage_arena = cov_arena;
}

/// Open a baked PMTiles archive from a file path, mmap'd rather than copied — a
/// whole chart library can be open without being resident (the page cache holds the
/// working set). The mapping is released in deinit; the file must stay in place for
/// the chart's lifetime.
pub fn openPmtilesPath(io: std.Io, path: []const u8) !*Chart {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.NotFound;
    defer f.close(io);
    const st = f.stat(io) catch return error.IoFailed;
    const len: usize = @intCast(st.size);
    if (len == 0) return error.InvalidArchive;
    const map = filemap.mapReadonly(f.handle, len) catch return error.IoFailed;
    errdefer filemap.unmap(map);
    var reader = pmtiles.Reader.init(gpa, map) catch return error.InvalidArchive;
    const src = gpa.create(Chart) catch {
        reader.deinit();
        return error.OutOfMemory;
    };
    src.* = .{ .backend = .{ .reader = reader }, .data_map = map, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    src.source_path = gpa.dupe(u8, path) catch null;
    attachEmbeddedCoverage(src);
    return src;
}

// Parse (+ apply updates) + portray one cell into a CellBackend. Reads the bytes
// but does not take ownership. Portrayal failure is non-fatal (classify() fallback).
fn buildCellBackend(base: []const u8, updates: []const []const u8, dir: []const u8) ?CellBackend {
    const loaded = parseAnyCell(base, updates) orelse return null;
    // Use the parsed cell's compilation scale (S-57 DSPM CSCL, or a native S-101
    // chart's DataCoverage display scale) — `peekScale` reads only the S-57 DSPM and
    // returns 0 for native, which would mis-band a native chart in the live compositor.
    var cb = CellBackend{ .cell = loaded.cell, .cscl = loaded.cell.params.cscl };
    const pa = gpa.create(std.heap.ArenaAllocator) catch return cb;
    pa.* = std.heap.ArenaAllocator.init(gpa);
    cb.portray_arena = pa;
    // Real M_COVR data-coverage polygons for the host to report as chart coverage.
    cb.coverage = cb.cell.mcovrCoverage(pa.allocator());
    if (portrayVariantsAny(pa.allocator(), &cb.cell, loaded.adapted, dir)) |cp| {
        cb.portrayal = cp.base;
        cb.portrayal_plain = cp.plain;
        cb.portrayal_simplified = cp.simplified;
    } else |_| {}
    // Assemble geometry + its projection + per-feature bboxes ONCE (the baker's
    // per-cell caches) so live per-view rendering reuses them across the view's tiles
    // instead of re-assembling + re-projecting + re-processing every feature per tile.
    if (scene.buildGeoCache(pa.allocator(), &cb.cell)) |g| {
        cb.geo = g;
        cb.geo_world = scene.buildGeoWorld(pa.allocator(), g) catch null;
        cb.feat_bbox = scene.buildFeatBBox(pa.allocator(), &cb.cell, g) catch null;
    } else |_| {}
    return cb;
}

fn freeCellBackend(cb: *CellBackend) void {
    cb.cell.deinit();
    if (cb.portray_arena) |pa| {
        pa.deinit();
        gpa.destroy(pa);
    }
}

fn openCell(bytes: []const u8, rules_dir: ?[]const u8) ?*Chart {
    var cb = buildCellBackend(bytes, &.{}, resolveRulesDir(rules_dir)) orelse return null;
    const src = gpa.create(Chart) catch {
        freeCellBackend(&cb);
        return null;
    };
    src.* = .{ .backend = .{ .cell = cb }, .data = null, .cache = std.AutoHashMap(u64, []u8).init(gpa) };
    return src;
}

/// A single ENC cell's on-disk bytes: base .000 + its sequential .001.. update chain.
const CellFiles = struct {
    base: []u8,
    updates: [][]u8,
    fn deinit(self: *CellFiles) void {
        gpa.free(self.base);
        for (self.updates) |u| gpa.free(u);
        gpa.free(self.updates);
    }
};

/// Read a .000 cell + its .001.. updates from the cell's directory into gpa buffers.
fn readCellFiles(path: []const u8) !CellFiles {
    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = .init(gpa, .{});
    defer {
        threaded.deinit();
        gpa.destroy(threaded);
    }
    const io = threaded.io();
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    const bn = std.fs.path.basename(path);
    const base = try dir.readFileAlloc(io, bn, gpa, .unlimited);
    errdefer gpa.free(base);
    var updates = std.ArrayList([]u8).empty;
    errdefer {
        for (updates.items) |u| gpa.free(u);
        updates.deinit(gpa);
    }
    if (bn.len > 4) {
        const stem = bn[0 .. bn.len - 4]; // strip ".000"
        var u: u32 = 1;
        while (u <= 999) : (u += 1) {
            const upn = std.fmt.allocPrint(gpa, "{s}.{d:0>3}", .{ stem, u }) catch break;
            defer gpa.free(upn);
            const ub = dir.readFileAlloc(io, upn, gpa, .unlimited) catch break;
            updates.append(gpa, ub) catch {
                gpa.free(ub);
                break;
            };
        }
    }
    return .{ .base = base, .updates = try updates.toOwnedSlice(gpa) };
}

/// Bake a SINGLE .000 cell (+ updates) to a PMTiles archive over its NATIVE band's
/// zoom range (`bandZooms(bandOf(cscl))`) and nothing else — the composite model bakes
/// each cell at its own compilation scale; the stitcher combines them and handles any
/// cross-band zoom expansion. Returns the bytes (gpa-owned; free with tile57_free).
/// null = nothing baked.
///
/// The archive metadata embeds the cell's own coverage (M_COVR + cscl + date/name),
/// so the composite stitcher rebuilds the ownership partition from the baked archives
/// without re-parsing the .000. Read it back with `decodedCoverageFromArchive`.
pub fn bakeChartBytes(cell_path: []const u8, rules_dir: ?[]const u8) !?[]u8 {
    // Populate the read-only portrayal globals (feature catalogue + complex-linestyle table)
    // before portraying: without them, complex lines fall back to plain geometry and their S-52
    // linestyle is dropped from the tile. Idempotent; in the parallel batch path bakeChartsParallel
    // has already warmed up before spawning workers, so this is a no-op there (and race-free).
    warmup();
    var cf = try readCellFiles(cell_path);
    defer cf.deinit();

    // Capture coverage for the embedded sidecar (one cheap parse). The stem is the
    // ownership tie-break name — matches the coverage loader.
    var cov_arena = std.heap.ArenaAllocator.init(gpa);
    defer cov_arena.deinit();
    var coverage_json: ?[]const u8 = null;
    // Parse native-aware (S-101 or S-57): the band scale + the archive's coverage
    // sidecar both come from the real cell, so a native S-101 chart bands by its
    // DataCoverage display scale (not the S-57-misparsed cscl=0 approach default).
    var cscl: i32 = s57.peekScale(gpa, cf.base) orelse 0;
    if (parseAnyCell(cf.base, cf.updates)) |loaded| {
        var cell = loaded.cell;
        defer cell.deinit();
        cscl = cell.params.cscl;
        const stem = std.fs.path.stem(std.fs.path.basename(cell_path));
        const band: u8 = @intFromEnum(bake_enc.bandOf(cscl));
        const cc = scene.coverage.fromCell(cov_arena.allocator(), &cell, stem, band);
        coverage_json = scene.coverage.encodeJson(cov_arena.allocator(), cc) catch null;
    }

    // The cell's band window, plus the extend_min fill DOWN to z0: sub-band tiles
    // (scamin-thinned by the scene cull) let the compositor pull this cell up into
    // coarser zooms where nothing coarser covers — a harbor-only region still
    // shows land and coast at z4. No overscale above the window.
    const zr = bake_enc.bandZooms(bake_enc.bandOf(cscl));
    const cell_in = [_]ChartInput{.{ .base = cf.base, .updates = cf.updates }};
    return bakeArchive(&cell_in, resolveRulesDir(rules_dir), 0, zr.max, .mlt, true, null, null, coverage_json);
}

// ---- parallel batch cell-bake -------------------------------------------------
// Bake many cells to their own per-cell PMTiles concurrently. The engine returns BYTES only — it
// never touches an output directory; the host writes each archive into the cache it manages. Each
// concurrent bake holds a whole cell's parse + portray + raster working set, so `workers` is a
// MEMORY bound (keep it small), not a core count.

// MAX_BAKE_WORKERS is a hard ceiling on batch-bake threads; the host normally passes far fewer.
const MAX_BAKE_WORKERS = 32;

const BakeCtx = struct {
    next: std.atomic.Value(usize),
    paths: []const []const u8,
    rules_dir: ?[]const u8,
    out: []?[]u8,
};

fn bakeCellWorker(ctx: *BakeCtx) void {
    // One cell per thread. Tile generation is serial (bake_enc.serialFor), so a worker is exactly
    // one thread — W workers stay W threads, never W x cpus.
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.paths.len) return;
        ctx.out[i] = bakeChartBytes(ctx.paths[i], ctx.rules_dir) catch null;
    }
}

/// Bake each cell in `paths` (a .000 path; its .001.. updates auto-read) to its own native-scale
/// PMTiles bytes IN PARALLEL across up to `workers` threads, writing cell i's archive to out[i]
/// (caller owns it — free each with freeBytes) or leaving it null when that cell produced nothing
/// or failed. out.len must equal paths.len. Race-free: warms up the process globals first, then
/// each bakeChartBytes is independent (thread-safe allocator, thread-local portrayal context).
/// `workers` is clamped to [1, min(paths.len, MAX_BAKE_WORKERS)] and is a MEMORY bound.
pub fn bakeChartsParallel(paths: []const []const u8, rules_dir: ?[]const u8, workers: usize, out: []?[]u8) void {
    std.debug.assert(out.len == paths.len);
    for (out) |*o| o.* = null;
    if (paths.len == 0) return;
    warmup(); // idempotent — populate the read-only globals before any worker touches them
    var ctx = BakeCtx{ .next = std.atomic.Value(usize).init(0), .paths = paths, .rules_dir = rules_dir, .out = out };
    var n = @min(@max(workers, 1), paths.len);
    if (n > MAX_BAKE_WORKERS) n = MAX_BAKE_WORKERS;
    if (n <= 1) return bakeCellWorker(&ctx);
    var threads: [MAX_BAKE_WORKERS]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < n - 1) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, bakeCellWorker, .{&ctx}) catch break;
    }
    bakeCellWorker(&ctx); // this thread participates too
    for (threads[0..spawned]) |t| t.join();
}

// ---- parallel batch cell-bake TO FILES (the host-cache path) -------------------
// Same parallel bake, but the engine WRITES each cell's PMTiles to a caller-provided path and
// frees it right after — so a host never holds N archives (peak memory ~ the worker count). The
// APP owns the cache: it names every out_path, so distinct library consumers don't clash. A
// <out_path>.sha content-hash sidecar is written beside each archive for the host's cache token.

/// Progress callback: invoked with (ctx, done, total) after each cell is processed, so a host can
/// drive an import progress bar. It may be called CONCURRENTLY from worker threads (done arrives
/// monotonically per fetch but can be delivered slightly out of order), so the callback must be
/// thread-safe. Null to skip.
///
/// Returns true to continue, false to CANCEL the bake: no further cell is picked up, but the cells
/// already in flight run to completion (a bake is not interruptible mid-cell), so the bake unwinds
/// within ~one cell's bake time rather than instantly. Every archive already written is complete, so
/// the incremental skip in bakeTree lets a later run resume. A host with no cancel returns true.
pub const BakeProgress = ?*const fn (?*anyopaque, u32, u32) callconv(.c) bool;

const BakeFileCtx = struct {
    next: std.atomic.Value(usize),
    in_paths: []const []const u8,
    out_paths: []const []const u8,
    rules_dir: ?[]const u8,
    io: std.Io,
    ok: []bool,
    progress: BakeProgress,
    progress_ctx: ?*anyopaque,
    done: std.atomic.Value(u32),
    /// Set when a progress callback returned false; every worker drains out at its next cell.
    cancel: std.atomic.Value(bool),
};

fn bakeOneToFile(ctx: *BakeFileCtx, i: usize) void {
    const arc = (bakeChartBytes(ctx.in_paths[i], ctx.rules_dir) catch null) orelse return;
    defer freeBytes(arc);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ctx.out_paths[i], .data = arc }) catch return;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(arc, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var sha_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    if (std.fmt.bufPrint(&sha_buf, "{s}.sha", .{ctx.out_paths[i]})) |sha_path| {
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = sha_path, .data = &hex }) catch {};
    } else |_| {}
    ctx.ok[i] = true;
}

fn bakeFileWorker(ctx: *BakeFileCtx) void {
    while (true) {
        if (ctx.cancel.load(.monotonic)) return; // a peer's progress callback said stop
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.in_paths.len) return;
        bakeOneToFile(ctx, i);
        const d = ctx.done.fetchAdd(1, .monotonic) + 1; // attempted count (smooth progress)
        if (ctx.progress) |cb| {
            if (!cb(ctx.progress_ctx, d, @intCast(ctx.in_paths.len))) {
                ctx.cancel.store(true, .monotonic);
                return;
            }
        }
    }
}

/// Bake each in_paths[i] in parallel (up to `workers` threads) and WRITE its PMTiles to
/// out_paths[i] (plus an <out_path>.sha content-hash sidecar), freeing each archive right after
/// the write — so the host never holds N archives (peak memory ~ the worker count). The app owns
/// the cache and names every out_path. `progress(progress_ctx, done, total)` fires (serialised)
/// after each cell and may CANCEL by returning false (see BakeProgress). Race-free (warms up first;
/// each bake is independent). Returns the count written — fewer than in_paths.len when cancelled.
pub fn bakeChartsToFiles(io: std.Io, in_paths: []const []const u8, out_paths: []const []const u8, rules_dir: ?[]const u8, workers: usize, progress: BakeProgress, progress_ctx: ?*anyopaque) usize {
    std.debug.assert(out_paths.len == in_paths.len);
    if (in_paths.len == 0) return 0;
    warmup();
    const ok = gpa.alloc(bool, in_paths.len) catch return 0;
    defer gpa.free(ok);
    @memset(ok, false);
    var ctx = BakeFileCtx{ .next = std.atomic.Value(usize).init(0), .in_paths = in_paths, .out_paths = out_paths, .rules_dir = rules_dir, .io = io, .ok = ok, .progress = progress, .progress_ctx = progress_ctx, .done = std.atomic.Value(u32).init(0), .cancel = std.atomic.Value(bool).init(false) };
    var n = @min(@max(workers, 1), in_paths.len);
    if (n > MAX_BAKE_WORKERS) n = MAX_BAKE_WORKERS;
    if (n <= 1) {
        bakeFileWorker(&ctx);
    } else {
        var threads: [MAX_BAKE_WORKERS]std.Thread = undefined;
        var spawned: usize = 0;
        while (spawned < n - 1) : (spawned += 1) threads[spawned] = std.Thread.spawn(.{}, bakeFileWorker, .{&ctx}) catch break;
        bakeFileWorker(&ctx);
        for (threads[0..spawned]) |t| t.join();
    }
    var count: usize = 0;
    for (ok) |o| {
        if (o) count += 1;
    }
    return count;
}

/// Walk `in_dir` for S-57 base cells (*.000) and bake each, IN PARALLEL, to the SAME relative path
/// under `out_dir` with a .pmtiles extension (in_dir/d1/US4CT1AA.000 -> out_dir/d1/US4CT1AA.pmtiles),
/// plus an <out>.sha sidecar. Output subdirs are created as needed. `in_dir` is the source ENC data;
/// `out_dir` is the caller's own cache (it owns the location + names, so consumers don't clash). The
/// engine writes + frees each archive, so the host never holds N in memory. `progress` fires per
/// cell (serialised) for an import progress bar and may CANCEL by returning false (see
/// BakeProgress). INCREMENTAL: a cell whose mirrored archive is already at least as new as its whole
/// input (.000 + update chain) is skipped, so a re-run over an unchanged tree bakes nothing — and a
/// run that resumes a cancelled one only bakes what the cancel left undone. Returns the count baked
/// THIS run; errors if `in_dir` is unreadable.
pub fn bakeTree(io: std.Io, in_dir: []const u8, out_dir: []const u8, rules_dir: ?[]const u8, workers: usize, progress: BakeProgress, progress_ctx: ?*anyopaque) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var in_paths = std.ArrayList([]const u8).empty;
    var out_paths = std.ArrayList([]const u8).empty;

    var dir = try std.Io.Dir.cwd().openDir(io, in_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".000")) continue;
        const in_path = std.fs.path.join(a, &.{ in_dir, entry.path }) catch continue;
        // Mirror the relative path, swapping .000 -> .pmtiles.
        const rel_noext = entry.path[0 .. entry.path.len - ".000".len];
        const out_rel = std.fmt.allocPrint(a, "{s}.pmtiles", .{rel_noext}) catch continue;
        const out_path = std.fs.path.join(a, &.{ out_dir, out_rel }) catch continue;
        // Incremental: skip a cell whose mirrored archive already exists and is at least as new as
        // its whole input — the .000 AND its update chain (.001, .002, …) — so re-baking a provider
        // (adding a district, or dropping a new .001 update) only re-bakes what actually changed.
        if (fileModNs(io, out_path)) |out_ns| {
            if (newestInputNs(io, in_path)) |in_ns| {
                if (out_ns >= in_ns) continue;
            }
        }
        if (std.fs.path.dirname(out_path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
        in_paths.append(a, in_path) catch continue;
        out_paths.append(a, out_path) catch continue;
    }
    if (in_paths.items.len == 0) return 0;
    return bakeChartsToFiles(io, in_paths.items, out_paths.items, rules_dir, workers, progress, progress_ctx);
}

/// The file's modification time in nanoseconds, or null if it doesn't exist / can't be statted.
fn fileModNs(io: std.Io, path: []const u8) ?i96 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    return st.mtime.nanoseconds;
}

/// The NEWEST mtime across a cell's whole input: its base .000 (`in_path`) and its contiguous
/// update chain <stem>.001, .002, … (stopping at the first gap — the same discovery readCellFiles
/// uses to apply them). Null if the base is missing. So a freshly-dropped .001 makes the cell newer
/// than a previously-baked archive, forcing a re-bake.
fn newestInputNs(io: std.Io, in_path: []const u8) ?i96 {
    var newest = fileModNs(io, in_path) orelse return null;
    const dir = std.fs.path.dirname(in_path) orelse ".";
    const bn = std.fs.path.basename(in_path);
    if (bn.len > 4) {
        const stem = bn[0 .. bn.len - 4]; // strip ".000"
        var u: u32 = 1;
        while (u <= 999) : (u += 1) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const up = std.fmt.bufPrint(&buf, "{s}{s}{s}.{d:0>3}", .{ dir, std.fs.path.sep_str, stem, u }) catch break;
            const ns = fileModNs(io, up) orelse break; // gap → the chain ends here
            if (ns > newest) newest = ns;
        }
    }
    return newest;
}

// Build the embedded-catalogue symbol + area-fill store for a view render (in `a`;
// deinit when done) and register the complex-linestyle table (idempotent,
// gpa-backed — the registry outlives the render, shared with any later bake).
fn viewSymbolStore(a: std.mem.Allocator, palette: render.resolve.PaletteId) !*sprite.CatalogStore {
    const css_name = switch (palette) {
        .day => "daySvgStyle",
        .dusk => "duskSvgStyle",
        .night => "nightSvgStyle",
    };
    var css_data: []const u8 = "";
    for (embedded_assets.css) |e| {
        if (std.mem.eql(u8, e.name, css_name)) css_data = e.bytes;
    }
    const sym_srcs = try a.alloc(sprite.SvgSrc, embedded_assets.symbols.len);
    for (embedded_assets.symbols, 0..) |e, i| sym_srcs[i] = .{ .id = e.name, .svg = e.bytes };
    const fill_srcs = try a.alloc(sprite.AreaFillSrc, embedded_assets.areafills.len);
    for (embedded_assets.areafills, 0..) |e, i| fill_srcs[i] = .{ .id = e.name, .xml = e.bytes };
    const store = try sprite.CatalogStore.init(a, sym_srcs, fill_srcs, css_data);

    var ls_srcs = std.ArrayList(style.LineStyleSrc).empty;
    defer ls_srcs.deinit(gpa);
    for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
    scene.linestyle.registerLinestylesXml(gpa, ls_srcs.items);
    return store;
}

/// Build the GPU-scene atlases into `a`: the sprite-symbol cell map (same
/// deterministic pack the host uploads) and the SDF glyph map. Cell SIZES are
/// geometry, palette-independent, so the day stylesheet gives UVs that match the
/// host's DEFAULT_CSS atlas PNG.
fn buildGpuAtlases(a: std.mem.Allocator) !struct { sprites: render.gpu.SpriteAtlas, glyphs: render.gpu.GlyphAtlas } {
    var css_data: []const u8 = "";
    for (embedded_assets.css) |e| {
        if (std.mem.eql(u8, e.name, "daySvgStyle")) css_data = e.bytes;
    }
    const sym_srcs = try a.alloc(sprite.SvgSrc, embedded_assets.symbols.len);
    for (embedded_assets.symbols, 0..) |e, i| sym_srcs[i] = .{ .id = e.name, .svg = e.bytes };
    const fill_srcs = try a.alloc(sprite.AreaFillSrc, embedded_assets.areafills.len);
    for (embedded_assets.areafills, 0..) |e, i| fill_srcs[i] = .{ .id = e.name, .xml = e.bytes };

    // sprite atlas: reuse the same builder tile57_bake_sprite_mln does, so the
    // cell rects are byte-for-byte the layout the host's PNG carries.
    var atlas = try sprite.spriteMln(a, sym_srcs, fill_srcs, css_data, &[_][]const u8{});
    var sprites = render.gpu.SpriteAtlas{ .width = atlas.width, .height = atlas.height };
    var cit = atlas.cells.iterator();
    while (cit.next()) |e| {
        const r = e.value_ptr.*;
        try sprites.cells.put(a, e.key_ptr.*, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    }

    // SDF glyph atlas: the same em_px/pad tile57_bake_glyph_sdf bakes.
    const cps = try sprite.glyph.defaultCodepoints(a);
    const gatlas = try sprite.glyph.build(a, render.font.notosans, cps, 32.0, 6);
    var glyphs = render.gpu.GlyphAtlas{ .em_px = gatlas.em_px };
    var git = gatlas.glyphs.iterator();
    while (git.next()) |e| {
        const g = e.value_ptr.*;
        try glyphs.glyphs.put(a, e.key_ptr.*, .{
            .u0 = g.u0, .v0 = g.v0, .u1 = g.u1, .v1 = g.v1,
            .off_x = g.off_x, .off_y = g.off_y, .w = g.w, .h = g.h, .advance = g.advance,
        });
    }
    return .{ .sprites = sprites, .glyphs = glyphs };
}

// ---- per-tile GEOMETRY cache (internal; the host never sees tiles) ----------
//
// The GPU scene is portray-once-then-translate: the host asks for a whole view
// and just uploads + draws it, but a pan/zoom that re-asks must not re-tessellate
// every tile. So tile57 caches each tile's built GEOMETRY (fills, lines, sprites,
// soundings — NO text) keyed by (handle, z, x, y), and assembles a view by
// concatenating cached tiles, portraying only the newly-exposed ones. LABELS are
// NOT cached here: they declutter across the whole view every call (see the label
// pass in renderGpuScene), so a name never repeats across a tile seam.
const GeomKey = struct { handle: usize, z: u8, x: u32, y: u32 };
const GeomEntry = struct { scene: *GpuScene, gen: u64 };
var g_geom: std.AutoHashMapUnmanaged(GeomKey, GeomEntry) = .empty;
var g_geom_gen: u64 = 0;
var g_geom_hash: u64 = 0;
var g_geom_hash_set = false;
const GEOM_CACHE_MAX = 1024;

/// Content hash of the geometry-affecting settings. A byte hash won't do —
/// Settings has slice fields (whose pointers move per call) and floats (whose
/// padding is undefined) — so hash field by field, slices by content.
fn settingsHash(s: *const render.resolve.Settings) u64 {
    var h = std.hash.Wyhash.init(0);
    inline for (@typeInfo(render.resolve.Settings).@"struct".fields) |f| hashVal(&h, @field(s.*, f.name));
    return h.final();
}
fn hashVal(h: *std.hash.Wyhash, v: anytype) void {
    switch (@typeInfo(@TypeOf(v))) {
        // A float's bit pattern is well-defined for a given value; only the
        // struct's PADDING was the byte-hash hazard, and this walks fields.
        .float => h.update(std.mem.asBytes(&v)),
        .optional => if (v) |vv| {
            h.update(&[_]u8{1});
            hashVal(h, vv);
        } else h.update(&[_]u8{0}),
        .pointer => |p| if (p.size == .slice) h.update(std.mem.sliceAsBytes(v)) else h.update(std.mem.asBytes(&v)),
        .@"enum" => h.update(std.mem.asBytes(&@intFromEnum(v))),
        .bool => h.update(&[_]u8{@intFromBool(v)}),
        else => h.update(std.mem.asBytes(&v)), // ints, packed structs, int arrays
    }
}

/// Drop the whole geometry cache when the geometry-affecting settings change —
/// contours, units, size scales, palette (via scheme) all rebake a tile.
fn geomInvalidate(s: *const render.resolve.Settings) void {
    const hh = settingsHash(s);
    if (g_geom_hash_set and hh == g_geom_hash) return;
    var it = g_geom.valueIterator();
    while (it.next()) |e| e.scene.deinit();
    g_geom.clearRetainingCapacity();
    g_geom_hash = hh;
    g_geom_hash_set = true;
}

/// Drop every cached tile belonging to a handle — called when it closes, so a
/// later handle reusing the address never reads its geometry.
pub fn geomDropHandle(handle: usize) void {
    var doomed = std.ArrayList(GeomKey).empty;
    defer doomed.deinit(gpa);
    var it = g_geom.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.handle == handle) doomed.append(gpa, kv.key_ptr.*) catch {};
    }
    for (doomed.items) |k| {
        if (g_geom.fetchRemove(k)) |kv| kv.value.scene.deinit();
    }
}

fn geomGet(key: GeomKey) ?*GpuScene {
    if (g_geom.getPtr(key)) |e| {
        g_geom_gen += 1;
        e.gen = g_geom_gen;
        return e.scene;
    }
    return null;
}

fn geomPut(key: GeomKey, sc: *GpuScene) void {
    g_geom_gen += 1;
    g_geom.put(gpa, key, .{ .scene = sc, .gen = g_geom_gen }) catch {
        sc.deinit();
        return;
    };
    if (g_geom.count() <= GEOM_CACHE_MAX) return;
    // Evict the least-recently-used (linear scan; the map is bounded).
    var oldest_key: ?GeomKey = null;
    var oldest_gen: u64 = std.math.maxInt(u64);
    var it = g_geom.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.gen < oldest_gen) {
            oldest_gen = kv.value_ptr.gen;
            oldest_key = kv.key_ptr.*;
        }
    }
    if (oldest_key) |ok| {
        if (g_geom.fetchRemove(ok)) |kv| kv.value.scene.deinit();
    }
}

// The GPU-scene atlases are static (per catalogue + font), so they build ONCE per
// process and every render — single chart or composed — shares them, rather than
// each Chart rasterizing its own. Process-lifetime; never freed.
var g_atlas_state: std.atomic.Value(u8) = .init(0);
var g_atlas_sprites: render.gpu.SpriteAtlas = .{ .width = 0, .height = 0 };
var g_atlas_glyphs: render.gpu.GlyphAtlas = .{};
var g_atlas_ok = false;

fn sharedGpuAtlases() struct { ?*const render.gpu.SpriteAtlas, ?*const render.gpu.GlyphAtlas } {
    while (g_atlas_state.load(.acquire) != 2) {
        if (g_atlas_state.cmpxchgStrong(@as(u8, 0), @as(u8, 1), .acquire, .monotonic) == null) {
            const aa = gpa.create(std.heap.ArenaAllocator) catch {
                g_atlas_state.store(2, .release);
                break;
            };
            aa.* = std.heap.ArenaAllocator.init(gpa);
            if (buildGpuAtlases(aa.allocator())) |built| {
                g_atlas_sprites = built.sprites;
                g_atlas_glyphs = built.glyphs;
                g_atlas_ok = true;
            } else |_| {
                aa.deinit();
                gpa.destroy(aa);
            }
            g_atlas_state.store(2, .release);
            break;
        }
        std.atomic.spinLoopHint();
    }
    if (!g_atlas_ok) return .{ null, null };
    return .{ &g_atlas_sprites, &g_atlas_glyphs };
}

// ---- compose-backed view renders --------------------------------------------
//
// The compositor is the tile source; these are its VIEW backends: compose every
// covering tile on demand (seams stitched through the ownership partition) and
// replay it through the native S-52 pixel path — the same scene Chart.renderView
// replays from a single archive, but across the whole composed set.

/// Render a VIEW over a runtime compositor to PNG / PDF / a callback canvas
/// (per `output`; bytes are gpa-owned, freeBytes — empty for the callback
/// output). The mariner's live-swappable settings evaluate at render time.
pub fn renderComposeView(src: *compose_mod.ComposeSource, lon: f64, lat: f64, zoom: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, output: render.pixel.Output, cb_table: ?*const render.cb_canvas.CCanvas) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const colors = try sharedColors();
    const store = try viewSymbolStore(a, palette);
    defer store.deinit();

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var ps = render.pixel.PixelSurface.initView(a, colors, palette, settings, zoom, w, h, pt, tile.EXTENT);
    ps.store = store.asStore();
    ps.output = output;
    ps.cb = cb_table;

    var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
    const surf = ps.asSurface();
    try surf.beginScene(vt.z);
    while (vt.next()) |t| {
        const res = src.tile(a, t.z, t.x, t.y) catch continue;
        const bytes = res.tile orelse continue;
        const layers = mlt.decode(a, bytes) catch continue; // the compositor serves raw MLT
        ps.setOrigin(t.origin_x, t.origin_y);
        scene.replayTile(a, surf, layers) catch return error.TileGen;
    }
    return surf.endScene(gpa) catch error.TileGen;
}

/// The VIEW-level, GLOBALLY-decluttered TEXT pass over a compositor: gather the
/// label candidates of every covering tile into ONE shared declutter pool and emit
/// ONLY the survivors (via draw_text_str / draw_text) — no fills, lines, symbols or
/// soundings. For a tile-renderer host that already draws geometry + symbols from
/// its own per-tile cache (tile57_compose_tile / a per-tile surface) but needs
/// labels decluttered ACROSS tile and CHART seams, which a per-tile pass cannot do.
/// World anchors + coordinate space are identical to renderComposeSurfaceView, so
/// text overlays the cached geometry with no re-projection.
///
/// Candidates memoize per tile (render/labelcache.zig), so a tile is composed,
/// decoded and portrayed ONCE per portrayal identity: a repeat call at any centre,
/// zoom or rotation over tiles already seen does no portrayal work at all — it
/// re-resolves the memoized candidates against the new view. Changing the palette
/// or any mariner setting retires the memo.
pub fn renderComposeLabels(src: *compose_mod.ComposeSource, lon: f64, lat: f64, zoom: f64, rotation_rad: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const colors = try sharedColors();
    var vs = render.vector.VectorSurface.init(a, colors, palette, settings, cb);
    vs.view_zoom = zoom; // scale at which labels declutter
    vs.view_rotation = rotation_rad; // contour-label uprightness + screen-frame declutter
    vs.labels_only = true; // the view-level text pass draws no geometry
    const surf = vs.asSurface();

    const cache = try composeLabelCache(src);
    cache.retarget(gpa, render.labelcache.epochOf(palette, settings));

    // The symbol store is built on the FIRST cache miss and not at all when the
    // view is fully memoized — for a compositor it is a per-call parse of the whole
    // SVG catalogue, which on a settled view is the largest cost left. A labels-only
    // walk never draws a symbol, but the store's init also registers the complex
    // linestyle catalogue the portrayal walk reads, so a MISS must still have it.
    var store: ?*sprite.CatalogStore = null;
    defer if (store) |s| s.deinit();

    const Portray = struct {
        src: *compose_mod.ComposeSource,
        a: std.mem.Allocator,
        surf: render.surface.Surface,
        vs: *render.vector.VectorSurface,
        store: *?*sprite.CatalogStore,
        palette: render.resolve.PaletteId,

        fn portray(self: *const @This(), z: u8, x: u32, y: u32) !void {
            if (self.store.* == null) {
                self.store.* = try viewSymbolStore(self.a, self.palette);
                self.vs.store = self.store.*.?.asStore();
            }
            const res = try self.src.tile(self.a, z, x, y);
            const bytes = res.tile orelse return;
            const layers = try mlt.decode(self.a, bytes);
            try scene.replayTile(self.a, self.surf, layers);
        }
    };
    const ctx = Portray{ .src = src, .a = a, .surf = surf, .vs = &vs, .store = &store, .palette = palette };

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
    try surf.beginScene(vt.z);
    while (vt.next()) |t| {
        for (tileCandidates(cache, &vs, t.z, t.x, t.y, &ctx)) |c| try vs.pushCandidate(c);
    }
    _ = try surf.endScene(a);
}

/// The label-candidate memo hung off a compositor, created on first use and
/// released when the source closes (compose.ComposeSource.render_cache).
fn composeLabelCache(src: *compose_mod.ComposeSource) !*render.labelcache.Cache {
    if (src.render_cache) |p| return @ptrCast(@alignCast(p));
    const c = try gpa.create(render.labelcache.Cache);
    c.* = .{};
    src.render_cache = c;
    src.render_cache_free = freeComposeLabelCache;
    return c;
}

fn freeComposeLabelCache(p: *anyopaque) void {
    const c: *render.labelcache.Cache = @ptrCast(@alignCast(p));
    c.deinit(gpa);
    gpa.destroy(c);
}

/// One tile's label candidates for a labels-only walk: the memo's, or — on a miss —
/// the ones `ctx.portray` shapes, captured into the new cache entry's own arena so
/// they outlive this call. An empty result is cached like any other (a tile with no
/// labels must not be re-portrayed either), and a tile that cannot be stored simply
/// contributes nothing, mirroring the decoded-tile memo's OOM behaviour.
fn tileCandidates(cache: *render.labelcache.Cache, vs: *render.vector.VectorSurface, z: u8, x: u32, y: u32, ctx: anytype) []const render.vector.Candidate {
    if (cache.get(z, x, y)) |hit| return hit;
    const e = cache.newEntry(gpa) orelse return &.{};
    var cap = render.vector.Capture{ .a = e.arena.allocator() };
    vs.capture = &cap;
    defer vs.capture = null;
    vs.setTile(z, x, y);
    ctx.portray(z, x, y) catch {};
    return cache.store(gpa, z, x, y, e, cap.list.items) orelse &.{};
}

/// renderComposeView's GPU-vector twin: the SAME composed view emitted as a
/// WORLD-SPACE tagged stream to the C surface callback (see render/vector.zig).
pub fn renderComposeSurfaceView(src: *compose_mod.ComposeSource, lon: f64, lat: f64, zoom: f64, rotation_rad: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const colors = try sharedColors();
    const store = try viewSymbolStore(a, palette);
    defer store.deinit();

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var vs = render.vector.VectorSurface.init(a, colors, palette, settings, cb);
    vs.store = store.asStore();
    vs.view_zoom = zoom; // scale at which labels/symbols declutter
    vs.view_rotation = rotation_rad; // contour-label uprightness + screen-frame declutter

    var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
    const surf = vs.asSurface();
    try surf.beginScene(vt.z);
    while (vt.next()) |t| {
        const res = src.tile(a, t.z, t.x, t.y) catch continue;
        const bytes = res.tile orelse continue;
        const layers = mlt.decode(a, bytes) catch continue;
        vs.setTile(t.z, t.x, t.y);
        scene.replayTile(a, surf, layers) catch continue;
    }
    _ = try surf.endScene(a);
}

/// The composed DRAW-READY twin: geometry cached per tile, labels decluttered
/// across the whole view — see Chart.renderGpuScene, with the compositor as the
/// tile source so a host draws a chart LIBRARY without owning a scene. Result
/// owns its arena (GpuScene.deinit).
pub fn renderComposeGpuScene(src: *compose_mod.ComposeSource, lon: f64, lat: f64, zoom: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings) !*GpuScene {
    geomInvalidate(settings);
    const out = try gpa.create(GpuScene);
    errdefer gpa.destroy(out);
    out.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .scene = undefined };
    errdefer out.arena.deinit();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var parts = std.ArrayList(render.gpu.Scene).empty;
    var cands = std.ArrayList(render.gpu.LabelCandidate).empty;

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
    while (vt.next()) |t| {
        const key = GeomKey{ .handle = @intFromPtr(src), .z = t.z, .x = t.x, .y = t.y };
        if (geomGet(key) == null) {
            const built = renderComposeTileGpuScene(src, t.z, t.x, t.y, palette, settings) catch continue;
            geomPut(key, built);
        }
        if (geomGet(key)) |g| {
            parts.append(sa, g.scene) catch {};
            cands.appendSlice(sa, g.candidates) catch {};
        }
    }

    parts.append(sa, try render.gpu.assembleLabels(sa, sa, cands.items, zoom, settings.ignore_scamin)) catch {};

    out.scene = try render.gpu.assemble(out.arena.allocator(), parts.items);
    return out;
}

/// ONE composed tile into a draw-ready scene — the per-tile twin of
/// renderComposeGpuScene, for a host that caches tiles (see Chart.renderTileGpuScene).
pub fn renderComposeTileGpuScene(src: *compose_mod.ComposeSource, z: u8, x: u32, y: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings) !*GpuScene {
    const out = try gpa.create(GpuScene);
    errdefer gpa.destroy(out);
    out.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .scene = undefined };
    errdefer out.arena.deinit();

    const colors = try sharedColors();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const store = try viewSymbolStore(sa, palette);
    defer store.deinit();

    var gs = try render.gpu.GpuSurface.init(sa, colors, palette, settings, @floatFromInt(z));
    defer gs.deinit();
    gs.store = store.asStore();
    const atl = sharedGpuAtlases();
    gs.sprites = atl[0];
    gs.glyphs = atl[1];
    gs.setTile(z, x, y);
    const surf = gs.asSurface();
    try surf.beginScene(z);
    if (src.tile(sa, z, x, y) catch null) |res| {
        if (res.tile) |bytes| {
            if (mlt.decode(sa, bytes)) |layers| {
                scene.replayTile(sa, surf, layers) catch {};
            } else |_| {}
        }
    }
    out.scene = try gs.build(out.arena.allocator());
    out.candidates = try gs.takeCandidates(out.arena.allocator());
    return out;
}

/// Cursor object-query over a runtime compositor (the S-52 §10.8 pick across the
/// whole composed set — seams included): replay the composed tile covering
/// (lon,lat) at the view zoom through a QuerySurface and report each feature the
/// point falls in via `cb`.
pub fn composeQueryPoint(src: *compose_mod.ComposeSource, lon: f64, lat: f64, zoom: f64, cb: *const render.query.QueryCb) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Query the tile at the VIEW zoom, clamped into the served range: its features
    // are already SCAMIN-bucketed to what's displayed and the pick radius (tile
    // units) maps to a constant on-screen distance.
    const zc = std.math.clamp(@round(zoom), @as(f64, @floatFromInt(src.minz)), @as(f64, @floatFromInt(src.loop_max)));
    const z: u8 = @intFromFloat(zc);
    const world = tile.lonLatToWorld(lon, lat);
    const n = std.math.exp2(@as(f64, @floatFromInt(z)));
    const tx: u32 = @intFromFloat(@floor(world[0] * n));
    const ty: u32 = @intFromFloat(@floor(world[1] * n));
    const local = tile.project(lon, lat, z, tx, ty, tile.EXTENT);
    var qs = render.query.QuerySurface{
        .qx = @floatFromInt(local.x),
        .qy = @floatFromInt(local.y),
        .radius = 96.0, // ~6 px at native tile scale
        .view_zoom = zoom, // raw view zoom for the SCAMIN cull
        .cb = cb,
    };
    const surf = qs.asSurface();
    try surf.beginScene(z);
    const res = src.tile(a, z, tx, ty) catch return;
    const bytes = res.tile orelse return;
    const layers = mlt.decode(a, bytes) catch return;
    scene.replayTile(a, surf, layers) catch return;
    _ = surf.endScene(a) catch {};
}

/// The metadata JSON blob of a PMTiles archive (decompressed), duped into `a`, or null
/// if the archive carries none. For a host to read the embedded scamin / coverage
/// without a full open. This engine writes metadata uncompressed; gzip is handled for
/// archives from another writer.
pub fn pmtilesMetadata(a: std.mem.Allocator, archive: []const u8) !?[]u8 {
    var r = try pmtiles.Reader.init(a, archive);
    defer r.deinit();
    const h = r.header;
    if (h.metadata_length == 0) return null;
    const raw = r.bytes[@intCast(h.metadata_offset)..][0..@intCast(h.metadata_length)];
    return switch (h.internal_compression) {
        .none => try a.dupe(u8, raw),
        .gzip => try gzip.decompress(a, raw),
        else => null,
    };
}

/// Decode the per-cell coverage embedded in a baked per-cell archive's metadata, or
/// null if absent. The whole result (rings + strings) is allocated in `a`. The
/// composite stitcher calls this over each cell's archive to rebuild the ownership
/// partition without re-parsing the source .000.
pub fn decodedCoverageFromArchive(a: std.mem.Allocator, archive: []const u8) !?scene.coverage.ChartCoverage {
    const json = (try pmtilesMetadata(a, archive)) orelse return null;
    return scene.coverage.decodeFromMetadata(a, json);
}

/// Populate the process-global READ-ONLY registries (the S-100 feature catalogue and
/// the complex-linestyle table) on the CALLING thread. Both are idempotent lazy-init
/// and thereafter read-only. A host that renders or bakes cells from multiple threads
/// MUST call this once on its main thread before spawning them: then concurrent
/// bake/render is race-free (the allocator is thread-safe, the portrayal context is
/// thread-local, and these two globals are already populated so nobody writes them).
pub fn warmup() void {
    catalogue.warmUp();
    var ls_srcs = std.ArrayList(style.LineStyleSrc).empty;
    defer ls_srcs.deinit(gpa);
    for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
    scene.linestyle.registerLinestylesXml(gpa, ls_srcs.items);
}

// Parallel open worker: peek each cell's band + bbox and copy its bytes.
const OpenWork = struct {
    inputs: []const ChartInput,
    out: []LazyCell,
    ok: []bool,

    fn run(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        _ = scratch; // persistent outputs go straight to `gpa`
        const c: *OpenWork = @ptrCast(@alignCast(uptr));
        const in = c.inputs[i];
        const meta = s57.peekMeta(gpa, in.base) orelse return;
        const bbox = meta.bounds orelse return;
        const base = gpa.dupe(u8, in.base) catch return;
        var ups: [][]u8 = &.{};
        if (in.updates.len > 0) {
            const arr = gpa.alloc([]u8, in.updates.len) catch {
                gpa.free(base);
                return;
            };
            var k: usize = 0;
            while (k < in.updates.len) : (k += 1) {
                arr[k] = gpa.dupe(u8, in.updates[k]) catch {
                    for (arr[0..k]) |u| gpa.free(u);
                    gpa.free(arr);
                    gpa.free(base);
                    return;
                };
            }
            ups = arr;
        }
        const name = if (in.name.len > 0) (gpa.dupe(u8, in.name) catch "") else "";
        c.out[i] = .{ .base = base, .updates = ups, .name = name, .bbox = bbox, .band = bake_enc.bandOf(meta.cscl), .cscl = meta.cscl };
        c.ok[i] = true;
    }
};

/// The public chart handle. Open with `openBytes`/`openCharts`; release with
/// `deinit`.
pub const Chart = struct {
    backend: Backend,
    data: ?[]u8 = null, // owned archive bytes (PMTiles backend only)
    /// Where this chart was opened from, when it came from a path (owned; null
    /// for byte-backed opens). The compositor uses it to find the ownership
    /// partition sidecar the bake wrote next to the archives, so a host never
    /// has to know that file exists.
    source_path: ?[]u8 = null,
    cache: std.AutoHashMap(u64, []u8), // tile key -> MVT bytes (owned)
    cache_max: usize = 8192,
    // Emit the per-feature pick-report attrs (s57/cell) on live-generated tiles.
    // Defaults ON; the C ABI open can turn it off for lean tiles. (No effect on a
    // PMTiles/reader backend — those tiles are already baked.)
    pick_attrs: bool = true,
    // The tile encoding reported for a cell backend (via tileType); fixed at MVT.
    // A PMTiles/reader backend ignores it — stored tiles serve verbatim in their
    // baked encoding (see tileType).
    tile_format: scene.TileFormat = .mvt,
    // The per-cell coverage decoded from the opened archive's metadata (name, date,
    // cscl, bbox, M_COVR rings) — read back by coverage()/nativeScale(), and what a
    // compositor borrows to place this chart in the ownership partition. Storage
    // lives in coverage_arena (freed in deinit).
    cell_cov: ?cell_coverage.ChartCoverage = null,
    coverage_arena: ?*std.heap.ArenaAllocator = null,
    // A path-opened archive is mmap'd rather than copied (never fully resident);
    // released in deinit. Bytes-opened archives use `data` instead.
    data_map: ?[]align(std.heap.page_size_min) const u8 = null,

    // ---- view-render caches (reader backend) --------------------------------
    // A view re-render replays mostly the SAME tiles (a pan reveals one strip, a
    // zoom settle swaps one band), and profiling put ~35% of every re-render in
    // gzip+MLT decode and another ~3% in re-building the palette and re-parsing
    // the SVG symbol catalogue. All of it is immutable for an open handle, so it
    // caches here: decoded tiles in a generation-evicted map (each entry owns its
    // arena, so eviction frees exactly one tile), colors + per-palette symbol
    // stores in one handle-lifetime arena. Same threading rule as the handle:
    // NOT synchronized.
    view_tiles: std.AutoHashMapUnmanaged(u64, *DecodedTile) = .empty,
    view_gen: u64 = 0,
    view_tiles_max: usize = 192, // > the ~96 tiles of one 2560px view: never evicts mid-render
    view_arena: ?*std.heap.ArenaAllocator = null,
    view_stores: [3]?*sprite.CatalogStore = .{ null, null, null },
    // The view label pass's per-tile candidate memo (render/labelcache.zig): what
    // lets renderSurfaceLabels run on every view-settle instead of re-portraying
    // the covering tiles each time. Bounded and released with the handle.
    label_cache: render.labelcache.Cache = .{},

    /// Open a source from in-memory bytes. `fmt` selects the backend (`.auto`
    /// sniffs PMTiles then S-57); `rules_dir` is the S-101 rules dir for cells
    /// (null = TILE57_S101_RULES env, else the vendored default). Bytes are copied.
    pub fn openBytes(bytes: []const u8, fmt: Format, rules_dir: ?[]const u8) !*Chart {
        if (fmt == .pmtiles or fmt == .auto) {
            const copy = try gpa.dupe(u8, bytes);
            if (openPmtiles(copy)) |src| return src; // openPmtiles freed `copy` on failure
            if (fmt == .pmtiles) return error.InvalidArchive;
        }
        return openCell(bytes, rules_dir) orelse error.InvalidCell;
    }

    /// Open an ENC_ROOT as a multi-cell source: cells are indexed cheaply (band +
    /// bbox) in parallel and parsed/portrayed lazily per tile. All bytes are
    /// copied. Errors if no cell's header parses.
    pub fn openCharts(cells_in: []const ChartInput, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart {
        if (cells_in.len == 0) return error.NotFound;
        const dir = resolveRulesDir(rules_dir);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);

        const tmp = try gpa.alloc(LazyCell, cells_in.len);
        defer gpa.free(tmp);
        const ok = try gpa.alloc(bool, cells_in.len);
        defer gpa.free(ok);
        @memset(ok, false);

        var ow = OpenWork{ .inputs = cells_in, .out = tmp, .ok = ok };
        bake_enc.parallelFor(gpa, cells_in.len, &ow, OpenWork.run);

        var valid: usize = 0;
        for (ok) |k| {
            if (k) valid += 1;
        }
        if (valid == 0) return error.InvalidCell; // cells provided, but none parsed

        const cells = gpa.alloc(LazyCell, valid) catch {
            for (tmp, ok) |*lc, k| if (k) lazyFreeCell(lc);
            return error.OutOfMemory;
        };
        var j: usize = 0;
        for (tmp, ok) |lc, k| if (k) {
            cells[j] = lc;
            j += 1;
        };

        const src = gpa.create(Chart) catch {
            for (cells) |*lc| lazyFreeCell(lc);
            gpa.free(cells);
            return error.OutOfMemory;
        };
        src.* = .{
            .backend = .{ .cells = .{ .cells = cells, .rules_dir = dir_copy } },
            .cache = std.AutoHashMap(u64, []u8).init(gpa),
            .pick_attrs = pick_attrs,
        };
        return src;
    }

    /// Open an ENC_ROOT as a streaming multi-cell source: the host supplies cheap
    /// per-cell metadata (bbox + scale) up front and a `reader` callback that
    /// returns a cell's bytes on demand. Cell bytes are read only when a tile
    /// needs them and freed on LRU eviction, so the host holds the working set's
    /// bytes — not the whole ENC_ROOT. No bytes are read at open. Errors if empty.
    pub fn openChartsStreaming(metas: []const ChartMeta, reader: ChartReadFn, user: ?*anyopaque, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart {
        if (metas.len == 0) return error.NotFound;
        const dir = resolveRulesDir(rules_dir);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);
        const cells = try gpa.alloc(LazyCell, metas.len);
        for (metas, 0..) |m, i| {
            cells[i] = .{
                .base = &.{},
                .updates = &.{},
                .bbox = .{ m.west, m.south, m.east, m.north },
                .band = bake_enc.bandOf(m.cscl),
                .cscl = m.cscl,
                .streaming = true,
                .index = i,
            };
        }
        const src = gpa.create(Chart) catch {
            gpa.free(cells);
            return error.OpenFailed;
        };
        src.* = .{
            .backend = .{ .cells = .{ .cells = cells, .rules_dir = dir_copy, .reader = reader, .reader_user = user } },
            .cache = std.AutoHashMap(u64, []u8).init(gpa),
            .pick_attrs = pick_attrs,
        };
        return src;
    }

    /// Open an on-disk ENC_ROOT directory (or a single `.000` file) as a STREAMING
    /// chart: enumerate the cells (CATALOG.031, else a `*.000` walk; single file =
    /// one cell), peek each one's bbox + compilation scale at open, then read cell
    /// bytes on demand for the working set (freed on LRU eviction) — the caller hands
    /// over only a path and the engine holds only what tiles need. The chart owns the
    /// retained Io + Dir for its lifetime (freed in deinit). Errors if no cell parses.
    pub fn openPath(path: []const u8, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart {
        const threaded = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(threaded);
        threaded.* = .init(gpa, .{});
        errdefer threaded.deinit();
        const io = threaded.io();

        const single_file = !isDirIo(io, path);
        const dir_path = if (single_file) (std.fs.path.dirname(path) orelse ".") else path;
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        errdefer dir.close(io);

        var metas = std.ArrayList(ChartMeta).empty;
        defer metas.deinit(gpa);
        var paths = std.ArrayList([]u8).empty;
        errdefer {
            for (paths.items) |p| gpa.free(p);
            paths.deinit(gpa);
        }

        if (single_file) {
            try addPathCell(io, dir, std.fs.path.basename(path), &metas, &paths);
        } else if (dir.readFileAlloc(io, "CATALOG.031", gpa, .unlimited)) |cbytes| {
            defer gpa.free(cbytes);
            var carena = std.heap.ArenaAllocator.init(gpa);
            defer carena.deinit();
            if (s57.parseCatalog(carena.allocator(), cbytes)) |entries| {
                for (entries) |e| {
                    if (e.is_cell) try addPathCell(io, dir, e.path, &metas, &paths);
                }
            }
        } else |_| {
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".000")) continue;
                try addPathCell(io, dir, entry.path, &metas, &paths);
            }
        }
        if (metas.items.len == 0) return error.OpenFailed;

        // Reuse the streaming backend with the internal file reader; the returned
        // Chart owns the PathCtx (Io + Dir + paths) via ls.path_ctx, freed in deinit.
        const src = try openChartsStreaming(metas.items, pathRead, null, rules_dir, pick_attrs);
        errdefer src.deinit();
        const ctx = try gpa.create(PathCtx);
        errdefer gpa.destroy(ctx);
        ctx.* = .{ .threaded = threaded, .io = io, .dir = dir, .paths = try paths.toOwnedSlice(gpa) };
        src.backend.cells.reader_user = ctx;
        src.backend.cells.path_ctx = ctx;
        return src;
    }

    /// Release the source and all cached tiles.
    const DecodedTile = struct {
        arena: std.heap.ArenaAllocator,
        layers: []tiles_mvt.DecodedLayer,
        gen: u64,
    };

    fn viewTileKey(z: u8, x: u32, y: u32) u64 {
        return (@as(u64, z) << 58) | (@as(u64, x) << 29) | @as(u64, y);
    }

    /// The decoded layers of stored tile (z,x,y) through the handle's decoded-tile
    /// cache. Null when the archive has no tile there (not cached — the miss is a
    /// directory binary-search, no decompression). Entries stay valid until this
    /// handle either evicts them (never within one render; see view_tiles_max) or
    /// closes.
    fn viewTileLayers(self: *Chart, rd: *pmtiles.Reader, z: u8, x: u32, y: u32) ?[]tiles_mvt.DecodedLayer {
        const key = viewTileKey(z, x, y);
        self.view_gen += 1;
        if (self.view_tiles.getPtr(key)) |ep| {
            ep.*.gen = self.view_gen;
            return ep.*.layers;
        }
        const e = gpa.create(DecodedTile) catch return null;
        e.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .layers = &.{}, .gen = self.view_gen };
        const ea = e.arena.allocator();
        const is_mlt = rd.header.tile_type == .mlt;
        const ok = blk: {
            const bytes = (rd.getTile(ea, z, x, y) catch break :blk false) orelse break :blk false;
            e.layers = (if (is_mlt) mlt.decode(ea, bytes) else tiles_mvt.decode(ea, bytes)) catch break :blk false;
            break :blk true;
        };
        if (!ok) {
            e.arena.deinit();
            gpa.destroy(e);
            return null;
        }
        if (self.view_tiles.count() >= self.view_tiles_max) {
            // Evict the least-recently-touched entry (linear scan; the map is small).
            var oldest_key: u64 = 0;
            var oldest_gen: u64 = std.math.maxInt(u64);
            var it = self.view_tiles.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.*.gen < oldest_gen) {
                    oldest_gen = kv.value_ptr.*.gen;
                    oldest_key = kv.key_ptr.*;
                }
            }
            if (self.view_tiles.fetchRemove(oldest_key)) |kv| {
                kv.value.arena.deinit();
                gpa.destroy(kv.value);
            }
        }
        self.view_tiles.put(gpa, key, e) catch {
            e.arena.deinit();
            gpa.destroy(e);
            return null;
        };
        return e.layers;
    }

    /// The handle-lifetime arena backing the cached palette + symbol stores.
    fn viewArena(self: *Chart) !std.mem.Allocator {
        if (self.view_arena == null) {
            const va = try gpa.create(std.heap.ArenaAllocator);
            va.* = std.heap.ArenaAllocator.init(gpa);
            self.view_arena = va;
        }
        return self.view_arena.?.allocator();
    }

    /// The palette colour tables (all three palettes). Parsed once per PROCESS, not
    /// once per handle: they are a pure function of the embedded colour profile — the
    /// same bytes for every chart — and read-only once parsed. A host that opens and
    /// purges chart handles as it walks a quilt (a large chart set makes that constant)
    /// was re-parsing the whole profile on every open, which showed up as a visible
    /// slice of frame time under the tile path.
    fn viewColorsRef(_: *Chart) !*render.resolve.Colors {
        return sharedColors();
    }

    /// The palette's symbol store, built once per handle per palette (the SVG
    /// catalogue parse dominated the old per-render setup).
    fn viewStoreFor(self: *Chart, palette: render.resolve.PaletteId) !*sprite.CatalogStore {
        const idx: usize = @intFromEnum(palette);
        if (self.view_stores[idx]) |st| return st;
        const va = try self.viewArena();
        const st = try viewSymbolStore(va, palette);
        self.view_stores[idx] = st;
        return st;
    }

    pub fn deinit(self: *Chart) void {
        geomDropHandle(@intFromPtr(self));
        switch (self.backend) {
            .reader => |*r| r.deinit(),
            .cell => |*cb| freeCellBackend(cb),
            .cells => |*ls| {
                for (ls.cells) |*lc| lazyFreeCell(lc);
                gpa.free(ls.cells);
                gpa.free(ls.rules_dir);
                if (ls.path_ctx) |c| c.deinit();
            },
        }
        var it = self.cache.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        self.cache.deinit();
        if (self.data) |d| gpa.free(d);
        if (self.source_path) |sp| gpa.free(sp);
        if (self.data_map) |m| filemap.unmap(m);
        if (self.coverage_arena) |ca| {
            ca.deinit();
            gpa.destroy(ca);
        }
        {
            var vit = self.view_tiles.valueIterator();
            while (vit.next()) |v| {
                v.*.arena.deinit();
                gpa.destroy(v.*);
            }
            self.view_tiles.deinit(gpa);
        }
        self.label_cache.deinit(gpa);
        if (self.view_arena) |va| {
            va.deinit();
            gpa.destroy(va);
        }
        gpa.destroy(self);
    }

    /// The resolved backend format (after an `.auto` sniff).
    pub fn format(self: *Chart) Format {
        return switch (self.backend) {
            .reader => .pmtiles,
            .cell, .cells => .s57,
        };
    }

    /// The cell's M_COVR(CATCOV=1) data-coverage polygons (polygon -> rings ->
    /// lon/lat points), for the host to report as chart coverage so OpenCPN quilts
    /// gaps to coarser cells. A live cell parses it; a per-cell baked PMTiles
    /// surfaces the copy embedded in its archive metadata. Null when absent.
    pub fn coverage(self: *const Chart) ?[]const []const []const s57.LonLat {
        if (self.cell_cov) |cc| {
            if (cc.cov1.len > 0) return cc.cov1;
        }
        return switch (self.backend) {
            .cell => |*c| if (c.coverage.len > 0) c.coverage else null,
            else => null,
        };
    }

    /// The cell's compilation scale (DSPM CSCL, 1:N), so the host doesn't derive an
    /// over-detailed one from the 0..18 zoom range. A live cell parses it; a per-cell
    /// baked PMTiles reads the copy in its archive metadata. 0 = unknown (derive from
    /// the zoom band instead).
    pub fn nativeScale(self: *const Chart) i32 {
        if (self.cell_cov) |cc| {
            if (cc.cscl != 0) return cc.cscl;
        }
        return switch (self.backend) {
            .cell => |*c| c.cscl,
            else => 0,
        };
    }

    /// The chart's PMTiles reader, for a compositor to borrow (null unless this is an
    /// archive-backed chart). The reader lives inside the chart: the chart must outlive
    /// every borrower, and a borrower's reads must not run concurrently with this
    /// chart's own render/query calls (no internal lock).
    pub fn pmtilesReader(self: *Chart) ?*pmtiles.Reader {
        return switch (self.backend) {
            .reader => |*r| r,
            else => null,
        };
    }

    /// The per-cell coverage embedded in the opened archive's metadata (name, date,
    /// cscl, bbox, M_COVR rings), or null if the archive carries none. Borrows the
    /// chart's storage.
    pub fn decodedCoverage(self: *const Chart) ?cell_coverage.ChartCoverage {
        return self.cell_cov;
    }

    /// The tile encoding this chart's tiles carry: a PMTiles backend reports its
    /// archive's stored tile type (tiles serve verbatim); a cell backend reports its
    /// live generation format (`tile_format`). Non-vector archive types (png/…) are
    /// reported as-is.
    pub fn tileType(self: *Chart) pmtiles.TileType {
        return switch (self.backend) {
            .reader => |r| r.header.tile_type,
            .cell, .cells => switch (self.tile_format) {
                .mvt => .mvt,
                .mlt => .mlt,
            },
        };
    }

    /// Min/max zoom served (PMTiles: archive range; cell: 0..18).
    pub fn zoomRange(self: *Chart) struct { min: u8, max: u8 } {
        return switch (self.backend) {
            .reader => |r| .{ .min = r.header.min_zoom, .max = r.header.max_zoom },
            .cell, .cells => .{ .min = 0, .max = 18 },
        };
    }

    /// Bitmask of navigational bands present (bit r = band rank r has a cell;
    /// 0=berthing/finest … 5=overview/coarsest). 0 for a single cell / PMTiles.
    pub fn bands(self: *Chart) u32 {
        return switch (self.backend) {
            .cells => |ls| blk: {
                var mask: u32 = 0;
                for (ls.cells) |lc| mask |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(lc.band)));
                break :blk mask;
            },
            else => 0,
        };
    }

    /// Geographic bounds [west, south, east, north] degrees, or null if unknown /
    /// degenerate / near-global. PMTiles -> archive bounds; cell -> data extent.
    pub fn bounds(self: *Chart) ?[4]f64 {
        var b: [4]f64 = undefined;
        switch (self.backend) {
            .reader => |r| {
                const h = r.header;
                if (h.min_lon_e7 == 0 and h.max_lon_e7 == 0 and h.min_lat_e7 == 0 and h.max_lat_e7 == 0) return null;
                b = .{
                    @as(f64, @floatFromInt(h.min_lon_e7)) / 1e7,
                    @as(f64, @floatFromInt(h.min_lat_e7)) / 1e7,
                    @as(f64, @floatFromInt(h.max_lon_e7)) / 1e7,
                    @as(f64, @floatFromInt(h.max_lat_e7)) / 1e7,
                };
            },
            .cell => |*cb| b = cb.cell.bounds() orelse return null,
            .cells => |ls| {
                if (ls.cells.len == 0) return null;
                var u: [4]f64 = .{ 1e9, 1e9, -1e9, -1e9 };
                for (ls.cells) |lc| {
                    u[0] = @min(u[0], lc.bbox[0]);
                    u[1] = @min(u[1], lc.bbox[1]);
                    u[2] = @max(u[2], lc.bbox[2]);
                    u[3] = @max(u[3], lc.bbox[3]);
                }
                b = u;
            },
        }
        if (b[2] - b[0] <= 1e-9 or b[3] - b[1] <= 1e-9) return null;
        if (b[2] - b[0] >= 359.0 or b[3] - b[1] >= 179.0) return null;
        return b;
    }

    /// A good initial camera on real data (the smallest chart cell near the data
    /// median, at a navigable zoom), for when fitting the whole source would zoom
    /// out uselessly. null for PMTiles / single cell (use fit-to-bounds).
    pub fn anchor(self: *Chart) ?struct { lat: f64, lon: f64, zoom: f64 } {
        switch (self.backend) {
            .cells => |ls| {
                var cnt: usize = 0;
                for (ls.cells) |lc| {
                    if (lc.bbox[2] - lc.bbox[0] < 10.0 and lc.bbox[3] - lc.bbox[1] < 10.0) cnt += 1;
                }
                if (cnt == 0) return null;
                const lons = gpa.alloc(f64, cnt) catch return null;
                defer gpa.free(lons);
                const lats = gpa.alloc(f64, cnt) catch return null;
                defer gpa.free(lats);
                var i: usize = 0;
                for (ls.cells) |lc| {
                    if (lc.bbox[2] - lc.bbox[0] >= 10.0 or lc.bbox[3] - lc.bbox[1] >= 10.0) continue;
                    lons[i] = (lc.bbox[0] + lc.bbox[2]) / 2;
                    lats[i] = (lc.bbox[1] + lc.bbox[3]) / 2;
                    i += 1;
                }
                std.mem.sort(f64, lons, {}, std.sort.asc(f64));
                std.mem.sort(f64, lats, {}, std.sort.asc(f64));
                const mlon = lons[cnt / 2];
                const mlat = lats[cnt / 2];
                var bestArea: f64 = 1e30;
                var best: ?[4]f64 = null;
                var nbd: f64 = 1e30;
                var nearest: ?[4]f64 = null;
                for (ls.cells) |lc| {
                    if (lc.bbox[2] - lc.bbox[0] >= 10.0 or lc.bbox[3] - lc.bbox[1] >= 10.0) continue;
                    const cx = (lc.bbox[0] + lc.bbox[2]) / 2;
                    const cy = (lc.bbox[1] + lc.bbox[3]) / 2;
                    const d = (cx - mlon) * (cx - mlon) + (cy - mlat) * (cy - mlat);
                    if (d < nbd) {
                        nbd = d;
                        nearest = lc.bbox;
                    }
                    if (@abs(cx - mlon) > 3.0 or @abs(cy - mlat) > 3.0) continue;
                    const area = (lc.bbox[2] - lc.bbox[0]) * (lc.bbox[3] - lc.bbox[1]);
                    if (area < bestArea) {
                        bestArea = area;
                        best = lc.bbox;
                    }
                }
                const b = best orelse nearest orelse return null;
                return .{ .lon = (b[0] + b[2]) / 2, .lat = (b[1] + b[3]) / 2, .zoom = 12 };
            },
            else => return null,
        }
    }

    /// Render a VIEW of the chart — centre + fractional zoom + pixel size —
    /// through the native S-52 pixel path: real portrayal, vector symbols,
    /// labels + declutter over the whole canvas. Returns PNG bytes (gpa-owned;
    /// free with freeBytes). Cell-backed sources only; a baked PMTiles source
    /// has no portrayal to render from (bundle-sourced rendering is future work).
    pub fn renderView(self: *Chart, lon: f64, lat: f64, zoom: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, output: render.pixel.Output, cb_table: ?*const render.cb_canvas.CCanvas) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const colors = try self.viewColorsRef();
        const store = try self.viewStoreFor(palette);

        // Continuous scaling between integer zooms; the host applies physical
        // calibration / @2x via settings.size_scale.
        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var ps = render.pixel.PixelSurface.initView(a, colors, palette, settings, zoom, w, h, pt, @import("tiles").tile.EXTENT);
        ps.store = store.asStore();
        ps.output = output;
        ps.cb = cb_table;

        switch (self.backend) {
            .reader => |*rd| {
                // Bundle-sourced replay: decode each covering baked tile and
                // re-emit it as Surface calls. Lossy by design — the bake-time
                // portrayal context is frozen — but the live-swappable props
                // (danger depth, sounding composition/unit) re-evaluate here.
                var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
                const surf = ps.asSurface();
                try surf.beginScene(vt.z);
                while (vt.next()) |t| {
                    const layers = self.viewTileLayers(rd, t.z, t.x, t.y) orelse continue;
                    ps.setOrigin(t.origin_x, t.origin_y);
                    scene.replayTile(a, surf, layers) catch return error.TileGen;
                }
                return surf.endScene(gpa) catch error.TileGen;
            },
            .cell => |*cb| {
                const one = [_]scene.CellRef{.{
                    .cell = &cb.cell,
                    .portrayal = cb.portrayal,
                    .portrayal_plain = cb.portrayal_plain,
                    .portrayal_simplified = cb.portrayal_simplified,
                }};
                return scene.generateView(&ps, a, gpa, &one, lon, lat, zoom, self.pick_attrs) catch error.TileGen;
            },
            // Baked tiles only: a multi-cell live view render would re-implement
            // the baker's composition — bake, then render the archive.
            .cells => return error.TileGen,
        }
    }

    /// renderView's GPU-vector twin: drive a VectorSurface over the same view
    /// tiles, emitting a WORLD-SPACE tagged stream to the C surface callback
    /// (see render/vector.zig). Live for both a baked bundle (.reader tile
    /// replay) and a live cell (.cell portrayal). No bytes are produced.
    pub fn renderSurfaceView(self: *Chart, lon: f64, lat: f64, zoom: f64, rotation_rad: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const colors = try self.viewColorsRef();
        const store = try self.viewStoreFor(palette);

        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var vs = render.vector.VectorSurface.init(a, colors, palette, settings, cb);
        vs.store = store.asStore();
        vs.view_zoom = zoom; // scale at which labels/symbols declutter
        vs.view_rotation = rotation_rad; // contour-label uprightness + screen-frame declutter
        const surf = vs.asSurface();

        var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
        try surf.beginScene(vt.z);
        switch (self.backend) {
            .reader => |*rd| {
                while (vt.next()) |t| {
                    const layers = self.viewTileLayers(rd, t.z, t.x, t.y) orelse continue;
                    vs.setTile(t.z, t.x, t.y);
                    scene.replayTile(a, surf, layers) catch continue;
                }
            },
            .cell => |*cb2| {
                const one = [_]scene.CellRef{cellRef(cb2)};
                while (vt.next()) |t| {
                    vs.setTile(t.z, t.x, t.y);
                    scene.appendTile(surf, a, &one, t.z, t.x, t.y, self.pick_attrs) catch continue;
                }
            },
            .cells => return error.Unsupported,
        }
        _ = try surf.endScene(a);
    }

    /// renderSurfaceView's DRAW-READY twin: instead of calling back per draw, it
    /// returns triangulated geometry already in S-52 paint order, packed into
    /// ranges a host draws one pipeline at a time (render/gpu.zig).
    ///
    /// A GPU host must batch by pipeline, which destroys the order the engine
    /// emitted in — so a callback host has to rebuild paint order, and to do that
    /// it grows a tessellator, a class taxonomy and a copy of the S-52 ordering
    /// rule. That is a second scene, free to drift from this one, and it did: the
    /// same OVERRADAR bug had to be fixed on both sides. This call exists so a
    /// host owns no scene and knows no S-52.
    ///
    /// PORTRAY ONCE, TRANSLATE. Geometry is cached per tile (see the geometry
    /// cache above), so a pan/zoom that re-asks re-tessellates only the newly
    /// exposed tiles and memcpys the rest. LABELS are the exception: they
    /// declutter across the WHOLE view every call — a name must not repeat across
    /// a tile seam — so they are portrayed fresh (cheap: shape + box, no
    /// tessellation) and assembled on top. The result owns its arena; release it
    /// with `GpuScene.deinit`.
    ///
    /// No rotation parameter, deliberately: geometry stays north-up in absolute
    /// world coordinates and the host applies the view rotation, so a course-up
    /// view that turns continuously never rebuilds.
    pub fn renderGpuScene(self: *Chart, lon: f64, lat: f64, zoom: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings) !*GpuScene {
        geomInvalidate(settings);
        const out = try gpa.create(GpuScene);
        errdefer gpa.destroy(out);
        out.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .scene = undefined };
        errdefer out.arena.deinit();

        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        // Each covering tile's cached geometry scene + its cached label candidates.
        var parts = std.ArrayList(render.gpu.Scene).empty;
        var cands = std.ArrayList(render.gpu.LabelCandidate).empty;

        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
        while (vt.next()) |t| {
            const key = GeomKey{ .handle = @intFromPtr(self), .z = t.z, .x = t.x, .y = t.y };
            if (geomGet(key) == null) {
                const built = self.renderTileGpuScene(t.z, t.x, t.y, palette, settings) catch continue;
                geomPut(key, built);
            }
            if (geomGet(key)) |g| {
                parts.append(sa, g.scene) catch {};
                cands.appendSlice(sa, g.candidates) catch {};
            }
        }

        // Labels: box every candidate at the view zoom and declutter across the
        // WHOLE view at once, so a name never repeats across a seam. Cheap — no
        // re-shaping (that was cached per tile).
        parts.append(sa, try render.gpu.assembleLabels(sa, sa, cands.items, zoom, settings.ignore_scamin)) catch {};

        out.scene = try render.gpu.assemble(out.arena.allocator(), parts.items);
        return out;
    }

    /// ONE tile portrayed into a draw-ready scene — the per-tile twin of
    /// renderGpuScene, so a host CACHES each tile's buffers and pan/zoom becomes a
    /// pure GPU transform of cached tiles, portraying only newly-exposed ones. The
    /// scene is in absolute-world coordinates (the host draws every cached tile
    /// with one camera), and declutter is PER-TILE at the tile's native zoom, so a
    /// label may repeat across a seam — a host wanting cross-tile text runs the
    /// view-level label pass on top. Result owns its arena (GpuScene.deinit).
    pub fn renderTileGpuScene(self: *Chart, z: u8, x: u32, y: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings) !*GpuScene {
        const out = try gpa.create(GpuScene);
        errdefer gpa.destroy(out);
        out.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .scene = undefined };
        errdefer out.arena.deinit();

        const colors = try self.viewColorsRef();
        const store = try self.viewStoreFor(palette);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        var gs = try render.gpu.GpuSurface.init(sa, colors, palette, settings, @floatFromInt(z));
        defer gs.deinit();
        gs.store = store.asStore();
        const atl = sharedGpuAtlases();
        gs.sprites = atl[0];
        gs.glyphs = atl[1];
        gs.setTile(z, x, y);
        const surf = gs.asSurface();
        try surf.beginScene(z);
        switch (self.backend) {
            .reader => |*rd| {
                if (self.viewTileLayers(rd, z, x, y)) |layers| scene.replayTile(sa, surf, layers) catch {};
            },
            .cell => |*cb2| {
                const one = [_]scene.CellRef{cellRef(cb2)};
                scene.appendTile(surf, sa, &one, z, x, y, self.pick_attrs) catch {};
            },
            .cells => return error.Unsupported,
        }
        out.scene = try gs.build(out.arena.allocator());
        out.candidates = try gs.takeCandidates(out.arena.allocator());
        return out;
    }

    /// The VIEW-level, GLOBALLY-decluttered TEXT pass — renderSurfaceView's twin
    /// that emits ONLY the surviving labels (draw_text_str / draw_text), no fills,
    /// lines, symbols or soundings. For a tile-renderer host that draws geometry +
    /// symbols from its own per-tile cache (renderSurfaceTile / tile57_chart_tile_surface)
    /// but needs labels decluttered ACROSS tile seams, which the per-tile pass cannot
    /// do. Same world anchors + coordinate space as renderSurfaceView, so the text
    /// overlays the cached geometry directly.
    ///
    /// Label candidates memoize per tile (render/labelcache.zig): a tile is portrayed
    /// ONCE per portrayal identity, and a repeat call at any centre, zoom or rotation
    /// over tiles already seen only re-resolves those candidates against the new view.
    /// Changing the palette or any mariner setting retires the memo. Live for a baked
    /// bundle (.reader) and a live cell (.cell); .cells is unsupported (bake, then
    /// compose).
    pub fn renderSurfaceLabels(self: *Chart, lon: f64, lat: f64, zoom: f64, rotation_rad: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const colors = try self.viewColorsRef();
        var vs = render.vector.VectorSurface.init(a, colors, palette, settings, cb);
        vs.view_zoom = zoom; // scale at which labels declutter
        vs.view_rotation = rotation_rad; // contour-label uprightness + screen-frame declutter
        vs.labels_only = true; // the view-level text pass draws no geometry
        const surf = vs.asSurface();
        // A labels-only walk draws no symbol, but the store's init also registers the
        // complex-linestyle catalogue the portrayal walk reads. It is memoized per
        // handle, so this is a hash lookup after the first view.
        vs.store = (try self.viewStoreFor(palette)).asStore();

        self.label_cache.retarget(gpa, render.labelcache.epochOf(palette, settings));

        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
        try surf.beginScene(vt.z);
        switch (self.backend) {
            .reader => |*rd| {
                const Portray = struct {
                    self: *Chart,
                    rd: *pmtiles.Reader,
                    a: std.mem.Allocator,
                    surf: render.surface.Surface,
                    fn portray(p: *const @This(), z: u8, x: u32, y: u32) !void {
                        const layers = p.self.viewTileLayers(p.rd, z, x, y) orelse return;
                        try scene.replayTile(p.a, p.surf, layers);
                    }
                };
                const ctx = Portray{ .self = self, .rd = rd, .a = a, .surf = surf };
                while (vt.next()) |t| {
                    for (tileCandidates(&self.label_cache, &vs, t.z, t.x, t.y, &ctx)) |c| try vs.pushCandidate(c);
                }
            },
            .cell => |*cb2| {
                const Portray = struct {
                    one: [1]scene.CellRef,
                    a: std.mem.Allocator,
                    surf: render.surface.Surface,
                    pick_attrs: bool,
                    fn portray(p: *const @This(), z: u8, x: u32, y: u32) !void {
                        try scene.appendTile(p.surf, p.a, &p.one, z, x, y, p.pick_attrs);
                    }
                };
                const ctx = Portray{ .one = .{cellRef(cb2)}, .a = a, .surf = surf, .pick_attrs = self.pick_attrs };
                while (vt.next()) |t| {
                    for (tileCandidates(&self.label_cache, &vs, t.z, t.x, t.y, &ctx)) |c| try vs.pushCandidate(c);
                }
            },
            .cells => return error.Unsupported,
        }
        _ = try surf.endScene(a);
    }

    /// Portray a SINGLE tile (z, x, y) to a CSurface — the per-tile twin of
    /// renderSurfaceView. Emits the same WORLD-SPACE tagged draw calls, but for
    /// exactly one tile instead of every tile under a view, so a host can portray +
    /// tessellate each tile ONCE, cache the geometry, and compose tiles itself
    /// (the MapLibre model). Decluttering is per-tile (labels resolve within the
    /// tile), so a host that wants cross-tile label suppression must still do a
    /// separate view-level text pass. `view_zoom` is the tile's own zoom.
    pub fn renderSurfaceTile(self: *Chart, z: u8, x: u32, y: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const colors = try self.viewColorsRef();
        const store = try self.viewStoreFor(palette);

        var vs = render.vector.VectorSurface.init(a, colors, palette, settings, cb);
        vs.store = store.asStore();
        vs.view_zoom = @floatFromInt(z); // declutter at the tile's native zoom
        const surf = vs.asSurface();

        try surf.beginScene(z);
        switch (self.backend) {
            .reader => |*rd| {
                if (self.viewTileLayers(rd, z, x, y)) |layers| {
                    vs.setTile(z, x, y);
                    scene.replayTile(a, surf, layers) catch {};
                }
            },
            .cell => |*cb2| {
                const one = [_]scene.CellRef{.{
                    .cell = &cb2.cell,
                    .portrayal = cb2.portrayal,
                    .portrayal_plain = cb2.portrayal_plain,
                    .portrayal_simplified = cb2.portrayal_simplified,
                    .geo = cb2.geo,
                    .geo_world = cb2.geo_world,
                    .feat_bbox = cb2.feat_bbox,
                }};
                vs.setTile(z, x, y);
                scene.appendTile(surf, a, &one, z, x, y, self.pick_attrs) catch {};
            },
            .cells => return error.Unsupported,
        }
        _ = try surf.endScene(a);
    }

    /// Cursor object-query: replay the finest tile covering (lon,lat) through a
    /// QuerySurface and report each feature the point falls in (class + S-57
    /// attribute JSON + source cell) via `cb`. Used for the S-52 §10.8 pick.
    pub fn queryPoint(self: *Chart, lon: f64, lat: f64, zoom: f64, cb: *const render.query.QueryCb) !void {
        const t = @import("tiles").tile;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // Query the tile at the VIEW zoom, not the finest: its features are already
        // SCAMIN-bucketed to what's displayed, the tile exists (it's what's drawn),
        // and the pick radius (tile units) maps to a constant on-screen distance.
        const zr = self.zoomRange();
        const zc = std.math.clamp(@round(zoom), @as(f64, @floatFromInt(zr.min)), @as(f64, @floatFromInt(zr.max)));
        const z: u8 = @intFromFloat(zc);
        const world = t.lonLatToWorld(lon, lat);
        const n = std.math.exp2(@as(f64, @floatFromInt(z)));
        const tx: u32 = @intFromFloat(@floor(world[0] * n));
        const ty: u32 = @intFromFloat(@floor(world[1] * n));
        const local = t.project(lon, lat, z, tx, ty, t.EXTENT);
        var qs = render.query.QuerySurface{
            .qx = @floatFromInt(local.x),
            .qy = @floatFromInt(local.y),
            .radius = 96.0, // ~6 px at native tile scale
            .view_zoom = zoom, // raw view zoom for the SCAMIN cull
            .cb = cb,
        };
        const surf = qs.asSurface();
        try surf.beginScene(z);
        switch (self.backend) {
            .reader => |*rd| {
                const is_mlt = rd.header.tile_type == .mlt;
                const bytes = (rd.getTile(a, z, tx, ty) catch return) orelse return;
                if (bytes.len == 0) return;
                const layers = if (is_mlt)
                    @import("tiles").mlt.decode(a, bytes) catch return
                else
                    @import("tiles").mvt.decode(a, bytes) catch return;
                scene.replayTile(a, surf, layers) catch return;
            },
            .cell => |*cb2| {
                const one = [_]scene.CellRef{.{
                    .cell = &cb2.cell,
                    .portrayal = cb2.portrayal,
                    .portrayal_plain = cb2.portrayal_plain,
                    .portrayal_simplified = cb2.portrayal_simplified,
                }};
                scene.appendTile(surf, a, &one, z, tx, ty, self.pick_attrs) catch return;
            },
            .cells => return,
        }
        _ = surf.endScene(a) catch {};
    }

    /// Render a VIEW as ASCII art — renderView's shape on the text surface:
    /// one Unicode character per terminal cell (cols x rows), optional
    /// ANSI-256 color. Returns UTF-8 bytes, one '\n'-terminated row per grid
    /// row (gpa-owned; free with freeBytes). Same backends as renderView.
    pub fn renderAscii(self: *Chart, lon: f64, lat: f64, zoom: f64, cols: u32, rows: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.Settings, ansi: bool) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // ANSI mode resolves tokens through the same embedded colour profile
        // the pixel path uses; plain mode never consults it. No symbol store
        // and no complex-linestyle table: the ASCII surface lowers symbol
        // NAMES to glyphs itself, and complex linestyles degrading to the
        // generic dashed stroke is exactly the fidelity a text grid carries.
        const colors = try sharedColors();
        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var as = render.ascii.AsciiSurface.initView(a, colors, palette, settings, zoom, cols, rows, pt, @import("tiles").tile.EXTENT);
        as.ansi = ansi;

        switch (self.backend) {
            .reader => |*rd| {
                // Bundle-sourced replay, exactly like renderView.
                var vt = scene.ViewTiles.init(lon, lat, zoom, as.w_px, as.h_px, as.px_per_tile);
                const surf = as.asSurface();
                try surf.beginScene(vt.z);
                const is_mlt = rd.header.tile_type == .mlt;
                while (vt.next()) |t| {
                    const bytes = (rd.getTile(a, t.z, t.x, t.y) catch continue) orelse continue;
                    const layers = if (is_mlt)
                        @import("tiles").mlt.decode(a, bytes) catch continue
                    else
                        @import("tiles").mvt.decode(a, bytes) catch continue;
                    as.setOrigin(t.origin_x, t.origin_y);
                    scene.replayTile(a, surf, layers) catch return error.TileGen;
                }
                return surf.endScene(gpa) catch error.TileGen;
            },
            .cell => |*cb| {
                const one = [_]scene.CellRef{.{
                    .cell = &cb.cell,
                    .portrayal = cb.portrayal,
                    .portrayal_plain = cb.portrayal_plain,
                    .portrayal_simplified = cb.portrayal_simplified,
                }};
                return scene.generateView(&as, a, gpa, &one, lon, lat, zoom, self.pick_attrs) catch error.TileGen;
            },
            // Baked tiles only: a multi-cell live view render would re-implement
            // the baker's composition — bake, then render the archive.
            .cells => return error.TileGen,
        }
    }

    /// The chart's per-cell metadata as a JSON array:
    /// [{"name","scale","edition","update","issueDate","agency","bbox"?}, …].
    /// DSID fields reflect the applied update chain; bbox is the cell's
    /// geometry extent, omitted when none parses. Returns null when the chart
    /// has no cells (a PMTiles chart carries no cell files — its manifest is
    /// the host-side sidecar). gpa-owned; free with freeBytes.
    pub fn chartsJson(self: *Chart) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var infos = std.ArrayList(s57.CellInfo).empty;
        switch (self.backend) {
            .reader => return null,
            .cell => |*cb| {
                // A bytes-open keeps only the parsed cell: read the identity
                // from its merged DSID + params.
                const d = cb.cell.dsid;
                const ext = std.fs.path.extension(d.dsnm);
                try infos.append(a, .{
                    .name = d.dsnm[0 .. d.dsnm.len - ext.len],
                    .edition = d.edtn,
                    .update = d.updn,
                    .issue_date = d.isdt,
                    .agency = d.agen,
                    .scale = cb.cell.params.cscl,
                    .bounds = cb.cell.bounds(),
                });
            },
            .cells => |*ls| {
                for (ls.cells) |*lc| {
                    if (lc.base.len > 0) {
                        if (s57.peekCellInfo(a, lc.base, lc.updates)) |ci| try infos.append(a, ci);
                    } else if (lc.cell) |*c| {
                        const d = c.dsid;
                        const ext = std.fs.path.extension(d.dsnm);
                        try infos.append(a, .{
                            .name = d.dsnm[0 .. d.dsnm.len - ext.len],
                            .edition = d.edtn,
                            .update = d.updn,
                            .issue_date = d.isdt,
                            .agency = d.agen,
                            .scale = c.params.cscl,
                            .bounds = c.bounds(),
                        });
                    } else {
                        // Streaming cell: read transiently (collectScaminCells pattern).
                        const rd = ls.reader orelse continue;
                        var cb: ChartBytes = .{};
                        if (!rd(ls.reader_user, lc.index, &cb)) continue;
                        defer freeCellBytes(&cb);
                        var ups: []const []const u8 = &.{};
                        var ups_arr: ?[][]const u8 = null;
                        if (cb.update_count > 0 and cb.updates != null and cb.update_lens != null) {
                            if (gpa.alloc([]const u8, cb.update_count)) |arr| {
                                for (arr, 0..) |*u, k| u.* = cb.updates.?[k][0..cb.update_lens.?[k]];
                                ups = arr;
                                ups_arr = arr;
                            } else |_| {}
                        }
                        defer if (ups_arr) |arr| gpa.free(arr);
                        if (s57.peekCellInfo(a, cb.base[0..cb.base_len], ups)) |ci| try infos.append(a, ci);
                    }
                }
            },
        }
        if (infos.items.len == 0) return null;

        var out = std.ArrayList(u8).empty;
        try out.append(a, '[');
        for (infos.items, 0..) |ci, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, "{\"name\":");
            try appendJsonStr(a, &out, ci.name);
            try out.print(a, ",\"scale\":{d},\"edition\":", .{ci.scale});
            try appendJsonStr(a, &out, ci.edition);
            try out.appendSlice(a, ",\"update\":");
            try appendJsonStr(a, &out, ci.update);
            try out.appendSlice(a, ",\"issueDate\":");
            try appendJsonStr(a, &out, ci.issue_date);
            try out.print(a, ",\"agency\":{d}", .{ci.agency});
            if (ci.bounds) |b| try out.print(a, ",\"bbox\":[{d},{d},{d},{d}]", .{ b[0], b[1], b[2], b[3] });
            try out.append(a, '}');
        }
        try out.append(a, ']');
        return try gpa.dupe(u8, out.items);
    }

    /// The chart's features for the given comma-separated object-class
    /// acronyms, as a GeoJSON FeatureCollection:
    /// geometry in lon/lat, properties = {"class": …, plus the feature's full
    /// S-57 acronym→value attribute map}. Parsed without portrayal. Polygon
    /// rings are emitted largest-first (exterior heuristic). Returns null when
    /// nothing matched. gpa-owned; free with freeBytes.
    pub fn featuresJson(self: *Chart, classes: []const u8) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // Wanted object-class acronyms (matched against each feature's class).
        var want = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, classes, ',');
        while (it.next()) |acr_raw| {
            const acr = std.mem.trim(u8, acr_raw, " ");
            if (acr.len > 0) try want.append(a, acr);
        }
        if (want.items.len == 0) return null;

        var out = std.ArrayList(u8).empty;
        try out.appendSlice(a, "{\"type\":\"FeatureCollection\",\"features\":[");
        var n: usize = 0;
        switch (self.backend) {
            .reader => return null,
            .cell => |*cb| try appendCellGeoJson(a, &out, &cb.cell, want.items, &n),
            .cells => |*ls| {
                for (ls.cells) |*lc| {
                    if (lc.cell) |*c| {
                        try appendCellGeoJson(a, &out, c, want.items, &n);
                    } else if (lc.base.len > 0) {
                        var cell = s57.parseCellWithUpdates(gpa, lc.base, lc.updates) catch continue;
                        defer cell.deinit();
                        try appendCellGeoJson(a, &out, &cell, want.items, &n);
                    } else {
                        const rd = ls.reader orelse continue;
                        var cb: ChartBytes = .{};
                        if (!rd(ls.reader_user, lc.index, &cb)) continue;
                        defer freeCellBytes(&cb);
                        var ups: []const []const u8 = &.{};
                        var ups_arr: ?[][]const u8 = null;
                        if (cb.update_count > 0 and cb.updates != null and cb.update_lens != null) {
                            if (gpa.alloc([]const u8, cb.update_count)) |arr| {
                                for (arr, 0..) |*u, k| u.* = cb.updates.?[k][0..cb.update_lens.?[k]];
                                ups = arr;
                                ups_arr = arr;
                            } else |_| {}
                        }
                        defer if (ups_arr) |arr| gpa.free(arr);
                        var cell = s57.parseCellWithUpdates(gpa, cb.base[0..cb.base_len], ups) catch continue;
                        defer cell.deinit();
                        try appendCellGeoJson(a, &out, &cell, want.items, &n);
                    }
                }
            },
        }
        if (n == 0) return null;
        try out.appendSlice(a, "]}");
        return try gpa.dupe(u8, out.items);
    }

    /// The distinct SCAMIN denominators present in the source, ascending. The host
    /// publishes these as the live SCAMIN manifest so its style builds one native
    /// per-value bucket layer per denominator (host-canonical-backend.md §2). A baked
    /// (PMTiles) source reads them from the archive metadata; a cell / ENC_ROOT source
    /// scans every cell's features (parsed without portrayal — SCAMIN is a plain S-57
    /// attribute), reading streamed cells transiently. Returns a gpa-owned slice; free
    /// the bytes with `freeBytes` (cast: `@ptrCast(vals.ptr)[0 .. vals.len * 4]`).
    pub fn scamin(self: *Chart) ![]u32 {
        var set = std.AutoHashMap(u32, void).init(gpa);
        defer set.deinit();
        switch (self.backend) {
            .reader => |*r| scaminFromMetadata(r, &set),
            .cell => |*cb| collectScaminCell(&cb.cell, &set),
            .cells => |*ls| collectScaminCells(ls, &set),
        }
        const vals = try gpa.alloc(u32, set.count());
        var i: usize = 0;
        var it = set.keyIterator();
        while (it.next()) |k| : (i += 1) vals[i] = k.*;
        std.mem.sort(u32, vals, {}, std.sort.asc(u32));
        return vals;
    }
};

/// Render ONE feature's resolved portrayal onto a solid background — the
/// `explore --kitty` thumbnail's isolated "mini scene". Only feature `fi` of
/// `cell` is portrayed (via its per-feature S-101 instruction stream in
/// `portrayal`, `only_fi` skipping the rest of the cell); the canvas is cleared
/// to the `bg` colour token (e.g. "DEPMS", the S-52 shallow-water shade) and the
/// feature framed by the caller's centre + zoom (a point sits at its node at
/// native size; a line/area is centred on its bbox). SCAMIN is ignored so the
/// feature always shows at the framing zoom. No Chart handle needed: the sprite
/// store + colour profile are built from the embedded catalogue exactly as
/// Chart.renderView does. Returns PNG/PDF bytes (gpa-owned; free with freeBytes).
pub fn renderFeature(
    cell: *s57.Cell,
    portrayal: ?[]const ?[]const u8,
    fi: usize,
    lon: f64,
    lat: f64,
    zoom: f64,
    w: u32,
    h: u32,
    palette: render.resolve.PaletteId,
    settings: *const render.resolve.Settings,
    bg: []const u8,
    output: render.pixel.Output,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const colors = try sharedColors();
    const css_name = switch (palette) {
        .day => "daySvgStyle",
        .dusk => "duskSvgStyle",
        .night => "nightSvgStyle",
    };
    var css_data: []const u8 = "";
    for (embedded_assets.css) |e| {
        if (std.mem.eql(u8, e.name, css_name)) css_data = e.bytes;
    }
    const sym_srcs = try a.alloc(sprite.SvgSrc, embedded_assets.symbols.len);
    for (embedded_assets.symbols, 0..) |e, i| sym_srcs[i] = .{ .id = e.name, .svg = e.bytes };
    const fill_srcs = try a.alloc(sprite.AreaFillSrc, embedded_assets.areafills.len);
    for (embedded_assets.areafills, 0..) |e, i| fill_srcs[i] = .{ .id = e.name, .xml = e.bytes };
    const store = try sprite.CatalogStore.init(a, sym_srcs, fill_srcs, css_data);
    defer store.deinit();

    // Complex-linestyle table (idempotent), same as renderView.
    var ls_srcs = std.ArrayList(@import("style").LineStyleSrc).empty;
    defer ls_srcs.deinit(gpa);
    for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
    scene.linestyle.registerLinestylesXml(gpa, ls_srcs.items);

    // Always show the previewed feature regardless of its SCAMIN at the framing zoom.
    var s = settings.*;
    s.ignore_scamin = true;

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var ps = render.pixel.PixelSurface.initView(a, colors, palette, &s, zoom, w, h, pt, tile.EXTENT);
    ps.store = store.asStore();
    ps.output = output;
    ps.bg_token = bg;

    const one = [_]scene.CellRef{.{ .cell = cell, .portrayal = portrayal, .only_fi = fi }};
    return scene.generateView(&ps, a, gpa, &one, lon, lat, zoom, false) catch error.TileGen;
}

/// A feature to HIGHLIGHT over a `renderCellView` — the `explore --tui` live cell
/// map pins the SELECTED feature so it stands out from every other charted
/// feature. `lon`/`lat` is the anchor (point node, or a line/area's bbox centre);
/// `bbox` = [west, south, east, north] additionally draws a box around a
/// line/area's extent (null for a point). Passing null to `renderCellView`
/// renders exactly as before.
pub const Highlight = struct {
    lon: f64,
    lat: f64,
    bbox: ?[4]f64 = null,
};

/// Render a FULL-CONTEXT view of an already-parsed cell + its portrayal — the
/// real quilted chart (ALL features, honouring SCAMIN, on the normal chart
/// background), centred on `lon`/`lat` at `zoom`. The `explore --tui --kitty`
/// live cell map draws with this: a whole-cell overview when a class header is
/// selected, or the cell zoomed IN to frame a feature (with its neighbours /
/// depths around it) when a feature is selected. Unlike `renderFeature` there is
/// no single-feature isolation and no forced background — it is `renderView`'s
/// `.cell` path, but driven from a caller-held cell so the TUI needn't open a
/// Chart handle (it already holds the parsed cell + portrayal). Returns PNG/PDF
/// bytes (gpa-owned; free with freeBytes). `highlight` (null for every other
/// caller) pins one feature over the finished chart — see `Highlight`.
pub fn renderCellView(
    cell: *s57.Cell,
    portrayal: ?[]const ?[]const u8,
    lon: f64,
    lat: f64,
    zoom: f64,
    w: u32,
    h: u32,
    palette: render.resolve.PaletteId,
    settings: *const render.resolve.Settings,
    output: render.pixel.Output,
    highlight: ?Highlight,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const colors = try sharedColors();
    const css_name = switch (palette) {
        .day => "daySvgStyle",
        .dusk => "duskSvgStyle",
        .night => "nightSvgStyle",
    };
    var css_data: []const u8 = "";
    for (embedded_assets.css) |e| {
        if (std.mem.eql(u8, e.name, css_name)) css_data = e.bytes;
    }
    const sym_srcs = try a.alloc(sprite.SvgSrc, embedded_assets.symbols.len);
    for (embedded_assets.symbols, 0..) |e, i| sym_srcs[i] = .{ .id = e.name, .svg = e.bytes };
    const fill_srcs = try a.alloc(sprite.AreaFillSrc, embedded_assets.areafills.len);
    for (embedded_assets.areafills, 0..) |e, i| fill_srcs[i] = .{ .id = e.name, .xml = e.bytes };
    const store = try sprite.CatalogStore.init(a, sym_srcs, fill_srcs, css_data);
    defer store.deinit();

    // Complex-linestyle table (idempotent), same as renderView / renderFeature.
    var ls_srcs = std.ArrayList(@import("style").LineStyleSrc).empty;
    defer ls_srcs.deinit(gpa);
    for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
    scene.linestyle.registerLinestylesXml(gpa, ls_srcs.items);

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var ps = render.pixel.PixelSurface.initView(a, colors, palette, settings, zoom, w, h, pt, tile.EXTENT);
    ps.store = store.asStore();
    ps.output = output;

    // Project the highlight's lon/lat (and bbox) into this view's canvas px so
    // the surface can pin the selected feature over the finished chart. The view
    // frame is standard web-mercator: `world` px span a normalised globe unit,
    // the centre lon/lat maps to the canvas centre.
    if (highlight) |hl| {
        const world = 256.0 * std.math.pow(f64, 2.0, zoom);
        const c = tile.lonLatToWorld(lon, lat);
        const cw = @as(f64, @floatFromInt(w)) / 2.0;
        const ch = @as(f64, @floatFromInt(h)) / 2.0;
        const toPx = struct {
            fn f(plon: f64, plat: f64, cc: [2]f64, wpx: f64, hw: f64, hh: f64) [2]f32 {
                const p = tile.lonLatToWorld(plon, plat);
                return .{ @floatCast((p[0] - cc[0]) * wpx + hw), @floatCast((p[1] - cc[1]) * wpx + hh) };
            }
        }.f;
        const anchor = toPx(hl.lon, hl.lat, c, world, cw, ch);
        var sh = render.pixel.ScreenHighlight{ .cx = anchor[0], .cy = anchor[1] };
        if (hl.bbox) |b| {
            const nw = toPx(b[0], b[3], c, world, cw, ch); // west,  north
            const se = toPx(b[2], b[1], c, world, cw, ch); // east,  south
            sh.bbox = .{ @min(nw[0], se[0]), @min(nw[1], se[1]), @max(nw[0], se[0]), @max(nw[1], se[1]) };
        }
        ps.highlight = sh;
    }

    const one = [_]scene.CellRef{.{ .cell = cell, .portrayal = portrayal }};
    return scene.generateView(&ps, a, gpa, &one, lon, lat, zoom, false) catch error.TileGen;
}

fn appendJsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        else => if (c < 0x20) {
            try out.print(a, "\\u{x:0>4}", .{c});
        } else try out.append(a, c),
    };
    try out.append(a, '"');
}

// Append one cell's matching features to a GeoJSON feature array (comma-led
// after the first). Geometry: prim 1 -> Point (SOUNDG -> MultiPoint of its
// 3-D soundings), prim 2 -> LineString/MultiLineString, prim 3 -> Polygon with
// rings ordered largest-|area|-first (exterior heuristic; ample for coverage /
// water-mask consumers). Properties: class + the full S-57 attribute map.
fn appendCellGeoJson(a: std.mem.Allocator, out: *std.ArrayList(u8), cell: *s57.Cell, want: []const []const u8, n: *usize) !void {
    for (cell.features, 0..) |f, fi| {
        const acr = catalogue.acronymByObjl(f.objl) orelse continue;
        var hit = false;
        for (want) |w| {
            if (std.mem.eql(u8, w, acr)) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;

        var geom = std.ArrayList(u8).empty;
        if (f.prim == 1) {
            if (f.objl == 129) {
                const snds = cell.soundingsFor(a, f) catch continue;
                if (snds.len == 0) continue;
                try geom.appendSlice(a, "{\"type\":\"MultiPoint\",\"coordinates\":[");
                for (snds, 0..) |sd, i| {
                    if (i > 0) try geom.append(a, ',');
                    try geom.print(a, "[{d},{d},{d}]", .{ sd.lon(), sd.lat(), sd.depth });
                }
                try geom.appendSlice(a, "]}");
            } else {
                const pg = cell.pointGeometry(f) orelse continue;
                try geom.print(a, "{{\"type\":\"Point\",\"coordinates\":[{d},{d}]}}", .{ pg.lon(), pg.lat() });
            }
        } else {
            const parts = scene.featureParts(a, cell.*, null, fi, f) catch continue;
            if (parts.len == 0) continue;
            if (f.prim == 3) {
                // Rings largest-first: |shoelace| descending.
                const areas = try a.alloc(f64, parts.len);
                for (parts, 0..) |ring, i| {
                    var s2: f64 = 0;
                    for (0..ring.len -| 1) |j| s2 += ring[j].lon() * ring[j + 1].lat() - ring[j + 1].lon() * ring[j].lat();
                    areas[i] = @abs(s2);
                }
                const order = try a.alloc(usize, parts.len);
                for (order, 0..) |*o, i| o.* = i;
                std.mem.sort(usize, order, areas, struct {
                    fn lt(ar: []f64, x: usize, y: usize) bool {
                        return ar[x] > ar[y];
                    }
                }.lt);
                try geom.appendSlice(a, "{\"type\":\"Polygon\",\"coordinates\":[");
                var emitted: usize = 0;
                for (order) |oi| {
                    const ring = parts[oi];
                    if (ring.len < 4) continue;
                    if (emitted > 0) try geom.append(a, ',');
                    try geom.append(a, '[');
                    for (ring, 0..) |p, i| {
                        if (i > 0) try geom.append(a, ',');
                        try geom.print(a, "[{d},{d}]", .{ p.lon(), p.lat() });
                    }
                    try geom.append(a, ']');
                    emitted += 1;
                }
                try geom.appendSlice(a, "]}");
                if (emitted == 0) continue;
            } else {
                const multi = parts.len > 1;
                if (multi) {
                    try geom.appendSlice(a, "{\"type\":\"MultiLineString\",\"coordinates\":[");
                } else {
                    try geom.appendSlice(a, "{\"type\":\"LineString\",\"coordinates\":");
                }
                for (parts, 0..) |line, li| {
                    if (li > 0) try geom.append(a, ',');
                    try geom.append(a, '[');
                    for (line, 0..) |p, i| {
                        if (i > 0) try geom.append(a, ',');
                        try geom.print(a, "[{d},{d}]", .{ p.lon(), p.lat() });
                    }
                    try geom.append(a, ']');
                }
                if (multi) try geom.append(a, ']');
                try geom.append(a, '}');
            }
        }
        if (geom.items.len == 0) continue;

        if (n.* > 0) try out.append(a, ',');
        n.* += 1;
        try out.appendSlice(a, "{\"type\":\"Feature\",\"geometry\":");
        try out.appendSlice(a, geom.items);
        // properties = {"class":ACR, ...full attr map} — splice class into the
        // engine's existing acronym->value pick blob.
        const attrs = scene.encodeS57Attrs(a, f) catch "{}";
        try out.appendSlice(a, ",\"properties\":{\"class\":");
        try appendJsonStr(a, out, acr);
        if (attrs.len > 2) {
            try out.append(a, ',');
            try out.appendSlice(a, attrs[1 .. attrs.len - 1]);
        }
        try out.appendSlice(a, "}}");
    }
}

// Collect a parsed cell's distinct SCAMIN denominators into `set`.
fn collectScaminCell(cell: *const s57.Cell, set: *std.AutoHashMap(u32, void)) void {
    for (cell.features) |f| if (scene.featureScamin(f)) |sc| if (sc > 0) set.put(@intCast(sc), {}) catch {};
    const cscl = cell.params.cscl;
    if (cscl > 0) {
        // The overscale (`oscl`) X2 gate denominator (cscl/OVERSCALE_FACTOR): the
        // AP(OVERSC01) hatch must flip on at a client crossing exactly at 2x, so
        // the live SCAMIN ladder needs this value too (the bake path picks it up
        // from the emitted tiles; the live path is precomputed from cells here).
        const gate = bake_enc.overscaleGateDenom(cscl);
        if (gate > 0) set.put(@intCast(gate), {}) catch {};
    }
}

// Scan every cell of a lazy/streaming source for SCAMIN. Loaded cells are read
// directly; unloaded cells are parsed throwaway (NO portrayal) — resident bytes in
// place, streamed cells read transiently via the host reader and freed — so the LRU
// and the loaded-cell set are left untouched.
fn collectScaminCells(ls: *LazySource, set: *std.AutoHashMap(u32, void)) void {
    for (ls.cells) |*lc| {
        if (lc.cell) |*c| {
            collectScaminCell(c, set);
            continue;
        }
        if (lc.base.len > 0) {
            var cell = s57.parseCellWithUpdates(gpa, lc.base, lc.updates) catch continue;
            defer cell.deinit();
            collectScaminCell(&cell, set);
            continue;
        }
        // Streaming cell with no resident bytes: read them via the host reader for
        // this scan only, then free (the normal tile path reads them again on demand).
        const rd = ls.reader orelse continue;
        var cb: ChartBytes = .{};
        if (!rd(ls.reader_user, lc.index, &cb)) continue;
        defer freeCellBytes(&cb);
        var ups: []const []const u8 = &.{};
        var ups_arr: ?[][]const u8 = null;
        if (cb.update_count > 0 and cb.updates != null and cb.update_lens != null) {
            if (gpa.alloc([]const u8, cb.update_count)) |arr| {
                for (arr, 0..) |*u, k| u.* = cb.updates.?[k][0..cb.update_lens.?[k]];
                ups = arr;
                ups_arr = arr;
            } else |_| {}
        }
        defer if (ups_arr) |arr| gpa.free(arr);
        var cell = s57.parseCellWithUpdates(gpa, cb.base[0..cb.base_len], ups) catch continue;
        defer cell.deinit();
        collectScaminCell(&cell, set);
    }
}

// Pull the distinct SCAMIN denominators from a baked archive's metadata JSON (the
// "scamin":[…] array that bakeArchive / the bundle bake splice in). The metadata is
// uncompressed in this engine's archives; gunzip it if some other writer compressed it.
fn scaminFromMetadata(r: *pmtiles.Reader, set: *std.AutoHashMap(u32, void)) void {
    const h = r.header;
    if (h.metadata_length == 0) return;
    const raw = r.bytes[@intCast(h.metadata_offset)..][0..@intCast(h.metadata_length)];
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    const json: []const u8 = switch (h.internal_compression) {
        .none => raw,
        .gzip => blk: {
            owned = gzip.decompress(gpa, raw) catch return;
            break :blk owned.?;
        },
        else => return,
    };
    scanScaminArray(json, set);
}

// Minimal extractor for `"scamin":[<uint>,<uint>,…]` from a metadata JSON object;
// tolerant of whitespace. Ignores everything else (no full JSON parse needed).
fn scanScaminArray(json: []const u8, set: *std.AutoHashMap(u32, void)) void {
    const ki = std.mem.indexOf(u8, json, "\"scamin\"") orelse return;
    var i = ki + "\"scamin\"".len;
    while (i < json.len and json[i] != '[' and json[i] != '}') i += 1; // skip ` : `
    if (i >= json.len or json[i] != '[') return;
    i += 1;
    while (i < json.len and json[i] != ']') {
        while (i < json.len and (json[i] < '0' or json[i] > '9') and json[i] != ']') i += 1;
        if (i >= json.len or json[i] == ']') break;
        var v: u32 = 0;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) v = v *% 10 +% (json[i] - '0');
        if (v > 0) set.put(v, {}) catch {};
    }
}

// ---- ENC_ROOT bake -------------------------------------------------------

const BakeSource = struct { base: []const u8, updates: []const []const u8, name: []const u8 = "" };

const BakeWork = struct {
    sources: []const BakeSource,
    outs: []?bake_enc.Backend,
    arenas: []?*std.heap.ArenaAllocator,
    rules_dir: []const u8,
    build_geo: bool,

    fn run(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        _ = scratch; // owns persistent backends via its own arenas / `gpa`
        const c: *BakeWork = @ptrCast(@alignCast(uptr));
        const src = c.sources[i];
        const loaded = parseAnyCell(src.base, src.updates) orelse return;
        var cell = loaded.cell;
        cell.name = src.name; // pick-report badge (borrowed for the bake call)
        const b = cell.bounds() orelse {
            cell.deinit();
            return;
        };
        var portrayal: ?[]const ?[]const u8 = null;
        var portrayal_plain: ?[]const ?[]const u8 = null;
        var portrayal_simplified: ?[]const ?[]const u8 = null;
        var geo: ?scene.GeoParts = null;
        var geo_world: ?scene.GeoWorld = null;
        var feat_bbox: ?[]const ?[4]f64 = null;
        const pa: ?*std.heap.ArenaAllocator = gpa.create(std.heap.ArenaAllocator) catch null;
        if (pa) |p| {
            p.* = std.heap.ArenaAllocator.init(gpa);
            if (portrayVariantsAny(p.allocator(), &cell, loaded.adapted, c.rules_dir)) |cp| {
                portrayal = cp.base;
                portrayal_plain = cp.plain;
                portrayal_simplified = cp.simplified;
            } else |_| {}
            // Build the geometry cache for EVERY cell, unconditionally.
            // `build_geo` (cacheGeoForBand) gated it to the finer bands, but coarse cells are
            // exactly the ones that hurt without it: the geo cache both cheapens per-tile
            // reprojection AND lets buildLabelCache assemble each feature's parts to populate
            // the label-point cache. Skipping it left the pole-of-inaccessibility (polylabel)
            // search running per tile on huge coarse cells (US1GC09M: minutes).
            geo = scene.buildGeoCache(p.allocator(), &cell) catch null;
            // The world-coordinate cache is what actually cheapens the reprojection above:
            // lon/lat -> web-mercator costs a tan + cos + log per point, and a feature's
            // points are re-projected into every tile at every zoom it touches. World
            // coords are tile-invariant, so compute them ONCE per cell here and let the
            // per-tile path reduce to worldToTile (multiply + round). Without this the
            // per-tile loop falls back to the full transcendental projection.
            if (geo) |g| geo_world = scene.buildGeoWorld(p.allocator(), g) catch null;
            // Per-feature lon/lat bbox — the per-tile spatial cull in appendCellFeatures.
            // Without it every feature in the cell is walked (and its portrayal parsed)
            // for every tile, even the ones it lies nowhere near.
            feat_bbox = scene.buildFeatBBox(p.allocator(), &cell, geo) catch null;
            // Per-feature label-point (polylabel) cache — tile-invariant, so compute it ONCE
            // per cell (only for Text/centred-symbol features) instead of re-running the search
            // for every tile a feature touches; the arena outlives the call via c.arenas.
            cell.label_cache = scene.buildLabelCache(p.allocator(), &cell, geo, portrayal) catch null;
            // Per-feature drawn-boundary cache (masked/coast-clipped area boundaries):
            // assemble the drawableLineParts subset + precompute its world coords ONCE, so
            // the per-tile stroke reprojects with a linear map instead of the transcendental
            // projection on every tile the area spans — the last per-tile projection hotspot
            // on Inland-ENC river cells (long shared coast boundaries).
            cell.drawn_boundary = scene.buildDrawnBoundary(p.allocator(), &cell) catch null;
        }
        // M_COVR coverage + scale for per-cell quilting (allocate into the cell's own
        // arena before the move, so it outlives with the backend).
        const coverage = cell.mcovrCoverage(cell.arena.allocator());
        const scamins = bake_enc.collectScamins(cell.arena.allocator(), &cell) catch &.{};
        const cscl = cell.params.cscl;
        // Sector-figure reach (exact, from the portrayal streams): buildTileMap
        // addresses the neighbouring tiles the cell's light legs/arcs cross.
        const lr = scene.collectLightReach(&cell, portrayal);
        c.outs[i] = .{ .cell = cell, .portrayal = portrayal, .portrayal_plain = portrayal_plain, .portrayal_simplified = portrayal_simplified, .geo = geo, .geo_world = geo_world, .feat_bbox = feat_bbox, .bounds = b, .cscl = cscl, .coverage = coverage, .scamins = scamins, .light_bbox = lr.bbox, .light_range_m = lr.range_m };
        c.arenas[i] = pa;
    }
};

/// Bake an ENC_ROOT (the same cells as `openCharts`) into ONE PMTiles archive,
/// zoom-banded per cell by compilation scale. Returns the archive bytes (free
/// with `freeBytes`), or null if nothing was covered. Streams band-by-band
/// (finest → coarsest, best-band dedup + the scamin-aware band handoff), holding
/// at most two adjacent bands' parsed cells at a time (a band's cells ride into
/// the next-coarser pass for its deferred floor tiles), not the whole catalogue.
/// `progress` (nullable) fires during the load+portray phase (stage 0) and the
/// tile-bake phase (stage 1). The caller owns the input bytes for the call.
pub fn bakeArchive(
    cells_in: []const ChartInput,
    rules_dir: ?[]const u8,
    minzoom: u8,
    maxzoom: u8,
    fmt: scene.TileFormat,
    pick_attrs: bool,
    progress: Progress,
    user: ?*anyopaque,
    // A single-cell composite bake passes that cell's coverage object (from
    // `scene.coverage.encodeJson`) to embed in the archive metadata; multi-cell
    // bakes pass null (no single coverage to carry).
    coverage_json: ?[]const u8,
) !?[]u8 {
    const dir = resolveRulesDir(rules_dir);

    var band_idx: [bake_enc.bands_fine_to_coarse.len]std.ArrayList(usize) = undefined;
    for (&band_idx) |*bi| bi.* = std.ArrayList(usize).empty;
    defer for (&band_idx) |*bi| bi.deinit(gpa);
    // Per-cell band + peek bbox: the bbox feeds the fill-down gate (a finer band
    // fills below its window only where no strictly-coarser band's footprint
    // covers). An empty bbox (no geometry) can't cover anything, so it never gates.
    const cbands = gpa.alloc(bake_enc.Band, cells_in.len) catch return error.BakeFailed;
    defer gpa.free(cbands);
    const cbboxes = gpa.alloc([4]f64, cells_in.len) catch return error.BakeFailed;
    defer gpa.free(cbboxes);
    for (cells_in, 0..) |in, i| {
        const m = s57.peekMeta(gpa, in.base);
        const band = bake_enc.bandOf(if (m) |mm| mm.cscl else 0);
        cbands[i] = band;
        cbboxes[i] = if (m) |mm| (mm.bounds orelse .{ 1e9, 1e9, -1e9, -1e9 }) else .{ 1e9, 1e9, -1e9, -1e9 };
        band_idx[@intFromEnum(band)].append(gpa, i) catch return error.BakeFailed;
    }

    catalogue.warmUp();
    portray.setQuiet(true);
    // Stream tiles into a StreamWriter (gzip+dedup, no raw-tile retention); the C
    // ABI returns bytes, so serialize the whole archive at the end.
    var sw = pmtiles.StreamWriter.init(gpa);
    defer sw.deinit();
    var baker = bake_enc.Baker.init(gpa, minzoom, maxzoom, .{ .ctx = &sw, .func = streamSink });
    baker.format = fmt;
    baker.pick_attrs = pick_attrs;
    defer baker.deinit();

    // Distinct SCAMIN denominators across all cells -> published in the archive
    // metadata so the client builds one native-minzoom bucket per value at load
    // (host-canonical-backend.md §2). Collected from the parsed cells (the source
    // of truth) while they're alive, before each band frees them.
    var scamin_set = std.AutoHashMap(u32, void).init(gpa);
    defer scamin_set.deinit();

    // The coarsest populated band gets .extend_min (fill down to minzoom — the
    // live tileRefs coarsest-band fallback); every other populated band defers its
    // floor into the next-coarser pass (.defer_down, the band handoff).
    var coarsest_pop: ?bake_enc.Band = null;
    for (bake_enc.bands_fine_to_coarse) |band| {
        if (band_idx[@intFromEnum(band)].items.len > 0) coarsest_pop = band;
    }
    // Band label (host §3): count the passes that actually bake — a band with no
    // cells still runs when the next-finer band deferred its floor tiles into it.
    var band_count: u8 = 0;
    {
        var carry_n: usize = 0;
        for (bake_enc.bands_fine_to_coarse) |band| {
            const own_n = band_idx[@intFromEnum(band)].items.len;
            const floor: bake_enc.FloorMode = if (coarsest_pop == band) .extend_min else .defer_down;
            if (bake_enc.passHasWork(band, minzoom, maxzoom, own_n, carry_n, floor)) band_count += 1;
            carry_n = if (own_n > 0 and floor == .defer_down and bake_enc.floorDeferred(band, minzoom, maxzoom)) own_n else 0;
        }
    }
    baker.band_count = band_count;

    // Band-handoff carry: the previous (finer) band's parsed backends + portrayal
    // arenas, kept alive through this pass so its deferred floor tiles bake with
    // both bands' cells. Peak memory: two adjacent bands.
    var carry_backs = std.ArrayList(bake_enc.Backend).empty;
    var carry_arenas = std.ArrayList(?*std.heap.ArenaAllocator).empty;
    defer {
        for (carry_backs.items) |*be| be.cell.deinit();
        for (carry_arenas.items) |pa| if (pa) |p| {
            p.deinit();
            gpa.destroy(p);
        };
        carry_backs.deinit(gpa);
        carry_arenas.deinit(gpa);
    }

    var loaded: usize = 0;
    var band_ord: u8 = 0;
    // Union sector-figure reach across the baked cells — published as the
    // archive's "light_reach" metadata so the compositor widens its tile
    // addressing by the same ring the baker did (null = no figures anywhere).
    var lr_union: ?[4]f64 = null;
    var lr_range_m: f64 = 0;
    for (bake_enc.bands_fine_to_coarse) |band| {
        const idxs = band_idx[@intFromEnum(band)].items;
        const floor: bake_enc.FloorMode = if (coarsest_pop == band) .extend_min else .defer_down;
        // Whether this band's cells must outlive their own pass (floor deferred
        // into the next one). A no-work pass can still defer (fully-clamped range).
        const deferred = idxs.len > 0 and floor == .defer_down and bake_enc.floorDeferred(band, minzoom, maxzoom);
        const has_work = bake_enc.passHasWork(band, minzoom, maxzoom, idxs.len, carry_backs.items.len, floor);
        if (!has_work and !deferred) {
            // Nothing bakes here and nothing rides on: drop a consumed-less carry.
            for (carry_backs.items) |*be| be.cell.deinit();
            for (carry_arenas.items) |pa| if (pa) |p| {
                p.deinit();
                gpa.destroy(p);
            };
            carry_backs.clearRetainingCapacity();
            carry_arenas.clearRetainingCapacity();
            continue;
        }
        if (has_work) {
            baker.band_index = band_ord;
            band_ord += 1;
        }

        // Parse + portray this band's own cells (also when the pass itself bakes
        // nothing but defers them — the next-coarser pass consumes them as carry).
        var sources = std.ArrayList(BakeSource).empty;
        defer {
            for (sources.items) |s| gpa.free(s.updates);
            sources.deinit(gpa);
        }
        sources.ensureTotalCapacity(gpa, idxs.len) catch continue;
        for (idxs) |i| {
            const in = cells_in[i];
            const ups = gpa.dupe([]const u8, in.updates) catch &.{};
            sources.appendAssumeCapacity(.{ .base = in.base, .updates = ups, .name = in.name });
        }

        const outs = gpa.alloc(?bake_enc.Backend, sources.items.len) catch continue;
        defer gpa.free(outs);
        @memset(outs, null);
        const pas = gpa.alloc(?*std.heap.ArenaAllocator, sources.items.len) catch continue;
        defer gpa.free(pas);
        @memset(pas, null);
        var bw = BakeWork{ .sources = sources.items, .outs = outs, .arenas = pas, .rules_dir = dir, .build_geo = bake_enc.cacheGeoForBand(band) };
        bake_enc.parallelFor(gpa, sources.items.len, &bw, BakeWork.run);
        loaded += idxs.len;
        if (progress) |cb| if (has_work) cb(user, 0, loaded, cells_in.len, band_ord - 1, band_count, @tagName(band).ptr);

        var backs = std.ArrayList(bake_enc.Backend).empty;
        var band_arenas = std.ArrayList(?*std.heap.ArenaAllocator).empty;
        backs.ensureTotalCapacity(gpa, outs.len) catch {};
        band_arenas.ensureTotalCapacity(gpa, outs.len) catch {};
        for (outs, pas) |o, pa| if (o) |be| {
            backs.appendAssumeCapacity(be);
            band_arenas.appendAssumeCapacity(pa);
        };
        for (backs.items) |be| {
            for (be.cell.features) |f| {
                if (scene.featureScamin(f)) |sc| scamin_set.put(@intCast(sc), {}) catch {};
            }
            // The cell's overscale gate denominator joins the ladder: the client
            // needs a crossing at the exact emitted `oscl` value (spec §5), so
            // the hatch flips exactly at the X2 boundary.
            if (be.cscl > 0) {
                const q = bake_enc.overscaleGateDenom(be.cscl);
                if (q > 0) scamin_set.put(@intCast(q), {}) catch {};
            }
            // Fold the sector-figure reach for the archive's "light_reach" key
            // (union bbox, max ground leg) while the backends are alive.
            if (be.light_bbox) |lb| {
                if (lr_union) |*u| {
                    u[0] = @min(u[0], lb[0]);
                    u[1] = @min(u[1], lb[1]);
                    u[2] = @max(u[2], lb[2]);
                    u[3] = @max(u[3], lb[3]);
                } else lr_union = lb;
                lr_range_m = @max(lr_range_m, be.light_range_m);
            }
        }
        if (has_work) {
            // Own cells first, then the finer band's carry (bakeBand own_len split).
            var all = std.ArrayList(bake_enc.Backend).empty;
            defer all.deinit(gpa);
            all.appendSlice(gpa, backs.items) catch {};
            all.appendSlice(gpa, carry_backs.items) catch {};
            baker.bakeBand(band, all.items, backs.items.len, floor, null, progress, user) catch {};
        }
        // Fill-down: this band fills its below-window zooms where it is the
        // coarsest band covering the ground (no strictly-coarser band's footprint
        // overlaps) — the district-pack empty-low-zoom hole that extend_min (the
        // single globally-coarsest band) can't reach. Mirrors the live tileRefs
        // fallbackBand; only cells a coarser band doesn't blanket participate.
        if (floor == .defer_down and backs.items.len > 0 and bake_enc.fillDownZooms(band, minzoom, maxzoom) != null) {
            var coarser = std.ArrayList(bake_enc.CoarserBox).empty;
            defer coarser.deinit(gpa);
            for (cbands, cbboxes) |cb, bx| {
                if (@intFromEnum(cb) > @intFromEnum(band)) // strictly coarser
                    coarser.append(gpa, .{ .bbox = bx, .max_z = bake_enc.bandZooms(cb).max }) catch {};
            }
            var fd = std.ArrayList(bake_enc.Backend).empty;
            defer fd.deinit(gpa);
            for (backs.items) |be| {
                if (!bake_enc.coveredByCoarser(be.bounds, coarser.items)) fd.append(gpa, be) catch {};
            }
            if (fd.items.len > 0) baker.bakeFillDown(band, fd.items, coarser.items, progress, user) catch {};
        }
        // The carry block's ride ends here; the own block becomes the NEXT pass's
        // carry (deferred) or is freed with it.
        for (carry_backs.items) |*be| be.cell.deinit();
        for (carry_arenas.items) |pa| if (pa) |p| {
            p.deinit();
            gpa.destroy(p);
        };
        carry_backs.clearRetainingCapacity();
        carry_arenas.clearRetainingCapacity();
        if (deferred) {
            carry_backs.appendSlice(gpa, backs.items) catch {
                for (backs.items) |*be| be.cell.deinit();
                backs.clearRetainingCapacity();
            };
            carry_arenas.appendSlice(gpa, band_arenas.items) catch {
                for (band_arenas.items) |pa| if (pa) |p| {
                    p.deinit();
                    gpa.destroy(p);
                };
                band_arenas.clearRetainingCapacity();
            };
        } else {
            for (backs.items) |*be| be.cell.deinit();
            for (band_arenas.items) |pa| if (pa) |p| {
                p.deinit();
                gpa.destroy(p);
            };
        }
        backs.deinit(gpa);
        band_arenas.deinit(gpa);
    }

    if (sw.num_addressed == 0) return null;
    const ub = baker.unionBounds();
    var scamin_vals = std.ArrayList(u32).empty;
    defer scamin_vals.deinit(gpa);
    {
        var it = scamin_set.keyIterator();
        while (it.next()) |k| try scamin_vals.append(gpa, k.*);
        std.mem.sort(u32, scamin_vals.items, {}, std.sort.asc(u32));
    }
    var light_reach_json: ?[]const u8 = null;
    defer if (light_reach_json) |lj| gpa.free(lj);
    if (lr_union) |u| light_reach_json = scene.coverage.encodeLightReachJson(gpa, .{ .bbox = u, .range_m = lr_range_m }) catch null;
    const meta = try scene.metadataJson(gpa, scamin_vals.items, coverage_json, light_reach_json);
    defer gpa.free(meta);
    return try sw.finishBytes(.{
        .metadata_json = meta,
        .min_lon_e7 = @intFromFloat(@round(ub[0] * 1e7)),
        .min_lat_e7 = @intFromFloat(@round(ub[1] * 1e7)),
        .max_lon_e7 = @intFromFloat(@round(ub[2] * 1e7)),
        .max_lat_e7 = @intFromFloat(@round(ub[3] * 1e7)),
        .tile_type = if (fmt == .mlt) .mlt else .mvt,
    });
}

// Tile sink: feed each streamed tile into the StreamWriter. The Baker already
// gzipped the tile in its parallel gen worker (bake_enc gzipTile), so `comp` is
// ALREADY compressed — use addCompressed (verbatim), NOT add (which would gzip a
// second time, double-gzipping every tile). MVT survives that (maplibre auto-
// inflates a gzip-magic body) but an MLT tile does not: the client strips one
// gzip layer and hands the MLT decoder still-gzipped bytes ("Unable to parse the
// tile"). The bundle.zig sink already does this correctly; this path had drifted.
// The Baker frees the buffer after this returns, so addCompressed copies it.
fn streamSink(ctx: ?*anyopaque, z: u8, x: u32, y: u32, comp: []const u8) anyerror!void {
    const sw: *pmtiles.StreamWriter = @ptrCast(@alignCast(ctx.?));
    try sw.addCompressed(z, x, y, comp);
}
