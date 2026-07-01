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

// CellInput.Name rides through to the `cell` pick-report property — and the
// omitPickAttrs flag drops it (and the rest of the pick attrs).
func TestCellInputName(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	const badge = "PICKCELLZZ" // distinctive token that can only come from the cell prop

	// badgePresent opens the cell (optionally omitting pick attrs) and reports
	// whether the cell badge appears in any tile across the cell's zoom range.
	badgePresent := func(pick PickAttrs) bool {
		src, err := OpenCells([]CellInput{{Base: data, Name: badge}}, "", pick)
		if err != nil {
			t.Fatalf("OpenCells(pick=%v): %v", pick, err)
		}
		defer src.Close()
		w, s, e, n, _ := src.Bounds()
		mn, mx := src.ZoomRange()
		for z := mn; z <= mx && z <= 14; z++ {
			tx, ty := lonLatToTile((w+e)/2, (s+n)/2, z)
			body, err := src.Tile(z, tx, ty)
			if err != nil {
				t.Fatalf("Tile %d/%d/%d: %v", z, tx, ty, err)
			}
			if bytes.Contains(body, []byte(badge)) {
				return true
			}
		}
		return false
	}

	if !badgePresent(PickInclude) {
		t.Fatal("cell badge absent with PickInclude — CellInput.Name not emitted as the `cell` prop")
	}
	if badgePresent(PickOmit) {
		t.Fatal("cell badge present with PickOmit — the opt-out did not drop pick attrs")
	}
}

func TestOpenCellAndTile(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	src, err := OpenCells([]CellInput{{Base: data}}, "", PickInclude)
	if err != nil {
		t.Fatalf("OpenCells: %v", err)
	}
	defer src.Close()

	mn, mx := src.ZoomRange()
	if mx < mn {
		t.Fatalf("bad zoom range %d..%d", mn, mx)
	}
	t.Logf("zoom %d..%d, bands=%#b, format=%d", mn, mx, src.Bands(), src.Format())

	w, s, e, n, ok := src.Bounds()
	if !ok {
		t.Fatal("expected known bounds for a single cell")
	}
	t.Logf("bounds W=%.4f S=%.4f E=%.4f N=%.4f", w, s, e, n)

	// Address the tile covering the cell's bounds centre at each zoom; assert at
	// least one non-empty MVT is produced across the cell's range.
	got := false
	for z := mn; z <= mx && z <= 14; z++ {
		tx, ty := lonLatToTile((w+e)/2, (s+n)/2, z)
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

	mn, mx := src.ZoomRange()
	w, s, e, n, ok := src.Bounds()
	if !ok {
		t.Fatal("expected known bounds for the streamed ENC_ROOT")
	}
	t.Logf("streamed: zoom %d..%d bounds W=%.4f S=%.4f E=%.4f N=%.4f", mn, mx, w, s, e, n)

	got := false
	for z := mn; z <= mx && z <= 14; z++ {
		tx, ty := lonLatToTile((w+e)/2, (s+n)/2, z)
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
