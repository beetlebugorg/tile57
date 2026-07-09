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

// BakeCell bakes ONE on-disk cell (a .000 path + its .001.. updates) to a PMTiles
// archive over its NATIVE band zoom range and returns the bytes — the per-cell tile
// store the composite stitcher consumes (the stitcher handles any cross-band zoom
// expansion). The archive metadata embeds that cell's own coverage (M_COVR + cscl +
// date/name); read it back with [PMTilesMetadata].
func BakeCell(path string) ([]byte, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: BakeCell needs a cell path: %w", ErrEmptyInput)
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var out *C.uint8_t
	var outLen C.size_t
	rc := C.tile57_bake_cell_bytes(cPath, &out, &outLen)
	switch rc {
	case 1:
		return tileBytes(out, outLen), nil
	case 0:
		return nil, fmt.Errorf("tile57: cell bake produced no tiles: %w", ErrNoCoverage)
	default:
		return nil, fmt.Errorf("tile57: cell bake failed")
	}
}
// PMTilesMetadata returns a PMTiles archive's metadata JSON blob (decompressed), or
// nil if the archive carries none. A [BakeCell] archive embeds the cell's coverage
// under a "coverage" key. The pmtiles bytes are read but not retained.
func PMTilesMetadata(pmtiles []byte) ([]byte, error) {
	if len(pmtiles) == 0 {
		return nil, fmt.Errorf("tile57: PMTilesMetadata needs archive bytes: %w", ErrEmptyInput)
	}
	var out *C.uint8_t
	var outLen C.size_t
	rc := C.tile57_pmtiles_metadata((*C.uint8_t)(unsafe.Pointer(&pmtiles[0])), C.size_t(len(pmtiles)), &out, &outLen)
	switch rc {
	case 1:
		return tileBytes(out, outLen), nil
	case 0:
		return nil, nil // archive has no metadata
	default:
		return nil, fmt.Errorf("tile57: read metadata failed")
	}
}

// PartitionBand selects which ownership-partition map [BakePartitionDebug] emits.
type PartitionBand int8

const (
	// BandGoverning emits, at each zoom, the partition of the band that governs it —
	// the natural view (coarse bands zoomed out, finer bands zoomed in).
	BandGoverning PartitionBand = -1
	// The six navigational-purpose bands, finest→coarsest: each emits ITS OWN
	// partition map at every zoom (e.g. BandHarbor is the finest quilt).
	BandBerthing PartitionBand = 0
	BandHarbor   PartitionBand = 1
	BandApproach PartitionBand = 2
	BandCoastal  PartitionBand = 3
	BandGeneral  PartitionBand = 4
	BandOverview PartitionBand = 5
)

// BakePartitionDebug bakes the ownership-partition DEBUG tiles from an on-disk
// ENC_ROOT into a single PMTiles at outPath — the composited faces (which cell renders
// which ground at each band), one polygon per owning cell in a layer named "partition"
// with the properties cell/cscl/band/tier/oi/color, and NO portrayed chart content. It
// is the raw material for a partition-debug UI: point a MapLibre style (using the
// vector_layers metadata) at it and fill by the "color" property.
//
// band = [BandGoverning] emits the band governing each zoom (the natural view);
// [BandBerthing]…[BandOverview] emit that one band's own map at every zoom. minZoom and
// maxZoom bound the tiles — the coarse bands are cheap, but harbor-level detail (maxZoom
// >= 13) multiplies the tile count ~4× per zoom, so raise it deliberately. Returns the
// cell count.
func BakePartitionDebug(encRoot, outPath string, minZoom, maxZoom uint8, band PartitionBand) (cellCount int, err error) {
	if encRoot == "" || outPath == "" {
		return 0, fmt.Errorf("tile57: BakePartitionDebug needs an ENC root and out path: %w", ErrEmptyInput)
	}
	cRoot := C.CString(encRoot)
	defer C.free(unsafe.Pointer(cRoot))
	cOut := C.CString(outPath)
	defer C.free(unsafe.Pointer(cOut))

	var cells C.uint32_t
	rc := C.tile57_bake_partition_debug(cRoot, cOut, C.uint8_t(minZoom), C.uint8_t(maxZoom), C.int8_t(band), &cells)
	switch rc {
	case 1:
		return int(cells), nil
	case 0:
		return 0, fmt.Errorf("tile57: partition-debug bake covered nothing: %w", ErrNoCoverage)
	default:
		return 0, fmt.Errorf("tile57: partition-debug bake failed")
	}
}
