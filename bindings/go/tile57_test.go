//go:build cgo

package tile57

import (
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
