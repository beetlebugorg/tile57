//go:build cgo

package tile57

import (
	"encoding/json"
	"strconv"
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
		0, 0, FormatMVT, m, nil, nil, 0)
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
	t.Skip("asserts the retired per-value SCAMIN model (log2 per-feature gate): dropped in " +
		"f9887c9 for the merged band-independent gate. Update to the merged/filter-gate model " +
		"(specs/scamin-layers.md, host-side pending).")
	build := func(ignore bool) string {
		m := MarinerDefaults()
		m.IgnoreScamin = ignore
		style, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "", "", 0, 0, FormatMVT, m, nil, nil, 0)
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

// TestViewingGroupsOff verifies the S-52 §14.5 fine-grained viewing-group deny-list
// reaches the style through the full C ABI: a non-empty off-set adds a vg deny-list
// filter referencing the off ids; nil/empty -> no vg filter at all.
func TestViewingGroupsOff(t *testing.T) {
	build := func(off []int32) string {
		m := MarinerDefaults()
		m.ViewingGroupsOff = off
		style, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
			"glyphs/{fontstack}/{range}.pbf", 0, 0, FormatMVT, m, nil, nil, 0)
		if err != nil {
			t.Fatalf("Style(off=%v): %v", off, err)
		}
		return string(style)
	}
	// nil off-set -> no vg filter.
	if g := build(nil); strings.Contains(g, `"vg"`) {
		t.Fatalf("nil off-set should produce no vg filter; found \"vg\"")
	}
	// empty off-set -> also no vg filter (show all).
	if g := build([]int32{}); strings.Contains(g, `"vg"`) {
		t.Fatalf("empty off-set should produce no vg filter; found \"vg\"")
	}
	// A non-empty off-set -> a vg deny-list filter referencing the off id.
	if on := build([]int32{27070}); !strings.Contains(on, `"vg"`) || !strings.Contains(on, "27070") {
		t.Fatalf("off-set {27070} should add a vg deny-list filter referencing 27070; got none")
	}
}

// TestScaminBuckets verifies the runtime build_style emits native per-value SCAMIN
// bucket layers when given a manifest (host host-canonical-backend.md §"Still needed"
// #1) — the same gating the offline bundle does. Without a manifest the _scamin
// layers fall back to the per-feature zoom-gate (log2); with one they become
// fractional-minzoom bucket layers (one per denominator, no log2 fallback).
func TestScaminBuckets(t *testing.T) {
	t.Skip("asserts the retired per-value SCAMIN #sm bucket layers: dropped in f9887c9 for " +
		"the merged band-independent gate (buckets no longer emitted). Update to the merged/" +
		"filter-gate model (specs/scamin-layers.md, host-side pending).")
	m := MarinerDefaults()
	scamin := []int32{89999, 119999, 259999}
	withManifest, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
		"glyphs/{fontstack}/{range}.pbf", 0, 0, FormatMVT, m, nil, scamin, 38.0)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Layers []map[string]any `json:"layers"`
	}
	if err := json.Unmarshal(withManifest, &doc); err != nil {
		t.Fatalf("style not valid JSON: %v", err)
	}
	// Each manifest value should produce a bucket layer with a numeric minzoom.
	for _, v := range scamin {
		tag := "#sm" + itoa(v)
		found := false
		for _, L := range doc.Layers {
			id, _ := L["id"].(string)
			if strings.Contains(id, tag) {
				found = true
				if _, ok := L["minzoom"].(float64); !ok {
					t.Fatalf("bucket layer %s has no numeric minzoom: %v", id, L["minzoom"])
				}
			}
		}
		if !found {
			t.Fatalf("no per-value bucket layer for SCAMIN %d (expected id containing %q)", v, tag)
		}
	}
	// With native buckets the per-feature zoom-gate fallback must be gone.
	if strings.Contains(string(withManifest), "log2") {
		t.Fatalf("manifest style should use native minzoom buckets, not the log2 zoom-gate")
	}
}

func itoa(v int32) string {
	return strconv.Itoa(int(v))
}

// TestStyleEncodingHint verifies the MLT source-encoding hint through the full C
// ABI: FormatMLT emits `"encoding":"mlt"` on the chart source (and the hint
// survives BuildStyle's template rebuild); FormatMVT/FormatDefault emit nothing.
func TestStyleEncodingHint(t *testing.T) {
	chartSource := func(b []byte) map[string]any {
		var doc struct {
			Sources map[string]map[string]any `json:"sources"`
		}
		if err := json.Unmarshal(b, &doc); err != nil {
			t.Fatalf("style not valid JSON: %v", err)
		}
		return doc.Sources["chart"]
	}
	build := func(enc TileFormat) []byte {
		tmpl, err := StyleTemplate(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
			"glyphs/{fontstack}/{range}.pbf", 0, 0, enc)
		if err != nil {
			t.Fatalf("StyleTemplate(enc=%v): %v", enc, err)
		}
		if got := chartSource(tmpl)["encoding"]; enc == FormatMLT && got != "mlt" {
			t.Fatalf("template chart source encoding = %v; want mlt", got)
		}
		ct, _ := ColortablesDefault()
		s, err := BuildStyle(tmpl, MarinerDefaults(), ct, nil, nil, 0)
		if err != nil {
			t.Fatalf("BuildStyle(enc=%v): %v", enc, err)
		}
		return s
	}
	if got := chartSource(build(FormatMLT))["encoding"]; got != "mlt" {
		t.Fatalf("built style chart source encoding = %v; want mlt (hint must survive the rebuild)", got)
	}
	for _, enc := range []TileFormat{FormatMVT, FormatDefault} {
		if got, ok := chartSource(build(enc))["encoding"]; ok {
			t.Fatalf("encoding hint for %v should be absent; got %v", enc, got)
		}
	}
}

// TestScaminFilterGate verifies the scamin-layers.md flag through the full C ABI:
// with a manifest, ScaminFilterGate collapses the per-value #sm bucket layers to one
// live-filtered layer per render-type — far fewer layers, no #sm, no native minzoom.
func TestScaminFilterGate(t *testing.T) {
	t.Skip("asserts the non-gated path emits per-value #sm bucket layers, but buckets were " +
		"dropped in f9887c9 (merged band-independent gate is the only mode). Rewrite against " +
		"the merged gate vs filter-gate output (specs/scamin-layers.md, host-side pending).")
	ct, _ := ColortablesDefault()
	tmpl, err := StyleTemplate(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
		"glyphs/{fontstack}/{range}.pbf", 0, 0, FormatMVT)
	if err != nil {
		t.Fatal(err)
	}
	scamin := []int32{4000, 12000, 30000, 90000, 180000} // 5 denominators
	layers := func(b []byte) int {
		var d struct {
			Layers []map[string]any `json:"layers"`
		}
		if err := json.Unmarshal(b, &d); err != nil {
			t.Fatalf("style not valid JSON: %v", err)
		}
		return len(d.Layers)
	}
	build := func(gate bool) []byte {
		m := MarinerDefaults()
		m.ScaminFilterGate = gate
		s, err := BuildStyle(tmpl, m, ct, nil, scamin, 38.0)
		if err != nil {
			t.Fatalf("BuildStyle(gate=%v): %v", gate, err)
		}
		return s
	}
	buck, gate := build(false), build(true)
	if !strings.Contains(string(buck), "#sm") {
		t.Fatal("bucketed style should carry per-value #sm bucket layers")
	}
	if strings.Contains(string(gate), "#sm") {
		t.Fatal("filter-gate style should have no #sm bucket layers")
	}
	if !strings.Contains(string(gate), "1000000000000") {
		t.Fatal("filter-gate style should carry the SCAMIN coalesce-max clause")
	}
	if lb, lg := layers(buck), layers(gate); lg >= lb {
		t.Fatalf("filter-gate should have far fewer layers: bucketed=%d gate=%d", lb, lg)
	}
}

// TestStyleDiff verifies the flicker-free mariner-toggle op array through the full
// C ABI (style-diff.md §5): no change -> "[]"; a display-category flip yields only
// setFilter ops; a day->night scheme change yields setPaintProperty colour ops and
// no filter change.
func TestStyleDiff(t *testing.T) {
	ct, err := ColortablesDefault()
	if err != nil {
		t.Fatal(err)
	}
	tmpl, err := StyleTemplate(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
		"glyphs/{fontstack}/{range}.pbf", 0, 0, FormatMVT)
	if err != nil {
		t.Fatal(err)
	}
	diff := func(from, to Mariner) string {
		ops, err := StyleDiff(tmpl, from, to, ct, nil, nil, 0)
		if err != nil {
			t.Fatalf("StyleDiff: %v", err)
		}
		var arr []map[string]any // the ops must be a valid JSON array
		if err := json.Unmarshal(ops, &arr); err != nil {
			t.Fatalf("diff ops not a JSON array: %v (%s)", err, ops)
		}
		return string(ops)
	}
	base := MarinerDefaults()

	// No change -> empty op array.
	if got := diff(base, base); got != "[]" {
		t.Fatalf("diff(default,default) = %s; want []", got)
	}

	// display_other re-gates only category filters -> setFilter ops, no paint/layout.
	other := base
	other.DisplayOther = true
	if got := diff(base, other); !strings.Contains(got, `"setFilter"`) ||
		strings.Contains(got, `"setPaintProperty"`) || strings.Contains(got, `"setLayoutProperty"`) {
		t.Fatalf("diff(default,display_other) should be setFilter-only; got %s", got)
	}

	// day -> night recolours -> setPaintProperty ops, no filter change.
	night := base
	night.Scheme = SchemeNight
	if got := diff(base, night); !strings.Contains(got, `"setPaintProperty"`) ||
		strings.Contains(got, `"setFilter"`) {
		t.Fatalf("diff(day,night) should be setPaintProperty-only; got %s", got)
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
			"glyphs/{fontstack}/{range}.pbf", 0, 0, FormatMVT, m, nil, nil, 0)
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
