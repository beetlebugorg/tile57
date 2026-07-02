//go:build cgo

package tile57

// Chart metadata + raw S-57 access: per-cell metadata, exchange-set catalogue
// decode, and raw feature access — everything a host previously parsed from
// S-57/ISO-8211 itself. With these, a host's S-57 knowledge shrinks to file
// staging conventions (.000/.NNN, ENC_ROOT/, CATALOG.031 as opaque bytes).

/*
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"strings"
	"unsafe"
)

// CellInfo is one cell's identity + coverage, as recorded in its DSID/DSPM
// after the applied update chain.
type CellInfo struct {
	Name      string     `json:"name"`      // cell stem, e.g. "US5MD1MC"
	Scale     int        `json:"scale"`     // DSPM CSCL (1:N)
	Edition   string     `json:"edition"`   // DSID EDTN
	Update    string     `json:"update"`    // DSID UPDN (last applied update)
	IssueDate string     `json:"issueDate"` // DSID ISDT, YYYYMMDD
	Agency    int        `json:"agency"`    // DSID AGEN (550 = NOAA)
	BBox      [4]float64 `json:"bbox"`      // [west, south, east, north]
	HasBBox   bool       `json:"-"`
}

// Cells returns the chart's per-cell metadata (one entry per cell, DSID fields
// after the update chain). A PMTiles source returns nil — its bundle manifest
// carries the cell inventory.
func (s *Source) Cells() ([]CellInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, ErrSourceClosed
	}
	var out *C.uint8_t
	var outLen C.size_t
	switch C.tile57_chart_cells(s.ptr, &out, &outLen) {
	case 1:
	case 0:
		return nil, nil
	default:
		return nil, fmt.Errorf("tile57: cell metadata error")
	}
	raw := tileBytes(out, outLen)
	var wire []struct {
		CellInfo
		BBox []float64 `json:"bbox"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		return nil, fmt.Errorf("tile57: cell metadata decode: %w", err)
	}
	infos := make([]CellInfo, len(wire))
	for i, w := range wire {
		infos[i] = w.CellInfo
		if len(w.BBox) == 4 {
			copy(infos[i].BBox[:], w.BBox)
			infos[i].HasBBox = true
		}
	}
	return infos, nil
}

// CatalogEntry is one CATD record of an exchange-set catalogue (CATALOG.031).
type CatalogEntry struct {
	File     string     `json:"file"`     // recorded path, '/'-normalised
	LongName string     `json:"longName"` // LFIL — the human chart title ("" when absent)
	Impl     string     `json:"impl"`     // "BIN" (a cell), "ASC", "TXT"
	BBox     [4]float64 `json:"bbox"`     // [west, south, east, north]
	HasBBox  bool       `json:"-"`
}

// CatalogEntries decodes a CATALOG.031 exchange-set catalogue. Not chart-scoped:
// the catalogue describes an exchange set, not an open chart.
func CatalogEntries(catalog []byte) ([]CatalogEntry, error) {
	if len(catalog) == 0 {
		return nil, nil
	}
	var out *C.uint8_t
	var outLen C.size_t
	switch C.tile57_catalog_entries((*C.uint8_t)(unsafe.Pointer(&catalog[0])), C.size_t(len(catalog)), &out, &outLen) {
	case 1:
	case 0:
		return nil, nil
	default:
		return nil, fmt.Errorf("tile57: catalogue parse error")
	}
	raw := tileBytes(out, outLen)
	var wire []struct {
		CatalogEntry
		BBox []float64 `json:"bbox"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		return nil, fmt.Errorf("tile57: catalogue decode: %w", err)
	}
	entries := make([]CatalogEntry, len(wire))
	for i, w := range wire {
		entries[i] = w.CatalogEntry
		if len(w.BBox) == 4 {
			copy(entries[i].BBox[:], w.BBox)
			entries[i].HasBBox = true
		}
	}
	return entries, nil
}

// Feature is one S-57 feature from [Source.Features]: its class acronym, the
// full attribute map (acronym → raw string value), and GeoJSON geometry.
type Feature struct {
	Class    string            // e.g. "DEPARE"
	Attrs    map[string]string // full S-57 attribute set, e.g. {"DRVAL1":"3.6"}
	Type     string            // GeoJSON type: Point/MultiPoint/LineString/MultiLineString/Polygon
	Geometry json.RawMessage   // the GeoJSON geometry object (lon/lat; soundings carry depth as a 3rd coord)
}

// Features returns the chart's features for the given object-class acronyms
// (e.g. "DEPARE", "DRGARE"), parsed without portrayal. A whole-ENC_ROOT query
// walks every cell — the caller owns that cost.
func (s *Source) Features(classes ...string) ([]Feature, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, ErrSourceClosed
	}
	if len(classes) == 0 {
		return nil, nil
	}
	cs := C.CString(strings.Join(classes, ","))
	defer C.free(unsafe.Pointer(cs))
	var out *C.uint8_t
	var outLen C.size_t
	switch C.tile57_chart_features(s.ptr, cs, &out, &outLen) {
	case 1:
	case 0:
		return nil, nil
	default:
		return nil, fmt.Errorf("tile57: feature query error")
	}
	raw := tileBytes(out, outLen)
	var fc struct {
		Features []struct {
			Geometry   json.RawMessage   `json:"geometry"`
			Properties map[string]string `json:"properties"`
		} `json:"features"`
	}
	if err := json.Unmarshal(raw, &fc); err != nil {
		return nil, fmt.Errorf("tile57: feature decode: %w", err)
	}
	feats := make([]Feature, len(fc.Features))
	for i, f := range fc.Features {
		var g struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(f.Geometry, &g)
		feats[i] = Feature{
			Class:    f.Properties["class"],
			Attrs:    f.Properties,
			Type:     g.Type,
			Geometry: f.Geometry,
		}
		delete(feats[i].Attrs, "class")
	}
	return feats, nil
}
