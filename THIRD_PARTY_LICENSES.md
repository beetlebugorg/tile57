# Third-party notices

tile57 / chartplotter-native is licensed under the [MIT License](LICENSE),
© 2026 Jeremy Collins.

The program bundles, embeds, ports, or builds on the third-party software and data
listed below. Each remains under its own license. This file is informational; the
upstream license text governs. **Keep it current** — when you vendor a library,
port an algorithm from another project, or embed third-party data, add it here in
the same change (see the polylabel entry as the worked example).

## Vendored libraries (compiled into the binary)

| Library | Version | Where | License |
| --- | --- | --- | --- |
| Lua | 5.4.7 | `vendor/lua/` | MIT (© 1994–2024 Lua.org, PUC-Rio) |
| nanosvg | 2013–14 (Mikko Mononen) | `vendor/nanosvg/` | zlib |
| stb_image_write | v1.16 (Sean Barrett) | `vendor/stb/` | public domain (MIT alternative) |
| Noto Sans Regular | 2026.05.01 (Google) | `vendor/fonts/NotoSans-Regular.ttf` | SIL Open Font License 1.1 |

- **Lua** is built from source and driven through `src/portray/lua_shim.c` to run
  the S-101 portrayal rules engine.
- **nanosvg** rasterizes the S-101 SVG symbols into the sprite atlas; it embeds
  Anti-Grain Geometry rasterizer math by Maxim Shemanarev (also permissive).
- **Noto Sans Regular** is `@embedFile`'d into the binary as the render
  engine's single label face (glyph outlines parsed by `src/render/font.zig`,
  a from-scratch TrueType outline reader — no font library is vendored).
- **stb_image_write** writes the PNG sprite atlases.

`vendor/lua/LICENSE.html` carries Lua's full notice; the nanosvg and stb licenses
are in the headers themselves.

## Ported algorithms

### polylabel (pole of inaccessibility)

The area "representative point" search in `src/s57/s57.zig`
(`areaRepresentativePoint` and its `PlCell` quad-tree refinement) is a port of the
Mapbox **polylabel** algorithm.

- Project: https://github.com/mapbox/polylabel — Vladimir Agafonkin / Mapbox

```
ISC License

Copyright (c) 2016 Mapbox

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

## IHO S-101 Portrayal Catalogue and Feature Catalogue

> **License status: to be confirmed.** Treat this as a known open item, not a
> cleared right to redistribute. **Unlike the Go reference** (which `.gitignore`s the
> catalogue and embeds it only in opt-in `_s101` release builds), this repository
> tracks the catalogue as **git submodules** and **embeds it into the default
> `tile57` binary** at build time (`embedDir` in `build.zig`). This repository
> therefore *does* redistribute IHO material — both as submodule references and in
> the built binary — so confirming the rights is more pressing here.

tile57 portrays charts using the **IHO S-101 Portrayal Catalogue** and **Feature
Catalogue** (symbols, color profiles, drawing rules, line styles, area fills, and
feature definitions). These materials are **© the International Hydrographic
Organization (IHO)**.

Source repositories (public, but **no license declared** — all rights reserved):

- Portrayal Catalogue — <https://github.com/iho-ohi/S-101_Portrayal-Catalogue>
  (`vendor/S-101_Portrayal-Catalogue`)
- Feature Catalogue — <https://github.com/iho-ohi/S-101-Documentation-and-FC>
  (`vendor/S-101-Documentation-and-FC`)

Embedded at build time via `embedDir` (`build.zig`): `Rules/*.lua`, `Symbols/*.svg`
+ `*.css`, `LineStyles/*.xml`, `AreaFills/*.xml`, `ColorProfiles/*.xml`. The
`--rules` / `--catalog` flags (and env overrides) can point at an external copy
instead. The IHO copyright and reproduction policy is at <https://iho.int>.

## Derived data

`vendor/s101/catalogue.json` and `vendor/s101/s57codes.json` are distilled from the
IHO Feature Catalogue and the **IHO S-57 Object & Attribute Catalogue** (the object
and attribute acronyms — `ADMARE`, `DEPARE`, …). They carry the same IHO-origin
caveat as the catalogue above. (The same S-57 acronym/code table is distributed in
machine-readable form by the **GDAL** project under MIT/X11.)

## Web demo assets (dev only — not part of the shipped library)

These live under `bindings/js/examples/web/` and `test/` and are used only by the
MapLibre GL JS demo; they are not linked into or embedded by the tile57 library.

| Asset | Where | License |
| --- | --- | --- |
| MapLibre GL JS v5.24.0 | `bindings/js/examples/web/lib/maplibre-gl.{js,css}` | BSD-3-Clause |
| pmtiles.js | `bindings/js/examples/web/lib/pmtiles.js` | BSD-3-Clause (Protomaps) |
| Noto Sans glyphs | `bindings/js/examples/web/glyphs/Noto Sans Regular/*.pbf` | SIL Open Font License 1.1 |
| S-101 sprite atlas | `test/assets/sprite-mln*.{json,png}`, `…/web/chart*/assets/` | generated by tile57 from the IHO Symbols (IHO origin, above) |

## Reference data read at runtime (not redistributed in this repo)

**NOAA ENC** S-57 cells: NOAA charts are works of the U.S. Government and are in the
**public domain**, carrying NOAA's standard disclaimer — the data is **not to be
used for navigation**.

## Formats and standards implemented (no third-party code copied)

- **PMTiles** archive format — Protomaps (BSD-3-Clause spec).
- **Mapbox Vector Tile (MVT)** spec — Mapbox.
- **MapLibre Tile (MLT)** spec — MapLibre.
- **IHO S-100 / S-101 / S-57 / S-52** standards — IHO.
