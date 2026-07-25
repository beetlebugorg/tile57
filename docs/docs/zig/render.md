---
title: Render
slug: /zig-api/render
---

# Render: the `Chart`

A `Chart` is one open chart — metadata, feature extraction, the S-52 cursor
pick, and view renders, with no composition. Tiles across many charts come from
the [compositor](./compose.md).

## Opening a chart

Opening (and baking) takes a `std.Io` and an allocator. Set those up once — any
allocator works; the C ABI uses `std.heap.c_allocator`:

```zig
const std = @import("std");
const tile57 = @import("tile57");

const gpa = std.heap.c_allocator;
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();
const io = threaded.io();
```

The common case is one **baked PMTiles archive**, opened `mmap`'d — a whole chart
library can be open without being resident, and the file stays borrowed for the
chart's lifetime (released in `deinit`):

```zig
var chart = try tile57.Chart.openPmtilesPath(io, "out/tiles/US5MD1MC.pmtiles");
defer chart.deinit();

const bbox = chart.bounds();   // geographic extent [w, s, e, n], or null
// … chart.renderView(…) / chart.queryPoint(…) below …
```

That is all most callers need. To serve tiles across *many* archives, open them
with the [compositor](./compose.md) instead.

### Other open modes

A chart can also come from memory or from live S-57 source. What it can serve
depends on how it was opened:

```zig
// A baked archive from memory (fmt .pmtiles, copied) — the same as
// openPmtilesPath but without a file. OR ONE live S-57 cell fully portrayed
// (fmt .auto / .s57): renders views with the S-101 rules evaluated at call time.
// rules_dir null/"" uses the embedded catalogue.
pub fn Chart.openBytes(bytes: []const u8, fmt: Format, rules_dir: ?[]const u8) !*Chart

// A streaming ENC_ROOT (or a single .000): enumerate the cells and peek each
// bbox + compilation scale at open, then read cell bytes on demand (freed on LRU
// eviction), so a whole catalogue opens instantly. Metadata + extraction ONLY
// (chartsJson / featuresJson / scamin / bounds) — no view renders, no tiles.
pub fn Chart.openPath(path: []const u8, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart

// The same streaming surface from in-memory charts / a host reader callback.
pub fn Chart.openCharts(cells: []const ChartInput, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart
pub fn Chart.openChartsStreaming(metas: []const ChartMeta, reader: ChartReadFn,
                                 user: ?*anyopaque, rules_dir: ?[]const u8, pick_attrs: bool) !*Chart
```

`Format` is `.auto` / `.pmtiles` / `.s57`. `rules_dir` is the S-101 portrayal
rules directory for live S-57 charts; `null` (or `""`) uses the rules embedded in
the binary (or `TILE57_S101_RULES` if set), so no on-disk catalogue is required; a
path overrides with an on-disk catalogue. The streaming open uses the extern types
`tile57.ChartMeta` (bbox + `cscl`), `tile57.ChartBytes` (a chart's base + updates,
ownership transferred to the library), and `tile57.ChartReadFn` (the reader
callback); multi-chart input for `openCharts` is `tile57.ChartInput`.

## Render surfaces

Every render surface draws the SAME portrayal of the SAME view — centre +
fractional zoom + pixel size — replaying the archive's baked tiles through the
S-52 pixel path: one scene across every covering tile, labels decluttered over the
whole canvas, catalogue symbols replayed as vectors. They differ only in what they
hand back. `palette` is `tile57.render.resolve.PaletteId` (`.day` / `.dusk` /
`.night`); `settings` is `*const tile57.Mariner` — the same S-52 display-options
struct the [style builder](./style.md) takes (aliased as `render.resolve.Settings`),
evaluated at render time. The composed twins live on the [compositor](./compose.md).

### Finished view (PNG / PDF)

```zig
// Render a VIEW through the native S-52 pixel path: real portrayal, vector
// symbols, labels + declutter over the whole canvas. `output` selects PNG / PDF /
// a callback canvas (cb_table). Returns gpa-owned bytes — free with
// tile57.freeBytes. Cell-backed sources only (a baked archive replays its tiles).
pub fn Chart.renderView(self: *Chart, lon: f64, lat: f64, zoom: f64, w: u32, h: u32,
                        palette: render.resolve.PaletteId, settings: *const render.resolve.Settings,
                        output: render.pixel.Output, cb_table: ?*const render.cb_canvas.CCanvas) ![]u8
```

### Host surface (vector callbacks)

```zig
// Portray the view once and drive world-space surface callbacks — the vector twin
// a GPU host tessellates once and transforms per frame, so symbols and text stay a
// constant on-screen size while the view moves. rotation_rad is the view rotation
// (radians CW; 0 = north-up), applied by the host.
pub fn Chart.renderSurfaceView(self: *Chart, lon: f64, lat: f64, zoom: f64, rotation_rad: f64,
                               w: u32, h: u32, palette: render.resolve.PaletteId,
                               settings: *const render.resolve.Settings,
                               cb: *const render.vector.CSurface) !void
```

`cb` is a `tile57.render.vector.CSurface` vtable — the same surface the C ABI's
`tile57_surface_cb` wraps. The callback semantics (world coordinates, SCAMIN and
display-category gates, `map`/`viewport` rotation alignment) and the S-52
**paint order** obligation are documented once on the C API page:
[Host surface](../api/render.md#host-surface-vector-callbacks) and
[Paint order](../api/render.md#paint-order).

### Draw-ready GPU scene

For a GPU host, `renderGpuScene` hands geometry back **already triangulated, already
in paint order, and already split into ranges that each draw with one pipeline** — so
the host owns no tessellator and no copy of the S-52 ordering rules. Upload the
buffers, then walk the ranges in order.

```zig
// Portray the whole view into draw-ready GPU buffers. No rotation parameter,
// deliberately: geometry stays north-up in world space and the host applies the
// view rotation, so a course-up view that turns continuously never rebuilds.
// pixel_ratio is the display density (1, 2, …), matching the sprite atlas you
// upload. The result owns its arena; release it with GpuScene.deinit.
pub fn Chart.renderGpuScene(self: *Chart, lon: f64, lat: f64, zoom: f64, w: u32, h: u32,
                            palette: render.resolve.PaletteId, settings: *const render.resolve.Settings,
                            pixel_ratio: f64) !*GpuScene
```

The returned `*tile57.GpuScene` owns an arena; call `.deinit()` when you have
finished uploading. Its buffers live on `.scene`, a `tile57.render.gpu.Scene`:

```zig
const gpu = tile57.render.gpu;   // Scene / Vertex / Quad / Range / NO_PATTERN

var gs = try chart.renderGpuScene(-76.48, 38.974, 13.5, 1600, 1200, .day, &settings, 2.0);
defer gs.deinit();

const s: gpu.Scene = gs.scene;
// Upload once — plus the sprite + SDF-glyph atlas textures you baked from
// tile57.sprite (see Portrayal assets).
uploadVertices(s.vertices);   // []const gpu.Vertex — world (x,y) + screen-space (ox,oy) + scamin/disp_cat + color + depth
uploadIndices(s.indices);     // []const u32
uploadQuads(s.quads);         // []const gpu.Quad — sprite + SDF-glyph vertices, 6 per quad

// Draw every range IN ORDER (they arrive sorted by paint_key — drawing them in
// sequence is all it takes to honour S-52 paint order):
for (s.ranges) |r| {          // []const gpu.Range
    switch (r.prim) {
        .triangles => drawIndexed(
            r.first, r.count, r.color,
            if (r.pattern != gpu.NO_PATTERN) s.patterns[r.pattern] else null,
        ),
        .quads => drawQuads(r.first, r.count, r.atlas), // r.atlas: .sprite / .glyph / .glyph_bold / .glyph_italic
    }
}
```

Each vertex splits its **world** position (which the camera transforms) from a
**screen-space** reference-pixel offset `(ox, oy)`, so a symbol or label holds a
constant on-screen size while its anchor rides the chart — no re-tessellation on
zoom. Per-vertex `scamin` / `disp_cat` are the visibility gates the host applies in
the shader (rather than rebuilding per zoom), and a range whose `flags` bit 0 is set
is OPAQUE — eligible for a front-to-back depth-tested pass (the per-vertex `depth`
encodes paint order: later paint = smaller = closer). The remaining field-by-field
semantics — pattern tiling, the upright fix on tangent-rotated text, `map_align`
rotation — are identical to the C ABI and documented once on the C API page:
[Draw-ready GPU scenes](../api/render.md#draw-ready-gpu-scenes-batched-buffers).

The composed twin — a whole chart library into one scene — is
[`tile57.compose.renderGpuScene`](./compose.md#composed-render-surfaces).

### Terminal (ASCII)

```zig
// The same view as a terminal text grid (Unicode; ansi = colour escapes).
pub fn Chart.renderAscii(self: *Chart, lon: f64, lat: f64, zoom: f64, cols: u32, rows: u32,
                         palette: render.resolve.PaletteId, settings: *const render.resolve.Settings,
                         ansi: bool) ![]u8
```

## Query the features under a point

```zig
// The S-52 cursor pick (§10.8): replay the finest tile covering (lon,lat) and
// report each feature the point falls in — class + S-57 attribute JSON + source
// cell — via cb. Passing the view zoom applies the same SCAMIN cull the renderer
// does, so it returns only the features actually displayed at that zoom.
pub fn Chart.queryPoint(self: *Chart, lon: f64, lat: f64, zoom: f64,
                        cb: *const render.query.QueryCb) !void
```

## Metadata + extraction

All JSON accessors are `gpa`-owned; free with `tile57.freeBytes`.

```zig
pub fn Chart.chartsJson(self: *Chart) !?[]u8          // per-cell metadata JSON array (the `cells` CLI)
pub fn Chart.featuresJson(self: *Chart, classes: []const u8) !?[]u8  // GeoJSON for comma-separated classes
pub fn Chart.coverage(self: *const Chart) ?[]const []const []const LonLat  // M_COVR data-coverage rings
pub fn Chart.bounds(self: *Chart) ?[4]f64             // geographic extent [w, s, e, n], if known
pub fn Chart.anchor(self: *Chart) ?struct { lat, lon, zoom }  // a good initial camera on real data
pub fn Chart.bands(self: *Chart) u32                  // bitmask of navigational bands present
pub fn Chart.zoomRange(self: *Chart) struct { min: u8, max: u8 }  // the zoom span the chart covers
pub fn Chart.nativeScale(self: *const Chart) i32      // compilation scale 1:N (0 = unknown)
pub fn Chart.scamin(self: *Chart) ![]u32              // the distinct SCAMIN denominators (the live manifest)
pub fn Chart.tileType(self: *Chart) pmtiles.TileType  // the tile encoding (MVT / MLT)
pub fn Chart.format(self: *Chart) Format              // the resolved backend (after .auto)
pub fn Chart.pmtilesReader(self: *Chart) ?*pmtiles.Reader        // raw per-archive tiles — the primitive
                                                                 // for writing your own compositor
pub fn Chart.decodedCoverage(self: *const Chart) ?ChartCoverage  // decoded coverage; what the compositor borrows
pub fn Chart.deinit(self: *Chart) void                // release the chart and its cached tiles
```

`pmtilesReader()` + `decodedCoverage()` are the two handles the built-in
[compositor](./compose.md) borrows when you compose over already-open charts.
