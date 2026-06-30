//go:build cgo

package tile57

import (
	"encoding/json"
	"testing"
)

func TestStyle(t *testing.T) {
	m := MarinerDefaults()
	if m.SafetyContour <= 0 {
		t.Fatalf("mariner defaults look unset: %+v", m)
	}
	style, err := Style(SchemeDay,
		"http://localhost:8080/tiles/tile57/{z}/{x}/{y}.mvt",
		"http://localhost:8080/sprite",
		"http://localhost:8080/glyphs/{fontstack}/{range}.pbf",
		m, nil)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Version int              `json:"version"`
		Sources map[string]any   `json:"sources"`
		Layers  []map[string]any `json:"layers"`
	}
	if err := json.Unmarshal(style, &doc); err != nil {
		t.Fatalf("style not valid JSON: %v", err)
	}
	if doc.Version == 0 || len(doc.Sources) == 0 || len(doc.Layers) == 0 {
		t.Fatalf("style missing version/sources/layers: version=%d sources=%d layers=%d",
			doc.Version, len(doc.Sources), len(doc.Layers))
	}
	t.Logf("style: %d bytes, version %d, %d sources, %d layers",
		len(style), doc.Version, len(doc.Sources), len(doc.Layers))
}
