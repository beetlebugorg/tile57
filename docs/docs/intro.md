---
id: intro
title: Introduction
slug: /
sidebar_position: 1
---

# chartplotter-native

:::warning Not for navigation

This project is coded almost entirely with AI (Claude). It is an experiment in
building a large, complex specification (IHO S-101) with AI, and a personal
learning tool — not a certified or tested product. **Do not rely on it for
real-world navigation.** See [Known limitations](./limitations.md).

:::

**chartplotter-native** generates **marine chart tiles** natively. A **Zig tile
generator** turns official NOAA S-57 ENC cells into S-52 marine chart tiles, and
**[MapLibre Native](https://github.com/maplibre/maplibre-native)** (the C++
renderer) draws them in a real window — Metal on macOS, OpenGL/EGL on Linux.

It is the native sibling of
[**chartplotter-go**](https://github.com/beetlebugorg/chartplotter), which bakes
the same charts into PMTiles and renders them in the browser with MapLibre GL JS.
Here the tile pipeline is reimplemented in Zig and the chart is drawn natively,
with platform chrome (SwiftUI / GTK4) to come.

## How it differs from chartplotter-go

- **Native, not web.** The renderer is MapLibre Native in a desktop window, not
  MapLibre GL JS in a browser.
- **Tiles in Zig.** The ISO 8211 / S-57 / S-101 / MVT pipeline is reimplemented
  in Zig as `libchartplotter.a`, exposing a small [C ABI](./c-api.md).
- **Live, in-process generation.** Instead of pre-baking a PMTiles archive, the
  Zig library generates a tile's vector bytes on demand behind a custom MapLibre
  `FileSource` — so you can render straight from a raw `.000` cell. (Reading a
  pre-baked PMTiles archive still works too.)
- **Same portrayal.** It runs the official IHO **S-101 Portrayal Catalogue** in
  embedded Lua 5.4, just like the Go reference — the Go project remains the
  parity oracle.

## Status

| Milestone | What | State |
|-----------|------|-------|
| M0 | MapLibre Native builds; headless EGL render | ✅ done |
| M1 | Annapolis chart from Go-baked PMTiles + ported S-52 style (Day/Dusk/Night) | ✅ done |
| M2 | Full S-52 fidelity: symbols, glyphs + text, soundings, area patterns, depth-shading | ✅ done |
| M3 | Interactive pan/zoom window serving live Zig tiles (`chartplotter`) | ✅ done |
| M4 | Zig MVT + gzip + PMTiles + projection/clip, differential-tested vs Go | ✅ done |
| M5 | Live in-process tile generation (`libchartplotter.a` + custom `FileSource`) | ✅ done |
| M6a–c | Zig ISO 8211 + S-57 decode + topology → **live cell → MVT → MapLibre** | ✅ done |
| M6d | Embedded-Lua **S-101 portrayal** (real IHO rules) → live ECDIS chart from a raw cell | ✅ core done (~96% of features) |

## Where to go next

- [**Installation**](./installation.md) — submodules, toolchain, reference data.
- [**Getting Started**](./getting-started.md) — build and run the headless and
  interactive hosts.
- [**C API**](./c-api.md) — embed `libchartplotter` in your own renderer.
- [**Architecture**](./architecture.md) — the pipeline and design decisions.
- [**Tile Schema**](./tile-schema.md) — the vector-tile layer contract.
- [**Known Limitations**](./limitations.md) — what does not render yet.
