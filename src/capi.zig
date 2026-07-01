//! C ABI for libtile57.a — a thin shim over the Zig engine API (source.zig).
//!
//! Contract: POD across the seam (ptr/len + status codes); Zig errors, slices
//! and optionals stay inside source.zig. Public header: ../../include/tile57.h.
//! The opaque `tile57_source` is a `*source.Source`.

const std = @import("std");
const source = @import("source.zig");
const bundle = @import("bundle"); // the whole chart-bundle pipeline (tiles + assets + manifest)
const chartstyle = @import("chartstyle");
const assets = @import("assets");
const sprite = @import("sprite");
// The S-52 ColorProfiles/colorProfile.xml baked into the library (build.zig), so
// the style C ABI generates colortables + a base style template with no on-disk
// catalogue. Symbols/linestyles are NOT embedded here (only the bake exe needs them).
const colorprofile_registry = @import("colorprofile_registry");

// smp_allocator (Zig's fast thread-safe GPA), not page_allocator: the live
// tile/source path makes many small, short-lived allocations; page_allocator
// would mmap each one. Matches the bake CLI's allocator choice.
const gpa = std.heap.smp_allocator;
const Source = source.Source;

// Wall-clock time for "today" date resolution in tile57_build_style. Zig 0.16
// keeps the clock behind Io; the lib links libc, so call time(3) directly.
extern fn time(tloc: ?*c_long) callconv(.c) c_long;

// Keep in sync with the TILE57_VERSION_* macros in tile57.h.
const version_string = "0.1.0";

// Mirrors tile57_format in tile57.h.
const CFormat = enum(c_int) { auto = 0, pmtiles = 1, s57_cell = 2 };

fn cFormat(f: source.Format) c_int {
    return @intFromEnum(@as(CFormat, switch (f) {
        .auto => .auto,
        .pmtiles => .pmtiles,
        .s57_cell => .s57_cell,
    }));
}

fn zigFormat(format: c_int) source.Format {
    return switch (format) {
        @intFromEnum(CFormat.pmtiles) => .pmtiles,
        @intFromEnum(CFormat.s57_cell) => .s57_cell,
        else => .auto,
    };
}

fn spanOpt(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

/// Return the library version string ("0.1.0").
export fn tile57_version() callconv(.c) [*:0]const u8 {
    return version_string;
}

/// Open a chart tile source from in-memory bytes. See tile57.h.
export fn tile57_source_open(
    data_ptr: [*]const u8,
    data_len: usize,
    format: c_int,
    rules_dir: ?[*:0]const u8,
) callconv(.c) ?*Source {
    return Source.openBytes(data_ptr[0..data_len], zigFormat(format), spanOpt(rules_dir)) catch null;
}

// One ENC cell's bytes for the C ABI. Mirrors tile57_cell_input in tile57.h.
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

// Convert the C CellInput[] into a Zig source.CellInput[] (slices into the host's
// borrowed buffers). Allocates the slice-of-slices into `a`; the engine copies
// what it keeps, so the caller frees the conversion arrays after the call.
fn toCellInputs(a: std.mem.Allocator, c_cells: []const CellInput) ?[]source.CellInput {
    const out = a.alloc(source.CellInput, c_cells.len) catch return null;
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

/// Open an ENC_ROOT as a multi-cell source. See tile57.h.
export fn tile57_source_open_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
    omit_pick_attrs: c_int,
) callconv(.c) ?*Source {
    if (count == 0) return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cells = toCellInputs(arena.allocator(), cells_ptr[0..count]) orelse return null;
    return Source.openCells(cells, spanOpt(rules_dir), omit_pick_attrs == 0) catch null;
}

/// Open a streaming ENC_ROOT source: host supplies per-cell metadata + a reader
/// that returns a cell's bytes on demand (read on first tile use, freed on LRU
/// eviction). See tile57.h. `metas`/`read`/`user` map to source.openCellsStreaming.
export fn tile57_source_open_cells_streaming(
    metas: [*]const source.CellMeta,
    count: usize,
    read: source.CellReadFn,
    user: ?*anyopaque,
    rules_dir: ?[*:0]const u8,
    omit_pick_attrs: c_int,
) callconv(.c) ?*Source {
    if (count == 0) return null;
    return Source.openCellsStreaming(metas[0..count], read, user, spanOpt(rules_dir), omit_pick_attrs == 0) catch null;
}

/// Open an on-disk ENC_ROOT directory (or single .000) as a streaming chart. See tile57.h.
/// (chart-api.md — additive during the source->chart migration.)
export fn tile57_chart_open(path: ?[*:0]const u8) callconv(.c) ?*Source {
    const p = spanOpt(path) orelse return null;
    return Source.openPath(p, null, true) catch null;
}

/// Open one in-memory ENC cell (base .000 bytes) as a resident chart. See tile57.h.
export fn tile57_chart_open_bytes(base: [*]const u8, len: usize) callconv(.c) ?*Source {
    if (len == 0) return null;
    const cells = [_]source.CellInput{.{ .base = base[0..len] }};
    return Source.openCells(&cells, null, true) catch null;
}

/// Open a baked PMTiles bundle from a file path. See tile57.h.
export fn tile57_chart_open_pmtiles(path: ?[*:0]const u8) callconv(.c) ?*Source {
    const p = spanOpt(path) orelse return null;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir_path = std.fs.path.dirname(p) orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    const bytes = dir.readFileAlloc(io, std.fs.path.basename(p), gpa, .unlimited) catch return null;
    defer gpa.free(bytes);
    return Source.openBytes(bytes, .pmtiles, null) catch null;
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
};

/// Fill *out with the chart's fixed metadata (zoom range, bands, bounds, anchor). See tile57.h.
export fn tile57_chart_get_info(src: ?*Source, out: *CChartInfo) callconv(.c) void {
    out.* = std.mem.zeroes(CChartInfo);
    const s = src orelse return;
    const zr = s.zoomRange();
    out.min_zoom = zr.min;
    out.max_zoom = zr.max;
    out.bands = s.bands();
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

// Progress callback for tile57_bake_cells / tile57_bake_bundle (matches the header
// typedef + source.Progress + bake_enc.Progress).
const BakeProgress = ?*const fn (user: ?*anyopaque, stage: u8, done: usize, total: usize, band_index: u8, band_count: u8, band_name: ?[*:0]const u8) callconv(.c) void;

/// Bake an ENC_ROOT into ONE PMTiles archive. See tile57.h. 1=ok, 0=empty, -1=error.
export fn tile57_bake_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    omit_pick_attrs: c_int,
    progress: BakeProgress,
    user: ?*anyopaque,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cells = toCellInputs(arena.allocator(), cells_ptr[0..count]) orelse return -1;
    const archive = source.bakeArchive(cells, spanOpt(rules_dir), minzoom, maxzoom, omit_pick_attrs == 0, progress, user) catch return -1;
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
    rules_dir: ?[*:0]const u8,
    catalog_dir: ?[*:0]const u8,
    created: ?[*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    omit_pick_attrs: c_int,
    progress: BakeProgress,
    user: ?*anyopaque,
    out_cell_count: ?*u32,
    out_bbox: ?*[4]f64,
) callconv(.c) c_int {
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
        .rules_dir = spanOpt(rules_dir) orelse "",
        .catalog_dir = spanOpt(catalog_dir) orelse "",
        .generator = generator,
        .created = spanOpt(created) orelse "",
        .minzoom = minzoom,
        .maxzoom = maxzoom,
        .pick_attrs = omit_pick_attrs == 0,
        .progress = progress,
        .progress_user = user,
    }) catch |err| return if (err == error.NoGeometry) 0 else -1;
    if (out_cell_count) |p| p.* = @intCast(res.cell_count);
    if (out_bbox) |p| p.* = res.bounds;
    return 1;
}

/// The resolved backend format (after a TILE57_FORMAT_AUTO sniff).
export fn tile57_source_format(src: ?*Source) callconv(.c) c_int {
    const s = src orelse return @intFromEnum(CFormat.auto);
    return cFormat(s.format());
}

export fn tile57_source_close(src: ?*Source) callconv(.c) void {
    if (src) |s| s.deinit();
}

/// Min/max zoom served by the source.
export fn tile57_source_zoom_range(src: ?*Source, min_z: *u8, max_z: *u8) callconv(.c) void {
    const s = src orelse {
        min_z.* = 0;
        max_z.* = 0;
        return;
    };
    const zr = s.zoomRange();
    min_z.* = zr.min;
    max_z.* = zr.max;
}

/// Bitmask of the navigational bands present in the source.
export fn tile57_source_bands(src: ?*Source) callconv(.c) u32 {
    const s = src orelse return 0;
    return s.bands();
}

/// The distinct SCAMIN denominators present in the source (the live SCAMIN manifest;
/// see tile57.h). On success returns 1 with *out pointing at *out_len int32 values
/// (ascending), 0 if there are none; -1 on error. Free *out with tile57_tile_free
/// ((uint8_t*)*out, *out_len * sizeof(int32_t)).
export fn tile57_source_scamin(src: ?*Source, out: *[*]i32, out_len: *usize) callconv(.c) c_int {
    const s = src orelse return -1;
    const vals = s.scamin() catch return -1;
    if (vals.len == 0) {
        source.freeBytes(@as([*]u8, @ptrCast(vals.ptr))[0 .. vals.len * @sizeOf(u32)]);
        out_len.* = 0;
        return 0;
    }
    out.* = @ptrCast(vals.ptr); // SCAMIN denominators fit in int32 (max ~2^31)
    out_len.* = vals.len;
    return 1;
}

/// Geographic bounds (west,south,east,north degrees); true when known.
export fn tile57_source_bounds(src: ?*Source, w: *f64, s: *f64, e: *f64, n: *f64) callconv(.c) bool {
    const so = src orelse return false;
    const b = so.bounds() orelse return false;
    w.* = b[0];
    s.* = b[1];
    e.* = b[2];
    n.* = b[3];
    return true;
}

/// A good initial camera (center lat/lon + zoom) on real data; true when set.
export fn tile57_source_anchor(src: ?*Source, lat: *f64, lon: *f64, zoom: *f64) callconv(.c) bool {
    const so = src orelse return false;
    const a = so.anchor() orelse return false;
    lat.* = a.lat;
    lon.* = a.lon;
    zoom.* = a.zoom;
    return true;
}

/// Fetch tile (z,x,y) as MVT bytes. 1=OK + out/out_len, 0=empty, -1=error.
export fn tile57_tile_get(
    src: ?*Source,
    z: u8,
    x: u32,
    y: u32,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const s = src orelse return -1;
    const r = s.tile(z, x, y) catch return -1;
    if (r) |bytes| {
        out.* = bytes.ptr;
        out_len.* = bytes.len;
        return 1;
    }
    return 0;
}

export fn tile57_tile_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    source.freeBytes(p[0..len]);
}

/// Free any engine-returned buffer (tiles, style, scamin array, colortables, …). See tile57.h.
/// (chart-api.md — the universal free; supersedes tile57_tile_free.)
export fn tile57_free(ptr: ?*anyopaque, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    source.freeBytes(@as([*]u8, @ptrCast(p))[0..len]);
}

/// Drop the in-memory tile cache (bounds memory in long-running hosts).
export fn tile57_source_clear_cache(src: ?*Source) callconv(.c) void {
    if (src) |s| s.clearCache();
}

// ---- portrayal asset generation (in-memory; mirrors tile57.h) --------------
//
// Generate the S-101 portrayal assets at runtime from in-memory catalogue bytes
// (the host reads the files; capi never touches the filesystem). All outputs are
// page-allocator-owned — free with tile57_tile_free.

// A named blob: NUL-terminated id + bytes. Mirrors tile57_named_bytes in tile57.h.
const NamedBytes = extern struct {
    id: [*:0]const u8,
    data: [*]const u8,
    len: usize,
};

fn lineStyleSrcs(a: std.mem.Allocator, items: []const NamedBytes) ?[]assets.LineStyleSrc {
    const out = a.alloc(assets.LineStyleSrc, items.len) catch return null;
    for (items, 0..) |it, i| out[i] = .{ .id = std.mem.span(it.id), .xml = it.data[0..it.len] };
    return out;
}

fn svgSrcs(a: std.mem.Allocator, items: []const NamedBytes) ?[]sprite.SvgSrc {
    const out = a.alloc(sprite.SvgSrc, items.len) catch return null;
    for (items, 0..) |it, i| out[i] = .{ .id = std.mem.span(it.id), .svg = it.data[0..it.len] };
    return out;
}

fn areaFillSrcs(a: std.mem.Allocator, items: []const NamedBytes) ?[]sprite.AreaFillSrc {
    const out = a.alloc(sprite.AreaFillSrc, items.len) catch return null;
    for (items, 0..) |it, i| out[i] = .{ .id = std.mem.span(it.id), .xml = it.data[0..it.len] };
    return out;
}

/// colortables.json from a ColorProfiles/colorProfile.xml. 1=ok, 0=error.
export fn tile57_colortables(xml: [*]const u8, xml_len: usize, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const json = assets.colorTablesJson(gpa, xml[0..xml_len]) catch return 0;
    out.* = json.ptr;
    out_len.* = json.len;
    return 1;
}

// The S-52 colour profile baked into the library, or null if (somehow) absent.
fn embeddedColorProfileXml() ?[]const u8 {
    for (colorprofile_registry.entries) |e| return e.bytes;
    return null;
}

/// S-52 colortables.json from the colour profile baked into the library — no
/// on-disk catalogue needed. Pair with tile57_style_template / tile57_build_style.
/// 1=ok + out/out_len (free with tile57_tile_free), 0=error.
export fn tile57_colortables_default(out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    const xml = embeddedColorProfileXml() orelse return 0;
    const json = assets.colorTablesJson(gpa, xml) catch return 0;
    out.* = json.ptr;
    out_len.* = json.len;
    return 1;
}

/// linestyles.json from the S-101 LineStyles/*.xml (id = file stem). 1=ok, 0=error.
export fn tile57_linestyles(srcs: [*]const NamedBytes, count: usize, out: *[*]u8, out_len: *usize) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = lineStyleSrcs(arena.allocator(), srcs[0..count]) orelse return 0;
    const json = assets.linestylesJson(gpa, list) catch return 0;
    out.* = json.ptr;
    out_len.* = json.len;
    return 1;
}

/// Sprite atlas (sprite.json + sprite.png) from the S-101 Symbols/*.svg + a
/// palette CSS. 1=ok with both buffers set (free each with tile57_tile_free), 0=error.
export fn tile57_sprite_atlas(
    svgs: [*]const NamedBytes,
    count: usize,
    css: [*]const u8,
    css_len: usize,
    out_json: *[*]u8,
    out_json_len: *usize,
    out_png: *[*]u8,
    out_png_len: *usize,
) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = svgSrcs(arena.allocator(), svgs[0..count]) orelse return 0;
    const atlas = sprite.spriteAtlas(gpa, list, css[0..css_len]) catch return 0;
    out_json.* = atlas.json.ptr;
    out_json_len.* = atlas.json.len;
    out_png.* = atlas.png.ptr;
    out_png_len.* = atlas.png.len;
    return 1;
}

/// Area-fill pattern atlas (patterns.json + patterns.png) from the AreaFills/*.xml
/// + their referenced Symbols/*.svg + a palette CSS. 1=ok, 0=error.
export fn tile57_pattern_atlas(
    fills: [*]const NamedBytes,
    fill_count: usize,
    symbols: [*]const NamedBytes,
    symbol_count: usize,
    css: [*]const u8,
    css_len: usize,
    out_json: *[*]u8,
    out_json_len: *usize,
    out_png: *[*]u8,
    out_png_len: *usize,
) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fl = areaFillSrcs(arena.allocator(), fills[0..fill_count]) orelse return 0;
    const sl = svgSrcs(arena.allocator(), symbols[0..symbol_count]) orelse return 0;
    const atlas = sprite.patternAtlas(gpa, fl, sl, css[0..css_len]) catch return 0;
    out_json.* = atlas.json.ptr;
    out_json_len.* = atlas.json.len;
    out_png.* = atlas.png.ptr;
    out_png_len.* = atlas.png.len;
    return 1;
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
/// 1=ok + out/out_len (free with tile57_tile_free), 0=error.
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
/// out/out_len (free with tile57_tile_free): "[]" when nothing changed, one op per
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
/// `minzoom` / `maxzoom` of 0 -> engine defaults. 1=ok + out/out_len (free with
/// tile57_tile_free), 0=error.
export fn tile57_style_template(
    scheme: c_int,
    source_tiles: ?[*:0]const u8,
    sprite_url: ?[*:0]const u8,
    glyphs_url: ?[*:0]const u8,
    minzoom: u32,
    maxzoom: u32,
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
    if (minzoom != 0) opts.minzoom = minzoom;
    if (maxzoom != 0) opts.maxzoom = maxzoom;
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
    };
}
