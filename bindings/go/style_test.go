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
		0, 0, m, nil, nil, 0)
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
		style, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "", "", 0, 0, m, nil, nil, 0)
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
			"glyphs/{fontstack}/{range}.pbf", 0, 0, m, nil, nil, 0)
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
	m := MarinerDefaults()
	scamin := []int32{89999, 119999, 259999}
	withManifest, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
		"glyphs/{fontstack}/{range}.pbf", 0, 0, m, nil, scamin, 38.0)
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

// TestSizeScale verifies the physical-scale multiplier wraps the size expressions
// through the full C ABI: at the default 1.0 line-width is the verbatim coalesce
// expression; a non-1.0 scale wraps it (and icon/text sizes) in ["*", scale, expr].
func TestSizeScale(t *testing.T) {
	build := func(scale float64) string {
		m := MarinerDefaults()
		m.SizeScale = scale
		style, err := Style(SchemeDay, "tile57://{z}/{x}/{y}", "sprite",
			"glyphs/{fontstack}/{range}.pbf", 0, 0, m, nil, nil, 0)
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
