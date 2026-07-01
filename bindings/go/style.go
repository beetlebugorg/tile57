//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// Scheme selects the S-52 colour palette (day/dusk/night).
type Scheme int32

const (
	SchemeDay   Scheme = C.TILE57_SCHEME_DAY
	SchemeDusk  Scheme = C.TILE57_SCHEME_DUSK
	SchemeNight Scheme = C.TILE57_SCHEME_NIGHT
)

// SchemeFromString maps "day"/"dusk"/"night" to a Scheme (default day).
func SchemeFromString(s string) Scheme {
	switch s {
	case "dusk":
		return SchemeDusk
	case "night":
		return SchemeNight
	default:
		return SchemeDay
	}
}

// DepthUnit selects the contour-label unit.
type DepthUnit int32

const (
	DepthMeters DepthUnit = C.TILE57_DEPTH_METERS
	DepthFeet   DepthUnit = C.TILE57_DEPTH_FEET
)

// BoundaryStyle selects symbolized vs plain area boundaries.
type BoundaryStyle int32

const (
	BoundarySymbolized BoundaryStyle = C.TILE57_BOUNDARY_SYMBOLIZED
	BoundaryPlain      BoundaryStyle = C.TILE57_BOUNDARY_PLAIN
)

// Mariner is the S-52 mariner display selection that drives the style patch — the
// Go mirror of tile57_mariner. Get a sensible default with [MarinerDefaults].
type Mariner struct {
	Scheme                                                  Scheme
	ShallowContour, SafetyContour, DeepContour, SafetyDepth float64
	FourShadeWater                                          bool
	DepthUnit                                               DepthUnit
	DisplayBase, DisplayStandard, DisplayOther              bool
	DataQuality, ShowInformCallouts                         bool
	ShowMetaBounds, ShowIsolatedDangersShallow              bool
	BoundaryStyle                                           BoundaryStyle
	SimplifiedPoints, ShowFullSectorLines                   bool
	TextNames, ShowLightDescriptions, TextOther             bool
	DateDependent, HighlightDateDependent                   bool
	DateView                                                string  // "YYYYMMDD" or "" (today)
	IgnoreScamin                                            bool    // ?ignoreScamin: drop SCAMIN gating, show all in-band
	ScaminFilterGate                                        bool    // scamin-layers.md: one live-filtered *_scamin layer per render-type instead of per-value buckets
	SizeScale                                               float64 // physical-scale multiplier for icon/line/text sizes (1.0 = verbatim)
	ViewingGroupsOff                                        []int32 // S-52 §14.5 DENY-LIST: vg ids turned OFF (nil/empty = show all)
}

// MarinerDefaults returns the canonical default mariner settings from libtile57.
func MarinerDefaults() Mariner {
	var cm C.tile57_mariner
	C.tile57_mariner_defaults(&cm)
	return marinerFromC(&cm)
}

// StyleTemplate returns the base MapLibre style template (layers + chart sources +
// sprite/glyph URLs) for a scheme, from the catalogue baked into libtile57.
// sourceTiles is the chart {z}/{x}/{y} URL; sprite/glyphs are base URLs ("" omits
// the symbol/text layers); minZoom/maxZoom of 0 use the engine defaults.
func StyleTemplate(scheme Scheme, sourceTiles, sprite, glyphs string, minZoom, maxZoom uint32) ([]byte, error) {
	cSrc, f1 := cStringOrNil(sourceTiles)
	defer f1()
	cSpr, f2 := cStringOrNil(sprite)
	defer f2()
	cGly, f3 := cStringOrNil(glyphs)
	defer f3()
	var out *C.uint8_t
	var n C.size_t
	if C.tile57_style_template(C.tile57_scheme(scheme), cSrc, cSpr, cGly,
		C.uint32_t(minZoom), C.uint32_t(maxZoom), &out, &n) != 1 {
		return nil, fmt.Errorf("tile57: style_template failed")
	}
	return tileBytes(out, n), nil
}

// BuildStyle patches a style template with the mariner settings + S-52 colortables
// into a concrete MapLibre style JSON. enabledBands (nil = show all) restricts the
// output to features whose band rank is listed. scamin is the SCAMIN manifest (the
// distinct denominators present, e.g. from Source.Scamin / the TileJSON): when
// non-empty the `_scamin` layers are split into per-value bucket layers with native
// minzoom = scaminDisplayZoom(value, scaminLat) — the same gating the offline bundle
// emits; nil/empty leaves them ungated. scaminLat is the source's center latitude.
func BuildStyle(template []byte, m Mariner, colortables []byte, enabledBands []int32, scamin []int32, scaminLat float64) ([]byte, error) {
	if len(template) == 0 {
		return nil, fmt.Errorf("tile57: empty style template: %w", ErrEmptyInput)
	}
	arena := &cArena{}
	defer arena.free()
	cm := m.toC(arena) // owns the full conversion incl. the ViewingGroupsOff deny-list
	tmplPtr, tmplLen := charPtr(template)
	ctPtr, ctLen := charPtr(colortables)
	bandsPtr, bandsN := arena.int32Array(enabledBands)
	scaminPtr, scaminN := arena.int32Array(scamin)

	var out *C.uint8_t
	var outLen C.size_t
	if C.tile57_build_style(tmplPtr, tmplLen, &cm, ctPtr, ctLen, bandsPtr, bandsN, scaminPtr, scaminN, C.double(scaminLat), &out, &outLen) != 1 {
		return nil, fmt.Errorf("tile57: build_style failed")
	}
	return tileBytes(out, outLen), nil
}

// StyleDiff returns the MapLibre mutation ops (a raw JSON array) to turn the style
// for `from` into the style for `to`, sharing the template/colortables/bands/scamin
// inputs of BuildStyle so the two styles are comparable. The result is "[]" when
// nothing changed, one op per differing filter/paint/layout key, or
// [{"op":"rebuild"}] when the host should fall back to a full setStyle. The host
// applies each op with map.setFilter / setPaintProperty / setLayoutProperty (see
// specs/style-diff.md); the raw JSON is returned so a server can forward it to the
// browser untouched.
func StyleDiff(template []byte, from, to Mariner, colortables []byte, enabledBands []int32, scamin []int32, scaminLat float64) ([]byte, error) {
	if len(template) == 0 {
		return nil, fmt.Errorf("tile57: empty style template: %w", ErrEmptyInput)
	}
	arena := &cArena{}
	defer arena.free()
	cFrom := from.toC(arena) // each owns its ViewingGroupsOff deny-list in the arena
	cTo := to.toC(arena)
	tmplPtr, tmplLen := charPtr(template)
	ctPtr, ctLen := charPtr(colortables)
	bandsPtr, bandsN := arena.int32Array(enabledBands)
	scaminPtr, scaminN := arena.int32Array(scamin)

	var out *C.uint8_t
	var outLen C.size_t
	if C.tile57_style_diff(tmplPtr, tmplLen, &cFrom, &cTo, ctPtr, ctLen, bandsPtr, bandsN, scaminPtr, scaminN, C.double(scaminLat), &out, &outLen) != 1 {
		return nil, fmt.Errorf("tile57: style_diff failed")
	}
	return tileBytes(out, outLen), nil
}

// Style is a convenience that runs the whole pipeline — default colortables +
// template (scheme, tiles/sprite/glyph URLs) patched by mariner + band filter — to
// produce a complete MapLibre style JSON from libtile57's baked-in catalogue.
// minZoom/maxZoom set the template's zoom span (0 = the engine default, i.e. z16 max);
// a host that overzooms past z16 must pass its own maxZoom here. scamin/scaminLat
// (typically Source.Scamin() + the source center latitude) gate the `_scamin` layers
// by value; pass nil/0 to leave them ungated.
func Style(scheme Scheme, sourceTiles, sprite, glyphs string, minZoom, maxZoom uint32, m Mariner, enabledBands []int32, scamin []int32, scaminLat float64) ([]byte, error) {
	ct, err := ColortablesDefault()
	if err != nil {
		return nil, err
	}
	tmpl, err := StyleTemplate(scheme, sourceTiles, sprite, glyphs, minZoom, maxZoom)
	if err != nil {
		return nil, err
	}
	return BuildStyle(tmpl, m, ct, enabledBands, scamin, scaminLat)
}

// toC converts a Mariner to its C struct — the COMPLETE conversion, including the
// ViewingGroupsOff deny-list, which must live in C memory: it is copied into `arena`
// (freed by the caller after the ABI call) so the engine never holds a Go pointer.
// Pass the same cArena used for the call's other C arrays. cgo maps C _Bool to Go
// bool, so the flag fields assign directly.
func (m Mariner) toC(arena *cArena) C.tile57_mariner {
	var c C.tile57_mariner
	c.scheme = C.tile57_scheme(m.Scheme)
	c.shallow_contour = C.double(m.ShallowContour)
	c.safety_contour = C.double(m.SafetyContour)
	c.deep_contour = C.double(m.DeepContour)
	c.safety_depth = C.double(m.SafetyDepth)
	c.four_shade_water = C.bool(m.FourShadeWater)
	c.depth_unit = C.tile57_depth_unit(m.DepthUnit)
	c.display_base = C.bool(m.DisplayBase)
	c.display_standard = C.bool(m.DisplayStandard)
	c.display_other = C.bool(m.DisplayOther)
	c.data_quality = C.bool(m.DataQuality)
	c.show_inform_callouts = C.bool(m.ShowInformCallouts)
	c.show_meta_bounds = C.bool(m.ShowMetaBounds)
	c.show_isolated_dangers_shallow = C.bool(m.ShowIsolatedDangersShallow)
	c.boundary_style = C.tile57_boundary_style(m.BoundaryStyle)
	c.simplified_points = C.bool(m.SimplifiedPoints)
	c.show_full_sector_lines = C.bool(m.ShowFullSectorLines)
	c.text_names = C.bool(m.TextNames)
	c.show_light_descriptions = C.bool(m.ShowLightDescriptions)
	c.text_other = C.bool(m.TextOther)
	c.date_dependent = C.bool(m.DateDependent)
	c.highlight_date_dependent = C.bool(m.HighlightDateDependent)
	for i := 0; i < len(m.DateView) && i < 8; i++ {
		c.date_view[i] = C.char(m.DateView[i])
	}
	c.ignore_scamin = C.bool(m.IgnoreScamin)
	c.scamin_filter_gate = C.bool(m.ScaminFilterGate)
	c.size_scale = C.double(m.SizeScale)
	// Viewing-group deny-list: arena-owned C array so no Go pointer crosses into C.
	vgOffPtr, vgOffN := arena.int32Array(m.ViewingGroupsOff)
	c.viewing_groups_off = vgOffPtr
	c.viewing_groups_off_len = C.uint32_t(vgOffN)
	return c
}

// marinerFromC converts a C mariner struct back to Go.
func marinerFromC(c *C.tile57_mariner) Mariner {
	m := Mariner{
		Scheme:                     Scheme(c.scheme),
		ShallowContour:             float64(c.shallow_contour),
		SafetyContour:              float64(c.safety_contour),
		DeepContour:                float64(c.deep_contour),
		SafetyDepth:                float64(c.safety_depth),
		FourShadeWater:             bool(c.four_shade_water),
		DepthUnit:                  DepthUnit(c.depth_unit),
		DisplayBase:                bool(c.display_base),
		DisplayStandard:            bool(c.display_standard),
		DisplayOther:               bool(c.display_other),
		DataQuality:                bool(c.data_quality),
		ShowInformCallouts:         bool(c.show_inform_callouts),
		ShowMetaBounds:             bool(c.show_meta_bounds),
		ShowIsolatedDangersShallow: bool(c.show_isolated_dangers_shallow),
		BoundaryStyle:              BoundaryStyle(c.boundary_style),
		SimplifiedPoints:           bool(c.simplified_points),
		ShowFullSectorLines:        bool(c.show_full_sector_lines),
		TextNames:                  bool(c.text_names),
		ShowLightDescriptions:      bool(c.show_light_descriptions),
		TextOther:                  bool(c.text_other),
		DateDependent:              bool(c.date_dependent),
		HighlightDateDependent:     bool(c.highlight_date_dependent),
		IgnoreScamin:               bool(c.ignore_scamin),
		ScaminFilterGate:           bool(c.scamin_filter_gate),
		SizeScale:                  float64(c.size_scale),
	}
	var dv []byte
	for i := 0; i < len(c.date_view); i++ {
		if c.date_view[i] == 0 {
			break
		}
		dv = append(dv, byte(c.date_view[i]))
	}
	m.DateView = string(dv)
	return m
}

// charPtr returns a C (char*, len) view of a read-only Go byte slice for the call.
func charPtr(b []byte) (*C.char, C.size_t) {
	if len(b) == 0 {
		return nil, 0
	}
	return (*C.char)(unsafe.Pointer(&b[0])), C.size_t(len(b))
}
