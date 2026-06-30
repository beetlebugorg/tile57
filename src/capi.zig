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
        out[i] = .{ .base = cc.base[0..cc.base_len], .updates = ups };
    }
    return out;
}

/// Open an ENC_ROOT as a multi-cell source. See tile57.h.
export fn tile57_source_open_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
) callconv(.c) ?*Source {
    if (count == 0) return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cells = toCellInputs(arena.allocator(), cells_ptr[0..count]) orelse return null;
    return Source.openCells(cells, spanOpt(rules_dir)) catch null;
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
) callconv(.c) ?*Source {
    if (count == 0) return null;
    return Source.openCellsStreaming(metas[0..count], read, user, spanOpt(rules_dir)) catch null;
}

// Progress callback for tile57_bake_cells (matches the header typedef + source.Progress).
const BakeProgress = ?*const fn (user: ?*anyopaque, stage: u8, done: usize, total: usize) callconv(.c) void;

/// Bake an ENC_ROOT into ONE PMTiles archive. See tile57.h. 1=ok, 0=empty, -1=error.
export fn tile57_bake_cells(
    cells_ptr: [*]const CellInput,
    count: usize,
    rules_dir: ?[*:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    progress: BakeProgress,
    user: ?*anyopaque,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cells = toCellInputs(arena.allocator(), cells_ptr[0..count]) orelse return -1;
    const archive = source.bakeArchive(cells, spanOpt(rules_dir), minzoom, maxzoom, progress, user) catch return -1;
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
};

// "YYYYMMDD" or "" from the fixed char[9] field.
fn dateViewSlice(buf: *const [9]u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..@min(n, 8)];
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
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    const m = chartstyle.MarinerSettings{
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
    };
    const tmpl = template_json[0..template_len];
    const cts: []const u8 = if (colortables_json) |p| p[0..colortables_len] else "";
    const bands: ?[]const i32 = if (enabled_bands) |p| p[0..enabled_band_count] else null;
    const now_unix: i64 = @intCast(time(null));
    // Single style builder: regenerate the full style with the mariner baked in
    // (chartstyle.buildStyle's template-patch pass is retired). buildFromTemplate lifts
    // the source config out of the passed template and drives the one styleJson.
    const style = assets.buildFromTemplate(gpa, tmpl, &m, cts, bands, now_unix) catch return 0;
    out.* = style.ptr;
    out_len.* = style.len;
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
    };
}
