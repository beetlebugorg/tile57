//go:build cgo

package tile57

import (
	"bytes"
	"math"
	"os"
	"testing"
)

// testCell is a small S-57 base cell shipped in the repo's testdata.
const testCell = "testdata/US5MD1MC.000"

func TestVersion(t *testing.T) {
	if v := Version(); v == "" {
		t.Fatal("empty version")
	}
}

func TestColortablesDefault(t *testing.T) {
	b, err := ColortablesDefault()
	if err != nil {
		t.Fatal(err)
	}
	if len(b) == 0 || b[0] != '{' {
		t.Fatalf("colortables not JSON object: %d bytes", len(b))
	}
}

// Pick-report attributes (class / s57 / cell, S-52 §10.8) ride on BAKED tiles by default
// (pick_attrs on). Cell-backed charts are metadata-only — bake first, serve the archive —
// so bake the fixture to PMTiles and scan its tiles for the pick-report keys.
func TestPickAttrs(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	pm, err := BakePmtiles([]Cell{{Base: data}}, BakeOpts{MaxZoom: 24}, nil)
	if err != nil {
		t.Fatalf("BakePmtiles: %v", err)
	}
	tmp := t.TempDir() + "/chart.pmtiles"
	if err := os.WriteFile(tmp, pm, 0o644); err != nil {
		t.Fatal(err)
	}
	src, err := OpenPMTiles(tmp)
	if err != nil {
		t.Fatalf("OpenPMTiles: %v", err)
	}
	defer src.Close()

	// Scan the tile grid covering the chart bounds until a tile carries the pick-report
	// property keys (present on every feature when pick attrs are on).
	info := src.Info()
	for z := info.MinZoom; z <= info.MaxZoom && z <= 16; z++ {
		x0, y0 := lonLatToTile(info.West, info.North, z)
		x1, y1 := lonLatToTile(info.East, info.South, z)
		for x := x0; x <= x1; x++ {
			for y := y0; y <= y1; y++ {
				body, err := src.Tile(z, x, y)
				if err != nil {
					t.Fatalf("Tile %d/%d/%d: %v", z, x, y, err)
				}
				if bytes.Contains(body, []byte("class")) && bytes.Contains(body, []byte("s57")) {
					return // pick-report attributes present — done
				}
			}
		}
	}
	t.Fatal("baked tiles carry no pick-report attributes (class/s57) — expected them by default")
}

// A cell-backed chart (OpenChartBytes) is METADATA-ONLY: it exposes bounds/scale for a
// header scan but never generates tiles on demand — the chart-api contract is "bake first,
// serve the archive". Assert the metadata is present and that Tile() is refused.
func TestOpenCellMetadata(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	src, err := OpenChartBytes(data)
	if err != nil {
		t.Fatalf("OpenChartBytes: %v", err)
	}
	defer src.Close()

	info := src.Info()
	if info.MaxZoom < info.MinZoom || !info.HasBounds {
		t.Fatalf("cell metadata looks unset: %+v", info)
	}
	t.Logf("zoom %d..%d, bounds W=%.4f S=%.4f E=%.4f N=%.4f",
		info.MinZoom, info.MaxZoom, info.West, info.South, info.East, info.North)

	// Cell-backed tiles are refused by design — bake first (BakeCell / BakePmtiles).
	if _, err := src.Tile(info.MinZoom, 0, 0); err == nil {
		t.Fatal("cell-backed Tile() should be refused (metadata-only; bake first)")
	}
}

// TestOpenPath opens a directory as a STREAMING chart (the engine enumerates cell
// metadata + reads the .000 on demand). Like a cell-backed chart it is metadata-only:
// bounds/zoom are known, but tiles come from a bake, not on-demand generation.
func TestOpenPath(t *testing.T) {
	if _, err := os.Stat(testCell); err != nil {
		t.Skipf("no test cell: %v", err)
	}
	src, err := Open("testdata")
	if err != nil {
		t.Fatalf("Open(testdata): %v", err)
	}
	defer src.Close()

	info := src.Info()
	if !info.HasBounds {
		t.Fatal("expected known bounds for the streamed ENC_ROOT")
	}
	t.Logf("streamed: zoom %d..%d bounds W=%.4f S=%.4f E=%.4f N=%.4f",
		info.MinZoom, info.MaxZoom, info.West, info.South, info.East, info.North)

	// Streaming cell-backed tiles are refused by design — bake first.
	if _, err := src.Tile(info.MinZoom, 0, 0); err == nil {
		t.Fatal("streaming cell-backed Tile() should be refused (metadata-only; bake first)")
	}
}

// TestOpenPMTilesAndInfo bakes the fixture to a PMTiles file, opens it via the path,
// and exercises the chart_get_info getter. Also covers OpenChartBytes.
func TestOpenPMTilesAndInfo(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	// OpenChartBytes (resident single cell) + Info.
	rc, err := OpenChartBytes(data)
	if err != nil {
		t.Fatalf("OpenChartBytes: %v", err)
	}
	if info := rc.Info(); !info.HasBounds || info.MaxZoom < info.MinZoom {
		t.Fatalf("resident chart info looks unset: %+v", info)
	}
	rc.Close()

	// Bake to a PMTiles file, then open it by path.
	pm, err := BakePmtiles([]Cell{{Base: data}}, BakeOpts{MaxZoom: 24}, nil)
	if err != nil {
		t.Fatalf("BakePmtiles: %v", err)
	}
	tmp := t.TempDir() + "/chart.pmtiles"
	if err := os.WriteFile(tmp, pm, 0o644); err != nil {
		t.Fatal(err)
	}
	src, err := OpenPMTiles(tmp)
	if err != nil {
		t.Fatalf("OpenPMTiles: %v", err)
	}
	defer src.Close()

	info := src.Info()
	if info.MaxZoom < info.MinZoom || !info.HasBounds {
		t.Fatalf("pmtiles chart info looks unset: %+v", info)
	}
	t.Logf("pmtiles: zoom %d..%d bounds W=%.4f E=%.4f anchor=%v", info.MinZoom, info.MaxZoom, info.West, info.East, info.HasAnchor)
	tx, ty := lonLatToTile((info.West+info.East)/2, (info.South+info.North)/2, info.MaxZoom)
	if _, err := src.Tile(info.MaxZoom, tx, ty); err != nil {
		t.Fatalf("Tile: %v", err)
	}
}

// lonLatToTile maps a lon/lat to its XYZ web-Mercator tile at zoom z.
func lonLatToTile(lon, lat float64, z uint8) (x, y uint32) {
	n := math.Exp2(float64(z))
	x = uint32((lon + 180.0) / 360.0 * n)
	latRad := lat * math.Pi / 180.0
	y = uint32((1.0 - math.Asinh(math.Tan(latRad))/math.Pi) / 2.0 * n)
	if max := uint32(n) - 1; x > max {
		x = max
	}
	if max := uint32(n) - 1; y > max {
		y = max
	}
	return x, y
}
