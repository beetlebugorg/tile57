//go:build cgo

package tile57

import (
	"math"
	"os"
	"path/filepath"
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

// bakeTestCell bakes the testdata cell for tests that need an archive.
func bakeTestCell(t *testing.T) []byte {
	t.Helper()
	if _, err := os.Stat(testCell); err != nil {
		t.Skipf("no test cell: %v", err)
	}
	pm, err := BakeCell(testCell)
	if err != nil {
		t.Fatalf("BakeCell: %v", err)
	}
	return pm
}

// A chart is ONE baked archive: opened from bytes it must report the zoom range,
// bounds, tile encoding, the compilation scale the bake embedded, and the real
// M_COVR coverage rings — everything a host chart-database needs with no .000.
func TestOpenBytesInfoCoverage(t *testing.T) {
	src, err := OpenBytes(bakeTestCell(t))
	if err != nil {
		t.Fatalf("OpenBytes: %v", err)
	}
	defer src.Close()

	info := src.Info()
	if info.MaxZoom < info.MinZoom || !info.HasBounds {
		t.Fatalf("chart info looks unset: %+v", info)
	}
	if info.NativeScale != 12000 {
		t.Fatalf("NativeScale = %d, want 12000 (embedded by the bake)", info.NativeScale)
	}
	if info.TileType != FormatMLT {
		t.Fatalf("TileType = %v, want FormatMLT", info.TileType)
	}
	cov, err := src.Coverage()
	if err != nil {
		t.Fatalf("Coverage: %v", err)
	}
	if len(cov) == 0 || len(cov[0]) < 3 {
		t.Fatalf("expected real M_COVR coverage rings, got %d", len(cov))
	}
	for _, ring := range cov {
		for _, p := range ring {
			if p[0] < info.West-1e-6 || p[0] > info.East+1e-6 || p[1] < info.South-1e-6 || p[1] > info.North+1e-6 {
				t.Fatalf("coverage vertex %v outside bounds", p)
			}
		}
	}
	t.Logf("zoom %d..%d, scale 1:%d, %d coverage ring(s), bounds W=%.4f S=%.4f E=%.4f N=%.4f",
		info.MinZoom, info.MaxZoom, info.NativeScale, len(cov),
		info.West, info.South, info.East, info.North)
}

// Open (path) mmaps the archive and must agree with the bytes-open on metadata.
func TestOpenPath(t *testing.T) {
	pm := bakeTestCell(t)
	path := filepath.Join(t.TempDir(), "US5MD1MC.pmtiles")
	if err := os.WriteFile(path, pm, 0o644); err != nil {
		t.Fatal(err)
	}
	src, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer src.Close()
	info := src.Info()
	if !info.HasBounds || info.NativeScale != 12000 {
		t.Fatalf("mmap'd chart info looks unset: %+v", info)
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
