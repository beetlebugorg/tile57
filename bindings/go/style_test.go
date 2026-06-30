//go:build cgo

package tile57

import (
	"encoding/json"
	"strings"
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

// TestIgnoreScamin verifies the ?ignoreScamin toggle disables SCAMIN scale-gating
// through the full C ABI: tile57_build_style carries no SCAMIN manifest, so the
// gated style uses the per-feature zoom-gate fallback ("log2"); IgnoreScamin drops
// it so every feature shows in-band.
func TestIgnoreScamin(t *testing.T) {
	build := func(ignore bool) string {
		m := MarinerDefaults()
		m.IgnoreScamin = ignore
		style, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "", "", m, nil)
		if err != nil {
			t.Fatalf("Style(ignore=%v): %v", ignore, err)
		}
		return string(style)
	}
	if g := build(false); !strings.Contains(g, "log2") {
		t.Fatalf("gated style should carry the SCAMIN zoom-gate (log2); not found")
	}
	if i := build(true); strings.Contains(i, "log2") {
		t.Fatalf("ignore_scamin style should drop the SCAMIN zoom-gate (log2); still present")
	}
}

// TestSizeScale verifies the physical-scale multiplier wraps the size expressions
// through the full C ABI: at the default 1.0 line-width is the verbatim coalesce
// expression; a non-1.0 scale wraps it (and icon/text sizes) in ["*", scale, expr].
func TestSizeScale(t *testing.T) {
	build := func(scale float64) string {
		m := MarinerDefaults()
		m.SizeScale = scale
		style, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
			"glyphs/{fontstack}/{range}.pbf", m, nil)
		if err != nil {
			t.Fatalf("Style(scale=%v): %v", scale, err)
		}
		return string(style)
	}
	if d := build(1.0); !strings.Contains(d, `"line-width":["coalesce",["get","width_px"],1]`) {
		t.Fatalf("default scale should emit the verbatim line-width expression")
	}
	s := build(2.0)
	for _, want := range []string{`"line-width":["*"`, `"icon-size":["*"`, `"text-size":["*"`} {
		if !strings.Contains(s, want) {
			t.Fatalf("scaled style missing wrapped size expression %q", want)
		}
	}
}
