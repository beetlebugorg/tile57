---
title: Low-level modules
slug: /zig-api/low-level
---

# Low-level modules

These packages have no C ABI equivalent — they are Zig-only, for callers that
compose their own pipeline below the `Chart` / `ComposeSource` surface.

## Tiling + encoding

The mid-level packages:

| Module | Role |
|--------|------|
| `tile57.mvt` / `tile57.mlt` | Mapbox Vector Tile / MapLibre Tile encode/decode |
| `tile57.tile` | web-mercator tiling + clipping |
| `tile57.pmtiles` | PMTiles read/write |
| `tile57.band` | compilation-scale → zoom-range mapping |
| `tile57.bake_enc` | banded multi-chart ENC_ROOT → PMTiles |
| `tile57.scene` | S-57 feature → tile-surface scene generation |
| `tile57.render` | the Surface/Canvas rendering path (PNG, PDF, ASCII, callbacks) |

## Raw formats (advanced)

The pure-Zig foundational parsers under `tile57.formats`:

| Module | Role |
|--------|------|
| `tile57.formats.iso8211` | ISO/IEC 8211 records |
| `tile57.formats.s57` | the S-57 chart parser + geometry |
| `tile57.formats.s101` | the S-101 catalogue, adapter, and instruction stream |

`tile57.coverage` is the per-chart M_COVR coverage sidecar (carried in an
archive's PMTiles metadata).
