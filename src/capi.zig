//! C ABI for libtile57.a — a thin shim over the Zig engine API (chart.zig).
//!
//! Contract: POD across the seam. Every export that can fail returns a tile57_status
//! (0 = OK), takes an optional caller-owned tile57_error* it fills on failure,
//! and defines its out-parameters on every return (result on OK, NULL/0
//! otherwise). Zig errors, slices and optionals stay inside chart.zig. Public
//! header: ../../include/tile57.h. The opaque `tile57` is a `*chart.Chart`;
//! the opaque `tile57_compose` is a `*compose.ComposeSource`.

const std = @import("std");
const chart = @import("chart.zig");
const s57 = @import("s57");
const bundle = @import("bundle"); // portrayal-asset emitters + the partition debug bake
const compose = @import("compose"); // the runtime tile compositor (tile57_compose_*)
const mariner = @import("style").mariner;
const style = @import("style");
const errors = @import("errors"); // the engine error taxonomy + describe()
// The S-52 ColorProfiles/colorProfile.xml baked into the library (build.zig), so
// the style C ABI generates colortables + a base style template with no on-disk
// catalogue. Symbols/linestyles are NOT embedded here (only the bake exe needs them).
const colorprofile_registry = @import("colorprofile_registry");

// smp_allocator (Zig's fast thread-safe GPA), not page_allocator: the live
// tile/chart path makes many small, short-lived allocations; page_allocator
// would mmap each one. Matches the bake CLI's allocator choice.
const gpa = std.heap.smp_allocator;
const Chart = chart.Chart;

// Wall-clock time for "today" date resolution in tile57_style_build. Zig 0.16
// keeps the clock behind Io; the lib links libc, so call time(3) directly.
extern fn time(tloc: ?*c_long) callconv(.c) c_long;

// Keep in sync with the TILE57_VERSION_* macros in tile57.h.
const version_string = "0.3.0";

fn spanOpt(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

// ---- error model (mirrors tile57_status / tile57_error in tile57.h) ---------

// Keep in sync with the tile57_status enum in tile57.h.
const Status = enum(c_int) { ok = 0, badarg, io, parse, nomem, unsupported, render, internal };

// Mirrors tile57_error in tile57.h: a caller-owned status + fixed message buffer.
const ERROR_MSG_MAX = 256;
const CError = extern struct { status: c_int, message: [ERROR_MSG_MAX]u8 };

const OK: c_int = @intFromEnum(Status.ok);

// Map an engine error (errors.Error) to a tile57_status. std IO errors that can
// surface directly from file ops map to .io; anything unrecognised is .internal.
fn statusOf(e: anyerror) Status {
    return switch (e) {
        error.OutOfMemory => .nomem,
        error.Unsupported => .unsupported,
        error.RenderFailed, error.TileGen => .render,
        error.InvalidCell, error.InvalidArchive, error.InvalidPartition => .parse,
        // Specific S-57 / ISO 8211 parse failures, propagated so the message
        // carries the exact reason (e.g. "BadLeader", "UnknownRUIN").
        error.ShortLeader,
        error.BadLeader,
        error.BadAsciiInt,
        error.BadAsciiDigit,
        error.MissingFieldTerminator,
        error.FieldOutOfBounds,
        error.ModifyMissingSpatial,
        error.ModifyMissingFeature,
        error.UnknownRUIN,
        error.BadFeatureRecord,
        => .parse,
        error.NotFound, error.IoFailed => .io,
        error.FileNotFound, error.AccessDenied, error.NotDir, error.IsDir, error.OpenFailed => .io,
        else => .internal,
    };
}

// Fill an optional caller-provided tile57_error (NULL to ignore) with a status +
// message; the message is copied, truncated to fit, and NUL-terminated.
fn setError(err: ?*CError, status: Status, msg: []const u8) void {
    const dst = err orelse return;
    dst.status = @intFromEnum(status);
    const n = @min(msg.len, ERROR_MSG_MAX - 1);
    @memcpy(dst.message[0..n], msg[0..n]);
    dst.message[n] = 0;
}

// Report a Zig error: set `err` (if any) with the mapped status + describe()
// message, and return the status code.
fn fail(err: ?*CError, e: anyerror) c_int {
    const s = statusOf(e);
    setError(err, s, errors.describe(e));
    return @intFromEnum(s);
}

// Like fail, but prefix the message with a context string (e.g. the file path):
// "US5MD1MC.000: malformed ISO 8211 leader". Truncated to fit.
fn failCtx(err: ?*CError, e: anyerror, context: []const u8) c_int {
    const s = statusOf(e);
    if (err) |dst| {
        dst.status = @intFromEnum(s);
        const msg = std.fmt.bufPrint(dst.message[0 .. ERROR_MSG_MAX - 1], "{s}: {s}", .{ context, errors.describe(e) }) catch blk: {
            // Context + reason overflowed the buffer; keep the reason alone.
            const r = errors.describe(e);
            const n = @min(r.len, ERROR_MSG_MAX - 1);
            @memcpy(dst.message[0..n], r[0..n]);
            break :blk dst.message[0..n];
        };
        dst.message[msg.len] = 0;
    }
    return @intFromEnum(s);
}

// Report a specific status with a literal message.
fn failWith(err: ?*CError, status: Status, msg: []const u8) c_int {
    setError(err, status, msg);
    return @intFromEnum(status);
}

// Validate + zero a (bytes, len) out-parameter pair. Every buffer-returning
// export runs this first, so outs are defined (NULL/0) on every return path.
fn bytesOut(out: ?*?[*]u8, out_len: ?*usize) error{BadArg}!struct { *?[*]u8, *usize } {
    const o = out orelse return error.BadArg;
    const n = out_len orelse return error.BadArg;
    o.* = null;
    n.* = 0;
    return .{ o, n };
}

// ---- export allocations ------------------------------------------------------
// Every buffer handed across the ABI is length-prefixed: a 16-byte header (the
// total allocation size in its first usize) sits before the returned pointer, so
// tile57_free needs only the pointer — the classic malloc shape — and the payload
// stays 16-aligned.
const EXPORT_HDR: usize = 16;

fn exportAlloc(len: usize) ?[*]u8 {
    const total = EXPORT_HDR + len;
    const raw = gpa.alignedAlloc(u8, .@"16", total) catch return null;
    std.mem.writeInt(usize, raw[0..@sizeOf(usize)], total, .little);
    return raw.ptr + EXPORT_HDR;
}

// Hand an engine-owned buffer across the ABI through (out, out_len): copy it into
// an export allocation and free the engine buffer. Returns OK, or NOMEM with the
// outs left NULL/0.
fn exportOut(err: ?*CError, o: *?[*]u8, n: *usize, bytes: []u8) c_int {
    defer chart.freeBytes(bytes);
    const p = exportAlloc(bytes.len) orelse return failWith(err, .nomem, "out of memory");
    @memcpy(p[0..bytes.len], bytes);
    o.* = p;
    n.* = bytes.len;
    return OK;
}

const bad_out = "out/out_len must not be null";

/// Return a static, human-readable string for a tile57_status.
export fn tile57_status_str(status: c_int) callconv(.c) [*:0]const u8 {
    return switch (status) {
        @intFromEnum(Status.ok) => "ok",
        @intFromEnum(Status.badarg) => "invalid argument",
        @intFromEnum(Status.io) => "I/O error",
        @intFromEnum(Status.parse) => "malformed input",
        @intFromEnum(Status.nomem) => "out of memory",
        @intFromEnum(Status.unsupported) => "unsupported input",
        @intFromEnum(Status.render) => "render failed",
        @intFromEnum(Status.internal) => "internal error",
        else => "unknown error",
    };
}

/// Return the library version string ("0.3.0").
export fn tile57_version() callconv(.c) [*:0]const u8 {
    return version_string;
}

// ===========================================================================
// 3. Bake — ENC source data in, per-cell PMTiles out (see tile57.h)
// ===========================================================================

/// The per-cell metadata of the S-57 data at `path` (one .000 or a whole ENC_ROOT)
/// as a JSON array — name/scale/edition/update/issueDate/agency/bbox per cell,
/// DSID fields reflecting the applied update chain. See tile57.h.
export fn tile57_enc_charts(path: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const p = spanOpt(path) orelse return failWith(err, .badarg, "path must not be null");
    const c = Chart.openPath(p, null, false) catch |e| return failCtx(err, e, p);
    defer c.deinit();
    const bytes = (c.chartsJson() catch |e| return fail(err, e)) orelse return OK;
    return exportOut(err, o, n, bytes);
}

/// The features of the S-57 data at `path` (one cell or a whole ENC_ROOT) for the
/// comma-separated object-class acronyms `classes`, as a GeoJSON FeatureCollection
/// (lon/lat geometry; properties = {"class", ...full S-57 attribute map}). Parsed
/// without portrayal. NULL/0 out when nothing matched. See tile57.h.
export fn tile57_enc_features(path: ?[*:0]const u8, classes: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const p = spanOpt(path) orelse return failWith(err, .badarg, "path must not be null");
    const cls = spanOpt(classes) orelse return failWith(err, .badarg, "classes must not be null");
    const c = Chart.openPath(p, null, false) catch |e| return failCtx(err, e, p);
    defer c.deinit();
    const bytes = (c.featuresJson(cls) catch |e| return fail(err, e)) orelse return OK;
    return exportOut(err, o, n, bytes);
}

/// tile57_enc_features over in-memory base-cell bytes (no update chain). See tile57.h.
export fn tile57_enc_features_bytes(base: ?[*]const u8, len: usize, classes: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const b = base orelse return failWith(err, .badarg, "base must not be null");
    if (len == 0) return failWith(err, .badarg, "len must not be zero");
    const cls = spanOpt(classes) orelse return failWith(err, .badarg, "classes must not be null");
    const charts_in = [_]chart.ChartInput{.{ .base = b[0..len] }};
    const c = Chart.openCharts(&charts_in, null, false) catch |e| return fail(err, e);
    defer c.deinit();
    const bytes = (c.featuresJson(cls) catch |e| return fail(err, e)) orelse return OK;
    return exportOut(err, o, n, bytes);
}

/// Decode a CATALOG.031 exchange-set catalogue into a JSON array of its CATD
/// entries: [{"file","longName","impl","bbox"?}, ...]. NULL/0 out when the file
/// holds no CATD records. See tile57.h.
export fn tile57_enc_catalog(catalog_031: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const cat = catalog_031 orelse return failWith(err, .badarg, "catalog_031 must not be null");
    if (len == 0) return failWith(err, .badarg, "len must not be zero");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = s57.parseCatalog(a, cat[0..len]) orelse return failWith(err, .parse, "malformed CATALOG.031");
    if (entries.len == 0) return OK;
    var buf = std.ArrayList(u8).empty;
    catalogJson(a, &buf, entries) catch |e| return fail(err, e);
    const bytes = gpa.dupe(u8, buf.items) catch |e| return fail(err, e);
    return exportOut(err, o, n, bytes);
}

fn catalogJson(a: std.mem.Allocator, buf: *std.ArrayList(u8), entries: []const s57.CatalogEntry) !void {
    try buf.append(a, '[');
    for (entries, 0..) |e, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"file\":");
        try jsonStr(a, buf, e.path);
        try buf.appendSlice(a, ",\"longName\":");
        try jsonStr(a, buf, e.long_name);
        try buf.appendSlice(a, ",\"impl\":");
        try jsonStr(a, buf, e.impl);
        if (e.bbox) |b| try buf.print(a, ",\"bbox\":[{d},{d},{d},{d}]", .{ b[0], b[1], b[2], b[3] });
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
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

/// Bake ONE cell (+ its updates, read from disk) to PMTiles bytes over its NATIVE
/// band zoom range, into *out / *out_len (free with tile57_free); NULL/0 when the
/// cell produced no tiles. See tile57.h.
export fn tile57_bake_chart_bytes(path: ?[*:0]const u8, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const p = spanOpt(path) orelse return failWith(err, .badarg, "path must not be null");
    const archive = chart.bakeChartBytes(p, null) catch |e| return failCtx(err, e, p);
    if (archive) |a| return exportOut(err, o, n, a);
    return OK;
}

/// Bake `n` charts to per-chart PMTiles bytes IN PARALLEL across up to `workers`
/// threads; out_bytes[i]/out_lens[i] get cell i's archive (free each with
/// tile57_free) or NULL/0 when it produced nothing. *out_baked (NULL to ignore) =
/// the count that produced bytes. `workers` is a MEMORY bound. See tile57.h.
export fn tile57_bake_charts(
    paths: ?[*]const ?[*:0]const u8,
    n: usize,
    workers: u32,
    out_bytes: ?[*]?[*]u8,
    out_lens: ?[*]usize,
    out_baked: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    if (out_baked) |p| p.* = 0;
    const ps = paths orelse return failWith(err, .badarg, "paths must not be null");
    const ob = out_bytes orelse return failWith(err, .badarg, "out_bytes must not be null");
    const ol = out_lens orelse return failWith(err, .badarg, "out_lens must not be null");
    if (n == 0) return OK;
    for (0..n) |i| {
        ob[i] = null;
        ol[i] = 0;
    }
    const list = gpa.alloc([]const u8, n) catch |e| return fail(err, e);
    defer gpa.free(list);
    for (0..n) |i| list[i] = spanOpt(ps[i]) orelse return failWith(err, .badarg, "a path in paths is null");
    const results = gpa.alloc(?[]u8, n) catch |e| return fail(err, e);
    defer gpa.free(results);
    chart.bakeChartsParallel(list, null, workers, results);
    var baked: usize = 0;
    var oom = false;
    for (0..n) |i| {
        const b = results[i] orelse continue;
        defer chart.freeBytes(b);
        if (oom) continue;
        const p = exportAlloc(b.len) orelse {
            oom = true;
            continue;
        };
        @memcpy(p[0..b.len], b);
        ob[i] = p;
        ol[i] = b.len;
        baked += 1;
    }
    if (oom) {
        for (0..n) |i| {
            if (ob[i]) |p| tile57_free(p);
            ob[i] = null;
            ol[i] = 0;
        }
        return failWith(err, .nomem, "out of memory");
    }
    if (out_baked) |p| p.* = baked;
    return OK;
}

/// Walk `in_dir` for S-57 base charts (*.000) and bake each IN PARALLEL to the SAME
/// relative path under `out_dir` with a .pmtiles extension (+ an <out>.sha sidecar),
/// creating subdirs as needed. INCREMENTAL: an archive already at least as new as
/// its whole input is skipped, so *out_baked (NULL to ignore) counts THIS run only.
/// `progress` returning false CANCELS (OK, with out_baked = what finished — see
/// tile57.h). An unreadable `in_dir` errors. See tile57.h.
export fn tile57_bake_tree(
    in_dir: ?[*:0]const u8,
    out_dir: ?[*:0]const u8,
    workers: u32,
    progress: chart.BakeProgress,
    progress_ctx: ?*anyopaque,
    out_baked: ?*u32,
    err: ?*CError,
) callconv(.c) c_int {
    if (out_baked) |p| p.* = 0;
    const in_d = spanOpt(in_dir) orelse return failWith(err, .badarg, "in_dir must not be null");
    const out_d = spanOpt(out_dir) orelse return failWith(err, .badarg, "out_dir must not be null");
    // Stand up a threaded std.Io for the tree walk + the workers' file writes.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const baked = chart.bakeTree(threaded.io(), in_d, out_d, null, workers, progress, progress_ctx) catch |e| return failCtx(err, e, in_d);
    if (out_baked) |p| p.* = @intCast(baked);
    return OK;
}

/// The metadata JSON blob of a PMTiles archive (decompressed) — e.g. the embedded
/// per-cell "coverage" a single-cell bake carries — into *out / *out_len (free with
/// tile57_free); NULL/0 when the archive carries none. See tile57.h.
export fn tile57_pmtiles_metadata(pmtiles_ptr: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const p = pmtiles_ptr orelse return failWith(err, .badarg, "pmtiles must not be null");
    if (len == 0) return failWith(err, .badarg, "len must not be zero");
    const meta = chart.pmtilesMetadata(gpa, p[0..len]) catch |e| return fail(err, e);
    if (meta) |m| return exportOut(err, o, n, m);
    return OK;
}

/// Bake the ownership-partition DEBUG tiles from an ENC_ROOT into a single PMTiles
/// at out_path (composited ownership faces, no portrayed content — for a
/// partition-debug UI). OK with *out_cell_count = 0 and no file written when
/// nothing is covered. See tile57.h.
export fn tile57_bake_partition_debug(
    enc_root: ?[*:0]const u8,
    out_path: ?[*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    band: i8,
    out_cell_count: ?*u32,
    err: ?*CError,
) callconv(.c) c_int {
    if (out_cell_count) |p| p.* = 0;
    const root = spanOpt(enc_root) orelse return failWith(err, .badarg, "enc_root must not be null");
    const outp = spanOpt(out_path) orelse return failWith(err, .badarg, "out_path must not be null");
    // The debug bake does filesystem I/O (read ENC_ROOT, write the pmtiles); the lib
    // has no std.process.Init, so stand up a threaded std.Io for the call. It streams
    // internally (StreamWriter over gpa), so pass the real gpa, not a scratch arena.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const nc = bundle.bakePartitionDebug(threaded.io(), gpa, root, outp, minzoom, maxzoom, band) catch |e| {
        if (e == error.NoGeometry) return OK; // nothing covered: count stays 0
        return failCtx(err, e, root);
    };
    if (out_cell_count) |p| p.* = @intCast(nc);
    return OK;
}

// ===========================================================================
// 4. Render — the `tile57` chart handle (see tile57.h)
// ===========================================================================

/// Open a baked PMTiles archive from a file path, mmap'd (never fully resident;
/// the file must stay in place while the chart is open). See tile57.h.
export fn tile57_chart_open(path: ?[*:0]const u8, out: ?*?*Chart, err: ?*CError) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, "out must not be null");
    o.* = null;
    const p = spanOpt(path) orelse return failWith(err, .badarg, "path must not be null");
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    o.* = chart.openPmtilesPath(threaded.io(), p) catch |e| return failCtx(err, e, p);
    return OK;
}

/// Open a baked PMTiles archive from in-memory bytes (copied). See tile57.h.
export fn tile57_chart_open_bytes(pmtiles_ptr: ?[*]const u8, len: usize, out: ?*?*Chart, err: ?*CError) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, "out must not be null");
    o.* = null;
    const b = pmtiles_ptr orelse return failWith(err, .badarg, "pmtiles must not be null");
    if (len == 0) return failWith(err, .badarg, "len must not be zero");
    o.* = Chart.openBytes(b[0..len], .pmtiles, null) catch |e| return fail(err, e);
    return OK;
}

// Fixed-size chart metadata (mirrors tile57_info in tile57.h).
const CInfo = extern struct {
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
    tile_type: u8, // the archive's stored encoding (TILE57_TILE_TYPE_*)
    native_scale: i32, // embedded compilation scale (1:N); 0 = derive from zoom band
};

// tile57_tile_type values (keep in sync with tile57.h).
const TILE_TYPE_MVT: u8 = 1;
const TILE_TYPE_MLT: u8 = 2;

/// Fill *out with the chart's fixed metadata (zoom range, bands, bounds, anchor,
/// tile encoding, embedded compilation scale). See tile57.h.
export fn tile57_chart_get_info(src: ?*Chart, out: ?*CInfo) callconv(.c) void {
    const o = out orelse return;
    o.* = std.mem.zeroes(CInfo);
    const s = src orelse return;
    const zr = s.zoomRange();
    o.min_zoom = zr.min;
    o.max_zoom = zr.max;
    o.native_scale = s.nativeScale();
    o.bands = s.bands();
    o.tile_type = switch (s.tileType()) {
        .mlt => TILE_TYPE_MLT,
        else => TILE_TYPE_MVT,
    };
    if (s.bounds()) |b| {
        o.has_bounds = true;
        o.west = b[0];
        o.south = b[1];
        o.east = b[2];
        o.north = b[3];
    }
    if (s.anchor()) |a| {
        o.has_anchor = true;
        o.anchor_lat = a.lat;
        o.anchor_lon = a.lon;
        o.anchor_zoom = a.zoom;
    }
}

/// The distinct SCAMIN denominators present in the chart (ascending, from the
/// archive metadata); NULL/0 out when there are none. Free *out with
/// tile57_free. See tile57.h.
export fn tile57_chart_scamin(handle: ?*Chart, out: ?*?[*]i32, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, bad_out);
    const n = out_len orelse return failWith(err, .badarg, bad_out);
    o.* = null;
    n.* = 0;
    const s = handle orelse return failWith(err, .badarg, "chart must not be null");
    const vals = s.scamin() catch |e| return fail(err, e);
    defer chart.freeBytes(std.mem.sliceAsBytes(vals));
    if (vals.len == 0) return OK;
    // SCAMIN denominators fit in int32 (the engine caps them).
    const p = exportAlloc(vals.len * @sizeOf(i32)) orelse return failWith(err, .nomem, "out of memory");
    @memcpy(p[0 .. vals.len * @sizeOf(u32)], std.mem.sliceAsBytes(vals));
    o.* = @ptrCast(@alignCast(p));
    n.* = vals.len;
    return OK;
}

const CCoverageCb = extern struct {
    ctx: ?*anyopaque,
    ring: *const fn (?*anyopaque, lonlat: [*]const f64, npts: usize) callconv(.c) void,
};

/// The chart's M_COVR data-coverage polygons, from the coverage the bake embedded
/// in the archive metadata: cb->ring is called once per polygon with its exterior
/// ring as interleaved lon,lat doubles. OK with no calls when the archive embeds
/// none. See tile57.h.
export fn tile57_chart_coverage(handle: ?*Chart, cb: ?*const CCoverageCb, err: ?*CError) callconv(.c) c_int {
    const self = handle orelse return failWith(err, .badarg, "chart must not be null");
    const cbp = cb orelse return failWith(err, .badarg, "cb must not be null");
    const polys = self.coverage() orelse return OK;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (polys) |poly| {
        if (poly.len == 0) continue;
        const ring = poly[0]; // exterior ring
        if (ring.len < 3) continue;
        const flat = a.alloc(f64, ring.len * 2) catch continue;
        for (ring, 0..) |p, i| {
            flat[2 * i] = @as(f64, @floatFromInt(p.lon_e7)) / 1e7;
            flat[2 * i + 1] = @as(f64, @floatFromInt(p.lat_e7)) / 1e7;
        }
        cbp.ring(cbp.ctx, flat.ptr, ring.len);
    }
    return OK;
}

/// The chart's own stored tile at (z,x,y), decompressed (MLT or MVT per
/// tile57_info.tile_type), with NO composition — the per-archive primitive an
/// embedder's own compositor consumes. NULL/0 out when the archive has no tile
/// there. See tile57.h.
export fn tile57_chart_tile(handle: ?*Chart, z: u8, x: u32, y: u32, out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const c = handle orelse return failWith(err, .badarg, "chart must not be null");
    const rd = c.pmtilesReader() orelse return failWith(err, .badarg, "chart is not archive-backed");
    const bytes = (rd.getTile(gpa, z, x, y) catch |e| return fail(err, e)) orelse return OK;
    return exportOut(err, o, n, bytes);
}

const CQueryCb = @import("render").query.QueryCb;

/// Cursor object-query at (lon,lat) for the view `zoom` (web-mercator): invokes
/// cb->feature once per displayed feature the point falls in, with its S-57 class,
/// attribute JSON, and source cell. See tile57.h.
export fn tile57_chart_query(handle: ?*Chart, lon: f64, lat: f64, zoom: f64, cb: ?*const CQueryCb, err: ?*CError) callconv(.c) c_int {
    const self = handle orelse return failWith(err, .badarg, "chart must not be null");
    const cbp = cb orelse return failWith(err, .badarg, "cb must not be null");
    self.queryPoint(lon, lat, zoom, cbp) catch |e| return fail(err, e);
    return OK;
}

const RenderPalette = @import("render").resolve.PaletteId;

fn paletteOf(settings: *const mariner.Settings) RenderPalette {
    return switch (settings.scheme) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
}

// Shared render prologue: width/height must be 1..MAX_RENDER_PX per side.
const MAX_RENDER_PX = 16384;
const bad_size = "width/height must be 1..16384";

/// Render a VIEW of this ONE chart (centre + fractional zoom + pixel size) to
/// PNG: the archive's baked tiles replayed through the native S-52 pixel path —
/// one scene across every covering tile, labels decluttered over the whole
/// canvas. No composition (see tile57_compose_png for the composed twin).
/// `m` NULL = defaults. See tile57.h.
export fn tile57_chart_png(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const c = handle orelse return failWith(err, .badarg, "chart must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    const bytes = c.renderView(lon, lat, zoom, width, height, paletteOf(&settings), &settings, .png, null) catch |e| return fail(err, e);
    return exportOut(err, o, n, bytes);
}

/// tile57_chart_png's vector twin: the SAME scene as a deterministic single-page PDF
/// (1 px = 1 pt, 72 dpi; vector fills, native strokes, glyph-outline text).
export fn tile57_chart_pdf(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const c = handle orelse return failWith(err, .badarg, "chart must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    const bytes = c.renderView(lon, lat, zoom, width, height, paletteOf(&settings), &settings, .pdf, null) catch |e| return fail(err, e);
    return exportOut(err, o, n, bytes);
}

const CbCanvas = @import("render").cb_canvas.CCanvas;

/// tile57_chart_png's callback twin: the SAME view painted through the C callback
/// table `canvas` (see tile57.h) instead of rasterising. Geometry in canvas
/// PIXEL space (y down), paint order, palette-resolved colours.
export fn tile57_chart_canvas(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    canvas: ?*const CbCanvas,
    err: ?*CError,
) callconv(.c) c_int {
    const c = handle orelse return failWith(err, .badarg, "chart must not be null");
    const cb = canvas orelse return failWith(err, .badarg, "canvas must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    const bytes = c.renderView(lon, lat, zoom, width, height, paletteOf(&settings), &settings, .callback, cb) catch |e| return fail(err, e);
    chart.freeBytes(bytes); // the callback path returns an empty buffer
    return OK;
}

const CSurface = @import("render").vector.CSurface;

/// The GPU vector twin: the SAME view emitted as a WORLD-SPACE tagged stream
/// (areas/lines in web-mercator [0,1]; symbols/text as a world anchor + local
/// reference-px outline; per-feature class + SCAMIN) to the C surface callback
/// `surface` (see tile57.h). Pan/zoom re-portray nothing on the host.
export fn tile57_chart_surface(
    handle: ?*Chart,
    lon: f64,
    lat: f64,
    zoom: f64,
    rotation_rad: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    surface: ?*const CSurface,
    err: ?*CError,
) callconv(.c) c_int {
    const c = handle orelse return failWith(err, .badarg, "chart must not be null");
    const sfc = surface orelse return failWith(err, .badarg, "surface must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    c.renderSurfaceView(lon, lat, zoom, rotation_rad, width, height, paletteOf(&settings), &settings, sfc) catch |e| return fail(err, e);
    return OK;
}

/// Portray ONE tile (z, x, y) to a surface — the per-tile twin of
/// tile57_chart_surface. Same WORLD-SPACE tagged draw calls, for a single tile, so
/// a host can portray+tessellate each tile once, cache it, and compose the view
/// from cached tiles (the MapLibre model). Decluttering is per-tile. See tile57.h.
export fn tile57_chart_tile_surface(
    handle: ?*Chart,
    z: u8,
    x: u32,
    y: u32,
    m: ?*const CMariner,
    surface: ?*const CSurface,
    err: ?*CError,
) callconv(.c) c_int {
    const c = handle orelse return failWith(err, .badarg, "chart must not be null");
    const sfc = surface orelse return failWith(err, .badarg, "surface must not be null");
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    c.renderSurfaceTile(z, x, y, paletteOf(&settings), &settings, sfc) catch |e| return fail(err, e);
    return OK;
}

/// Portray ONE MLT tile from CALLER-SUPPLIED bytes to a surface — the archive-less
/// twin of tile57_chart_tile_surface. For a host that fetched a tile (e.g. over
/// HTTP from a tile server) and wants it painted with no chart open: `mlt`/`mlt_len`
/// are the raw (decompressed) MLT tile bytes, (z,x,y) place it, decluttering is
/// per-tile. Same WORLD-SPACE tagged draw calls as tile57_chart_tile_surface. The
/// colour profile + symbol catalogue are the ones baked into the library. See tile57.h.
export fn tile57_render_mlt_tile(
    mlt: ?[*]const u8,
    mlt_len: usize,
    z: u8,
    x: u32,
    y: u32,
    m: ?*const CMariner,
    surface: ?*const CSurface,
    err: ?*CError,
) callconv(.c) c_int {
    const b = mlt orelse return failWith(err, .badarg, "mlt bytes must not be null");
    const sfc = surface orelse return failWith(err, .badarg, "surface must not be null");
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    chart.renderMltTileSurface(b[0..mlt_len], z, x, y, paletteOf(&settings), &settings, sfc) catch |e| return fail(err, e);
    return OK;
}

/// Release a chart and all cached tiles. Must not be called while any borrower
/// (a compositor, a renderer) may still read from it. See tile57.h.
export fn tile57_chart_close(handle: ?*Chart) callconv(.c) void {
    if (handle) |s| s.deinit();
}

// ===========================================================================
// 5. Compose — the runtime compositor over open charts (see tile57.h)
// ===========================================================================

/// Coverage/zoom summary of a compositor, filled by tile57_compose_get_meta.
const CComposeMeta = extern struct {
    min_zoom: u8,
    max_zoom: u8, // deepest zoom that can be served (native windows + one fill-up overscale zoom)
    charts: u32, // coverage-carrying charts held
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

/// Open a compositor over `n` open charts, BORROWING their archives + embedded
/// coverage (the charts must outlive it; close the compositor first). Charts whose
/// archives embed no coverage are skipped; none at all is TILE57_ERR_UNSUPPORTED.
/// `partition_path` (or NULL) names a partition sidecar (tile57_compose_save_partition;
/// the `tile57 bake` CLI writes partition.tpart) to load and skip the build — a
/// missing/stale one falls back to building. See tile57.h.
export fn tile57_compose_open(
    charts: ?[*]const ?*Chart,
    n: usize,
    partition_path: ?[*:0]const u8,
    out: ?*?*compose.ComposeSource,
    err: ?*CError,
) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, "out must not be null");
    o.* = null;
    const cs = charts orelse return failWith(err, .badarg, "charts must not be null");
    if (n == 0) return failWith(err, .badarg, "n must not be zero");

    const archives = gpa.alloc(compose.ChartArchive, n) catch |e| return fail(err, e);
    defer gpa.free(archives);
    var na: usize = 0;
    for (0..n) |i| {
        const c = cs[i] orelse return failWith(err, .badarg, "a chart in charts is null");
        const rd = c.pmtilesReader() orelse return failWith(err, .badarg, "a chart in charts is not archive-backed");
        const cov = c.decodedCoverage() orelse continue; // embeds no coverage: owns no ground
        archives[na] = .{ .reader = rd, .cov = cov };
        na += 1;
    }

    // Optional partition sidecar; the lib has no std.process.Init, so stand up a
    // threaded std.Io for the read (nothing else here does file I/O).
    var owned: ?[]u8 = null;
    defer if (owned) |b| gpa.free(b);
    if (spanOpt(partition_path)) |pp| {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        if (readSidecar(threaded.io(), pp)) |b| {
            owned = b;
        } else |_| {}
    }

    o.* = (compose.ComposeSource.open(gpa, archives[0..na], owned) catch |e| return fail(err, e)) orelse
        return failWith(err, .unsupported, "no chart carries per-cell coverage");
    return OK;
}

/// Compose the tile (z,x,y) on demand into RAW (decompressed) MLT in *out / *out_len
/// (free with tile57_free) — the HTTP layer gzips on the wire. NULL/0 out with OK =
/// no bytes; *out_owned (NULL to ignore) then distinguishes true empty ocean (false,
/// safe to cache) from owned-but-empty (true — transient during a bake, suspect
/// after). Byte-faithful to the batch compositor. See tile57.h.
export fn tile57_compose_tile(
    handle: ?*compose.ComposeSource,
    z: u8,
    x: u32,
    y: u32,
    out: ?*?[*]u8,
    out_len: ?*usize,
    out_owned: ?*bool,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    if (out_owned) |p| p.* = false;
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    const res = src.tile(gpa, z, x, y) catch |e| return fail(err, e);
    if (out_owned) |p| p.* = res.owned;
    if (res.tile) |t| return exportOut(err, o, n, t);
    return OK;
}

/// Render a VIEW over the compositor to PNG — the composed twin of tile57_chart_png:
/// every covering tile is composed on demand (seams stitched through the
/// ownership partition) and replayed through the native S-52 pixel path. See
/// tile57.h.
export fn tile57_compose_png(
    handle: ?*compose.ComposeSource,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    const bytes = chart.renderComposeView(src, lon, lat, zoom, width, height, paletteOf(&settings), &settings, .png, null) catch |e| return fail(err, e);
    return exportOut(err, o, n, bytes);
}

/// tile57_compose_png's vector twin: the SAME composed scene as a deterministic
/// single-page PDF. See tile57.h.
export fn tile57_compose_pdf(
    handle: ?*compose.ComposeSource,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    const bytes = chart.renderComposeView(src, lon, lat, zoom, width, height, paletteOf(&settings), &settings, .pdf, null) catch |e| return fail(err, e);
    return exportOut(err, o, n, bytes);
}

/// tile57_compose_png's callback twin: the SAME composed view painted through the
/// C callback table `canvas` (pixel space, paint order). See tile57.h.
export fn tile57_compose_canvas(
    handle: ?*compose.ComposeSource,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    canvas: ?*const CbCanvas,
    err: ?*CError,
) callconv(.c) c_int {
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    const cb = canvas orelse return failWith(err, .badarg, "canvas must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    const bytes = chart.renderComposeView(src, lon, lat, zoom, width, height, paletteOf(&settings), &settings, .callback, cb) catch |e| return fail(err, e);
    chart.freeBytes(bytes); // the callback path returns an empty buffer
    return OK;
}

/// The composed GPU vector twin: the SAME composed view emitted as a WORLD-SPACE
/// tagged stream to the C surface callback (see tile57.h). See tile57_chart_surface for
/// the single-chart form.
export fn tile57_compose_surface(
    handle: ?*compose.ComposeSource,
    lon: f64,
    lat: f64,
    zoom: f64,
    rotation_rad: f64,
    width: u32,
    height: u32,
    m: ?*const CMariner,
    surface: ?*const CSurface,
    err: ?*CError,
) callconv(.c) c_int {
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    const sfc = surface orelse return failWith(err, .badarg, "surface must not be null");
    if (width == 0 or height == 0 or width > MAX_RENDER_PX or height > MAX_RENDER_PX)
        return failWith(err, .badarg, bad_size);
    const settings: mariner.Settings = if (m) |p| marinerFromC(p) else .{};
    chart.renderComposeSurfaceView(src, lon, lat, zoom, rotation_rad, width, height, paletteOf(&settings), &settings, sfc) catch |e| return fail(err, e);
    return OK;
}

/// Cursor object-query over the composed set (the S-52 pick, seams included):
/// invokes cb->feature once per displayed feature the point falls in. See
/// tile57.h.
export fn tile57_compose_query(handle: ?*compose.ComposeSource, lon: f64, lat: f64, zoom: f64, cb: ?*const CQueryCb, err: ?*CError) callconv(.c) c_int {
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    const cbp = cb orelse return failWith(err, .badarg, "cb must not be null");
    chart.composeQueryPoint(src, lon, lat, zoom, cbp) catch |e| return fail(err, e);
    return OK;
}

/// Fill *out with the compositor's zoom range + union coverage bounds (zeroed when
/// the handle is NULL). See tile57.h.
export fn tile57_compose_get_meta(handle: ?*compose.ComposeSource, out: ?*CComposeMeta) callconv(.c) void {
    const o = out orelse return;
    o.* = std.mem.zeroes(CComposeMeta);
    const src = handle orelse return;
    o.* = .{
        .min_zoom = src.minz,
        .max_zoom = src.loop_max,
        .charts = @intCast(src.readers.len),
        .west = src.bounds[0],
        .south = src.bounds[1],
        .east = src.bounds[2],
        .north = src.bounds[3],
    };
}

/// Serialize the compositor's ownership partition to the file `path` (a sidecar a
/// later tile57_compose_open can load to skip the build). See tile57.h.
export fn tile57_compose_save_partition(handle: ?*compose.ComposeSource, path: ?[*:0]const u8, err: ?*CError) callconv(.c) c_int {
    const src = handle orelse return failWith(err, .badarg, "compose handle must not be null");
    const p = spanOpt(path) orelse return failWith(err, .badarg, "path must not be null");
    const bytes = src.serializePartition(gpa) catch |e| return fail(err, e);
    defer gpa.free(bytes);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = p, .data = bytes }) catch |e| return failCtx(err, e, p);
    return OK;
}

/// Release a compositor. Its charts stay open (and stay the caller's to close).
export fn tile57_compose_close(handle: ?*compose.ComposeSource) callconv(.c) void {
    if (handle) |src| src.deinit();
}

// ===========================================================================
// 6. Style + portrayal assets (see tile57.h)
// ===========================================================================

// The S-52 colour profile baked into the library, or null if (somehow) absent.
fn embeddedColorProfileXml() ?[]const u8 {
    for (colorprofile_registry.entries) |e| return e.bytes;
    return null;
}

/// S-52 colortables.json from the colour profile baked into the library — no
/// on-disk catalogue needed. Pair with tile57_style_template / tile57_style_build.
export fn tile57_colortables_default(out: ?*?[*]u8, out_len: ?*usize, err: ?*CError) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const xml = embeddedColorProfileXml() orelse return failWith(err, .internal, "embedded colour profile missing");
    const json = style.colorTablesJson(gpa, xml) catch |e| return fail(err, e);
    return exportOut(err, o, n, json);
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

/// All portrayal assets in memory (the same files the offline bake writes to disk),
/// from the embedded catalogue (catalog_dir NULL/"") or an on-disk one. Free with
/// tile57_assets_free. See tile57.h.
export fn tile57_bake_assets(catalog_dir: ?[*:0]const u8, out: ?*CAssets, err: ?*CError) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, "out must not be null");
    o.* = .{};
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

    const ct = bundle.colorTablesBytes(io, a, cd) catch |e| return fail(err, e);
    const ls = bundle.linestylesBytes(io, a, cd) catch |e| return fail(err, e);
    const spr = bundle.spriteAtlasBytes(io, a, cd, bundle.DEFAULT_CSS) catch |e| return fail(err, e);
    const pat = bundle.patternAtlasBytes(io, a, cd, bundle.DEFAULT_CSS) catch |e| return fail(err, e);

    fillAssets(o, ct, ls, spr.json, spr.png, pat.json, pat.png) catch |e| {
        tile57_assets_free(o);
        return fail(err, e);
    };
    return OK;
}

/// Like tile57_bake_assets but the sprite_* fields carry the MapLibre sprite-mln
/// atlas (pivot-centred cells + {name:{x,y,width,height,pixelRatio}} JSON). Only
/// sprite_json/sprite_png are filled. Free with tile57_assets_free. See tile57.h.
export fn tile57_bake_sprite_mln(catalog_dir: ?[*:0]const u8, out: ?*CAssets, err: ?*CError) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, "out must not be null");
    o.* = .{};
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cd = spanOpt(catalog_dir) orelse "";
    const spr = bundle.spriteMlnBytes(io, a, cd, bundle.DEFAULT_CSS, &[_][]const u8{}) catch |e| return fail(err, e);
    fillAssets(o, "", "", spr.json, spr.png, "", "") catch |e| {
        tile57_assets_free(o);
        return fail(err, e);
    };
    return OK;
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
/// Only sprite_* filled. Free with tile57_assets_free. See tile57.h.
export fn tile57_bake_glyph_sdf(out: ?*CAssets, err: ?*CError) callconv(.c) c_int {
    const o = out orelse return failWith(err, .badarg, "out must not be null");
    o.* = .{};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const font = @import("render").font.notosans;
    const cps = glyph_sdf.defaultCodepoints(a) catch |e| return fail(err, e);
    var atlas = glyph_sdf.build(a, font, cps, 32.0, 6) catch |e| return fail(err, e);
    const png = (atlas.encodePng(a) catch |e| return fail(err, e)) orelse
        return failWith(err, .internal, "glyph atlas PNG encode produced nothing");
    const json = glyphMetricsJson(a, &atlas) catch |e| return fail(err, e);
    o.sprite_png = (gpa.dupe(u8, png) catch |e| {
        tile57_assets_free(o);
        return fail(err, e);
    }).ptr;
    o.sprite_png_len = png.len;
    o.sprite_json = (gpa.dupe(u8, json) catch |e| {
        tile57_assets_free(o);
        return fail(err, e);
    }).ptr;
    o.sprite_json_len = json.len;
    return OK;
}

/// Free every non-null buffer in *out and zero the struct. See tile57.h.
export fn tile57_assets_free(out: ?*CAssets) callconv(.c) void {
    const o = out orelse return;
    if (o.colortables) |p| chart.freeBytes(p[0..o.colortables_len]);
    if (o.linestyles) |p| chart.freeBytes(p[0..o.linestyles_len]);
    if (o.sprite_json) |p| chart.freeBytes(p[0..o.sprite_json_len]);
    if (o.sprite_png) |p| chart.freeBytes(p[0..o.sprite_png_len]);
    if (o.pattern_json) |p| chart.freeBytes(p[0..o.pattern_json_len]);
    if (o.pattern_png) |p| chart.freeBytes(p[0..o.pattern_png_len]);
    o.* = .{};
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
    // end for ABI-append-safety. The pointee must outlive the tile57_style_build call.
    viewing_groups_off: [*c]const i32,
    viewing_groups_off_len: u32,
    // Gate SCAMIN with a live client filter instead of per-value bucket layers
    // (one *_scamin layer per render-type). Appended for ABI-append-safety.
    scamin_filter_gate: bool,
    // S-52 §10.1.10 overscale indication (AP(OVERSC01) over overscaled coverage):
    // drives the `overscale` layer's visibility. Appended for ABI-append-safety;
    // tile57_mariner_defaults sets true.
    show_overscale: bool,
    // Per-category size multipliers for text / soundings, on top of size_scale.
    // Appended for ABI-append-safety; marinerFromC reads 0 (an un-set field) as 1.0.
    text_size_scale: f64,
    sounding_size_scale: f64,
    // Spot soundings, independent of the display category. S-52 files SOUNDG under OTHER, but
    // every ECDIS gives soundings their own switch and the everyday setting is STANDARD +
    // soundings ON; without this a host must enable the whole OTHER category to get them, and
    // takes the seabed, the cables and the rest of the low-priority clutter with it.
    //
    // TRI-STATE, so a zeroed struct keeps the old meaning (Appended for ABI-append-safety):
    //   0 = follow the display category (what every existing host gets)
    //   1 = show soundings, whatever the category says
    //   2 = hide soundings, whatever the category says
    soundings: u8,
};

/// The tri-state `soundings` field as the engine's optional bool.
fn soundingsOf(v: u8) ?bool {
    return switch (v) {
        1 => true,
        2 => false,
        else => null, // 0 / unknown: follow the display category
    };
}

// "YYYYMMDD" or "" from the fixed char[9] field.
fn dateViewSlice(buf: *const [9]u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..@min(n, 8)];
}

// Translate the extern CMariner into the internal mariner.Settings the
// style builders take. The returned value borrows `cm`'s date_view and
// viewing_groups_off storage, so `cm` (and its viewing_groups_off array) must
// outlive every use of the result — true within a single ABI call.
fn marinerFromC(cm: *const CMariner) mariner.Settings {
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
        .show_soundings = soundingsOf(cm.soundings),
        .show_overscale = cm.show_overscale,
        .size_scale = cm.size_scale,
        // Appended fields: an un-set (zero) multiplier means "no extra scale", so a
        // host that zero-inits without tile57_mariner_defaults still gets 1.0 rather
        // than invisible text/soundings.
        .text_size_scale = if (cm.text_size_scale > 0) cm.text_size_scale else 1.0,
        .sounding_size_scale = if (cm.sounding_size_scale > 0) cm.sounding_size_scale else 1.0,
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
    // SCAMIN is a 1:N denominator (> 0); a negative is garbage from the host. Clamp
    // to 0 ("no scale gate") rather than let a safety-checked @intCast abort the
    // whole process across the ABI.
    for (p[0..scamin_count], 0..) |v, i| buf[i] = if (v < 0) 0 else @intCast(v);
    return buf;
}

/// Build a MapLibre style JSON from a template + mariner settings + colortables.
/// See tile57.h.
export fn tile57_style_build(
    template_json: ?[*]const u8,
    template_len: usize,
    cm: ?*const CMariner,
    colortables_json: ?[*]const u8,
    colortables_len: usize,
    enabled_bands: ?[*]const i32,
    enabled_band_count: usize,
    scamin: ?[*]const i32,
    scamin_count: usize,
    scamin_lat: f64,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const tp = template_json orelse return failWith(err, .badarg, "template_json must not be null");
    const cmp = cm orelse return failWith(err, .badarg, "mariner must not be null");
    const m = marinerFromC(cmp);
    const tmpl = tp[0..template_len];
    const cts: []const u8 = if (colortables_json) |p| p[0..colortables_len] else "";
    const bands: ?[]const i32 = if (enabled_bands) |p| p[0..enabled_band_count] else null;
    // SCAMIN manifest (the distinct denominators the host read from the source /
    // TileJSON): converted from the host's i32 to the u32 denominators styleJson
    // buckets on. Empty/NULL -> the *_scamin layers stay ungated.
    const scamin_buf = scaminBuf(scamin, scamin_count) catch |e| return fail(err, e);
    defer if (scamin_buf.len > 0) gpa.free(scamin_buf);
    const now_unix: i64 = @intCast(time(null));
    const style_json = style.buildFromTemplateScamin(gpa, tmpl, &m, cts, bands, now_unix, scamin_buf, scamin_lat) catch |e| return fail(err, e);
    return exportOut(err, o, n, style_json);
}

/// Compute the minimal MapLibre style-mutation ops turning the style for `old_m`
/// into the style for `new_m` (same inputs as tile57_style_build, so the styles are
/// comparable): a JSON op array — "[]" when nothing changed, [{"op":"rebuild"}]
/// when the layer SET differs (host falls back to setStyle). See tile57.h.
export fn tile57_style_diff(
    template_json: ?[*]const u8,
    template_len: usize,
    old_m: ?*const CMariner,
    new_m: ?*const CMariner,
    colortables_json: ?[*]const u8,
    colortables_len: usize,
    enabled_bands: ?[*]const i32,
    enabled_band_count: usize,
    scamin: ?[*]const i32,
    scamin_count: usize,
    scamin_lat: f64,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const tp = template_json orelse return failWith(err, .badarg, "template_json must not be null");
    const omp = old_m orelse return failWith(err, .badarg, "old_m must not be null");
    const nmp = new_m orelse return failWith(err, .badarg, "new_m must not be null");
    const om = marinerFromC(omp);
    const nm = marinerFromC(nmp);
    const tmpl = tp[0..template_len];
    const cts: []const u8 = if (colortables_json) |p| p[0..colortables_len] else "";
    const bands: ?[]const i32 = if (enabled_bands) |p| p[0..enabled_band_count] else null;
    const scamin_buf = scaminBuf(scamin, scamin_count) catch |e| return fail(err, e);
    defer if (scamin_buf.len > 0) gpa.free(scamin_buf);
    // One wall-clock read shared by both builds so "today" date resolution matches
    // on both sides — otherwise a clock tick could show as a spurious date-filter op.
    const now_unix: i64 = @intCast(time(null));

    const old_style = style.buildFromTemplateScamin(gpa, tmpl, &om, cts, bands, now_unix, scamin_buf, scamin_lat) catch |e| return fail(err, e);
    defer gpa.free(old_style);
    const new_style = style.buildFromTemplateScamin(gpa, tmpl, &nm, cts, bands, now_unix, scamin_buf, scamin_lat) catch |e| return fail(err, e);
    defer gpa.free(new_style);

    const ops = style.diff(gpa, old_style, new_style) catch |e| return fail(err, e);
    return exportOut(err, o, n, ops);
}

/// Generate the base MapLibre style template from the catalogue baked into the
/// library — the chart `sources` block, sprite/glyph URLs and the layer set;
/// mariner settings are then applied on top with tile57_style_build. See tile57.h
/// for the parameter semantics (minzoom emitted verbatim; tile_encoding MLT emits
/// "encoding":"mlt" on the source).
export fn tile57_style_template(
    scheme: c_int,
    source_tiles: ?[*:0]const u8,
    sprite_url: ?[*:0]const u8,
    glyphs_url: ?[*:0]const u8,
    minzoom: u32,
    maxzoom: u32,
    tile_encoding: u8,
    out: ?*?[*]u8,
    out_len: ?*usize,
    err: ?*CError,
) callconv(.c) c_int {
    const o, const n = bytesOut(out, out_len) catch return failWith(err, .badarg, bad_out);
    const xml = embeddedColorProfileXml() orelse return failWith(err, .internal, "embedded colour profile missing");
    const cts = style.colorTablesJson(gpa, xml) catch |e| return fail(err, e);
    defer gpa.free(cts);
    var opts = style.Options{
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
    // Analysed complex linestyles from the embedded catalogue: the template gains the
    // ls_style decoration layers + the "tile57:linestyles" metadata carrier (tile57_style_build
    // rebuilds them from that carrier on every mariner change). bundle.linestylesBytes does
    // filesystem I/O for an on-disk catalogue, so stand up a threaded std.Io; "" = embedded.
    var ls_arena = std.heap.ArenaAllocator.init(gpa);
    defer ls_arena.deinit();
    var ls_threaded: std.Io.Threaded = .init(gpa, .{});
    defer ls_threaded.deinit();
    opts.linestyles_json = bundle.linestylesBytes(ls_threaded.io(), ls_arena.allocator(), "") catch null;
    const style_json = style.json(gpa, opts) catch |e| return fail(err, e);
    return exportOut(err, o, n, style_json);
}

/// Fill `cm` with the canonical default mariner settings. date_view = "".
export fn tile57_mariner_defaults(cm: ?*CMariner) callconv(.c) void {
    const o = cm orelse return;
    const d = mariner.Settings{};
    o.* = .{
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
        .soundings = if (d.show_soundings) |on| (if (on) @as(u8, 1) else @as(u8, 2)) else 0,
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
        .text_size_scale = d.text_size_scale,
        .sounding_size_scale = d.sounding_size_scale,
    };
}

// ===========================================================================
// 7. Util (see tile57.h)
// ===========================================================================

/// Populate the process-global read-only registries (S-100 catalogue + linestyles) on
/// the calling thread. Call ONCE on the main thread before opening/baking charts from
/// worker threads, so concurrent bake/render is race-free. See tile57.h.
export fn tile57_warmup() callconv(.c) void {
    chart.warmup();
}

/// Free any engine-returned buffer (tiles, style, the scamin array, colortables,
/// …). Buffers are length-prefixed at allocation, so the pointer is all it
/// needs — the universal free. See tile57.h.
export fn tile57_free(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const base: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(p)) - EXPORT_HDR);
    const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    gpa.free(base[0..total]);
}
