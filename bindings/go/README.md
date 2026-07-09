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

// Bake an ENC_ROOT: each cell becomes its own PMTiles under <out>/tiles/, plus
// an ownership partition at <out>/partition.tpart.
n, err := tile57.BakeTree("/enc/ENC_ROOT", "/out", 4, nil)

// Open the compositor over the baked archives + partition, and serve tiles.
src, _ := tile57.OpenCompose([]string{"/out/tiles/US5MD1MC.pmtiles"}, "/out/partition.tpart")
defer src.Close()
body, owned, _ := src.Serve(13, 2359, 3139) // owned=false, body=nil => open ocean

// Or open one cell/archive for metadata (cells, features, SCAMIN, bounds).
chart, _ := tile57.Open("/enc/ENC_ROOT")
defer chart.Close()
cells, _ := chart.Cells()
scamin := chart.Scamin() // []uint32, ascending
```

## Surface

- **Charts (metadata + query)** — `Open` (path, streaming), `OpenChartBytes` (one
  in-memory cell), `OpenPMTiles` (a baked archive); `Source.Info`, `Meta`, `Cells`,
  `Features`, `Scamin`, `Close`.
- **Bake** — `BakeCell` (one cell → PMTiles bytes), `BakeTree` (an ENC_ROOT → per-cell
  archives + `partition.tpart`), `BakeAssets` (portrayal assets in memory).
- **Compose** — `OpenCompose` (archives + partition); `ComposeSource.Serve` (a tile,
  with an ownership flag), `Meta`, `SavePartition`, `Close`.
- **Style** — `ColortablesDefault`, `Style`, `BuildStyle`, `StyleDiff`,
  `MarinerDefaults`, `CatalogEntries`.

`libtile57` is not internally synchronized; every `Source` method is mutex-guarded,
so a `Source` is safe for concurrent use.

## Tests

```sh
zig build && go test ./...
```

The tests are self-contained: they use the S-101 PortrayalCatalogue vendored at
`../../vendor/` and a small ENC cell in `testdata/`.
