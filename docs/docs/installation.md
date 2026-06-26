---
id: installation
title: Installation
sidebar_position: 2
---

# Installation

chartplotter-native builds from source. CMake is the top-level integrator: it
builds the vendored MapLibre Native and drives `zig build` for the tile
generator. There are no pre-built binaries.

## 1. Clone + fetch the submodules

```sh
git clone https://github.com/beetlebugorg/chartplotter-native.git
cd chartplotter-native
git submodule update --init --recursive
```

The submodules are large: **MapLibre Native** (~1.6 GB into
`vendor/maplibre-native/`) and the official **IHO S-101 catalogue** (Portrayal +
Feature catalogues under `vendor/`; the FC repo is ~350 MB).

## 2. Toolchain

### macOS (Apple Silicon or Intel)

```sh
xcode-select --install            # Clang + Metal
brew install cmake ninja libuv    # libuv backs the darwin run loop
pip3 install Pillow               # for the sprite builder
```

Metal works out of the box.

### Linux (Arch shown; adapt for your distro)

```sh
sudo pacman -S --needed cmake ninja clang python-pillow \
  glfw wayland libxkbcommon libepoxy   # glfw + wayland only for the window
sudo pacman -S --needed ccache         # optional, for fast rebuilds
```

### Zig 0.16.0 (required)

The tile generator and all three of our targets need **Zig 0.16.0**. Install it
from [ziglang.org/download](https://ziglang.org/download/) (pin 0.16.0) and put
it on your `PATH`; CMake finds it automatically (it also checks `~/.local/bin`
and `~/.local/share/zig-0.16.0`).

:::note Lua is vendored
Lua 5.4 is vendored under `engine/vendor/lua` and compiled into
`libchartplotter.a` — no system Lua is needed.
:::

:::tip First build is slow
The first `mbgl-core` build is large (~15 min on 8 cores). `ccache` (picked up
automatically when present) makes subsequent rebuilds fast.
:::

## 3. Reference data + styles

Our hosts render tiles + assets produced by the Go reference impl, plus generated
styles. `gen-reference.sh` picks the right prebuilt Go binary for your OS/arch
(`../chartplotter-go/dist/chartplotter_<os>_<arch>_s101`), emits assets, bakes
`annapolis.pmtiles`, and generates the full-S-52 styles:

```sh
scripts/gen-reference.sh    # assets + tiles + styles
scripts/gen-style.sh        # just the styles, if reference data already exists
```

Reference data and the generated styles are gitignored (they are machine-specific
— the styles embed an absolute PMTiles path). Regenerate them after cloning.
After a `git pull`, `scripts/dev-rebuild.sh` regenerates the styles and rebuilds
our targets in whichever build dir exists.

Next: [**Getting Started**](./getting-started.md) builds and runs the hosts.
