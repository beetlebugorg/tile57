---
id: zig-api
title: Zig API
sidebar_position: 5
---

# Zig API

The engine is a Zig package named **`tile57`** (v0.3.0, requires Zig 0.16).
Add it as a dependency and `@import("tile57")` for the curated public surface
(`src/tile57.zig`). The [C ABI](./c-api.md) is a thin shim over this same API,
and both share the same shape: **bake, then compose** (or bake, then render) —
source charts bake once to per-chart archives, and every output is produced
from baked archives. These pages are grouped the same way as the [C API](./c-api.md).

:::note
`zig fetch --save "https://github.com/beetlebugorg/tile57/archive/refs/tags/v0.3.0.tar.gz"`
adds it. A fetched package carries the S-101 catalogue as a lazy dependency, so
there are no submodules to initialise. See [Installation](./installation.md).
:::

## Sections

| Page | What it covers |
|------|----------------|
| [Errors & lifecycle](./zig/errors-lifecycle.md) | the error-union model, handle lifetime + threading, `tile57.warmup`, `tile57.freeBytes`, the version string |
| [Bake](./zig/bake.md) | `tile57.bake` — charts → per-chart PMTiles archives |
| [Render](./zig/render.md) | the `Chart` — open modes, the render surfaces (pixel / surface callbacks / GPU scene / ASCII), the cursor pick, and metadata |
| [Compose](./zig/compose.md) | `tile57.compose` — the `ComposeSource` stitching many charts into one |
| [Portrayal assets](./zig/assets.md) | `tile57.sprite` — the sprite + area-fill pattern atlases |
| [MapLibre style](./zig/style.md) | `tile57.style` + `tile57.Mariner` — a concrete style JSON, colour tables, line styles |
| [Low-level modules](./zig/low-level.md) | Zig-only packages with no C ABI equivalent: tiling/encoding and the raw `tile57.formats` parsers |
