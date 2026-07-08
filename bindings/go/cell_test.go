//go:build cgo

package tile57

import (
	"encoding/json"
	"os"
	"testing"
)

// A single-cell bake must embed the cell's own coverage in the PMTiles metadata, so
// the composite stitcher rebuilds the ownership partition without re-parsing the .000.
// Validates the full round-trip on a real NOAA cell: bake -> embed -> read -> decode.
func TestBakeCellEmbedsCoverage(t *testing.T) {
	if _, err := os.Stat(testCell); err != nil {
		t.Skipf("no test cell %s: %v", testCell, err)
	}

	pm, err := BakeCell(testCell, 0, 16)
	if err != nil {
		t.Fatalf("BakeCell: %v", err)
	}
	if len(pm) < 7 || string(pm[:7]) != "PMTiles" {
		t.Fatalf("not a PMTiles archive (got %d bytes)", len(pm))
	}

	meta, err := PMTilesMetadata(pm)
	if err != nil {
		t.Fatalf("PMTilesMetadata: %v", err)
	}
	if meta == nil {
		t.Fatal("archive carries no metadata")
	}

	var m struct {
		Coverage *struct {
			Name string         `json:"name"`
			Date string         `json:"date"`
			Cscl int32          `json:"cscl"`
			Band uint8          `json:"band"`
			Bbox [4]int32       `json:"bbox"`
			Cov1 [][][][2]int32 `json:"cov1"`
		} `json:"coverage"`
	}
	if err := json.Unmarshal(meta, &m); err != nil {
		t.Fatalf("unmarshal metadata: %v\n%s", err, meta)
	}
	if m.Coverage == nil {
		t.Fatal("no coverage embedded in the metadata")
	}
	c := m.Coverage
	if c.Name != "US5MD1MC" {
		t.Errorf("coverage name = %q, want US5MD1MC", c.Name)
	}
	if c.Cscl <= 0 {
		t.Errorf("coverage cscl = %d, want > 0", c.Cscl)
	}
	if len(c.Cov1) == 0 {
		t.Fatal("no M_COVR coverage rings")
	}
	// bbox must be a non-degenerate box in integer lon/lat.
	if !(c.Bbox[0] < c.Bbox[2] && c.Bbox[1] < c.Bbox[3]) {
		t.Errorf("degenerate bbox %v", c.Bbox)
	}
	nPts := 0
	for _, feat := range c.Cov1 {
		for _, ring := range feat {
			nPts += len(ring)
		}
	}
	if nPts < 3 {
		t.Errorf("coverage has %d points, want a real ring (>= 3)", nPts)
	}
	// Every vertex must sit within the reported bbox (integer coords, no f64 drift).
	for _, feat := range c.Cov1 {
		for _, ring := range feat {
			for _, p := range ring {
				if p[0] < c.Bbox[0] || p[0] > c.Bbox[2] || p[1] < c.Bbox[1] || p[1] > c.Bbox[3] {
					t.Fatalf("vertex %v outside bbox %v", p, c.Bbox)
				}
			}
		}
	}
	t.Logf("US5MD1MC: cscl=%d band=%d date=%q, %d M_COVR feature(s), %d pts, bbox=%v",
		c.Cscl, c.Band, c.Date, len(c.Cov1), nPts, c.Bbox)
}
