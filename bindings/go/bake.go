//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"

// Trampoline: the C progress callback calls back into this exported Go function.
extern bool tile57GoBakeProgress(void *ctx, uint32_t done, uint32_t total);
*/
import "C"

import (
	"fmt"
	"runtime/cgo"
	"unsafe"
)

// The C callback can cancel the bake by returning false; BakeTree's progress func has no
// way to say so, so this always continues. (A cancellable Go bake would take a variant
// whose callback returns bool — the C ABI already supports it.)
//
//export tile57GoBakeProgress
func tile57GoBakeProgress(ctx unsafe.Pointer, done, total C.uint32_t) C.bool {
	if fn, ok := cgo.Handle(uintptr(ctx)).Value().(func(int, int)); ok && fn != nil {
		fn(int(done), int(total))
	}
	return C.bool(true)
}

// BakeChart bakes ONE on-disk chart (a .000 path + its .001.. updates) to a PMTiles
// archive over its NATIVE band zoom range and returns the bytes — the per-chart tile
// store the compositor consumes (it handles any cross-band zoom expansion). The
// archive metadata embeds that chart's own coverage (M_COVR + cscl + date/name);
// read it back with [PMTilesMetadata], or open the archive with [OpenBytes]. A
// chart that produces no tiles returns ErrNoCoverage.
func BakeChart(path string) ([]byte, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: BakeChart needs a chart path: %w", ErrEmptyInput)
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var out *C.uint8_t
	var outLen C.size_t
	var cerr C.tile57_error
	if st := C.tile57_bake_chart_bytes(cPath, &out, &outLen, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	if out == nil {
		return nil, fmt.Errorf("tile57: chart bake produced no tiles: %w", ErrNoCoverage)
	}
	return tileBytes(out, outLen), nil
}

// BakeTree walks inDir for S-57 base charts (*.000) and bakes each IN PARALLEL to the SAME relative
// path under outDir with a .pmtiles extension (+ an <out>.sha content-hash sidecar), creating
// subdirs. INCREMENTAL: a chart whose archive is already up to date (newer than its .000 and its
// update chain) is skipped, so a re-run over an unchanged tree bakes nothing — 0 over a warm cache
// is success. The engine writes and frees each archive as it goes, so this never holds N archives
// in memory (peak ~ workers). outDir is the caller's OWN cache — it owns the location + layout, so
// distinct consumers don't clash. onProgress(done, total) fires per baked chart (may be called
// concurrently from workers, so it must be safe for concurrent use). Returns the number baked
// THIS run.
func BakeTree(inDir, outDir string, workers int, onProgress func(done, total int)) (int, error) {
	if inDir == "" || outDir == "" {
		return 0, fmt.Errorf("tile57: BakeTree needs input + output dirs: %w", ErrEmptyInput)
	}
	if workers < 1 {
		workers = 1
	}
	cIn := C.CString(inDir)
	defer C.free(unsafe.Pointer(cIn))
	cOut := C.CString(outDir)
	defer C.free(unsafe.Pointer(cOut))

	var cb C.tile57_bake_progress
	var ctx unsafe.Pointer
	if onProgress != nil {
		h := cgo.NewHandle(onProgress)
		defer h.Delete()
		cb = C.tile57_bake_progress(C.tile57GoBakeProgress)
		ctx = unsafe.Pointer(h) //nolint:govet // cgo.Handle passed as the void* ctx, retrieved verbatim
	}
	var baked C.uint32_t
	var cerr C.tile57_error
	if st := C.tile57_bake_tree(cIn, cOut, C.uint32_t(workers), cb, ctx, &baked, &cerr); st != C.TILE57_OK {
		return 0, statusError(st, &cerr)
	}
	return int(baked), nil
}

// PMTilesMetadata returns a PMTiles archive's metadata JSON blob (decompressed), or
// nil if the archive carries none. A [BakeChart] archive embeds the chart's coverage
// under a "coverage" key. The pmtiles bytes are read but not retained.
func PMTilesMetadata(pmtiles []byte) ([]byte, error) {
	if len(pmtiles) == 0 {
		return nil, fmt.Errorf("tile57: PMTilesMetadata needs archive bytes: %w", ErrEmptyInput)
	}
	var out *C.uint8_t
	var outLen C.size_t
	var cerr C.tile57_error
	if st := C.tile57_pmtiles_metadata((*C.uint8_t)(unsafe.Pointer(&pmtiles[0])), C.size_t(len(pmtiles)), &out, &outLen, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	if out == nil {
		return nil, nil // archive has no metadata
	}
	return tileBytes(out, outLen), nil
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
// ENC_ROOT into a single PMTiles at outPath — the composited faces (which chart renders
// which ground at each band), one polygon per owning chart in a layer named "partition"
// with the properties cell/cscl/band/tier/oi/color, and NO portrayed chart content. It
// is the raw material for a partition-debug UI: point a MapLibre style (using the
// vector_layers metadata) at it and fill by the "color" property.
//
// band = [BandGoverning] emits the band governing each zoom (the natural view);
// [BandBerthing]…[BandOverview] emit that one band's own map at every zoom. minZoom and
// maxZoom bound the tiles — the coarse bands are cheap, but harbor-level detail (maxZoom
// >= 13) multiplies the tile count ~4× per zoom, so raise it deliberately. Returns the
// chart count; nothing covered returns ErrNoCoverage (no file written).
func BakePartitionDebug(encRoot, outPath string, minZoom, maxZoom uint8, band PartitionBand) (chartCount int, err error) {
	if encRoot == "" || outPath == "" {
		return 0, fmt.Errorf("tile57: BakePartitionDebug needs an ENC root and out path: %w", ErrEmptyInput)
	}
	cRoot := C.CString(encRoot)
	defer C.free(unsafe.Pointer(cRoot))
	cOut := C.CString(outPath)
	defer C.free(unsafe.Pointer(cOut))

	var charts C.uint32_t
	var cerr C.tile57_error
	if st := C.tile57_bake_partition_debug(cRoot, cOut, C.uint8_t(minZoom), C.uint8_t(maxZoom), C.int8_t(band), &charts, &cerr); st != C.TILE57_OK {
		return 0, statusError(st, &cerr)
	}
	if charts == 0 {
		return 0, fmt.Errorf("tile57: partition-debug bake covered nothing: %w", ErrNoCoverage)
	}
	return int(charts), nil
}
