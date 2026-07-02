# tile57 — Go binding

The canonical Go (cgo) binding to **libtile57**, the native Zig chart engine in this
repo. It lives next to the engine (`bindings/go`, alongside `bindings/wasm`) so it
tracks the C ABI in [`include/tile57.h`](../../include/tile57.h) as that ABI evolves —
a host imports it and works in **Go only**, never touching cgo, the header, or the
Zig build.

## Requirements

- `CGO_ENABLED=1` and a C toolchain.
- The static library built once from the repo root:

  ```sh
  zig build            # produces zig-out/lib/libtile57.a
  ```

  The cgo directives in `tile57.go` link `../../zig-out/lib/libtile57.a` and include
  `../../include` relative to this package, so the library must exist before you
  `go build`/`go test` here.

## Use it from another module

Because the cgo paths are relative to this package's source, an importing module
points at a **local checkout** with a `replace` directive (cgo can't link a path
inside the module cache):

```go
// go.mod
require github.com/beetlebugorg/tile57/bindings/go v0.0.0
replace github.com/beetlebugorg/tile57/bindings/go => /path/to/chartplotter-native/bindings/go
```

```go
import tile57 "github.com/beetlebugorg/tile57/bindings/go"

// Bake a single cell.000 or a whole ENC_ROOT dir into a self-contained bundle.
cells, bbox, err := tile57.BakeBundle("/enc/ENC_ROOT", "/out/bundle", "", "", "", 0, 16, nil)

// Or serve tiles live, and publish the SCAMIN manifest for the style.
src, _ := tile57.Open("/enc/ENC_ROOT")
defer src.Close()
mvt, _ := src.Tile(13, 2359, 3139)
manifest := src.Scamin() // []uint32, ascending
```

## Surface

- **Charts** — `Open` (path, streaming), `OpenChartBytes` (one in-memory cell),
  `OpenPMTiles` (baked bundle); `Source.Tile`, `Info`, `Meta`, `Scamin`,
  `ClearCache`, `Close`.
- **Bake** — `BakeCells` (→ one PMTiles archive in memory), `BakeBundle` (→ a full
  on-disk bundle: tiles + assets + per-scheme styles + manifest).
- **Assets / style** — `ColortablesDefault`, `Colortables`, `Linestyles`,
  `SpriteAtlas`, `PatternAtlas`, `StyleTemplate`, `BuildStyle`, `Style`,
  `MarinerDefaults`.

`libtile57` is not internally synchronized; every `Source` method is mutex-guarded,
so a `Source` is safe for concurrent use.

## Tests

```sh
zig build && go test ./...
```

The tests are self-contained: they use the S-101 PortrayalCatalogue vendored at
`../../vendor/` and a small ENC cell in `testdata/`.
