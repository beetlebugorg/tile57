---
title: Bake
slug: /zig-api/bake
---

# Bake

Tile production is **bake, then compose**. First bake each chart to its own
PMTiles at its compilation scale — the archive embeds the chart's M_COVR
coverage, compilation scale, and identity in its metadata. Then open a
[compositor](./compose.md) over the archives and serve any `(z, x, y)` tile on
demand. Strictly one chart, one archive.

Every returned byte buffer is `gpa`-owned; free it with `tile57.freeBytes` (see
[Errors & lifecycle](./errors-lifecycle.md)).

```zig
// Bake an ENC_ROOT: each chart -> <out>/tiles/<STEM>.pmtiles + <out>/partition.tpart.
const n = try tile57.bake.tree(io, "/enc/ENC_ROOT", "/out", null, 4, null, null);
```

```zig
// Bake ONE chart (+ its .001.. updates, read from disk) to PMTiles bytes over its
// native band zoom range. Returns null when the chart produced no tiles.
// rules_dir null/"" uses the embedded S-101 catalogue.
pub fn bake.chartBytes(cell_path: []const u8, rules_dir: ?[]const u8) !?[]u8

// Bake N charts IN PARALLEL across `workers` threads (a MEMORY bound — pass a
// small count). out[i] receives chart i's archive bytes, or null.
pub fn bake.chartsParallel(paths: []const []const u8, rules_dir: ?[]const u8,
                           workers: usize, out: []?[]u8) void

// The same, writing each archive straight to its out_paths[i] file (the engine
// writes + frees each archive, so the host never holds N in memory). Returns the
// count written; `progress` fires per chart and may cancel by returning false.
pub fn bake.chartsToFiles(io: std.Io, in_paths: []const []const u8,
                          out_paths: []const []const u8, rules_dir: ?[]const u8,
                          workers: usize, progress: bake.Progress, progress_ctx: ?*anyopaque) usize

// Walk in_dir for *.000 charts and bake each IN PARALLEL to the SAME relative path
// under out_dir with a .pmtiles extension. INCREMENTAL: a chart whose archive is
// already at least as new as its whole input (.000 + update chain) is skipped, so a
// re-run over an unchanged tree bakes nothing. Returns the count baked THIS run.
pub fn bake.tree(io: std.Io, in_dir: []const u8, out_dir: []const u8,
                 rules_dir: ?[]const u8, workers: usize,
                 progress: bake.Progress, progress_ctx: ?*anyopaque) !usize

// Read a baked archive's metadata JSON (decompressed) — a per-chart bake embeds
// the chart's coverage + compilation scale + date/name. null when it carries none.
pub fn bake.pmtilesMetadata(a: std.mem.Allocator, archive: []const u8) !?[]u8
```

`bake.Progress` is the optional progress-callback type — it fires per chart
(serialised) for an import progress bar and may **cancel** by returning `false`; a
cancelled `tree` run resumes where it left off, baking only what the cancel left
undone.

The `tile57 bake <cell.000 | ENC_ROOT> -o out/` CLI produces this structure
directly: `out/tiles/<STEM>.pmtiles` per chart plus `out/partition.tpart`.

Reading raw S-57 source data — a chart inventory or GeoJSON feature extraction with
no bake — goes through a streaming `Chart`; see [`openPath`](./render.md) and
`chartsJson` / `featuresJson` on the [Render](./render.md#metadata--extraction) page.
