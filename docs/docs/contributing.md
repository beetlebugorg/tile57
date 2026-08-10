---
id: contributing
title: Contributing
slug: /contributing
sidebar_position: 11
---

# Contributing

tile57 is an **AI-first project**: it is built with AI assistance, and the most
valuable contribution is usually a clear description of what you want — a
requirement or a prototype — rather than finished code. That is not a barrier to
entry; it is the fastest path from an idea to a working feature here.

## AI-First Development

This project is built with AI assistance. We encourage contributors to use AI tools
for development and to contribute by providing clear requirements and/or a prototype
of what they'd like rather than code.

Why this works well for a chart engine:

- **The spec is the hard part, not the typing.** tile57 implements IHO S-101 / S-57
  decoding, the S-101 Portrayal Catalogue, and S-52 display. Most of the effort is
  interpreting the spec correctly — and a precise requirement (which rule, which
  object class, what the chart should look like) is exactly what turns into a correct
  implementation.
- **A prototype communicates faster than prose.** A screenshot of the wrong
  portrayal, a small ENC cell that reproduces a bug, or a rough sketch of the API you
  wish existed tells us more than a paragraph.
- **Humans review everything.** AI-assisted changes are reviewed for correctness and
  safety before they land — and this being a chart engine, **[not for
  navigation](./limitations.md)** is a standing constraint on every change.

## Ways to contribute

### 1. Report an issue

Open a [GitHub issue](https://github.com/beetlebugorg/tile57/issues). A good bug
report includes:

- **What you expected** — ideally with the relevant S-52 / S-101 rule or a reference
  image of the correct portrayal.
- **What happened instead** — a screenshot, the PNG/PDF/ASCII output, or the console
  output.
- **How to reproduce** — the smallest ENC cell (or a public NOAA/IHO cell name) and
  the exact command or call: e.g. `tile57 png <cell> --view <lon,lat,z> --size WxH`.
- **Environment** — OS, Zig version, native vs. WASM, and the tile57 version
  (`tile57_version()` / `tile57 --version`).

### 2. Request a feature (the preferred path)

The most useful contribution is a **clear requirement or a prototype** of what you'd
like. This is how new features are best started here — describe the outcome and let
the implementation follow. A strong request covers:

- **Problem & context** — what you're trying to do and why the engine can't do it yet.
- **Proposed behaviour** — what the output or API should be. Concrete beats abstract:
  a target image, the exact tiles/PNG you'd expect, or the function signature you want.
- **Spec references** — the S-101/S-52/S-57 sections or object classes involved, if
  you know them (we'll find them if you don't).
- **Examples** — input (a cell, a view) → expected output, including edge cases.
- **Done when** — how we'll both know it works: a rule that portrays without error, a
  reference render that matches, a cell that now decodes.

A rough prototype counts as a requirement: a script, a hand-edited style, a mock of
the API, or an image marked up with what's wrong — anything that pins down the intent.

### 3. Contribute code

Direct pull requests are welcome. Please:

- Keep the change focused and describe the intent (link the issue/requirement it
  addresses).
- Build and test locally — `zig build && zig build test` (see
  [Installation](./installation.md)).
- Expect review for correctness and safety, the same as AI-assisted changes.

## Cutting a release

The version lives in three files and has to agree with the tag — the release
build checks all three and stops if they diverge:

- `build.zig.zon` — `.version`
- `src/tile57.zig` — `pub const version`
- `tools/common.zig` — `pub const VERSION`

Bump them, commit, then tag and push:

```sh
git tag v0.4.0 && git push origin v0.4.0
```

`.github/workflows/release.yml` builds macOS, Linux and Windows on x86-64 and
arm64, attaches the archives, the `.deb`s and `SHA256SUMS` to a GitHub release,
and updates the Homebrew tap. A tag with a suffix — `v0.4.0-rc1` — publishes as
a prerelease and leaves the tap alone; use one to exercise the matrix before the
real tag. `scripts/package-release.sh <version> <target>` produces the same
archive locally after a `zig build`.

The tap lives in [beetlebugorg/homebrew-tap](https://github.com/beetlebugorg/homebrew-tap)
and its formula is generated, not hand-edited; the release workflow needs a
`HOMEBREW_TAP_TOKEN` secret with write access to it.

## The process

1. **Open** an issue or a requirement/prototype.
2. **Discuss** — we refine the requirement together on the issue.
3. **Implement** — often AI-assisted, always human-reviewed.
4. **Verify** — tests, and where portrayal is involved, a reference render.
5. **Document** — the relevant page under [Docs](./intro.md) is updated with the change.
