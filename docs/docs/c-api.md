---
id: c-api
title: C API
sidebar_position: 6
---

# C API

`libtile57.a` exposes the whole engine behind a thin C ABI —
[`include/tile57.h`](../../include/tile57.h), prefix `tile57_`. It is a shim over
the [Zig API](./zig-api.md); the two stay in lock-step.

The pipeline is three stages, and the header (and these pages) are organised the
same way:

- **[Bake](./api/bake.md)** — ENC source data in, per-chart PMTiles out. Each chart
  bakes to its own archive at its own compilation scale, with its M_COVR coverage +
  scale embedded in the archive metadata. The bake page also carries the raw-source
  readers (chart inventory, feature extraction, exchange-set catalogue).
- **[Render](./api/render.md)** — a **`tile57`** chart handle opens ONE baked archive
  and answers for it with NO composition: metadata (info / SCAMIN / coverage), its
  stored tiles verbatim (`tile57_chart_tile` — the primitive for writing your own
  compositor), the S-52 cursor pick, and the render surfaces (PNG / PDF, host vector
  callbacks, the draw-ready GPU scene, canvas, cross-view labels).
- **[Compose](./api/compose.md)** — a **`tile57_compose`** handle stitches MANY open
  charts through the ownership partition and offers the SAME output set, composed:
  `tile57_compose_tile` (what a live tile server hands its HTTP layer — the bytes are
  MapLibre Tiles), `_png`, `_pdf`, `_canvas`, `_surface`, `_query`.

Everything is **bake, then compose** (or bake, then render): source charts
bake once to per-chart archives; every output is produced from baked archives.

Style + portrayal-asset generation rounds out the surface: the mariner's S-52
display options become a concrete [MapLibre style](./api/style.md) JSON plus the
[colortables and sprite / pattern / glyph atlases](./api/assets.md) it references.

The [errors & lifecycle](./api/errors-lifecycle.md) conventions — the status/error
protocol, handle lifetime + threading, `tile57_warmup`, and `tile57_free` — apply to
every call on every page below.

## Sections

| Page | What it covers |
|------|----------------|
| [Errors & lifecycle](./api/errors-lifecycle.md) | `tile57_status` / `tile57_error`, handle lifetime + threading, `tile57_warmup`, `tile57_free`, diagnostics, versioning |
| [Bake](./api/bake.md) | charts → per-chart PMTiles archives; the raw S-57 source readers |
| [Render](./api/render.md) | the `tile57_chart` handle, the cursor pick, and every render surface (PNG / PDF, host vector callbacks, draw-ready GPU scene, canvas, cross-view labels) |
| [Compose](./api/compose.md) | the `tile57_compose` handle — many charts stitched into one composed output set |
| [Portrayal assets](./api/assets.md) | colour tables, line styles, sprite + pattern + SDF-glyph atlases |
| [MapLibre style](./api/style.md) | the `tile57_mariner` options → a concrete style JSON, plus flicker-free style diffs |
