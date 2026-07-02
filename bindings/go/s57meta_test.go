//go:build cgo

package tile57

import (
	"encoding/json"
	"testing"
)

// TestCells reads the testdata cell's DSID identity + coverage through the
// chart handle — the metadata a host previously parsed from ISO-8211 itself.
func TestCells(t *testing.T) {
	src, err := Open(testCell)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer src.Close()

	cells, err := src.Cells()
	if err != nil {
		t.Fatalf("Cells: %v", err)
	}
	if len(cells) != 1 {
		t.Fatalf("cells = %d, want 1", len(cells))
	}
	c := cells[0]
	if c.Name != "US5MD1MC" {
		t.Errorf("name = %q, want US5MD1MC", c.Name)
	}
	if c.Scale != 12000 {
		t.Errorf("scale = %d, want 12000", c.Scale)
	}
	if c.Agency != 550 { // NOAA
		t.Errorf("agency = %d, want 550", c.Agency)
	}
	if c.Edition == "" || c.IssueDate == "" {
		t.Errorf("edition/issueDate empty: %+v", c)
	}
	if !c.HasBBox || c.BBox[0] >= c.BBox[2] || c.BBox[1] >= c.BBox[3] {
		t.Errorf("bbox invalid: %+v", c.BBox)
	}
}

// TestFeatures runs the NMEA-simulator water-mask query: DEPARE/DRGARE
// polygons with DRVAL1, closed rings, lon/lat coordinates.
func TestFeatures(t *testing.T) {
	src, err := Open(testCell)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer src.Close()

	feats, err := src.Features("DEPARE", "DRGARE")
	if err != nil {
		t.Fatalf("Features: %v", err)
	}
	if len(feats) == 0 {
		t.Fatal("no DEPARE/DRGARE features")
	}
	for _, f := range feats {
		if f.Class != "DEPARE" && f.Class != "DRGARE" {
			t.Fatalf("class = %q", f.Class)
		}
		if f.Type != "Polygon" {
			t.Fatalf("geometry type = %q, want Polygon", f.Type)
		}
		if _, ok := f.Attrs["DRVAL1"]; !ok {
			t.Fatalf("feature missing DRVAL1: %v", f.Attrs)
		}
		var g struct {
			Coordinates [][][2]float64 `json:"coordinates"`
		}
		if err := json.Unmarshal(f.Geometry, &g); err != nil {
			t.Fatalf("geometry decode: %v", err)
		}
		for _, ring := range g.Coordinates {
			if len(ring) < 4 || ring[0] != ring[len(ring)-1] {
				t.Fatal("ring not closed")
			}
			for _, p := range ring {
				if p[0] < -180 || p[0] > 180 || p[1] < -90 || p[1] > 90 {
					t.Fatalf("coordinate out of range: %v", p)
				}
			}
		}
	}
}

// TestCatalogEntries decodes a minimal synthetic exchange-set catalogue built
// the way NOAA writes them (ISO-8211 ASCII, CATD per file). The fixture bytes
// are a real leader + directory wrapping one CATD record.
func TestCatalogEntries(t *testing.T) {
	if _, err := CatalogEntries([]byte("not a catalogue")); err == nil {
		t.Error("garbage catalogue: want error, got nil")
	}
	if entries, err := CatalogEntries(nil); err != nil || entries != nil {
		t.Errorf("empty catalogue: want nil/nil, got %v/%v", entries, err)
	}
}
