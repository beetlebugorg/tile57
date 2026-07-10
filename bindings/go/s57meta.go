//go:build cgo

package tile57

// Raw S-57 access, handle-free: per-cell metadata, GeoJSON feature extraction,
// and exchange-set catalogue decode — everything a host previously parsed from
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

// Cells returns the per-cell metadata of the S-57 data at path — one .000 file
// (with its update chain applied) or a whole ENC_ROOT directory — for a host's
// chart-database scan.
func Cells(path string) ([]CellInfo, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: empty path: %w", ErrEmptyInput)
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	var out *C.uint8_t
	var outLen C.size_t
	var cerr C.tile57_error
	if st := C.tile57_enc_cells(cPath, &out, &outLen, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	if out == nil {
		return nil, nil
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
	var cerr C.tile57_error
	if st := C.tile57_enc_catalog((*C.uint8_t)(unsafe.Pointer(&catalog[0])), C.size_t(len(catalog)), &out, &outLen, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	if out == nil {
		return nil, nil
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

// Feature is one S-57 feature from [Features]: its class acronym, the full
// attribute map (acronym → raw string value), and GeoJSON geometry.
type Feature struct {
	Class    string            // e.g. "DEPARE"
	Attrs    map[string]string // full S-57 attribute set, e.g. {"DRVAL1":"3.6"}
	Type     string            // GeoJSON type: Point/MultiPoint/LineString/MultiLineString/Polygon
	Geometry json.RawMessage   // the GeoJSON geometry object (lon/lat; soundings carry depth as a 3rd coord)
}

// Features returns the features of the S-57 data at path (one cell, updates
// applied, or a whole ENC_ROOT) for the given object-class acronyms (e.g.
// "DEPARE", "DRGARE"), parsed without portrayal. A whole-ENC_ROOT extraction
// walks every cell — the caller owns that cost.
func Features(path string, classes ...string) ([]Feature, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: empty path: %w", ErrEmptyInput)
	}
	if len(classes) == 0 {
		return nil, nil
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	cs := C.CString(strings.Join(classes, ","))
	defer C.free(unsafe.Pointer(cs))
	var out *C.uint8_t
	var outLen C.size_t
	var cerr C.tile57_error
	if st := C.tile57_enc_features(cPath, cs, &out, &outLen, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return decodeFeatures(out, outLen)
}

// FeaturesBytes is [Features] over in-memory base-cell bytes (a .000 read from a
// zip member, say). No update chain is applied.
func FeaturesBytes(base []byte, classes ...string) ([]Feature, error) {
	if len(base) == 0 {
		return nil, fmt.Errorf("tile57: empty cell bytes: %w", ErrEmptyInput)
	}
	if len(classes) == 0 {
		return nil, nil
	}
	cs := C.CString(strings.Join(classes, ","))
	defer C.free(unsafe.Pointer(cs))
	var out *C.uint8_t
	var outLen C.size_t
	var cerr C.tile57_error
	if st := C.tile57_enc_features_bytes((*C.uint8_t)(unsafe.Pointer(&base[0])), C.size_t(len(base)), cs, &out, &outLen, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return decodeFeatures(out, outLen)
}

// decodeFeatures unmarshals an engine GeoJSON FeatureCollection buffer (freeing
// it) into []Feature. A nil buffer (nothing matched) decodes to nil.
func decodeFeatures(out *C.uint8_t, outLen C.size_t) ([]Feature, error) {
	if out == nil {
		return nil, nil
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
