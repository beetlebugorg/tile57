---
id: installation
title: Installation
sidebar_position: 2
---

# Installation

tile57 builds from source with **Zig 0.16** — no CMake, no system libraries
beyond Zig itself. There are no pre-built binaries.

## 1. Clone + fetch the submodules

```sh
git clone https://github.com/beetlebugorg/tile57.git
cd tile57
git submodule update --init --recursive
```

The vendored **IHO S-101 Portrayal Catalogue** comes in as a submodule (under
`vendor/`). It is a **build-time** dependency: `zig build` embeds the
catalogue (the Lua portrayal rules plus the symbols, line styles, area fills and
colour profile) directly into the binary via `@embedFile`, so the resulting
`tile57` needs no on-disk catalogue at runtime. Lua 5.4 is vendored under
`vendor/lua` and compiled in, so no system Lua is needed either.

## 2. Zig 0.16.0 (required)

The engine, the `tile57` CLI, and the static library all need **Zig 0.16.0**.
Install it from [ziglang.org/download](https://ziglang.org/download/) (pin
0.16.0) and put it on your `PATH`.

## 3. Build + test

```sh
zig build         # builds zig-out/bin/tile57 + libtile57.a
zig build test    # runs the test suite
```

`zig build` produces:

| Target | What it is |
|--------|-----------|
| `tile57` (`zig-out/bin/tile57`) | the offline CLI: bake cells/ENC_ROOTs to PMTiles or a chart bundle, and emit portrayal assets. |
| `libtile57.a` | the static library behind the [C ABI](./c-api.md) (`include/tile57.h`). |

The engine is also a Zig package named `tile57` (v0.2.0); a Zig consumer
depends on it and uses `@import("tile57")` — see the [Zig API](./zig-api.md).

:::note Consume it as a path dependency (for now)
Depend on a local clone via a `.path` dependency in your `build.zig.zon`,
with the clone's submodules initialised:

```zig
.dependencies = .{
    .tile57 = .{ .path = "../tile57" },
},
```

**Known issue:** fetching by URL/hash (`zig fetch --save <url>`) does not work
yet — `build.zig.zon`'s `.paths` currently ships only `build.zig`,
`build.zig.zon`, and `src/`, so a fetched package is missing `vendor/` (the
embedded catalogue + Lua), `include/`, `tools/`, and the LICENSE, and cannot
build. Until that's fixed, use a path dependency.
:::

## Runtime knob

- `TILE57_S101_RULES=<dir>` — S-101 portrayal rules directory for raw S-57 cells.
  An **override**: the rules are embedded in the binary by default, so this is
  only needed to portray against a different on-disk catalogue (it applies when a
  caller passes `NULL`/`null` for the `rules_dir` argument). The CLI accepts the
  same override per-command via `--rules <dir>` (portrayal) and `--catalog <dir>`
  / a positional catalogue path (assets); an explicit path takes precedence over
  the embedded copy.

Next: [**Getting Started**](./getting-started.md) bakes a chart and fetches a
tile.
