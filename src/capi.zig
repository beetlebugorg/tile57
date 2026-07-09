//! C ABI for libtile57.a — a thin shim over the Zig engine API (chart.zig).
//!
//! Contract: POD across the seam (ptr/len + status codes); Zig errors, slices
//! and optionals stay inside chart.zig. Public header: ../../include/tile57.h.
//! The opaque `tile57_chart` is a `*chart.Chart`.

const std = @import("std");
const chart = @import("chart.zig");
const s57 = @import("s57");
const bundle = @import("bundle"); // the whole chart-bundle pipeline (tiles + assets + manifest)
const chartstyle = @import("assets").chartstyle;
const assets = @import("assets");
// The S-52 ColorProfiles/colorProfile.xml baked into the library (build.zig), so
// the style C ABI generates colortables + a base style template with no on-disk
// catalogue. Symbols/linestyles are NOT embedded here (only the bake exe needs them).
const colorprofile_registry = @import("colorprofile_registry");

// smp_allocator (Zig's fast thread-safe GPA), not page_allocator: the live
// tile/chart path makes many small, short-lived allocations; page_allocator
// would mmap each one. Matches the bake CLI's allocator choice.
const gpa = std.heap.smp_allocator;
const Chart = chart.Chart;

// Wall-clock time for "today" date resolution in tile57_build_style. Zig 0.16
// keeps the clock behind Io; the lib links libc, so call time(3) directly.
extern fn time(tloc: ?*c_long) callconv(.c) c_long;

// Keep in sync with the TILE57_VERSION_* macros in tile57.h.
const version_string = "0.1.0";

fn spanOpt(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

/// Return the library version string ("0.1.0").
export fn tile57_version() callconv(.c) [*:0]const u8 {
    return version_string;
}

// One ENC cell's bytes for the C ABI. Mirrors tile57_cell in tile57.h.
const CellInput = extern struct {
    base: [*]const u8,
    base_len: usize,
    updates: ?[*]const [*]const u8,
    update_lens: ?[*]const usize,
    update_count: usize,
    // Source cell name (NUL-terminated, e.g. "US4MD81M") for the pick report's
    // "source cell" badge. NULL/"" = omitted. Appended after the original fields so
    // a host that zero-inits the struct gets the no-name (NULL) behaviour.
    name: ?[*:0]const u8 = null,
};

// Convert the C CellInput[] into a Zig chart.CellInput[] (slices into the host's
// borrowed buffers). Allocates the slice-of-slices into `a`; the engine copies
// what it keeps, so the caller frees the conversion arrays after the call.
fn toCellInputs(a: std.mem.Allocator, c_cells: []const CellInput) ?[]chart.CellInput {
    const out = a.alloc(chart.CellInput, c_cells.len) catch return null;
    for (c_cells, 0..) |cc, i| {
        var ups: []const []const u8 = &.{};
        if (cc.updates != null and cc.update_lens != null and cc.update_count > 0) {
            const arr = a.alloc([]const u8, cc.update_count) catch return null;
            var k: usize = 0;
            while (k < cc.update_count) : (k += 1) arr[k] = cc.updates.?[k][0..cc.update_lens.?[k]];
            ups = arr;
        }
        out[i] = .{ .base = cc.base[0..cc.base_len], .updates = ups, .name = spanOpt(cc.name) orelse "" };
    }
    return out;
}

/// Open ONE S-57 cell (a .000 file, with its .001.. update chain auto-read from the
/// same directory) — or a whole ENC_ROOT directory — via the STREAMING path-open: cell
/// metadata (name/scale/M_COVR) is enumerated up front and tiles are baked lazily per
/// request. Unlike a bake-to-reader open, this backend exposes the per-cell list
/// (tile57_chart_cells) — a header/metadata scan needs no tile bake. See tile57.h.
export fn tile57_chart_open(path: ?[*:0]const u8) callconv(.c) ?*Chart {
    const p = spanOpt(path) orelse return null;
    return chart.Chart.openPath(p, null, true) catch null;
}

/// Open ONE cell for METADATA ONLY (bbox + native scale + M_COVR coverage): a cheap
/// parse, no tile bake — for a host's header/scan pass. Do NOT render_surface this
/// handle (no portrayal). See tile57.h.
export fn tile57_chart_open_header(path: ?[*:0]const u8) callconv(.c) ?*Chart {
    const p = spanOpt(path) orelse return null;
    return chart.openCellHeader(p, null, true) catch null;
}

/// Open ONE cell by baking only [minzoom, maxzoom] to an in-memory PMTiles — a host
/// bakes a narrow band fast for first paint, then re-opens the full range in the
/// background (progressive load). Renders via the fast reader path. See tile57.h.
export fn tile57_chart_open_zoom(path: ?[*:0]const u8, minzoom: u8, maxzoom: u8) callconv(.c) ?*Chart {
    const p = spanOpt(path) orelse return null;
    return chart.openCellBaked(p, null, true, minzoom, maxzoom) catch null;
}

/// Bake ONE cell (+ its updates, read from disk) to PMTiles bytes over its NATIVE band
/// zoom range, into *out / *out_len (free with tile57_free). For persisting a per-cell
/// tile cache to disk. 1=ok, 0=nothing baked, -1=error. See tile57.h.
export fn tile57_bake_cell_bytes(path: ?[*:0]const u8, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const p = spanOpt(path) orelse return -1;
    const archive = chart.bakeCellBytes(p, null) catch return -1;
    if (archive) |a| {
        out.* = a.ptr;
        out_len.* = a.len;
        return 1;
    }
    return 0;
}

/// Combine N per-cell PMTiles archives (each from tile57_bake_cell_bytes, coverage
/// embedded) into one merged PMTiles via the ownership partition. The archives are passed
/// CONCATENATED in `blob` (total `blob_len` bytes), split by the `n` `lens`
/// (sum(lens) == blob_len). Returns 1 with the composed archive in *out / *out_len (free
/// with tile57_free), 0 if nothing composed, -1 on error. See tile57.h.
export fn tile57_compose(
    blob: ?[*]const u8,
    blob_len: usize,
    lens: ?[*]const usize,
    n: usize,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const b = blob orelse return -1;
    const ls = lens orelse return -1;
    if (n == 0) return 0;
    const archives = gpa.alloc([]const u8, n) catch return -1;
    defer gpa.free(archives);
    var off: usize = 0;
    for (0..n) |i| {
        if (off + ls[i] > blob_len) return -1; // lengths overrun the blob
        archives[i] = b[off .. off + ls[i]];
        off += ls[i];
    }
    const composed = bundle.composeArchives(gpa, archives) catch return -1;
    if (composed) |c| {
        out.* = c.ptr;
        out_len.* = c.len;
        return 1;
    }
    return 0;
}

/// Streaming disk-to-disk composite: combine the `n` per-cell PMTiles at `paths` (each from
/// tile57_bake_cell_bytes, written to disk) into one merged PMTiles at `out_path`. The per-cell
/// files are mmap'd (never all resident) and the output is streamed, so a whole district
/// composes in bounded memory. Writes the count of contributing cells to *out_cells if
/// non-null. Returns 1 on success, 0 if nothing composed, -1 on error. See tile57.h.
export fn tile57_compose_files(
    paths: ?[*]const ?[*:0]const u8,
    n: usize,
    out_path: ?[*:0]const u8,
    out_cells: ?*u32,
    on_progress: ?*const fn (ctx: ?*anyopaque, zoom: u32, min_zoom: u32, max_zoom: u32, done: u64, total: u64) callconv(.c) void,
    ctx: ?*anyopaque,
) callconv(.c) c_int {
    const ps = paths orelse return -1;
    const op = spanOpt(out_path) orelse return -1;
    if (n == 0) return 0;
    const list = gpa.alloc([]const u8, n) catch return -1;
    defer gpa.free(list);
    for (0..n) |i| list[i] = spanOpt(ps[i]) orelse return -1;

    // Optional streaming progress: a stack-lived sink the compose walks the zoom ladder through.
    var prog: bundle.ComposeProgress = undefined;
    var pptr: ?*bundle.ComposeProgress = null;
    if (on_progress) |cb| {
        prog = .{ .cb = cb, .ctx = ctx };
        pptr = &prog;
    }

    // The lib has no std.process.Init; stand up a threaded std.Io for the file I/O.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const nc = bundle.composeArchivesToFile(threaded.io(), gpa, list, op, pptr) catch return -1;
    if (out_cells) |p| p.* = @intCast(nc);
    return if (nc > 0) 1 else 0;
}

/// Coverage/zoom summary of a resident compositor, filled by tile57_compose_meta.
const CComposeMeta = extern struct {
    min_zoom: u8,
    max_zoom: u8, // deepest zoom that can be served (native windows + one fill-up overscale zoom)
    cells: u32, // coverage-carrying archives held
    west: f64,
    south: f64,
    east: f64,
    north: f64,
};

/// Read a partition sidecar file into a fresh gpa-owned buffer (or error). Used only during open.
fn readSidecar(io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const n: usize = @intCast(st.size);
    const buf = try gpa.alloc(u8, n);
    errdefer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

/// Open a resident runtime compositor over the `n` per-cell PMTiles at `paths` (each from
/// tile57_bake_cell_bytes, on disk), mmap'd so the cell set is never fully resident. `partition_path`
/// (or NULL) names a partition sidecar (from `tile57 compose --save-partition`) to load and skip the
/// build; a missing/stale one falls back to building. Returns an opaque handle (free with
/// tile57_compose_close), or NULL on error / no coverage-carrying archive. See tile57.h.
export fn tile57_compose_open(
    paths: ?[*]const ?[*:0]const u8,
    n: usize,
    partition_path: ?[*:0]const u8,
) callconv(.c) ?*bundle.ComposeSource {
    const ps = paths orelse return null;
    if (n == 0) return null;
    const list = gpa.alloc([]const u8, n) catch return null;
    defer gpa.free(list);
    for (0..n) |i| list[i] = spanOpt(ps[i]) orelse return null;

    // The lib has no std.process.Init; stand up a threaded std.Io for the open-time file I/O
    // (mmap survives it, and serve/close need no io).
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var load_bytes: ?[]const u8 = null;
    var owned: ?[]u8 = null;
    defer if (owned) |b| gpa.free(b);
    if (spanOpt(partition_path)) |pp| {
        if (readSidecar(io, pp)) |b| {
            owned = b;
            load_bytes = b;
        } else |_| {}
    }

    return (bundle.openComposeSourceFiles(io, gpa, list, load_bytes) catch return null) orelse return null;
}

/// Compose the tile (z,x,y) on demand, returning the RAW (decompressed) MLT in *out / *out_len (free
/// with tile57_free) — what a live tile server hands its HTTP layer. 1=served, 0=no cell owns this
/// tile, -1=error. Byte-faithful to the batch compositor. See tile57.h.
export fn tile57_compose_serve(
    handle: ?*bundle.ComposeSource,
    z: u8,
    x: u32,
    y: u32,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const src = handle orelse return -1;
    const tile = src.serve(gpa, z, x, y) catch return -1;
    if (tile) |t| {
        out.* = t.ptr;
        out_len.* = t.len;
        return 1;
    }
    return 0;
}

/// Fill `out` with the compositor's zoom range + union coverage bounds. See tile57.h.
export fn tile57_compose_meta_get(handle: ?*bundle.ComposeSource, out: *CComposeMeta) callconv(.c) void {
    const src = handle orelse return;
    out.* = .{
        .min_zoom = src.minz,
        .max_zoom = src.loop_max,
        .cells = @intCast(src.readers.len),
        .west = src.bounds[0],
        .south = src.bounds[1],
        .east = src.bounds[2],
        .north = src.bounds[3],
    };
}

/// Release a compositor opened by tile57_compose_open (munmaps the archives, frees the partition).
export fn tile57_compose_close(handle: ?*bundle.ComposeSource) callconv(.c) void {
    if (handle) |src| src.deinit();
}

/// The metadata JSON blob of a PMTiles archive (e.g. the embedded per-cell "coverage"
/// a single-cell bake carries), into *out / *out_len (free with tile57_free). 1=ok,
/// 0=no metadata, -1=error. See tile57.h.
export fn tile57_pmtiles_metadata(pmtiles_ptr: ?[*]const u8, len: usize, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const p = pmtiles_ptr orelse return -1;
    const meta = chart.pmtilesMetadata(gpa, p[0..len]) catch return -1;
    if (meta) |m| {
        out.* = m.ptr;
        out_len.* = m.len;
        return 1;
    }
    return 0;
}

/// Open a whole ENC_ROOT directory (or a single cell) as a lazily-baked chart — the
/// `.cells` backend, for tile fetch / bake, not live render_surface_cb. See tile57.h.
export fn tile57_charts_open(path: ?[*:0]const u8) callconv(.c) ?*Chart {
    const p = spanOpt(path) orelse return null;
    return Chart.openPath(p, null, true) catch null;
}

/// Populate the process-global read-only registries (S-100 catalogue + linestyles) on
/// the calling thread. Call ONCE on the main thread before opening/baking cells from
/// worker threads, so concurrent bake/render is race-free. See tile57.h.
export fn tile57_warmup() callconv(.c) void {
    chart.warmup();
}

/// Open one in-memory ENC cell (base .000 bytes) as a resident chart. See tile57.h.
export fn tile57_chart_open_bytes(base: [*]const u8, len: usize) callconv(.c) ?*Chart {
    if (len == 0) return null;
    const cells = [_]chart.CellInput{.{ .base = base[0..len] }};
    return Chart.openCells(&cells, null, true) catch null;
}

/// Open a baked PMTiles bundle from a file path. See tile57.h.
export fn tile57_chart_open_pmtiles(path: ?[*:0]const u8) callconv(.c) ?*Chart {
    const p = spanOpt(path) orelse return null;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir_path = std.fs.path.dirname(p) orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    const bytes = dir.readFileAlloc(io, std.fs.path.basename(p), gpa, .unlimited) catch return null;
    defer gpa.free(bytes);
    return Chart.openBytes(bytes, .pmtiles, null) catch null;
}

// Fixed-size chart metadata (mirrors tile57_chart_info in tile57.h): folds the old
// zoom_range / bounds / anchor / bands getters into one struct fill.
const CChartInfo = extern struct {
    min_zoom: u8,
    max_zoom: u8,
    bands: u32,
    has_bounds: bool,
    west: f64,
    south: f64,
    east: f64,
    north: f64,
    has_anchor: bool,
    anchor_lat: f64,
    anchor_lon: f64,
    anchor_zoom: f64,
    // The encoding tile57_chart_tile returns (TILE57_TILE_TYPE_*): a PMTiles
    // backend reports its archive's stored type; a cell backend its live
    // generation format. Appended for ABI-append-safety.
    tile_type: u8,
    native_scale: i32, // live cell compilation scale (1:N); 0 = derive from zoom
};

// tile57_tile_type values (keep in sync with tile57.h).
const TILE_TYPE_MVT: u8 = 1;
const TILE_TYPE_MLT: u8 = 2;

/// Fill *out with the chart's fixed metadata (zoom range, bands, bounds, anchor,
/// tile encoding). See tile57.h.
export fn tile57_chart_get_info(src: ?*Chart, out: *CChartInfo) callconv(.c) void {
    out.* = std.mem.zeroes(CChartInfo);
    const s = src orelse return;
    const zr = s.zoomRange();
    out.min_zoom = zr.min;
    out.max_zoom = zr.max;
    out.native_scale = s.nativeScale();
    out.bands = s.bands();
    out.tile_type = switch (s.tileType()) {
        .mlt => TILE_TYPE_MLT,
        else => TILE_TYPE_MVT,
    };
    if (s.bounds()) |b| {
        out.has_bounds = true;
        out.west = b[0];
        out.south = b[1];
        out.east = b[2];
        out.north = b[3];
    }
    if (s.anchor()) |a| {
        out.has_anchor = true;
        out.anchor_lat = a.lat;
        out.anchor_lon = a.lon;
        out.anchor_zoom = a.zoom;
    }
}

const CQueryCb = @import("render").query.QueryCb;

/// Cursor object-query at (lon,lat) for the view `zoom` (web-mercator): invokes
/// cb->feature once per displayed feature the point falls in, with its S-57 class,
/// attribute JSON, and source cell. 0=ok, -1=bad args. See tile57.h.
export fn tile57_chart_query(handle: ?*Chart, lon: f64, lat: f64, zoom: f64, cb: ?*const CQueryCb) callconv(.c) c_int {
    const self = handle orelse return -1;
    const cbp = cb orelse return -1;
    self.queryPoint(lon, lat, zoom, cbp) catch return -1;
    return 0;
}

const CCoverageCb = extern struct {
    ctx: ?*anyopaque,
    ring: *const fn (?*anyopaque, lonlat: [*]const f64, npts: usize) callconv(.c) void,
};

/// The chart's M_COVR data-coverage polygons (live-cell backend only): cb->ring is
/// called once per polygon with its exterior ring as interleaved lon,lat doubles.
/// A baked PMTiles chart carries no coverage polygon (returns 0, no calls).
/// 0 ok, -1 bad args. See tile57.h.
export fn tile57_chart_coverage(handle: ?*Chart, cb: ?*const CCoverageCb) callconv(.c) c_int {
    const self = handle orelse return -1;
    const cbp = cb orelse return -1;
    const polys = self.coverage() orelse return 0;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (polys) |poly| {
        if (poly.len == 0) continue;
        const ring = poly[0]; // exterior ring
        if (ring.len < 3) continue;
        const out = a.alloc(f64, ring.len * 2) catch continue;
        for (ring, 0..) |p, i| {
            out[2 * i] = @as(f64, @floatFromInt(p.lon_e7)) / 1e7;
            out[2 * i + 1] = @as(f64, @floatFromInt(p.lat_e7)) / 1e7;
        }
        cbp.ring(cbp.ctx, out.ptr, ring.len);
    }
    return 0;
}

// Progress callback for tile57_bake_pmtiles / tile57_bake_bundle (matches the header
// typedef + chart.Progress + bake_enc.Progress).
const BakeProgress = ?*const fn (user: ?*anyopaque, stage: u8, done: usize, total: usize, band_index: u8, band_count: u8, band_name: ?[*:0]const u8) callconv(.c) void;

// Shared bake options. Mirrors tile57_bake_opts in tile57.h. catalog_dir/created
// are read only by tile57_bake_bundle.
const CBakeOpts = extern struct {
    rules_dir: ?[*:0]const u8,
    catalog_dir: ?[*:0]const u8,
    created: ?[*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    omit_pick_attrs: bool,
    progress: BakeProgress,
    progress_user: ?*anyopaque,
    // Baked tile encoding: 0 = engine default (MLT), TILE57_TILE_TYPE_MVT,
    // TILE57_TILE_TYPE_MLT. Appended for ABI-append-safety (a zero-initialised
    // struct bakes the default).
    format: u8,
};

// The passed opts or all-defaults (matching NULL opts = every field at its default).
fn bakeOptsOr(opts: ?*const CBakeOpts) CBakeOpts {
    return if (opts) |p| p.* else .{
        .rules_dir = null,
        .catalog_dir = null,
        .created = null,
        .minzoom = 0,
        .maxzoom = 0,
        .omit_pick_attrs = false,
        .progress = null,
        .progress_user = null,
        .format = 0,
    };
}

// tile57_bake_opts.format -> engine TileFormat (0 = default = MLT).
fn bakeFormat(v: u8) @import("scene").TileFormat {
    return if (v == TILE_TYPE_MVT) .mvt else .mlt;
}

/// Bake an ENC_ROOT into ONE PMTiles archive. See tile57.h. 1=ok, 0=empty, -1=error.
export fn tile57_bake_pmtiles(
    cells_ptr: [*]const CellInput,
    count: usize,
    opts: ?*const CBakeOpts,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const o = bakeOptsOr(opts);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cells = toCellInputs(arena.allocator(), cells_ptr[0..count]) orelse return -1;
    const archive = chart.bakeArchive(cells, spanOpt(o.rules_dir), o.minzoom, o.maxzoom, bakeFormat(o.format), !o.omit_pick_attrs, o.progress, o.progress_user, null) catch return -1;
    if (archive) |a| {
        out.* = a.ptr;
        out_len.* = a.len;
        return 1;
    }
    return 0;
}

// Manifest generator string for bake_bundle (matches the CLI's "tile57 0.1.0").
const generator = "tile57 " ++ version_string;

/// Bake a single cell.000 OR a whole ENC_ROOT directory (on-disk paths) into a
/// self-contained chart bundle written under out_dir — the SAME package the
/// `tile57 bake … -o out/` CLI emits (tiles/chart.pmtiles with scamin+vector_layers
/// metadata + assets/{colortables,linestyles}.json + sprite-mln + per-scheme
/// style-{day,dusk,night}.json + manifest.json). rules_dir/catalog_dir NULL or ""
/// use the catalogue embedded in the library. created NULL/"" leaves the manifest
/// "created" unset (else an ISO8601 stamp). progress may be NULL (the built-in
/// console progress is used). out_cell_count / out_bbox (w,s,e,n) are optional.
/// 1=ok, 0=nothing covered (no geometry), -1=error. See tile57.h.
export fn tile57_bake_bundle(
    input: [*:0]const u8,
    out_dir: [*:0]const u8,
    opts: ?*const CBakeOpts,
    out_cell_count: ?*u32,
    out_bbox: ?*[4]f64,
) callconv(.c) c_int {
    const o = bakeOptsOr(opts);
    // The bundle pipeline does filesystem I/O (read ENC, write the bundle dir); the
    // lib has no std.process.Init, so stand up a threaded std.Io for the call.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Scratch arena: bakeBundle's allocations (paths, manifest, styles, cell names)
    // are all consumed by the on-disk writes, so they're freed when this returns.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const res = bundle.bakeBundle(io, arena.allocator(), .{
        .input = std.mem.span(input),
        .out_dir = std.mem.span(out_dir),
        .rules_dir = spanOpt(o.rules_dir) orelse "",
        .catalog_dir = spanOpt(o.catalog_dir) orelse "",
        .generator = generator,
        .created = spanOpt(o.created) orelse "",
        .minzoom = o.minzoom,
        .maxzoom = o.maxzoom,
        .format = bakeFormat(o.format),
        .pick_attrs = !o.omit_pick_attrs,
        .progress = o.progress,
        .progress_user = o.progress_user,
    }) catch |err| return if (err == error.NoGeometry) 0 else -1;
    if (out_cell_count) |p| p.* = @intCast(res.cell_count);
    if (out_bbox) |p| p.* = res.bounds;
    return 1;
}

/// Bake the ownership-partition DEBUG tiles from an ENC_ROOT (on-disk path) into a
/// single PMTiles at out_path: the composited faces (which cell renders which ground
/// at each band), tagged cell/cscl/band/tier/oi/color, NO portrayed content — for a
/// partition-debug UI. `band` < 0 = the band governing each zoom (the natural view);
/// 0..5 (berthing..overview) = one band's own map at every zoom. out_cell_count is
/// optional. 1=ok, 0=nothing covered (no M_COVR), -1=error. See tile57.h.
export fn tile57_bake_partition_debug(
    enc_root: [*:0]const u8,
    out_path: [*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    band: i8,
    out_cell_count: ?*u32,
) callconv(.c) c_int {
    // The debug bake does filesystem I/O (read ENC_ROOT, write the pmtiles); the lib
    // has no std.process.Init, so stand up a threaded std.Io for the call. It streams
    // internally (StreamWriter over gpa), so pass the real gpa, not a scratch arena.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const nc = bundle.bakePartitionDebug(io, gpa, std.mem.span(enc_root), std.mem.span(out_path), minzoom, maxzoom, band) catch |err| return if (err == error.NoGeometry) 0 else -1;
    if (out_cell_count) |p| p.* = @intCast(nc);
    return 1;
}

/// Release a chart and all cached tiles. See tile57.h.
export fn tile57_chart_close(handle: ?*Chart) callconv(.c) void {
    if (handle) |s| s.deinit();
}

/// The distinct SCAMIN denominators present in the chart (the live SCAMIN manifest;
/// see tile57.h). On success returns 1 with *out pointing at *out_len int32 values
/// (ascending), 0 if there are none; -1 on error. Free *out with tile57_free
/// ((uint8_t*)*out, *out_len * sizeof(int32_t)).
export fn tile57_chart_scamin(handle: ?*Chart, out: *[*]i32, out_len: *usize) callconv(.c) c_int {
    const s = handle orelse return -1;
    const vals = s.scamin() catch return -1;
    if (vals.len == 0) {
        chart.freeBytes(@as([*]u8, @ptrCast(vals.ptr))[0 .. vals.len * @sizeOf(u32)]);
        out_len.* = 0;
        return 0;
    }
    out.* = @ptrCast(vals.ptr); // SCAMIN denominators fit in int32 (max ~2^31)
    out_len.* = vals.len;
    return 1;
}

/// Fetch tile (z,x,y) as decompressed vector-tile bytes in the chart's tile
/// encoding (chart_info.tile_type: stored type for a PMTiles backend, the live
/// generation format for a cell backend). 1=OK + out/out_len, 0=empty, -1=error.
export fn tile57_chart_tile(
    handle: ?*Chart,
    z: u8,
    x: u32,
    y: u32,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const s = handle orelse return -1;
    const r = s.tile(z, x, y) catch return -1;
    if (r) |bytes| {
        out.* = bytes.ptr;
        out_len.* = bytes.len;
        return 1;
    }
    return 0;
}

/// Render a VIEW of the chart (centre + fractional zoom + pixel size) to PNG
/// through the native S-52 pixel path: the mariner settings evaluate LIVE
/// (real safety contour, category/SCAMIN/text-group gates, palette), symbols
/// replay as vectors, labels declutter over the whole canvas. `m` NULL =
/// defaults. Returns 0 with *out/*out_len set (free with tile57_free);
/// -1 bad handle, -2 render failure, -3 unsupported source (a baked PMTiles
/// chart carries no portrayal to render from).
export fn tile57_chart_render_view(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const c = handle orelse return -1;
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return -2;
    const settings: chartstyle.MarinerSettings = if (m) |p| marinerFromC(p) else .{};
    const palette: RenderPalette = switch (settings.scheme) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
    const bytes = c.renderView(lon, lat, zoom, width, height, palette, &settings, .png, null) catch |e| switch (e) {
        error.Unsupported => return -3,
        else => return -2,
    };
    out.* = bytes.ptr;
    out_len.* = bytes.len;
    return 0;
}

const RenderPalette = @import("render").resolve.PaletteId;

/// The chart's per-cell metadata as JSON:
/// [{"name","scale","edition","update","issueDate","agency","bbox"?}, …].
/// DSID fields reflect the applied update chain. Returns 1 with *out/*out_len
/// set (free with tile57_free); 0 when the chart has no cells (e.g. a PMTiles
/// chart — its manifest is the sidecar); -1 on error/bad handle.
export fn tile57_chart_cells(handle: ?*Chart, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const c = handle orelse return -1;
    const bytes = (c.cellsJson() catch return -1) orelse return 0;
    out.* = bytes.ptr;
    out_len.* = bytes.len;
    return 1;
}

/// Decode a CATALOG.031 exchange-set catalogue into a JSON array of its CATD
/// entries:
/// [{"file","longName","impl","bbox"?}, …]. Not chart-scoped. Returns 1 with
/// *out/*out_len set (free with tile57_free); 0 when no CATD records; -1 on
/// parse error.
export fn tile57_catalog_entries(catalog_031: [*]const u8, len: usize, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = s57.parseCatalog(a, catalog_031[0..len]) orelse return -1;
    if (entries.len == 0) return 0;
    var buf = std.ArrayList(u8).empty;
    buf.append(a, '[') catch return -1;
    for (entries, 0..) |e, i| {
        if (i > 0) buf.append(a, ',') catch return -1;
        buf.appendSlice(a, "{\"file\":") catch return -1;
        jsonStr(a, &buf, e.path) catch return -1;
        buf.appendSlice(a, ",\"longName\":") catch return -1;
        jsonStr(a, &buf, e.long_name) catch return -1;
        buf.appendSlice(a, ",\"impl\":") catch return -1;
        jsonStr(a, &buf, e.impl) catch return -1;
        if (e.bbox) |b| buf.print(a, ",\"bbox\":[{d},{d},{d},{d}]", .{ b[0], b[1], b[2], b[3] }) catch return -1;
        buf.append(a, '}') catch return -1;
    }
    buf.append(a, ']') catch return -1;
    const bytes = gpa.dupe(u8, buf.items) catch return -1;
    out.* = bytes.ptr;
    out_len.* = bytes.len;
    return 1;
}

fn jsonStr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        else => if (ch < 0x20) {
            try buf.print(a, "\\u{x:0>4}", .{ch});
        } else try buf.append(a, ch),
    };
    try buf.append(a, '"');
}

/// The chart's features for the given comma-separated object-class acronyms
/// (e.g. "DEPARE,DRGARE") as a GeoJSON FeatureCollection:
/// lon/lat geometry, properties = {"class", …the full S-57 attribute map}.
/// Parsed without portrayal; a whole-ENC_ROOT query walks every cell — the
/// caller owns that cost. Returns 1 with *out/*out_len set (free with
/// tile57_free); 0 when nothing matched; -1 on error.
export fn tile57_chart_features(handle: ?*Chart, classes: ?[*:0]const u8, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const c = handle orelse return -1;
    const cls = classes orelse return -1;
    const bytes = (c.featuresJson(std.mem.span(cls)) catch return -1) orelse return 0;
    out.* = bytes.ptr;
    out_len.* = bytes.len;
    return 1;
}

/// tile57_chart_render_view's vector twin: the SAME scene emitted as a
/// deterministic single-page PDF (1 px = 1 pt, 72 dpi page; vector fills,
/// native strokes, glyph-outline text). Same returns/ownership.
export fn tile57_chart_render_pdf(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const c = handle orelse return -1;
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return -2;
    const settings: chartstyle.MarinerSettings = if (m) |p| marinerFromC(p) else .{};
    const palette: RenderPalette = switch (settings.scheme) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
    const bytes = c.renderView(lon, lat, zoom, width, height, palette, &settings, .pdf, null) catch |e| switch (e) {
        error.Unsupported => return -3,
        else => return -2,
    };
    out.* = bytes.ptr;
    out_len.* = bytes.len;
    return 0;
}

const CbCanvas = @import("render").cb_canvas.CCanvas;

/// tile57_chart_render_view's GPU/vector twin: run the SAME view portrayal, but
/// paint every resolved, flattened primitive through the C callback table
/// `canvas` (see tile57.h) instead of rasterising. Geometry is emitted in canvas
/// PIXEL space (y down) in paint order; colours are resolved for the palette.
/// Same INVERTED return convention as tile57_chart_render_view:
///   0 ok / -1 bad handle / -2 render failure / -3 unsupported source.
export fn tile57_chart_render_view_cb(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    canvas: ?*const CbCanvas,
) callconv(.c) c_int {
    const c = handle orelse return -1;
    const cb = canvas orelse return -2;
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return -2;
    const settings: chartstyle.MarinerSettings = if (m) |p| marinerFromC(p) else .{};
    const palette: RenderPalette = switch (settings.scheme) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
    const bytes = c.renderView(lon, lat, zoom, width, height, palette, &settings, .callback, cb) catch |e| switch (e) {
        error.Unsupported => return -3,
        else => return -2,
    };
    chart.freeBytes(bytes); // the callback path returns an empty buffer
    return 0;
}

const CSurface = @import("render").vector.CSurface;

/// GPU vector twin of render_view_cb: run the SAME view portrayal, but emit a
/// WORLD-SPACE tagged stream (areas/lines in web-mercator [0,1]; symbols/text as
/// a world anchor + local reference-px outline; per-feature class + SCAMIN) to
/// the C surface callback `surface` (see tile57.h). The host transforms geometry
/// and pins symbols/text at a constant screen size, culling by SCAMIN — no
/// re-portrayal per pan/zoom. Works for a baked bundle OR a live cell.
///   0 ok / -1 bad handle / -2 render failure / -3 unsupported source.
export fn tile57_chart_render_surface_cb(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    surface: ?*const CSurface,
) callconv(.c) c_int {
    const c = handle orelse return -1;
    const sfc = surface orelse return -2;
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return -2;
    const settings: chartstyle.MarinerSettings = if (m) |p| marinerFromC(p) else .{};
    const palette: RenderPalette = switch (settings.scheme) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
    c.renderSurfaceView(lon, lat, zoom, width, height, palette, &settings, sfc) catch |e| switch (e) {
        error.Unsupported => return -3,
        else => return -2,
    };
    return 0;
}

/// Free any engine-returned buffer (tiles, style, scamin array, colortables, …). See tile57.h.
/// (chart-api.md — the universal free.)
export fn tile57_free(ptr: ?*anyopaque, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    chart.freeBytes(@as([*]u8, @ptrCast(p))[0..len]);
}

/// Drop the in-memory tile cache (bounds memory in long-running hosts).
export fn tile57_chart_clear_cache(handle: ?*Chart) callconv(.c) void {
    if (handle) |s| s.clearCache();
}

/// Select the encoding for LIVE-generated tiles on a cell-backed chart
/// (0 = engine default (MLT), TILE57_TILE_TYPE_MVT, TILE57_TILE_TYPE_MLT).
/// No-op for a baked PMTiles chart — its stored encoding is fixed. Changing the
/// format drops the tile cache so served coordinates regenerate. The result is
/// reported by chart_info.tile_type. See tile57.h.
export fn tile57_chart_set_tile_format(handle: ?*Chart, fmt: u8) callconv(.c) void {
    if (handle) |s| s.setTileFormat(bakeFormat(fmt));
}

// ---- portrayal asset generation (in-memory; mirrors tile57.h) --------------
//
// Generate the S-101 portrayal assets from the library's embedded catalogue (or an
// on-disk PortrayalCatalog override). Reuses the same bundle emitters bake_bundle
// writes to disk, so the in-memory bundle matches the on-disk one byte-for-byte.

// The S-52 colour profile baked into the library, or null if (somehow) absent.
fn embeddedColorProfileXml() ?[]const u8 {
    for (colorprofile_registry.entries) |e| return e.bytes;
    return null;
}

/// S-52 colortables.json from the colour profile baked into the library — no
/// on-disk catalogue needed. Pair with tile57_style_template / tile57_build_style.
/// 1=ok + out/out_len (free with tile57_free), 0=error.
export fn tile57_colortables_default(out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const xml = embeddedColorProfileXml() orelse return 0;
    const json = assets.colorTablesJson(gpa, xml) catch return 0;
    out.* = json.ptr;
    out_len.* = json.len;
    return 1;
}

// All portrayal assets in memory. Mirrors tile57_assets in tile57.h; each non-null
// field is a gpa-owned buffer freed by tile57_assets_free (via chart.freeBytes).
const CAssets = extern struct {
    colortables: ?[*]u8 = null,
    colortables_len: usize = 0,
    linestyles: ?[*]u8 = null,
    linestyles_len: usize = 0,
    sprite_json: ?[*]u8 = null,
    sprite_json_len: usize = 0,
    sprite_png: ?[*]u8 = null,
    sprite_png_len: usize = 0,
    pattern_json: ?[*]u8 = null,
    pattern_json_len: usize = 0,
    pattern_png: ?[*]u8 = null,
    pattern_png_len: usize = 0,
};

// Dupe each generated (arena-owned) buffer into `gpa` so the C owner can free them
// via chart.freeBytes. Fills out.* in place; on OOM the caller frees via
// tile57_assets_free (each field's len is set immediately after its ptr).
fn fillAssets(out: *CAssets, ct: []const u8, ls: []const u8, spr_json: []const u8, spr_png: []const u8, pat_json: []const u8, pat_png: []const u8) !void {
    out.colortables = (try gpa.dupe(u8, ct)).ptr;
    out.colortables_len = ct.len;
    out.linestyles = (try gpa.dupe(u8, ls)).ptr;
    out.linestyles_len = ls.len;
    out.sprite_json = (try gpa.dupe(u8, spr_json)).ptr;
    out.sprite_json_len = spr_json.len;
    out.sprite_png = (try gpa.dupe(u8, spr_png)).ptr;
    out.sprite_png_len = spr_png.len;
    out.pattern_json = (try gpa.dupe(u8, pat_json)).ptr;
    out.pattern_json_len = pat_json.len;
    out.pattern_png = (try gpa.dupe(u8, pat_png)).ptr;
    out.pattern_png_len = pat_png.len;
}

/// All portrayal assets in memory (the same files bake_bundle writes to disk), from
/// the embedded catalogue (catalog_dir NULL/"") or an on-disk one. 1=ok + *out filled
/// (free with tile57_assets_free), 0=error. See tile57.h.
export fn tile57_bake_assets(catalog_dir: ?[*:0]const u8, out: *CAssets) callconv(.c) c_int {
    out.* = .{};
    // The bundle emitters do filesystem I/O for an on-disk catalogue; the lib has no
    // std.process.Init, so stand up a threaded std.Io for the call.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Scratch arena for generation; the final buffers are duped into gpa (C-owned).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cd = spanOpt(catalog_dir) orelse "";

    const ct = bundle.colorTablesBytes(io, a, cd) catch return 0;
    const ls = bundle.linestylesBytes(io, a, cd) catch return 0;
    const spr = bundle.spriteAtlasBytes(io, a, cd, bundle.DEFAULT_CSS) catch return 0;
    const pat = bundle.patternAtlasBytes(io, a, cd, bundle.DEFAULT_CSS) catch return 0;

    fillAssets(out, ct, ls, spr.json, spr.png, pat.json, pat.png) catch {
        tile57_assets_free(out);
        return 0;
    };
    return 1;
}

/// Like tile57_bake_assets but the sprite_* fields carry the MapLibre sprite-mln
/// atlas: each symbol pivot-centred in its cell + {name:{x,y,width,height,
/// pixelRatio}} JSON. Only sprite_json/sprite_png are filled. Free with
/// tile57_assets_free. 1=ok, 0=error. See tile57.h.
export fn tile57_bake_sprite_mln(catalog_dir: ?[*:0]const u8, out: *CAssets) callconv(.c) c_int {
    out.* = .{};
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cd = spanOpt(catalog_dir) orelse "";
    const spr = bundle.spriteMlnBytes(io, a, cd, bundle.DEFAULT_CSS, &[_][]const u8{}) catch return 0;
    fillAssets(out, "", "", spr.json, spr.png, "", "") catch {
        tile57_assets_free(out);
        return 0;
    };
    return 1;
}

const glyph_sdf = @import("sprite").glyph;

// Glyph metrics as compact JSON: {"em_px","pad","glyphs":{cp:[u0,v0,u1,v1,ox,oy,w,h,adv]}}.
fn glyphMetricsJson(a: std.mem.Allocator, atlas: *const glyph_sdf.Atlas) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(a, "{{\"em_px\":{d},\"pad\":{d},\"glyphs\":{{", .{ atlas.em_px, atlas.pad });
    var it = atlas.glyphs.iterator();
    var first = true;
    while (it.next()) |e| {
        const g = e.value_ptr.*;
        if (!first) try out.append(a, ',');
        first = false;
        try out.print(a, "\"{d}\":[{d},{d},{d},{d},{d},{d},{d},{d},{d}]", .{ e.key_ptr.*, g.u0, g.v0, g.u1, g.v1, g.off_x, g.off_y, g.w, g.h, g.advance });
    }
    try out.appendSlice(a, "}}");
    return out.toOwnedSlice(a);
}

/// SDF glyph atlas for GPU text: sprite_png = the RGBA SDF atlas, sprite_json =
/// {"em_px","pad","glyphs":{codepoint:[u0,v0,u1,v1,ox,oy,w,h,adv]}} (EM units).
/// Only sprite_* filled. Free with tile57_assets_free. 1=ok, 0=error. See tile57.h.
export fn tile57_bake_glyph_sdf(out: *CAssets) callconv(.c) c_int {
    out.* = .{};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const font = @import("render").font.notosans;
    const cps = glyph_sdf.defaultCodepoints(a) catch return 0;
    var atlas = glyph_sdf.build(a, font, cps, 32.0, 6) catch return 0;
    const png = (atlas.encodePng(a) catch return 0) orelse return 0;
    const json = glyphMetricsJson(a, &atlas) catch return 0;
    out.sprite_png = (gpa.dupe(u8, png) catch {
        tile57_assets_free(out);
        return 0;
    }).ptr;
    out.sprite_png_len = png.len;
    out.sprite_json = (gpa.dupe(u8, json) catch {
        tile57_assets_free(out);
        return 0;
    }).ptr;
    out.sprite_json_len = json.len;
    return 1;
}

/// Free every non-null buffer in *out and zero the struct. See tile57.h.
export fn tile57_assets_free(out: *CAssets) callconv(.c) void {
    if (out.colortables) |p| chart.freeBytes(p[0..out.colortables_len]);
    if (out.linestyles) |p| chart.freeBytes(p[0..out.linestyles_len]);
    if (out.sprite_json) |p| chart.freeBytes(p[0..out.sprite_json_len]);
    if (out.sprite_png) |p| chart.freeBytes(p[0..out.sprite_png_len]);
    if (out.pattern_json) |p| chart.freeBytes(p[0..out.pattern_json_len]);
    if (out.pattern_png) |p| chart.freeBytes(p[0..out.pattern_png_len]);
    out.* = .{};
}

// ---- chart-style generation (mirrors tile57_mariner in tile57.h) -----------

const CMariner = extern struct {
    scheme: c_int,
    shallow_contour: f64,
    safety_contour: f64,
    deep_contour: f64,
    safety_depth: f64,
    four_shade_water: bool,
    depth_unit: c_int,
    display_base: bool,
    display_standard: bool,
    display_other: bool,
    data_quality: bool,
    show_inform_callouts: bool,
    show_meta_bounds: bool,
    show_isolated_dangers_shallow: bool,
    boundary_style: c_int,
    simplified_points: bool,
    show_full_sector_lines: bool,
    text_names: bool,
    show_light_descriptions: bool,
    text_other: bool,
    date_dependent: bool,
    highlight_date_dependent: bool,
    date_view: [9]u8,
    ignore_scamin: bool,
    size_scale: f64,
    // S-52 §14.5 fine-grained viewing-group control: a DENY-LIST of the raw `vg`
    // ids the mariner turned OFF (NULL/len 0 -> every group shown). Appended at the
    // end for ABI-append-safety. The pointee must outlive the tile57_build_style call.
    viewing_groups_off: [*c]const i32,
    viewing_groups_off_len: u32,
    // scamin-layers.md: gate SCAMIN with a live client filter instead of per-value
    // bucket layers (one *_scamin layer per render-type). Appended for ABI-append-safety.
    scamin_filter_gate: bool,
    // S-52 §10.1.10 overscale indication (AP(OVERSC01) over overscaled coverage):
    // drives the `overscale` layer's visibility. Appended for ABI-append-safety;
    // tile57_mariner_defaults sets true.
    show_overscale: bool,
};

// "YYYYMMDD" or "" from the fixed char[9] field.
fn dateViewSlice(buf: *const [9]u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..@min(n, 8)];
}

// Translate the extern CMariner into the internal chartstyle.MarinerSettings the
// style builders take. The returned value borrows `cm`'s date_view and
// viewing_groups_off storage, so `cm` (and its viewing_groups_off array) must
// outlive every use of the result — true within a single ABI call.
fn marinerFromC(cm: *const CMariner) chartstyle.MarinerSettings {
    return .{
        .scheme = switch (cm.scheme) {
            1 => .dusk,
            2 => .night,
            else => .day,
        },
        .shallow_contour = cm.shallow_contour,
        .safety_contour = cm.safety_contour,
        .deep_contour = cm.deep_contour,
        .safety_depth = cm.safety_depth,
        .four_shade_water = cm.four_shade_water,
        .depth_unit = if (cm.depth_unit == 1) .feet else .meters,
        .display_base = cm.display_base,
        .display_standard = cm.display_standard,
        .display_other = cm.display_other,
        .data_quality = cm.data_quality,
        .show_inform_callouts = cm.show_inform_callouts,
        .show_meta_bounds = cm.show_meta_bounds,
        .show_isolated_dangers_shallow = cm.show_isolated_dangers_shallow,
        .boundary_style = if (cm.boundary_style == 1) .plain else .symbolized,
        .simplified_points = cm.simplified_points,
        .show_full_sector_lines = cm.show_full_sector_lines,
        .text_names = cm.text_names,
        .show_light_descriptions = cm.show_light_descriptions,
        .text_other = cm.text_other,
        .date_dependent = cm.date_dependent,
        .highlight_date_dependent = cm.highlight_date_dependent,
        .date_view = dateViewSlice(&cm.date_view),
        .ignore_scamin = cm.ignore_scamin,
        .scamin_filter_gate = cm.scamin_filter_gate,
        .show_overscale = cm.show_overscale,
        .size_scale = cm.size_scale,
        .viewing_groups_off = if (cm.viewing_groups_off != null and cm.viewing_groups_off_len > 0)
            cm.viewing_groups_off[0..cm.viewing_groups_off_len]
        else
            null,
    };
}

// The distinct SCAMIN denominators the host passed (host i32 -> u32 styleJson
// buckets on). Returns an empty slice for NULL/count 0. Caller frees a non-empty
// result with gpa.free.
fn scaminBuf(scamin: ?[*]const i32, scamin_count: usize) ![]u32 {
    const p = scamin orelse return &.{};
    if (scamin_count == 0) return &.{};
    const buf = try gpa.alloc(u32, scamin_count);
    for (p[0..scamin_count], 0..) |v, i| buf[i] = @intCast(v);
    return buf;
}

/// Build a MapLibre style JSON from a template + mariner settings + colortables.
/// 1=ok + out/out_len (free with tile57_free), 0=error.
export fn tile57_build_style(
    template_json: [*]const u8,
    template_len: usize,
    cm: *const CMariner,
    colortables_json: ?[*]const u8,
    colortables_len: usize,
    enabled_bands: ?[*]const i32,
    enabled_band_count: usize,
    scamin: ?[*]const i32,
    scamin_count: usize,
    scamin_lat: f64,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const m = marinerFromC(cm);
    const tmpl = template_json[0..template_len];
    const cts: []const u8 = if (colortables_json) |p| p[0..colortables_len] else "";
    const bands: ?[]const i32 = if (enabled_bands) |p| p[0..enabled_band_count] else null;
    // SCAMIN manifest (the distinct denominators the host read from the source /
    // TileJSON): converted from the host's i32 to the u32 denominators styleJson
    // buckets on. Empty/NULL -> the *_scamin layers stay ungated (host §"Still
    // needed" #1: the runtime build_style now emits the SAME per-value native-minzoom
    // buckets the offline bundle does when given the manifest).
    const scamin_buf = scaminBuf(scamin, scamin_count) catch return 0;
    defer if (scamin_buf.len > 0) gpa.free(scamin_buf);
    const now_unix: i64 = @intCast(time(null));
    // Single style builder: regenerate the full style with the mariner baked in
    // (chartstyle.buildStyle's template-patch pass is retired). buildFromTemplate lifts
    // the source config out of the passed template and drives the one styleJson.
    const style = assets.buildFromTemplateScamin(gpa, tmpl, &m, cts, bands, now_unix, scamin_buf, scamin_lat) catch return 0;
    out.* = style.ptr;
    out_len.* = style.len;
    return 1;
}

/// Compute the minimal MapLibre style-mutation ops to turn the style for `old_m`
/// into the style for `new_m` (same template/colortables/bands/scamin inputs as
/// tile57_build_style, so the two styles are comparable). Writes a JSON op array to
/// out/out_len (free with tile57_free): "[]" when nothing changed, one op per
/// differing filter/paint/layout key, or [{"op":"rebuild"}] when the two mariners
/// would produce a different SET of layers (host falls back to a full setStyle).
/// 1=ok, 0=error. See style-diff.md.
export fn tile57_style_diff(
    template_json: [*]const u8,
    template_len: usize,
    old_m: *const CMariner,
    new_m: *const CMariner,
    colortables_json: ?[*]const u8,
    colortables_len: usize,
    enabled_bands: ?[*]const i32,
    enabled_band_count: usize,
    scamin: ?[*]const i32,
    scamin_count: usize,
    scamin_lat: f64,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const om = marinerFromC(old_m);
    const nm = marinerFromC(new_m);
    const tmpl = template_json[0..template_len];
    const cts: []const u8 = if (colortables_json) |p| p[0..colortables_len] else "";
    const bands: ?[]const i32 = if (enabled_bands) |p| p[0..enabled_band_count] else null;
    const scamin_buf = scaminBuf(scamin, scamin_count) catch return 0;
    defer if (scamin_buf.len > 0) gpa.free(scamin_buf);
    // One wall-clock read shared by both builds so "today" date resolution matches
    // on both sides — otherwise a clock tick could show as a spurious date-filter op.
    const now_unix: i64 = @intCast(time(null));

    const old_style = assets.buildFromTemplateScamin(gpa, tmpl, &om, cts, bands, now_unix, scamin_buf, scamin_lat) catch return 0;
    defer gpa.free(old_style);
    const new_style = assets.buildFromTemplateScamin(gpa, tmpl, &nm, cts, bands, now_unix, scamin_buf, scamin_lat) catch return 0;
    defer gpa.free(new_style);

    const ops = assets.styleDiff(gpa, old_style, new_style) catch return 0;
    out.* = ops.ptr;
    out_len.* = ops.len;
    return 1;
}

/// Generate the base MapLibre style template from the catalogue baked into the
/// library — no on-disk catalogue or template file needed. This carries the chart
/// `sources` block, sprite/glyph URLs and the layer set; mariner settings are then
/// applied on top with tile57_build_style (which substitutes only paint/filter
/// props and takes no source). `scheme` is a tile57_scheme. `source_tiles` is the
/// {z}/{x}/{y} chart tiles URL (NULL -> a default pmtiles:// source). `sprite` /
/// `glyphs` are base URLs that enable the symbol / text layers (NULL omits them).
/// `minzoom` is the chart source's tile floor, emitted VERBATIM — pass the
/// archive's real minzoom (0 = tiles exist from z0; MapLibre never requests below
/// a source's minzoom, so an inflated floor blanks every lower zoom). `maxzoom`
/// of 0 -> engine default. `tile_encoding` is the chart source's tile encoding
/// (a tile57_tile_type; TILE57_TILE_TYPE_MLT emits `"encoding":"mlt"` on the
/// source so maplibre-gl >=5.12 decodes MLT natively; 0/MVT emits nothing).
/// 1=ok + out/out_len (free with tile57_free), 0=error.
export fn tile57_style_template(
    scheme: c_int,
    source_tiles: ?[*:0]const u8,
    sprite_url: ?[*:0]const u8,
    glyphs_url: ?[*:0]const u8,
    minzoom: u32,
    maxzoom: u32,
    tile_encoding: u8,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const xml = embeddedColorProfileXml() orelse return 0;
    const cts = assets.colorTablesJson(gpa, xml) catch return 0;
    defer gpa.free(cts);
    var opts = assets.StyleOpts{
        .scheme = switch (scheme) {
            1 => "dusk",
            2 => "night",
            else => "day",
        },
        .colortables_json = cts,
    };
    if (source_tiles) |s| opts.source_tiles = std.mem.span(s);
    if (sprite_url) |s| opts.sprite = std.mem.span(s);
    if (glyphs_url) |g| opts.glyphs = std.mem.span(g);
    opts.minzoom = minzoom;
    if (maxzoom != 0) opts.maxzoom = maxzoom;
    if (tile_encoding == TILE_TYPE_MLT) opts.encoding = "mlt";
    const style = assets.styleJson(gpa, opts) catch return 0;
    out.* = style.ptr;
    out_len.* = style.len;
    return 1;
}

/// Fill `cm` with the canonical default mariner settings. date_view = "".
export fn tile57_mariner_defaults(cm: *CMariner) callconv(.c) void {
    const d = chartstyle.MarinerSettings{};
    cm.* = .{
        .scheme = @intCast(@intFromEnum(d.scheme)),
        .shallow_contour = d.shallow_contour,
        .safety_contour = d.safety_contour,
        .deep_contour = d.deep_contour,
        .safety_depth = d.safety_depth,
        .four_shade_water = d.four_shade_water,
        .depth_unit = @intCast(@intFromEnum(d.depth_unit)),
        .display_base = d.display_base,
        .display_standard = d.display_standard,
        .display_other = d.display_other,
        .data_quality = d.data_quality,
        .show_inform_callouts = d.show_inform_callouts,
        .show_meta_bounds = d.show_meta_bounds,
        .show_isolated_dangers_shallow = d.show_isolated_dangers_shallow,
        .boundary_style = @intCast(@intFromEnum(d.boundary_style)),
        .simplified_points = d.simplified_points,
        .show_full_sector_lines = d.show_full_sector_lines,
        .text_names = d.text_names,
        .show_light_descriptions = d.show_light_descriptions,
        .text_other = d.text_other,
        .date_dependent = d.date_dependent,
        .highlight_date_dependent = d.highlight_date_dependent,
        .date_view = [_]u8{0} ** 9,
        .ignore_scamin = d.ignore_scamin,
        .size_scale = d.size_scale,
        .viewing_groups_off = null, // every viewing group shown
        .viewing_groups_off_len = 0,
        .scamin_filter_gate = d.scamin_filter_gate,
        .show_overscale = d.show_overscale,
    };
}
