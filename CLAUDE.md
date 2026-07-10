# tile57 — engine conventions

## The API style

The public surface (include/tile57.h, src/tile57.zig, bindings/go) follows one
style. Hold every new or renamed symbol against it.

**The pipeline is the organizing principle.** Everything is bake, then compose
(or bake, then render): source cells bake once to per-cell archives; every
output is produced from baked archives. Sections, in order: Version, Errors,
Bake, Render (the chart), Compose, Style, Util. The header, the Zig public
root, and the docs all follow that same section order.

**Handles are nouns; the chart is the namesake.** `tile57` is one open baked
archive (the sqlite3 pattern: the library's name is its central handle).
Further handles extend the prefix: `tile57_compose`. Handle lifecycle verbs
attach to the handle name: `tile57_open` / `tile57_open_bytes` /
`tile57_close`; `tile57_compose_open` / `tile57_compose_close`.

**Outputs are named by what you get, never by how it's produced or served.**
`tile`, `png`, `pdf`, `canvas`, `surface`, `query` — not serve/render/build/
generate. The chart and the compositor offer the SAME output set, so the names
mirror exactly: `tile57_png` ↔ `tile57_compose_png`, `tile57_tile` ↔
`tile57_compose_tile`, and so on. The compositor is "many charts in, one chart
out"; keep that symmetry when adding an output — it goes on both handles or
has a stated reason not to.

**Families are noun-first prefixes.** `tile57_style_build` / `_style_diff` /
`_style_template` (never `build_style`); `tile57_bake_*` for the import
pipeline; `tile57_enc_*` for the handle-free raw S-57 source readers. ENC is
the ONE vocabulary for raw source data (enc_root, tile57_enc_cells) — never
s57_/source_/scan_ variants of the same idea.

**The status model is universal.** Every call that can fail returns
`tile57_status` (never a bare int, count, or bool) and takes an optional
caller-owned `tile57_error*` as its LAST parameter. Out-parameters come after
inputs and are ALWAYS defined on return — the result on TILE57_OK, NULL/0
otherwise. "Nothing produced" is NOT a failure: OK with a NULL/zero out. Every
pointer argument is BADARG-checked (no NULL derefs across the ABI). Counts and
flags come back through optional out-pointers (NULL to ignore), not return
values. Say "call that can fail" in docs, not "fallible".

**Memory has one rule.** Calls that return bytes allocate `*out`; the caller
releases with `tile57_free(ptr)` — buffers are length-prefixed at allocation,
so the pointer is all it needs. POD across the seam: no Zig errors, slices, or
optionals cross the ABI.

**Ownership and borrowing are explicit.** The compositor BORROWS its charts
(charts outlive it; close the compositor first). A path-opened chart mmaps its
file (the file stays in place). No handle is internally synchronized; document
lifetime + threading on every handle-producing call.

**The Zig public root is curated, not a module mirror.** src/tile57.zig shapes
the public namespace by the API sections; when module layering puts an
implementation elsewhere (e.g. composed view renders live beside Chart because
the `compose` module is a dependency leaf without the render path), the root
still surfaces it under the name it belongs to (`tile57.compose.renderView`).
Public surface trumps internal layering.

**Go bindings track shape, not spelling.** Idiomatic Go names over the same
structure: `Open`/`OpenBytes` on the archive, package-level `Cells`/`Features`/
`FeaturesBytes`/`CatalogEntries` for the enc readers, `ComposeSource.Tile`
mirroring `tile57_compose_tile`, errors as wrapped sentinels
(`errors.Is(err, tile57.ErrParse)`).

## Other repo rules

- Never reference specs/*.md in code comments (specs/ is never committed);
  describe designs inline.
- Docs read standalone: present-tense capability statements, no prior-version
  framing ("now supports", "anymore"), no "plain language", no "fallible", no
  "seam" in user-facing docs.
- Never `git add -A` (vendor/ submodules; charts/ + test/ hold huge untracked
  local data). Stage explicit paths. Commit after every change.
- Never hardcode machine-specific paths in code or tests; real-cell paths come
  from args/env.
- Validate conversion/portrayal changes on real ENC_ROOT cells, not just unit
  tests.
