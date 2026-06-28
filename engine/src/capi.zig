//! C ABI for libtile57.a — a thin shim over the Zig engine API (source.zig).
//!
//! Contract: POD across the seam (ptr/len + status codes); Zig errors, slices
//! and optionals stay inside source.zig. Public header: ../../include/tile57.h.
//! The opaque `tile57_source` is a `*source.Source`.

const std = @import("std");
const source = @import("source.zig");
const chartstyle = @import("chartstyle");

const gpa = std.heap.page_allocator;
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
    const style = chartstyle.buildStyle(gpa, tmpl, &m, cts, bands, now_unix) catch return 0;
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
