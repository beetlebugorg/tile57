---
id: cli
title: The CLI
sidebar_position: 4
---

# The CLI

`tile57` (built to `zig-out/bin/tile57` by `zig build`) is the offline
command-line tool over the engine: it bakes charts, serves and inspects tiles,
renders finished views, and emits the portrayal assets. The S-101 Portrayal
Catalogue — rules and assets — is embedded in the binary, so no command needs
an on-disk catalogue; `--rules <dir>` (portrayal) or a positional catalogue
path (the asset commands) overrides the embedded copy.

Usage lines keep S-57's own word for a chart: a *cell*. `<cell.000>` is one
chart's base file (its sequential `.001`, `.002` … updates are discovered
automatically); `ENC_ROOT` is a whole catalogue directory.

## Bake and serve

### `bake`

```
tile57 bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [--from-archives]
```

Produces the **live-composite structure** every other output is served from:
each chart bakes at its native band scale to its own
`<out>/tiles/<STEM>.pmtiles` (M_COVR coverage embedded in the archive
metadata), and the ownership partition is written to `<out>/partition.tpart`.
There is no merged archive — a runtime compositor serves any tile on demand —
and re-runs are incremental: an archive already newer than its whole input
(`.000` + update chain) is skipped.

`--from-archives` treats the input as an existing directory of per-chart
archives and only (re)builds `partition.tpart` over them.

### `compose-tile`

```
tile57 compose-tile <tiles-dir> <z> <x> <y> [--load-partition FILE] [-o out] [--bench N]
```

Serves ONE composed tile on demand from a live-composite structure — the
runtime compositor as a command. `--load-partition` reuses the baked
`partition.tpart` instead of rebuilding the partition; `--bench N` times an
N×N block of tiles around `(x, y)`.

## Render

### `png` / `pdf`

```
tile57 png|pdf <cell.000 | bundle.pmtiles> <z> <x> <y> -o <out> [--size N]
tile57 png|pdf <cell.000 | bundle.pmtiles> --view <lon,lat,zoom> --size WxH -o <out>
```

Render one tile, or a view (any centre, fractional zoom, any pixel size),
through the [native S-52 pixel path](./rendering.md): PNG raster or
deterministic vector PDF with real text objects. An S-57 chart renders with
the S-101 rules evaluated live; a baked `.pmtiles` bundle renders by tile
replay. `--palette day|dusk|night` picks the colour scheme, `--dq` overlays
data quality, `--scale F` multiplies physical symbol size, and the mariner
settings flags (`--safety`, `--feet`, `--no-names`, …) are shown in
[The Rendering Engine](./rendering.md#from-the-command-line).

### `ascii`

```
tile57 ascii <cell.000 | bundle.pmtiles> --view <lon,lat,zoom> [--size COLSxROWS] [--ansi] [--tui] [--kitty]
```

The chart in your terminal as a Unicode grid (default size: the terminal).
`--ansi` adds xterm-256 colour, `--tui` opens an interactive pan/zoom loop,
and `--kitty` paints real S-52 pixels inline on kitty-graphics terminals
(Ghostty, Kitty).

## Portrayal assets and style

Each of these takes an optional positional catalogue directory; without one it
uses the catalogue embedded in the binary.

### `assets`

```
tile57 assets [portrayal-catalog-dir] -o <out-dir>
```

Emits every portrayal asset a renderer needs: `colortables.json` (S-52 token →
Day/Dusk/Night hex), `linestyles.json`, the sprite atlas (`sprite.json` +
`sprite.png`), and the area-fill pattern atlas (`patterns.json` +
`patterns.png`).

### `style`

```
tile57 style [portrayal-catalog-dir] --scheme day|dusk|night -o <out.json>
```

Emits one concrete MapLibre `style.json`, with colours resolved from the
catalogue (or `--colortables FILE`). `--source-tiles` / `--pmtiles-url` pick
the tile source, `--sprite` / `--glyphs` enable the symbol and text layers,
and `--minzoom` / `--maxzoom` bound the source.

### `sprite` / `pattern` / `sprite-mln`

```
tile57 sprite|pattern|sprite-mln [portrayal-catalog-dir] -o <out-dir>
```

The focused atlas emitters: `sprite` writes the S-101 symbol atlas, `pattern`
the area-fill pattern atlas, and `sprite-mln` the MapLibre sprite sheet (every
symbol packed into one PNG, each atlas cell centered on its symbol's pivot,
plus the JSON index).

## Inspect

### `explore`

```
tile57 explore <cell.000 | ENC_ROOT --view LON,LAT,ZOOM> [--class ACR[,ACR..]] [--object FOID|RCID|INDEX]
```

The portrayal microscope: dumps, per feature, the raw S-57 (class +
attributes), the S-101 portrayal instruction stream (raw and parsed), and the
resolved Surface draw calls. Takes a single chart, or an ENC_ROOT with
`--view LON,LAT,ZOOM` (or a `…/#v=LON,LAT,ZOOM` share URL) to pull just the
charts under that viewport. `--zoom N` picks the resolving tile, `--json`
emits machine-readable output, `--no-resolve` skips the draw-call pass, and
`--tui` opens a two-pane explorer (`--kitty` adds inline render thumbnails
and a live chart map that frames the selection).

### `cells` / `cell` / `features` / `catalog`

```
tile57 cells    <cell.000 | ENC_ROOT>
tile57 cell     <file.000>
tile57 features <cell.000 | ENC_ROOT> <ACR[,ACR...]>
tile57 catalog  <CATALOG.031>
```

The raw S-57 readers (the CLI face of the `tile57_enc_*` C calls). `cells`
prints per-chart metadata for a chart or a whole catalogue — name, scale,
edition, update, issue date, agency, bbox. `cell` summarises one chart.
`features` extracts the named object classes (e.g. `DEPARE,DRGARE`) as a
GeoJSON FeatureCollection. `catalog` decodes an exchange-set catalogue into
its entries (file, title, bbox).

### `s101`

```
tile57 s101 <file.000> [--features N]
```

Inspects a native S-101 (S-100 Part 10a) chart: confirms detection, prints the
coordinate factors and record counts, the in-band code-table sizes, a
feature-class histogram, and the assembled geometry summary. It then runs the
portrayal rules and reports how many features drew, were empty, or errored. Use
`--features N` to also dump the first N features with their attributes. Charts
are auto-detected everywhere — `png`, `bake`, and the C API read a native S-101
`.000` transparently — so this command is for inspection, not a separate load path.

### `inspect` / `tiledump`

```
tile57 inspect  <file.pmtiles> [z x y]
tile57 tiledump <tile.mlt | tile.mvt> [--geom CLASS [--coords]]
```

`inspect` summarises a baked archive — zoom range and tile counts — and, given
`z x y`, one stored tile (`-o` dumps its raw decompressed bytes). `tiledump`
decodes one raw tile and summarises it: per-layer feature counts by geometry
type plus value histograms of the portrayal properties (`class`,
`symbol_name`, `ls`). `--geom CLASS` switches to per-feature geometry detail
for one class (`--coords` lists the coordinates) — for hunting degenerate
geometry.

### `objlcount`

```
tile57 objlcount <file.000> <objl> [prim]
```

Counts features of one S-57 object-class code (optionally one geometric
primitive) — a corpus-scan helper for finding charts that exercise a class.

## `version` / `help`

`tile57 version` prints the engine version; `tile57 help` prints the usage
summary. A few extra subcommands (`partdbg-png`, `zoomsizes`, `audit-holes`,
`audit-pairs`) are engine-development diagnostics and may change without
notice.
