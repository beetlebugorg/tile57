---
title: Compose
slug: /zig-api/compose
---

# Compose

The runtime compositor stitches per-chart archives into one seamless chart: any
`(z, x, y)` tile on demand through the ownership partition (charts never
double-draw where they meet), and the same view outputs as a single
[chart](./render.md), composed. It **borrows** its charts — their mmap'd readers +
decoded coverage — so the chart set is never fully resident and the charts must
outlive the source. Open once, serve many, `deinit`.

```zig
// Open the compositor over on-disk archives + a partition, then compose tiles.
var src = (try tile57.compose.ComposeSource.openFiles(io, gpa, paths, "/out/partition.tpart")).?;
defer src.deinit();
const result = try src.tile(gpa, 13, 2359, 3139); // result.tile: ?[]u8, result.owned: bool

// The composed view outputs live beside the Chart ones:
const png = try tile57.compose.renderView(src, lon, lat, 13.5, 1600, 1200, .day, &settings, .png, null);
```

```zig
// Open over per-chart PMTiles paths (mmap'd; the chart set is never fully
// resident). load_partition (null to skip) names a .tpart sidecar to load and
// skip the build. Null when no archive carries coverage.
pub fn ComposeSource.openFiles(io: std.Io, gpa: std.mem.Allocator,
                               paths: []const []const u8, load_partition: ?[]const u8) !?*ComposeSource

// Open over already-open charts' archives (everything is BORROWED — the charts
// must outlive this source). Build each ChartArchive from a chart's
// pmtilesReader() + decodedCoverage().
pub fn ComposeSource.open(gpa: std.mem.Allocator, archives: []const ChartArchive,
                          load_partition: ?[]const u8) !?*ComposeSource

// Compose one tile on demand. TileResult = { tile: ?[]u8, owned: bool }: a null
// tile with owned=false is true empty ocean (safe to cache); owned=true but null
// is a chart owning the ground that produced nothing (transient while its bake runs).
pub fn ComposeSource.tile(self: *ComposeSource, gpa: std.mem.Allocator,
                          z: u8, tx: u32, ty: u32) !TileResult

// Serialize the ownership partition (a sidecar a later openFiles loads to skip
// the build).
pub fn ComposeSource.serializePartition(self: *ComposeSource, gpa: std.mem.Allocator) ![]u8

// Release the source. Its charts stay open (and stay yours to close).
pub fn ComposeSource.deinit(self: *ComposeSource) void
```

A host that already holds open charts composes over them instead — the compositor
borrows each chart's mmap'd reader + decoded coverage, so the charts must outlive it:

```zig
const archives = [_]tile57.compose.ChartArchive{
    .{ .reader = chart.pmtilesReader().?, .cov = chart.decodedCoverage().? },
};
var src = (try tile57.compose.ComposeSource.open(gpa, &archives, null)).?;
```

## Composed render surfaces

Each composed output is the matching single-chart [render surface](./render.md#render-surfaces)
over the whole set instead of one archive — same `palette` (`.day` / `.dusk` /
`.night`) and `settings` (`*const tile57.Mariner`), same callbacks, but taking a
`*ComposeSource` as the first argument and decluttering labels across tile **and
chart** seams. They live under the `compose` name because their render path depends
on `Chart`, while the underlying `compose` module is a dependency leaf.

### Finished view (PNG / PDF)

```zig
pub fn compose.renderView(src: *ComposeSource, lon: f64, lat: f64, zoom: f64, w: u32, h: u32,
                          palette: render.resolve.PaletteId, settings: *const render.resolve.Settings,
                          output: render.pixel.Output, cb_table: ?*const render.cb_canvas.CCanvas) ![]u8
```

`output` selects `.png` / `.pdf` / a callback canvas (pass `cb_table` for the
canvas, else `null`). Returns `gpa`-owned bytes — free with `tile57.freeBytes`. The
composed twin of [`Chart.renderView`](./render.md#finished-view-png--pdf), rendered
across every covering tile.

```zig
const png = try tile57.compose.renderView(src, -76.48, 38.974, 13.5, 1600, 1200, .day, &settings, .png, null);
defer tile57.freeBytes(png);
```

### Host surface (vector callbacks)

```zig
pub fn compose.renderSurfaceView(src: *ComposeSource, lon: f64, lat: f64, zoom: f64, rotation_rad: f64,
                                 w: u32, h: u32, palette: render.resolve.PaletteId,
                                 settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void
```

Drives the same `tile57.render.vector.CSurface` vtable as
[`Chart.renderSurfaceView`](./render.md#host-surface-vector-callbacks) — the vector
twin a GPU host tessellates once and transforms per frame — but portrayed across the
whole set. `rotation_rad` is the view rotation (radians CW; 0 = north-up), applied
by the host. The callback contract and the S-52 paint-order obligation are on the C
API page: [Host surface](../api/render.md#host-surface-vector-callbacks) and
[Paint order](../api/render.md#paint-order).

### Draw-ready GPU scene

```zig
pub fn compose.renderGpuScene(src: *ComposeSource, lon: f64, lat: f64, zoom: f64, w: u32, h: u32,
                              palette: render.resolve.PaletteId, settings: *const render.resolve.Settings,
                              pixel_ratio: f64) !*GpuScene
```

The GPU twin of `renderSurfaceView`: a whole chart library into one
`tile57.GpuScene`, seams stitched across cells. Use it exactly like
[`Chart.renderGpuScene`](./render.md#draw-ready-gpu-scene) — upload `gs.scene`'s
buffers, walk `gs.scene.ranges` in order and draw each, then `gs.deinit()`.
`pixel_ratio` is the display density, matching the sprite atlas you upload.

```zig
var gs = try tile57.compose.renderGpuScene(src, -76.48, 38.974, 13.5, 1600, 1200, .day, &settings, 2.0);
defer gs.deinit();
for (gs.scene.ranges) |r| {
    // same draw loop as Chart.renderGpuScene — pick a pipeline from r.prim/r.atlas,
    // draw r.first/r.count, in order.
    _ = r;
}
```

### Cross-view label pass

```zig
pub fn compose.renderLabels(src: *ComposeSource, lon: f64, lat: f64, zoom: f64, rotation_rad: f64,
                            w: u32, h: u32, palette: render.resolve.PaletteId,
                            settings: *const render.resolve.Settings, cb: *const render.vector.CSurface) !void
```

A view-level, globally-decluttered **text-only** pass — it emits only the surviving
labels through the same `CSurface` text callbacks (at the same world anchors as
`renderSurfaceView`), decluttered across tile and chart seams, and draws no fills,
lines, symbols, or soundings. A host that caches geometry per tile draws that cache
itself, then calls this once per frame to overlay the globally-decluttered text last
(text draws on top). See the C API's
[cross-view label pass](../api/render.md#per-tile-surface--cross-view-labels).

### Cursor pick

```zig
pub fn compose.queryPoint(src: *ComposeSource, lon: f64, lat: f64, zoom: f64,
                          cb: *const render.query.QueryCb) !void
```

The S-52 §10.8 cursor pick across chart boundaries — the composed twin of
[`Chart.queryPoint`](./render.md#query-the-features-under-a-point), reporting each
feature under `(lon, lat)` at the view `zoom` (class + S-57 attribute JSON + source
cell) through `cb`.

---

`tile57.compose.tile` is the stateless core `ComposeSource.tile` uses, and
`tile57.partition` is the ownership partition and its `.tpart` sidecar
(serialize / deserialize).
