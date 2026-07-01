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

// A resident chart (OpenChartBytes) portrays live, so its generated tiles carry the
// S-52 §10.8 pick-report attributes (class / cell / s57) on every feature by default.
// The per-cell Name badge and the PickOmit opt-out were parameters of the dropped
// multi-cell open (chart-api.md); the surviving live-open surface always includes the
// pick report.
func TestPickAttrs(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	src, err := OpenChartBytes(data)
	if err != nil {
		t.Fatalf("OpenChartBytes: %v", err)
	}
	defer src.Close()

	// Scan the tile grid covering the chart bounds until a tile carries the pick-report
	// property keys (present on every feature when pick attrs are on).
	info := src.Info()
	for z := info.MinZoom; z <= info.MaxZoom && z <= 14; z++ {
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
	t.Fatal("resident chart tiles carry no pick-report attributes (class/s57) — expected them by default")
}

func TestOpenCellAndTile(t *testing.T) {
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
	if info.MaxZoom < info.MinZoom {
		t.Fatalf("bad zoom range %d..%d", info.MinZoom, info.MaxZoom)
	}
	if !info.HasBounds {
		t.Fatal("expected known bounds for a single cell")
	}
	t.Logf("zoom %d..%d, bands=%#b, bounds W=%.4f S=%.4f E=%.4f N=%.4f",
		info.MinZoom, info.MaxZoom, info.Bands, info.West, info.South, info.East, info.North)

	// Address the tile covering the cell's bounds centre at each zoom; assert at
	// least one non-empty MVT is produced across the cell's range.
	got := false
	for z := info.MinZoom; z <= info.MaxZoom && z <= 14; z++ {
		tx, ty := lonLatToTile((info.West+info.East)/2, (info.South+info.North)/2, z)
		body, err := src.Tile(z, tx, ty)
		if err != nil {
			t.Fatalf("Tile %d/%d/%d: %v", z, tx, ty, err)
		}
		if len(body) > 0 {
			got = true
			t.Logf("tile %d/%d/%d -> %d bytes MVT", z, tx, ty, len(body))
		}
	}
	if !got {
		t.Fatal("no non-empty tile produced across the cell's zoom range")
	}
}

// TestOpenPath opens the testdata directory as a STREAMING chart (engine enumerates
// + reads the .000 on demand) and asserts it tiles like the byte-opened cell.
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

	got := false
	for z := info.MinZoom; z <= info.MaxZoom && z <= 14; z++ {
		tx, ty := lonLatToTile((info.West+info.East)/2, (info.South+info.North)/2, z)
		body, err := src.Tile(z, tx, ty)
		if err != nil {
			t.Fatalf("Tile %d/%d/%d: %v", z, tx, ty, err)
		}
		if len(body) > 0 {
			got = true
		}
	}
	if !got {
		t.Fatal("no non-empty tile from the streamed chart")
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
	pm, err := BakeCells([]CellInput{{Base: data}}, "", 0, 24, PickInclude, nil)
	if err != nil {
		t.Fatalf("BakeCells: %v", err)
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
