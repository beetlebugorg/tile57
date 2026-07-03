//! The tile57 engine API, in Zig. A `Chart` is an embeddable nautical-chart
//! tile source: open it from in-memory bytes (a PMTiles archive or raw S-57 ENC
//! cells) and it serves decompressed Mapbox Vector Tiles by (z, x, y). Multi-cell
//! ENC_ROOT sources index cells cheaply and parse + portray them lazily per
//! requested tile (LRU-bounded), so a host can open the whole NOAA catalogue
//! instantly and pay only for the cells under the current view. `bakeArchive`
//! bakes an ENC_ROOT into one band-streamed PMTiles archive.
//!
//! This is the single source of truth; the C ABI (capi.zig / include/tile57.h)
//! is a thin shim over these types. The engine uses a single thread-safe
//! general-purpose allocator internally — `tile`/`bakeArchive` return bytes owned
//! by it; free them with `freeBytes`.
//!
//! Threading: a Chart is NOT internally synchronized — don't call `tile` on the
//! same Chart from multiple threads concurrently (the tile cache + LRU mutate
//! without a lock). Distinct charts are independent. `openCells`/`bakeArchive`
//! parallelize internally over cores.

const std = @import("std");
const pmtiles = @import("tiles").pmtiles;
const gzip = @import("tiles").gzip;
const s57 = @import("s57");
const scene = @import("scene");
const portray = @import("portray");
const bake_enc = @import("scene").bake_enc;
const catalogue = @import("s100").catalogue;
const tile = @import("tiles").tile;
const render = @import("render");
const sprite = @import("sprite");
const embedded_assets = @import("catalog"); // S-101 portrayal assets (renderView store)
const assets = @import("assets"); // displayDenomZ (the physical display-scale formula)

// smp_allocator (Zig's fast thread-safe GPA), not page_allocator: the engine
// makes many small, short-lived allocations (tile cache, cell dupes, index
// lists); page_allocator would mmap each one. Matches the bake CLI + C ABI.
const gpa = std.heap.smp_allocator;

// Env access lives in C (Zig 0.16 puts env behind Io); returns the S-101 rules
// dir from TILE57_S101_RULES or null. Provided by the portrayal C shim.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

/// Backend / on-disk format. `auto` sniffs PMTiles first, then S-57.
pub const Format = enum { auto, pmtiles, s57_cell };

/// One ENC cell: the base .000 bytes plus its sequential update files (.001…).
/// Bytes are borrowed for the duration of the call (copied where retained).
pub const CellInput = struct {
    base: []const u8,
    updates: []const []const u8 = &.{},
    /// Source ENC cell name (dataset stem, e.g. "US4MD81M") for the pick report's
    /// "source cell" badge. "" = unknown (the `cell` prop is omitted). The eager
    /// (openCells) path copies it; the bake path borrows it for the call.
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
pub const CellMeta = extern struct {
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
pub const CellBytes = extern struct {
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
pub const CellReadFn = *const fn (user: ?*anyopaque, index: usize, out: *CellBytes) callconv(.c) bool;

/// Free bytes returned by `Chart.tile` / `bakeArchive` (page-allocator owned).
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
};

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
    // slice of the band-handoff quantization ladder (bake_enc.quantizeHandoff).
    scamins: []const u32 = &.{},
    // SCAMIN standalone: the cell's matchable SCAMIN point records
    // (scamin_pts.collectRecs; cell.arena, Rec.cell stamped at gather time) —
    // the live per-tile dedup's inputs. null until loaded.
    recs: ?[]const scene.scamin_pts.Rec = null,
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
    reader: ?CellReadFn = null, // streaming: read a cell's bytes on demand
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

// The cell's M_COVR (OBJL 302, CATCOV=1) data-coverage polygons, assembled +
// cached on first use. Each polygon is a list of lon/lat rings (exterior + holes).
fn lazyCellCoverage(lc: *LazyCell) []const []const []const s57.LonLat {
    if (lc.coverage) |c| return c;
    if (lc.cell) |*cell| {
        const a = cell.arena.allocator();
        var polys = std.ArrayList([]const []const s57.LonLat).empty;
        for (cell.features) |f| {
            if (f.objl != 302) continue; // M_COVR
            const cv = f.attr(18) orelse continue; // CATCOV (S-57 attr 18)
            const n = std.fmt.parseInt(i64, std.mem.trim(u8, cv, " "), 10) catch continue;
            if (n != 1) continue; // 1 = coverage available (2 = no coverage)
            const rings = cell.lineGeometryParts(a, f) catch continue;
            if (rings.len > 0) polys.append(a, rings) catch {};
        }
        lc.coverage = polys.items;
        return polys.items;
    }
    return &.{};
}

fn coverageContains(polys: []const []const []const s57.LonLat, lon: f64, lat: f64) bool {
    for (polys) |rings| if (s57.pointInRings(rings, lon, lat)) return true;
    return false;
}

// The finest (smallest 1:N) compilation scale among the indexed cells whose
// M_COVR coverage contains (lon,lat); maxInt when none — the live twin of
// bake_enc.finestCsclAt, same derived-extent rule (a cell with no M_COVR counts
// via its bbox only when `include_derived`: points/lines, never fills), so the
// live path quilts + band-hands-off exactly like the baker.
fn finestCsclAtLive(ls: *LazySource, idxs: []const u32, lon: f64, lat: f64, include_derived: bool) i32 {
    var best: i32 = std.math.maxInt(i32);
    for (idxs) |i| {
        const lc = &ls.cells[i];
        if (lc.cscl <= 0 or lc.cscl >= best) continue;
        const cov = lazyCellCoverage(lc);
        const covered = if (cov.len > 0)
            coverageContains(cov, lon, lat)
        else
            include_derived and (lon >= lc.bbox[0] and lon <= lc.bbox[2] and lat >= lc.bbox[1] and lat <= lc.bbox[3]);
        if (covered) best = lc.cscl;
    }
    return best;
}

fn bboxOverlap(a_: [4]f64, b_: [4]f64) bool {
    return a_[0] <= b_[2] and a_[2] >= b_[0] and a_[1] <= b_[3] and a_[3] >= b_[1];
}

// Free the host-malloc'd buffers a streaming reader transferred to us (libc free).
fn freeCellBytes(cb: *CellBytes) void {
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
fn addPathCell(io: std.Io, dir: std.Io.Dir, relpath: []const u8, metas: *std.ArrayList(CellMeta), paths: *std.ArrayList([]u8)) !void {
    const bytes = dir.readFileAlloc(io, relpath, gpa, .unlimited) catch return;
    defer gpa.free(bytes);
    const m = s57.peekMeta(gpa, bytes) orelse return;
    const bb = m.bounds orelse return;
    try metas.append(gpa, .{ .west = bb[0], .south = bb[1], .east = bb[2], .north = bb[3], .cscl = m.cscl });
    try paths.append(gpa, try gpa.dupe(u8, relpath));
}

// Internal CellReadFn for a path-backed chart: read cell `index`'s base .000 + its
// sequential .001.. updates from the retained dir into libc-malloc'd buffers (the
// engine frees them via freeCellBytes). Mirrors the baker's per-cell load.
fn pathRead(user: ?*anyopaque, index: usize, out: *CellBytes) callconv(.c) bool {
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
    var cb: CellBytes = .{};
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

// Parse + portray a lazy cell if not already loaded, and stamp its LRU tick.
fn lazyEnsureLoaded(ls: *LazySource, lc: *LazyCell) void {
    ls.tick += 1;
    lc.tick = ls.tick;
    if (lc.cell != null) return;
    if (lc.streaming and lc.base.len == 0) {
        if (!streamRead(ls, lc)) return;
    }
    var cell = s57.parseCellWithUpdates(gpa, lc.base, lc.updates) catch return;
    cell.name = lc.name; // pick-report source-cell badge (gpa-owned, lives with the source)
    if (gpa.create(std.heap.ArenaAllocator)) |p| {
        p.* = std.heap.ArenaAllocator.init(gpa);
        if (portray.portrayCellVariants(p.allocator(), &cell, ls.rules_dir)) |cp| {
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
    // SCAMIN standalone: the cell's matchable point records for the live
    // per-tile dedup (Rec.cell is stamped when gathered — 0 here).
    lc.recs = scamin_pts.collectRecs(cell.arena.allocator(), &cell, lc.cscl, 0) catch null;
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
    lc.recs = null; // ditto (cell.arena)
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

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
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
    return src;
}

// Parse (+ apply updates) + portray one cell into a CellBackend. Reads the bytes
// but does not take ownership. Portrayal failure is non-fatal (classify() fallback).
fn buildCellBackend(base: []const u8, updates: []const []const u8, dir: []const u8) ?CellBackend {
    const cell = s57.parseCellWithUpdates(gpa, base, updates) catch return null;
    var cb = CellBackend{ .cell = cell };
    const pa = gpa.create(std.heap.ArenaAllocator) catch return cb;
    pa.* = std.heap.ArenaAllocator.init(gpa);
    if (portray.portrayCellVariants(pa.allocator(), &cb.cell, dir)) |cp| {
        cb.portrayal = cp.base;
        cb.portrayal_plain = cp.plain;
        cb.portrayal_simplified = cp.simplified;
        cb.portray_arena = pa;
    } else |_| {
        pa.deinit();
        gpa.destroy(pa);
    }
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

// Parallel open worker: peek each cell's band + bbox and copy its bytes.
const OpenWork = struct {
    inputs: []const CellInput,
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

/// The public chart handle. Open with `openBytes`/`openCells`; release with
/// `deinit`.
pub const Chart = struct {
    backend: Backend,
    data: ?[]u8 = null, // owned archive bytes (PMTiles backend only)
    cache: std.AutoHashMap(u64, []u8), // tile key -> MVT bytes (owned)
    cache_max: usize = 8192,
    // Emit the per-feature pick-report attrs (s57/cell) on live-generated tiles.
    // Defaults ON; the C ABI open can turn it off for lean tiles. (No effect on a
    // PMTiles/reader backend — those tiles are already baked.)
    pick_attrs: bool = true,
    // Encoding for LIVE-generated tiles (cell backends). Defaults to MVT so
    // existing chart-handle consumers (MVT-only renderers) are unaffected; a host
    // whose renderer decodes MLT opts in via setTileFormat. A PMTiles/reader
    // backend ignores it — stored tiles serve verbatim in their baked encoding
    // (see tileType).
    tile_format: scene.TileFormat = .mvt,

    /// Open a source from in-memory bytes. `fmt` selects the backend (`.auto`
    /// sniffs PMTiles then S-57); `rules_dir` is the S-101 rules dir for cells
    /// (null = TILE57_S101_RULES env, else the vendored default). Bytes are copied.
    pub fn openBytes(bytes: []const u8, fmt: Format, rules_dir: ?[]const u8) !*Chart {
        if (fmt == .pmtiles or fmt == .auto) {
            const copy = try gpa.dupe(u8, bytes);
            if (openPmtiles(copy)) |src| return src; // openPmtiles freed `copy` on failure
            if (fmt == .pmtiles) return error.OpenFailed;
        }
        return openCell(bytes, rules_dir) orelse error.OpenFailed;
    }

    /// Open an ENC_ROOT as a multi-cell source: cells are indexed cheaply (band +
    /// bbox) in parallel and parsed/portrayed lazily per tile. All bytes are
    /// copied. Errors if no cell's header parses.
    pub fn openCells(cells_in: []const CellInput, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart {
        if (cells_in.len == 0) return error.OpenFailed;
        const dir = resolveRulesDir(rules_dir);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);

        const tmp = gpa.alloc(LazyCell, cells_in.len) catch return error.OpenFailed;
        defer gpa.free(tmp);
        const ok = gpa.alloc(bool, cells_in.len) catch return error.OpenFailed;
        defer gpa.free(ok);
        @memset(ok, false);

        var ow = OpenWork{ .inputs = cells_in, .out = tmp, .ok = ok };
        bake_enc.parallelFor(gpa, cells_in.len, &ow, OpenWork.run);

        var valid: usize = 0;
        for (ok) |k| {
            if (k) valid += 1;
        }
        if (valid == 0) return error.OpenFailed;

        const cells = gpa.alloc(LazyCell, valid) catch {
            for (tmp, ok) |*lc, k| if (k) lazyFreeCell(lc);
            return error.OpenFailed;
        };
        var j: usize = 0;
        for (tmp, ok) |lc, k| if (k) {
            cells[j] = lc;
            j += 1;
        };

        const src = gpa.create(Chart) catch {
            for (cells) |*lc| lazyFreeCell(lc);
            gpa.free(cells);
            return error.OpenFailed;
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
    pub fn openCellsStreaming(metas: []const CellMeta, reader: CellReadFn, user: ?*anyopaque, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart {
        if (metas.len == 0) return error.OpenFailed;
        const dir = resolveRulesDir(rules_dir);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);
        const cells = gpa.alloc(LazyCell, metas.len) catch return error.OpenFailed;
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
    /// TODO(chart-api): unify the enumeration with the baker's bakeRoot (parity-gated).
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

        var metas = std.ArrayList(CellMeta).empty;
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
        const src = try openCellsStreaming(metas.items, pathRead, null, rules_dir, pick_attrs);
        errdefer src.deinit();
        const ctx = try gpa.create(PathCtx);
        errdefer gpa.destroy(ctx);
        ctx.* = .{ .threaded = threaded, .io = io, .dir = dir, .paths = try paths.toOwnedSlice(gpa) };
        src.backend.cells.reader_user = ctx;
        src.backend.cells.path_ctx = ctx;
        return src;
    }

    /// Release the source and all cached tiles.
    pub fn deinit(self: *Chart) void {
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
        gpa.destroy(self);
    }

    /// The resolved backend format (after an `.auto` sniff).
    pub fn format(self: *Chart) Format {
        return switch (self.backend) {
            .reader => .pmtiles,
            .cell, .cells => .s57_cell,
        };
    }

    /// The encoding `tile` returns: a PMTiles backend reports its archive's stored
    /// tile type (tiles serve verbatim); a cell backend reports its live
    /// generation format (`tile_format`). Non-vector archive types (png/…) are
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

    /// Select the encoding for LIVE-generated tiles (cell backends; no-op for a
    /// baked PMTiles backend — its stored encoding is fixed). Drops the tile
    /// cache so already-served coordinates regenerate in the new format.
    pub fn setTileFormat(self: *Chart, fmt: scene.TileFormat) void {
        switch (self.backend) {
            .reader => return,
            .cell, .cells => {},
        }
        if (self.tile_format == fmt) return;
        self.tile_format = fmt;
        self.clearCache();
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

    /// Fetch tile (z,x,y) as decompressed vector-tile bytes in the chart's tile
    /// encoding (`tileType`): a PMTiles backend serves the stored bytes verbatim
    /// (MVT or MLT, whatever was baked); a cell backend generates in
    /// `tile_format`. Returns null for an empty / absent tile, else
    /// page-allocator-owned bytes (free with `freeBytes`). Cached per source, so
    /// re-requests are cheap and deterministic.
    pub fn tile(self: *Chart, z: u8, x: u32, y: u32) !?[]u8 {
        const key = tileKey(z, x, y);
        if (self.cache.get(key)) |cached| {
            if (cached.len == 0) return null;
            return try gpa.dupe(u8, cached);
        }
        const bytes: []u8 = switch (self.backend) {
            .reader => |*r| (r.getTile(gpa, z, x, y) catch return error.TileGen) orelse try gpa.alloc(u8, 0),
            .cell => |*cb| blk_cell: {
                const one = [_]scene.CellRef{.{
                    .cell = &cb.cell,
                    .portrayal = cb.portrayal,
                    .portrayal_plain = cb.portrayal_plain,
                    .portrayal_simplified = cb.portrayal_simplified,
                }};
                var ar = std.heap.ArenaAllocator.init(gpa);
                defer ar.deinit();
                break :blk_cell scene.encodeTile(ar.allocator(), gpa, &one, z, x, y, self.tile_format, self.pick_attrs) catch return error.TileGen;
            },
            .cells => |*ls| try tileFromCells(ls, z, x, y, self.tile_format, self.pick_attrs),
        };
        if (self.cache.count() >= self.cache_max) {
            var cit = self.cache.valueIterator();
            while (cit.next()) |v| gpa.free(v.*);
            self.cache.clearRetainingCapacity();
        }
        self.cache.put(key, bytes) catch {}; // best-effort; cache owns `bytes` on success
        if (bytes.len == 0) return null;
        return try gpa.dupe(u8, bytes);
    }

    /// Render a VIEW of the chart — centre + fractional zoom + pixel size —
    /// through the native S-52 pixel path: real portrayal, vector symbols,
    /// labels + declutter over the whole canvas. Returns PNG bytes (gpa-owned;
    /// free with freeBytes). Cell-backed sources only; a baked PMTiles source
    /// has no portrayal to render from (bundle-sourced rendering is future work).
    pub fn renderView(self: *Chart, lon: f64, lat: f64, zoom: f64, w: u32, h: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.MarinerSettings, output: render.pixel.Output) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var colors = try render.resolve.Colors.init(a, embedded_assets.colorprofile[0].bytes);
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

        // Complex-linestyle table (idempotent): without it MARSYS51/cable/
        // pipeline styles degrade to generic dashed strokes. gpa-backed: the
        // registry outlives this render (shared with any later bake).
        var ls_srcs = std.ArrayList(@import("assets").LineStyleSrc).empty;
        defer ls_srcs.deinit(gpa);
        for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
        scene.registerLinestylesXml(gpa, ls_srcs.items);

        // Continuous scaling between integer zooms; the host applies physical
        // calibration / @2x via settings.size_scale.
        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var ps = render.pixel.PixelSurface.initView(a, &colors, palette, settings, zoom, w, h, pt, @import("tiles").tile.EXTENT);
        ps.store = store.asStore();
        ps.output = output;

        switch (self.backend) {
            .reader => |*rd| {
                // Bundle-sourced replay: decode each covering baked tile and
                // re-emit it as Surface calls. Lossy by design — the bake-time
                // portrayal context is frozen — but the live-swappable props
                // (danger depth, sounding composition/unit) re-evaluate here.
                var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
                const surf = ps.asSurface();
                try surf.beginScene(vt.z);
                const is_mlt = rd.header.tile_type == .mlt;
                while (vt.next()) |t| {
                    const bytes = (rd.getTile(a, t.z, t.x, t.y) catch continue) orelse continue;
                    const layers = if (is_mlt)
                        @import("tiles").mlt.decode(a, bytes) catch continue
                    else
                        @import("tiles").mvt.decode(a, bytes) catch continue;
                    ps.setOrigin(t.origin_x, t.origin_y);
                    scene.replayTile(surf, layers) catch return error.TileGen;
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
            .cells => |*ls| {
                const keep_from = ls.tick + 1;
                var vt = scene.ViewTiles.init(lon, lat, zoom, w, h, pt);
                const surf = ps.asSurface();
                try surf.beginScene(vt.z);
                while (vt.next()) |t| {
                    var refs = std.ArrayList(scene.CellRef).empty;
                    defer refs.deinit(gpa);
                    if (!try tileRefs(ls, t.z, t.x, t.y, &refs, a)) continue;
                    ps.setOrigin(t.origin_x, t.origin_y);
                    scene.appendTile(surf, a, refs.items, t.z, t.x, t.y, self.pick_attrs) catch return error.TileGen;
                }
                const bytes = surf.endScene(gpa) catch return error.TileGen;
                lazyEvict(ls, keep_from);
                return bytes;
            },
        }
    }

    /// Render a VIEW as ASCII art — renderView's shape on the text surface:
    /// one Unicode character per terminal cell (cols x rows), optional
    /// ANSI-256 color. Returns UTF-8 bytes, one '\n'-terminated row per grid
    /// row (gpa-owned; free with freeBytes). Same backends as renderView.
    pub fn renderAscii(self: *Chart, lon: f64, lat: f64, zoom: f64, cols: u32, rows: u32, palette: render.resolve.PaletteId, settings: *const render.resolve.MarinerSettings, ansi: bool) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // ANSI mode resolves tokens through the same embedded colour profile
        // the pixel path uses; plain mode never consults it. No symbol store
        // and no complex-linestyle table: the ASCII surface lowers symbol
        // NAMES to glyphs itself, and complex linestyles degrading to the
        // generic dashed stroke is exactly the fidelity a text grid carries.
        var colors = try render.resolve.Colors.init(a, embedded_assets.colorprofile[0].bytes);
        const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
        var as = render.ascii.AsciiSurface.initView(a, &colors, palette, settings, zoom, cols, rows, pt, @import("tiles").tile.EXTENT);
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
                    scene.replayTile(surf, layers) catch return error.TileGen;
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
            .cells => |*ls| {
                const keep_from = ls.tick + 1;
                var vt = scene.ViewTiles.init(lon, lat, zoom, as.w_px, as.h_px, as.px_per_tile);
                const surf = as.asSurface();
                try surf.beginScene(vt.z);
                while (vt.next()) |t| {
                    var refs = std.ArrayList(scene.CellRef).empty;
                    defer refs.deinit(gpa);
                    if (!try tileRefs(ls, t.z, t.x, t.y, &refs, a)) continue;
                    as.setOrigin(t.origin_x, t.origin_y);
                    scene.appendTile(surf, a, refs.items, t.z, t.x, t.y, self.pick_attrs) catch return error.TileGen;
                }
                const bytes = surf.endScene(gpa) catch return error.TileGen;
                lazyEvict(ls, keep_from);
                return bytes;
            },
        }
    }

    /// The chart's per-cell metadata as a JSON array:
    /// [{"name","scale","edition","update","issueDate","agency","bbox"?}, …].
    /// DSID fields reflect the applied update chain; bbox is the cell's
    /// geometry extent, omitted when none parses. Returns null when the chart
    /// has no cells (a PMTiles chart carries no cell files — its manifest is
    /// the host-side sidecar). gpa-owned; free with freeBytes.
    pub fn cellsJson(self: *Chart) !?[]u8 {
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
                        var cb: CellBytes = .{};
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
                        var cb: CellBytes = .{};
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

    /// Drop the in-memory tile cache (bounds memory in long-running hosts).
    pub fn clearCache(self: *Chart) void {
        var it = self.cache.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        self.cache.clearRetainingCapacity();
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
    settings: *const render.resolve.MarinerSettings,
    bg: []const u8,
    output: render.pixel.Output,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try render.resolve.Colors.init(a, embedded_assets.colorprofile[0].bytes);
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
    var ls_srcs = std.ArrayList(@import("assets").LineStyleSrc).empty;
    defer ls_srcs.deinit(gpa);
    for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
    scene.registerLinestylesXml(gpa, ls_srcs.items);

    // Always show the previewed feature regardless of its SCAMIN at the framing zoom.
    var s = settings.*;
    s.ignore_scamin = true;

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var ps = render.pixel.PixelSurface.initView(a, &colors, palette, &s, zoom, w, h, pt, tile.EXTENT);
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
    settings: *const render.resolve.MarinerSettings,
    output: render.pixel.Output,
    highlight: ?Highlight,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try render.resolve.Colors.init(a, embedded_assets.colorprofile[0].bytes);
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
    var ls_srcs = std.ArrayList(@import("assets").LineStyleSrc).empty;
    defer ls_srcs.deinit(gpa);
    for (embedded_assets.linestyles) |e| ls_srcs.append(gpa, .{ .id = e.name, .xml = e.bytes }) catch {};
    scene.registerLinestylesXml(gpa, ls_srcs.items);

    const pt: f32 = @floatCast(256.0 * std.math.pow(f64, 2.0, zoom - @round(zoom)));
    var ps = render.pixel.PixelSurface.initView(a, &colors, palette, settings, zoom, w, h, pt, tile.EXTENT);
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
    // The cell's compilation scale, quantized UP its own SCAMIN ladder — the value
    // the raw-cscl smax handoff tag hands off at, so the live client ladder has a
    // crossing to flip carried copies on (see bakeArchive's fold).
    const cscl = cell.params.cscl;
    if (cscl > 0) {
        var best: i64 = std.math.maxInt(i64);
        for (cell.features) |f| if (scene.featureScamin(f)) |sc| {
            if (sc >= cscl and sc < best) best = sc;
        };
        set.put(if (best != std.math.maxInt(i64)) @intCast(best) else @intCast(cscl), {}) catch {};
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
        var cb: CellBytes = .{};
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

// The fallback band for a tile whose zoom sits outside every overlapping
// cell's native window: bake_enc.fallbackBand (finest above all windows,
// coarsest below / in gaps).
const fallbackBand = bake_enc.fallbackBand;

// Whether cell `i`'s light sector figures can reach into tile bounds `tb` at
// zoom z: its light bbox expanded by the per-zoom figure reach
// (scene.lightReachTiles — one tile for display-mm legs/arcs, the honest span
// for ground-length directional legs) overlaps the tile. A never-loaded cell
// (reach unknown) within the one-tile `ring` is loaded once to resolve it; the
// result persists across LRU eviction, so this never reloads. Caveat: an
// unloaded cell whose ground legs reach FURTHER than one tile only resolves
// after its first load — any view near the cell triggers that.
fn lightReachOverlap(ls: *LazySource, i: u32, tb: [4]f64, z: u8, ring: *const [4]f64) bool {
    const lc = &ls.cells[i];
    if (!lc.light_known) {
        if (!bboxOverlap(lc.bbox, ring.*)) return false; // provisional one-tile ring
        lazyEnsureLoaded(ls, lc);
        if (!lc.light_known) return false; // unreadable cell
    }
    const lb = lc.light_bbox orelse return false;
    const reach = scene.lightReachTiles(lc.light_range_m, z, (tb[1] + tb[3]) * 0.5);
    const pad_lon = (tb[2] - tb[0]) * reach;
    const pad_lat = (tb[3] - tb[1]) * reach;
    return lb[0] <= tb[2] + pad_lon and lb[2] >= tb[0] - pad_lon and
        lb[1] <= tb[3] + pad_lat and lb[3] >= tb[1] - pad_lat;
}

// Multi-cell tile generation: collect overlapping cells, lazily load them, apply
// per-scale M_COVR quilting + the scamin-aware band handoff, and overlay
// coarse→fine.
// Select + load the cells contributing to tile (z,x,y) and append their
// quilted CellRefs (suppression/carry computed against the finest covering
// compilation scale, bake_enc.carryGate). Returns false when nothing overlaps.
// Factored from tileFromCells so renderView reuses the exact same selection.
// `scratch` must outlive the tile's encode/append (the per-tile arena): the
// SCAMIN-standalone overlay mini cells are built into it.
fn tileRefs(ls: *LazySource, z: u8, x: u32, y: u32, refs: *std.ArrayList(scene.CellRef), scratch: std.mem.Allocator) !bool {
    const tb = tile.tileBoundsLonLat(z, x, y); // [w,s,e,n]
    // One-tile ring around the tile: the provisional reach-candidacy margin for
    // cells whose sector-figure reach isn't known yet (never loaded).
    const ring = [4]f64{
        tb[0] - (tb[2] - tb[0]), tb[1] - (tb[3] - tb[1]),
        tb[2] + (tb[2] - tb[0]), tb[3] + (tb[3] - tb[1]),
    };
    var any_incl = false;
    var coarsest: ?bake_enc.Band = null;
    var finest: ?bake_enc.Band = null;
    for (ls.cells) |lc| {
        if (!bboxOverlap(lc.bbox, tb)) continue;
        const zr = bake_enc.bandZooms(lc.band);
        if (z >= zr.min and z <= zr.max) any_incl = true;
        if (coarsest == null or @intFromEnum(lc.band) > @intFromEnum(coarsest.?)) coarsest = lc.band;
        if (finest == null or @intFromEnum(lc.band) < @intFromEnum(finest.?)) finest = lc.band;
    }

    // In-tile cells join by band window exactly as before (out-of-window zooms
    // fall back per fallbackBand); cells NEAR the tile join reach-only when
    // their light sector figures can cross into it (lightReachOverlap) — those
    // ride the tile for their figures alone, excluded from the tile-level
    // quilting ladder / overscale scan below (mirrors bake_enc REACH_FLAG).
    var idxs = std.ArrayList(u32).empty;
    defer idxs.deinit(gpa);
    var ridxs = std.ArrayList(u32).empty;
    defer ridxs.deinit(gpa);
    for (ls.cells, 0..) |lc, i| {
        const zr = bake_enc.bandZooms(lc.band);
        const in_window = z >= zr.min and z <= zr.max;
        const use = if (any_incl or coarsest == null)
            in_window
        else
            lc.band == fallbackBand(finest.?, coarsest.?, z);
        if (!use) continue;
        if (bboxOverlap(lc.bbox, tb)) {
            idxs.append(gpa, @intCast(i)) catch {};
        } else if (lightReachOverlap(ls, @intCast(i), tb, z, &ring)) {
            ridxs.append(gpa, @intCast(i)) catch {};
        }
    }
    if (idxs.items.len == 0 and ridxs.items.len == 0) return false;
    const sortByBand = struct {
        fn lt(l: *LazySource, a: u32, b: u32) bool {
            return @intFromEnum(l.cells[a].band) > @intFromEnum(l.cells[b].band);
        }
    }.lt;
    std.mem.sort(u32, idxs.items, ls, sortByBand);
    std.mem.sort(u32, ridxs.items, ls, sortByBand);

    for (idxs.items) |i| lazyEnsureLoaded(ls, &ls.cells[i]);
    for (ridxs.items) |i| lazyEnsureLoaded(ls, &ls.cells[i]);

    // Per-scale quilting + scamin-aware band handoff, the same rules as the baker
    // (bake_enc TileGenCtx.gen): the finest covering cscl gates lines/patterns at
    // the tile centre (derived extents count) and fills/points over the whole tile
    // (real M_COVR only); carryGate turns blanket suppression into an smax-tagged
    // carry where the tile's display window opens coarser than that cscl.
    const w = tb[0];
    const s_ = tb[1];
    const e = tb[2];
    const nlat = tb[3];
    const clon = (w + e) / 2;
    const clat = (s_ + nlat) / 2;
    const gf_centre = finestCsclAtLive(ls, idxs.items, clon, clat, true);
    var gf_whole: i32 = finestCsclAtLive(ls, idxs.items, clon, clat, false);
    for ([_][2]f64{ .{ w, nlat }, .{ e, nlat }, .{ w, s_ }, .{ e, s_ } }) |corner| {
        gf_whole = @max(gf_whole, finestCsclAtLive(ls, idxs.items, corner[0], corner[1], false));
    }
    const display_denom = assets.displayDenomZ(z, clat);
    const ladders = gpa.alloc([]const u32, idxs.items.len) catch return false;
    defer gpa.free(ladders);
    for (idxs.items, 0..) |i, j| ladders[j] = ls.cells[i].scamins;
    // Scale-boundary overscale refinement (specs/overscale.md): the finest
    // compilation scale CONTRIBUTING to this tile — over the quilting's own
    // participant list, mirroring bake_enc TileGenCtx.gen. A cell hatches its
    // OVERSC01 coverage only when a strictly-finer cell also rides this tile
    // (gf_tile < its cscl); whole-view overscale emits no hatch (HUD readout).
    var gf_tile: i32 = std.math.maxInt(i32);
    for (idxs.items) |i| {
        const cs = ls.cells[i].cscl;
        if (cs > 0 and cs < gf_tile) gf_tile = cs;
    }

    for (idxs.items) |i| {
        const lc = &ls.cells[i];
        if (lc.cell) |*c| {
            const g = bake_enc.carryGate(lc.cscl, gf_centre, gf_whole, display_denom, ladders);
            refs.append(gpa, .{
                .cell = c,
                .portrayal = lc.portrayal,
                .portrayal_plain = lc.portrayal_plain,
                .portrayal_simplified = lc.portrayal_simplified,
                .band = @intFromEnum(lc.band),
                .suppress_fills = g.suppress_whole,
                .suppress_patterns = g.suppress_centre,
                .suppress_lines = g.suppress_centre,
                .suppress_points = g.suppress_whole,
                .smax = g.smax,
                // Overscale tag (S-52 §10.1.10.2): the X2 gate denominator
                // (cscl / OVERSCALE_FACTOR). collectScaminCell adds it to the live
                // SCAMIN ladder so the client crossing is exact + never fires early.
                .oscl = bake_enc.overscaleGateDenom(lc.cscl),
                // Hatch only where this cell is the best-available data at a scale
                // boundary: a finer cell rides the tile (gf_tile < cscl) AND this
                // cell wins the pure quilt somewhere (gf_whole >= cscl, pre-carry) —
                // an occluded coarse overview contributes no hatch (specs/overscale.md v3).
                .overscale_hatch = lc.cscl > 0 and gf_tile < lc.cscl and gf_whole >= lc.cscl,
                // SCAMIN standalone: the overlay below owns prim==1 SCAMIN features.
                .skip_scamin_points = true,
                .light_range_m = lc.light_range_m,
            }) catch {};
        }
    }
    // Reach-only cells: their raw bbox misses the tile, only their light sector
    // figures cross into it. Same gates as the in-tile cells (the gf_* samples
    // lie inside the tile, which their coverage can't contain — no suppression
    // they wouldn't get at home), but never an overscale hatch and never a
    // ladder contribution (they were excluded from `ladders`/`gf_tile` above).
    for (ridxs.items) |i| {
        const lc = &ls.cells[i];
        if (lc.cell) |*c| {
            const g = bake_enc.carryGate(lc.cscl, gf_centre, gf_whole, display_denom, ladders);
            refs.append(gpa, .{
                .cell = c,
                .portrayal = lc.portrayal,
                .portrayal_plain = lc.portrayal_plain,
                .portrayal_simplified = lc.portrayal_simplified,
                .band = @intFromEnum(lc.band),
                .suppress_fills = g.suppress_whole,
                .suppress_patterns = g.suppress_centre,
                .suppress_lines = g.suppress_centre,
                .suppress_points = g.suppress_whole,
                .smax = g.smax,
                .oscl = bake_enc.overscaleGateDenom(lc.cscl),
                .overscale_hatch = false,
                .skip_scamin_points = true,
                .light_range_m = lc.light_range_m,
            }) catch {};
        }
    }

    // SCAMIN standalone (specs/scamin-standalone.md), live half: the deduped
    // cross-cell SCAMIN point objects join this tile independent of bands. The
    // dedup here is PER TILE over the covering cells' cached records — matching
    // is local (copies sit within the FOID guard of each other), so it resolves
    // exactly like the bake's global pre-pass.
    appendLiveOverlay(ls, z, tb, clat, refs, scratch) catch {};
    return true;
}

// Gather the covering cells' SCAMIN point records around tile bounds `tb`,
// dedup them locally, cap winners against the finest covering chart, and
// append one mini-cell CellRef per contributing source cell (built into
// `scratch`, which must outlive the tile's encode). Skipped entirely when the
// tile's window is coarser than any plausible SCAMIN (MAX_OVERLAY_DENOM) so
// low zooms don't lazily load the whole root.
fn appendLiveOverlay(ls: *LazySource, z: u8, tb: [4]f64, clat: f64, refs: *std.ArrayList(scene.CellRef), scratch: std.mem.Allocator) !void {
    const floor_denom = assets.displayDenomZ(z + 1, clat);
    if (floor_denom > scamin_pts.MAX_OVERLAY_DENOM) return;

    // Gather margin: one tile (sector-figure reach, mirroring the bake's mini
    // padding) or the FOID guard, whichever is wider — so a group whose member
    // sits just outside the tile still resolves with its full copy set.
    const guard_deg = scamin_pts.FOID_GUARD_M / 111_320.0;
    const gm_lon = @max(tb[2] - tb[0], guard_deg / @max(@cos(clat * std.math.pi / 180.0), 0.2));
    const gm_lat = @max(tb[3] - tb[1], guard_deg);
    const gtb = [4]f64{ tb[0] - gm_lon, tb[1] - gm_lat, tb[2] + gm_lon, tb[3] + gm_lat };

    // Candidate cells: EVERY cell overlapping the gather bounds, loaded on
    // demand regardless of band — the standalone model needs the fine cells'
    // copies (winner geometry/attrs) in coarse tiles and vice versa. A cell
    // whose light sector figures reach FURTHER than the shared margin (ground-
    // length directional legs) also joins via its known reach ring.
    var cand = std.ArrayList(u32).empty;
    defer cand.deinit(gpa);
    for (ls.cells, 0..) |lc, i| {
        if (bboxOverlap(lc.bbox, gtb) or lightReachOverlap(ls, @intCast(i), tb, z, &gtb))
            cand.append(gpa, @intCast(i)) catch {};
    }
    if (cand.items.len == 0) return;
    for (cand.items) |i| lazyEnsureLoaded(ls, &ls.cells[i]);

    // Gather + stamp the records in the window (Rec.cell = live cell index).
    var recs = std.ArrayList(scamin_pts.Rec).empty;
    defer recs.deinit(gpa);
    for (cand.items) |i| {
        const lc = &ls.cells[i];
        const cell_recs = lc.recs orelse continue;
        // Per-cell gather bounds: the shared margin, widened to the cell's own
        // sector-figure reach so a far directional light's record still gathers.
        var cg = gtb;
        if (lc.light_known and lc.light_range_m > 0) {
            const reach = scene.lightReachTiles(lc.light_range_m, z, clat);
            cg[0] = @min(cg[0], tb[0] - (tb[2] - tb[0]) * reach);
            cg[1] = @min(cg[1], tb[1] - (tb[3] - tb[1]) * reach);
            cg[2] = @max(cg[2], tb[2] + (tb[2] - tb[0]) * reach);
            cg[3] = @max(cg[3], tb[3] + (tb[3] - tb[1]) * reach);
        }
        for (cell_recs) |r0| {
            if (r0.lon < cg[0] or r0.lon > cg[2] or r0.lat < cg[1] or r0.lat > cg[3]) continue;
            var r = r0;
            r.cell = i;
            recs.append(gpa, r) catch return;
        }
    }
    if (recs.items.len == 0) return;
    try scamin_pts.dedup(gpa, recs.items);

    // Winners: eligibility-clamp against this tile's window, cap against the
    // finest covering chart (real M_COVR only — the same rule as the bake's
    // resolveWinners), and bucket per source cell for the mini build. Emission
    // bounds = tile + the source cell's sector-figure reach pad (one tile for
    // display-mm figures, the honest span for ground-length directional legs;
    // the per-feature cull inside appendCellFeatures owns the fine filtering).
    var per_cell = std.AutoHashMap(u32, std.ArrayList(scamin_pts.MiniEntry)).init(gpa);
    defer {
        var vit = per_cell.valueIterator();
        while (vit.next()) |v| v.deinit(gpa);
        per_cell.deinit();
    }
    var ladders = std.ArrayList([]const u32).empty;
    defer ladders.deinit(gpa);
    for (recs.items) |r| {
        if (!r.winner) continue;
        const reach = scene.lightReachTiles(ls.cells[r.cell].light_range_m, z, clat);
        const pad_lon = (tb[2] - tb[0]) * reach;
        const pad_lat = (tb[3] - tb[1]) * reach;
        if (r.lon < tb[0] - pad_lon or r.lon > tb[2] + pad_lon or
            r.lat < tb[1] - pad_lat or r.lat > tb[3] + pad_lat) continue;
        var finest: i32 = std.math.maxInt(i32);
        ladders.clearRetainingCapacity();
        for (cand.items) |i| {
            const lc = &ls.cells[i];
            if (lc.cscl <= 0) continue;
            const cov = lazyCellCoverage(lc);
            if (cov.len == 0) continue;
            if (!coverageContains(cov, r.lon, r.lat)) continue;
            finest = @min(finest, lc.cscl);
            ladders.append(gpa, lc.scamins) catch {};
        }
        const cap = scamin_pts.capFor(r.cscl, finest, ladders.items);
        if (!scamin_pts.eligibleAt(r.effective, cap, floor_denom)) continue;
        const gop = try per_cell.getOrPut(r.cell);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(scamin_pts.MiniEntry).empty;
        try gop.value_ptr.append(gpa, .{ .feat = r.feat, .lon = r.lon, .lat = r.lat, .effective = r.effective, .smax = cap });
    }

    var it = per_cell.iterator();
    while (it.next()) |e| {
        const lc = &ls.cells[e.key_ptr.*];
        if (lc.cell == null) continue;
        const cell = &lc.cell.?;
        const mini = try scratch.create(scamin_pts.Mini);
        mini.* = try scamin_pts.buildMini(scratch, cell, e.value_ptr.items, lc.portrayal, lc.portrayal_simplified);
        try refs.append(gpa, .{
            .cell = &mini.cell,
            .portrayal = mini.portrayal,
            .portrayal_simplified = mini.portrayal_simplified,
            .feat_bbox = mini.feat_bbox,
            .feat_smax = mini.feat_smax,
            .scamin_floor = floor_denom,
            .band = @intFromEnum(lc.band),
            .light_range_m = lc.light_range_m,
        });
    }
}

fn tileFromCells(ls: *LazySource, z: u8, x: u32, y: u32, fmt: scene.TileFormat, pick_attrs: bool) ![]u8 {
    const keep_from = ls.tick + 1;
    var refs = std.ArrayList(scene.CellRef).empty;
    defer refs.deinit(gpa);
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    if (!try tileRefs(ls, z, x, y, &refs, ar.allocator())) return try gpa.alloc(u8, 0);
    const bytes = scene.encodeTile(ar.allocator(), gpa, refs.items, z, x, y, fmt, pick_attrs) catch return error.TileGen;
    lazyEvict(ls, keep_from);
    return bytes;
}

// ---- ENC_ROOT bake -------------------------------------------------------

const BakeSource = struct { base: []const u8, updates: []const []const u8, name: []const u8 = "" };

// ---- SCAMIN standalone pre-pass (specs/scamin-standalone.md) ---------------
// Before ANY band pass bakes a tile, every cell is parsed once (parallel,
// transient) and scanned for SCAMIN point records; the union is deduped
// globally (FOID identity across US3/US4/US5 copies), each winner gets its
// effective (MAX) scamin + smax cap, and the winner-owning cells are re-parsed
// to portray JUST the winners (portrayCellSubset) into overlay mini cells.
// The Baker then joins those minis into EVERY tile by per-feature scale-window
// eligibility — independent of bands/emitted-skip/carry-down. The pre-pass
// must be global and up-front because the finest bands bake first: a z16 tile
// needs the effective scamin unioned from the US3 copy parsed only much later.

const scamin_pts = scene.scamin_pts;

const ScanWork = struct {
    sources: []const BakeSource,
    arenas: []?*std.heap.ArenaAllocator, // per-cell scan arenas (freed by the caller)
    scans: []scamin_pts.CellScan,

    fn run(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        _ = scratch;
        const c: *ScanWork = @ptrCast(@alignCast(uptr));
        const src = c.sources[i];
        var cell = s57.parseCellWithUpdates(gpa, src.base, src.updates) catch return;
        defer cell.deinit();
        const pa = gpa.create(std.heap.ArenaAllocator) catch return;
        pa.* = std.heap.ArenaAllocator.init(gpa);
        c.scans[i] = scamin_pts.scanCell(pa.allocator(), &cell, @intCast(i)) catch {
            pa.deinit();
            gpa.destroy(pa);
            return;
        };
        c.arenas[i] = pa;
    }
};

const MiniWork = struct {
    sources: []const BakeSource,
    entries: []const []const scamin_pts.MiniEntry, // per-cell winners (resolveWinners)
    rules_dir: []const u8,
    arenas: []?*std.heap.ArenaAllocator, // per-cell mini arenas (freed by the caller)
    minis: []?scamin_pts.Mini,

    fn run(uptr: *anyopaque, i: usize, scratch: std.mem.Allocator) void {
        _ = scratch;
        const c: *MiniWork = @ptrCast(@alignCast(uptr));
        if (c.entries[i].len == 0) return;
        const src = c.sources[i];
        var cell = s57.parseCellWithUpdates(gpa, src.base, src.updates) catch return;
        defer cell.deinit();
        cell.name = src.name;
        const pa = gpa.create(std.heap.ArenaAllocator) catch return;
        pa.* = std.heap.ArenaAllocator.init(gpa);
        const a = pa.allocator();
        var ok = false;
        defer if (!ok) {
            pa.deinit();
            gpa.destroy(pa);
        };
        // Portray only the winner features (whole-cell adapt, subset rule run).
        const mask = a.alloc(bool, cell.features.len) catch return;
        @memset(mask, false);
        for (c.entries[i]) |e| {
            if (e.feat < mask.len) mask[e.feat] = true;
        }
        var tmp = std.heap.ArenaAllocator.init(gpa);
        defer tmp.deinit();
        const cp = portray.portrayCellSubset(tmp.allocator(), &cell, c.rules_dir, mask) catch portray.CellPortrayal{ .base = &.{} };
        c.minis[i] = scamin_pts.buildMini(a, &cell, c.entries[i], cp.base, cp.simplified) catch return;
        c.arenas[i] = pa;
        ok = true;
    }
};

/// The overlay state a bake driver holds for its whole run: the mini-cell
/// Backends handed to Baker.overlay plus the arenas that own them.
const BakeOverlay = struct {
    backends: []bake_enc.Backend = &.{},
    arenas: []?*std.heap.ArenaAllocator = &.{},

    fn deinit(self: *BakeOverlay) void {
        for (self.arenas) |pa| if (pa) |p| {
            p.deinit();
            gpa.destroy(p);
        };
        if (self.arenas.len > 0) gpa.free(self.arenas);
        if (self.backends.len > 0) gpa.free(self.backends);
    }
};

// Run the whole pre-pass over in-memory cell sources. Returns an empty overlay
// on any failure (the bake then simply behaves band-quilted for points).
fn buildBakeOverlay(sources: []const BakeSource, rules_dir: []const u8) BakeOverlay {
    const n = sources.len;
    if (n == 0) return .{};
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Phase A: parallel parse + scan (cells freed immediately).
    const scan_arenas = sa.alloc(?*std.heap.ArenaAllocator, n) catch return .{};
    @memset(scan_arenas, null);
    defer for (scan_arenas) |pa| if (pa) |p| {
        p.deinit();
        gpa.destroy(p);
    };
    const scans = sa.alloc(scamin_pts.CellScan, n) catch return .{};
    @memset(scans, scamin_pts.CellScan{});
    var sw = ScanWork{ .sources = sources, .arenas = scan_arenas, .scans = scans };
    bake_enc.parallelFor(gpa, n, &sw, ScanWork.run);

    // Phase B: global dedup + caps (serial, cheap).
    const entries = scamin_pts.resolveWinners(gpa, sa, scans, n) catch return .{};

    // Phase C: parallel re-parse + subset-portray + mini build for winner cells.
    const mini_arenas = gpa.alloc(?*std.heap.ArenaAllocator, n) catch return .{};
    @memset(mini_arenas, null);
    const minis = sa.alloc(?scamin_pts.Mini, n) catch {
        gpa.free(mini_arenas);
        return .{};
    };
    @memset(minis, null);
    var mw = MiniWork{ .sources = sources, .entries = entries, .rules_dir = rules_dir, .arenas = mini_arenas, .minis = minis };
    bake_enc.parallelFor(gpa, n, &mw, MiniWork.run);

    var backends = std.ArrayList(bake_enc.Backend).empty;
    for (minis, mini_arenas) |m, pa| {
        const mini = m orelse continue;
        if (pa == null) continue;
        // Deduped LIGHTS winners keep their sector-figure reach (see
        // bundle.buildRootOverlay): the overlay tile pad widens to the
        // ground-leg span so a directional light's leg isn't chopped.
        const lr = scene.collectLightReach(&mini.cell, mini.portrayal);
        backends.append(gpa, .{
            .cell = mini.cell,
            .portrayal = mini.portrayal,
            .portrayal_simplified = mini.portrayal_simplified,
            .feat_bbox = mini.feat_bbox,
            .feat_smax = mini.feat_smax,
            .bounds = mini.bounds,
            .cscl = mini.cell.params.cscl,
            .light_bbox = lr.bbox,
            .light_range_m = lr.range_m,
        }) catch break;
    }
    return .{ .backends = backends.toOwnedSlice(gpa) catch &.{}, .arenas = mini_arenas };
}

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
        var cell = s57.parseCellWithUpdates(gpa, src.base, src.updates) catch return;
        cell.name = src.name; // pick-report badge (borrowed for the bake call)
        const b = cell.bounds() orelse {
            cell.deinit();
            return;
        };
        var portrayal: ?[]const ?[]const u8 = null;
        var portrayal_plain: ?[]const ?[]const u8 = null;
        var portrayal_simplified: ?[]const ?[]const u8 = null;
        var geo: ?scene.GeoParts = null;
        const pa: ?*std.heap.ArenaAllocator = gpa.create(std.heap.ArenaAllocator) catch null;
        if (pa) |p| {
            p.* = std.heap.ArenaAllocator.init(gpa);
            if (portray.portrayCellVariants(p.allocator(), &cell, c.rules_dir)) |cp| {
                portrayal = cp.base;
                portrayal_plain = cp.plain;
                portrayal_simplified = cp.simplified;
            } else |_| {}
            if (c.build_geo) geo = scene.buildGeoCache(p.allocator(), &cell) catch null;
        }
        // M_COVR coverage + scale for per-cell quilting (allocate into the cell's own
        // arena before the move, so it outlives with the backend).
        const coverage = cell.mcovrCoverage(cell.arena.allocator());
        const scamins = bake_enc.collectScamins(cell.arena.allocator(), &cell) catch &.{};
        const cscl = cell.params.cscl;
        // Sector-figure reach (exact, from the portrayal streams): buildTileMap
        // addresses the neighbouring tiles the cell's light legs/arcs cross.
        const lr = scene.collectLightReach(&cell, portrayal);
        c.outs[i] = .{ .cell = cell, .portrayal = portrayal, .portrayal_plain = portrayal_plain, .portrayal_simplified = portrayal_simplified, .geo = geo, .bounds = b, .cscl = cscl, .coverage = coverage, .scamins = scamins, .light_bbox = lr.bbox, .light_range_m = lr.range_m };
        c.arenas[i] = pa;
    }
};

/// Bake an ENC_ROOT (the same cells as `openCells`) into ONE PMTiles archive,
/// zoom-banded per cell by compilation scale. Returns the archive bytes (free
/// with `freeBytes`), or null if nothing was covered. Streams band-by-band
/// (finest → coarsest, best-band dedup + the scamin-aware band handoff), holding
/// at most two adjacent bands' parsed cells at a time (a band's cells ride into
/// the next-coarser pass for its deferred floor tiles), not the whole catalogue.
/// `progress` (nullable) fires during the load+portray phase (stage 0) and the
/// tile-bake phase (stage 1). The caller owns the input bytes for the call.
pub fn bakeArchive(
    cells_in: []const CellInput,
    rules_dir: ?[]const u8,
    minzoom: u8,
    maxzoom: u8,
    fmt: scene.TileFormat,
    pick_attrs: bool,
    progress: Progress,
    user: ?*anyopaque,
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

    // SCAMIN standalone: build the deduped point overlay BEFORE any band pass
    // (the finest bands bake first and already need the effective scamins the
    // coarsest cells contribute). The smax caps join the crossing ladder — they
    // are quantized onto real SCAMIN values, but a raw-CSCL fallback still needs
    // its client crossing published.
    var ov_sources = std.ArrayList(BakeSource).empty;
    defer ov_sources.deinit(gpa);
    for (cells_in) |in| ov_sources.append(gpa, .{ .base = in.base, .updates = in.updates, .name = in.name }) catch break;
    var overlay = buildBakeOverlay(ov_sources.items, dir);
    defer overlay.deinit();
    baker.overlay = overlay.backends;
    baker.scamin_standalone = true;
    for (overlay.backends) |be| if (be.feat_smax) |fs| for (fs) |v| {
        if (v > 0) scamin_set.put(@intCast(v), {}) catch {};
    };

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
            // The cell's quantized compilation scale joins the ladder too: the
            // overscale (`oscl`) and raw-cscl smax fallback tags need a client
            // crossing at their emitted value. Quantizing against the cell's OWN
            // ladder covers every per-tile result — a cross-cell quantization can
            // only land on another cell's ladder value, folded above already.
            if (be.cscl > 0) {
                const q = bake_enc.quantizeHandoff(&.{be.scamins}, be.cscl);
                if (q > 0) scamin_set.put(@intCast(q), {}) catch {};
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
    const meta = try scene.metadataJson(gpa, scamin_vals.items);
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

// Tile sink: feed each streamed tile into the StreamWriter (the Baker frees the
// buffer after this returns; StreamWriter gzips+copies what it keeps).
fn streamSink(ctx: ?*anyopaque, z: u8, x: u32, y: u32, mvt: []const u8) anyerror!void {
    const sw: *pmtiles.StreamWriter = @ptrCast(@alignCast(ctx.?));
    try sw.add(z, x, y, mvt);
}
