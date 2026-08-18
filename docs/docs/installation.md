---
id: installation
title: Installation
sidebar_position: 2
---

# Installation

Every [release](https://github.com/beetlebugorg/tile57/releases) ships pre-built
binaries for macOS, Linux and Windows on x86-64 and arm64. Each archive carries
the `tile57` CLI, the static library `libtile57.a`, and the C header
`include/tile57.h`. The IHO S-101 Portrayal Catalogue is embedded in both, so
nothing else has to be on disk at run time.

## Homebrew (macOS and Linux)

```sh
brew install beetlebugorg/tap/tile57
```

## Debian and Ubuntu

```sh
curl -LO https://github.com/beetlebugorg/tile57/releases/latest/download/tile57_0.3.0_amd64.deb
sudo apt install ./tile57_0.3.0_amd64.deb
```

`arm64` is published alongside `amd64`. There is no apt repository — the `.deb`
is a release asset, so upgrades mean downloading the next one.

## Direct download

Pick the archive for your platform from the
[latest release](https://github.com/beetlebugorg/tile57/releases/latest) —
`tile57-<version>-<target>.tar.gz`, or `.zip` for Windows — and put `bin/tile57`
on your `PATH`. `<target>` is the Zig target triple: `aarch64-macos`,
`x86_64-macos`, `aarch64-linux-gnu`, `x86_64-linux-gnu`, `aarch64-windows-gnu`,
or `x86_64-windows-gnu`.

```sh
tar xzf tile57-0.3.0-aarch64-macos.tar.gz
sudo install -m755 tile57-0.3.0-aarch64-macos/bin/tile57 /usr/local/bin/
tile57 version
```

Every release includes a `SHA256SUMS` file. Verify before installing:

```sh
curl -LO https://github.com/beetlebugorg/tile57/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

macOS binaries are not notarized. If Gatekeeper refuses to run one, clear the
quarantine flag on the extracted directory before installing:

```sh
xattr -dr com.apple.quarantine tile57-0.3.0-aarch64-macos
```

Homebrew does this for you.

## Build from source

Building needs **Zig 0.16.0** and nothing else — no CMake, no system libraries.
Install Zig from [ziglang.org/download](https://ziglang.org/download/) (pin
0.16.0) and put it on your `PATH`.

```sh
git clone https://github.com/beetlebugorg/tile57.git
cd tile57
git submodule update --init --recursive   # the vendored S-101 catalogue
zig build                                 # builds zig-out/bin/tile57 + libtile57.a
zig build test                            # runs the test suite
```

| Target | What it is |
|--------|-----------|
| `tile57` (`zig-out/bin/tile57`) | the offline CLI: bake charts/ENC_ROOTs to PMTiles or a chart bundle, and emit portrayal assets. |
| `libtile57.a` | the static library behind the [C ABI](./c-api.md) (`include/tile57.h`). |

The **IHO S-101 Portrayal Catalogue** comes in as a git submodule under `vendor/`.
It is a *build-time* dependency: `zig build` embeds the catalogue — the Lua
portrayal rules plus the symbols, line styles, area fills and colour profile —
directly into the binary via `@embedFile`. Lua 5.4 is vendored under `vendor/lua`
and compiled in, so no system Lua is needed either.

## As a Zig package

The engine is a Zig package named `tile57` (v0.3.0). Fetch it by tag:

```sh
zig fetch --save "https://github.com/beetlebugorg/tile57/archive/refs/tags/v0.3.0.tar.gz"
```

```zig
const tile57 = b.dependency("tile57", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("tile57", tile57.module("tile57"));
```

A fetched package carries its own copy of the portrayal catalogue (Zig's fetcher
does not follow git submodules, so the catalogue arrives as a lazy package
dependency instead) — no submodule init needed. See the
[Zig API](./zig-api.md) for what the module exposes.

## Runtime knob

- `TILE57_S101_RULES=<dir>` — S-101 portrayal rules directory for raw S-57 charts.
  An **override**: the rules are embedded in the binary by default, so this is
  only needed to portray against a different on-disk catalogue (it applies when a
  caller passes `NULL`/`null` for the `rules_dir` argument). The CLI accepts the
  same override per-command via `--rules <dir>` (portrayal) and `--catalog <dir>`
  / a positional catalogue path (assets); an explicit path takes precedence over
  the embedded copy.

Next: [**Getting Started**](./getting-started.md) bakes a chart and fetches a
tile.
