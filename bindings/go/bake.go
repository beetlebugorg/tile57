//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"

// Forward declaration of the //export'd Go progress callback (defined in
// progress.go). The trampoline lets us hand libtile57 a real C function pointer
// that re-enters Go, without taking the address of a Go func in Go code.
void tile57GoBakeProgress(void *user, uint8_t stage, size_t done, size_t total,
                          uint8_t band_index, uint8_t band_count, const char *band_name);

// user != NULL → re-enter Go for progress; NULL → no progress (bake_pmtiles has no
// console default, and its trampoline no-ops on a NULL user regardless).
static int tile57_bake_pmtiles_cb(const tile57_cell *cells, size_t count,
                                  const char *rules_dir, uint8_t minz, uint8_t maxz,
                                  int omit_pick_attrs, uint8_t format,
                                  void *user, uint8_t **out, size_t *out_len) {
    tile57_bake_opts opts = {
        .rules_dir = rules_dir,
        .catalog_dir = NULL,
        .created = NULL,
        .minzoom = minz,
        .maxzoom = maxz,
        .omit_pick_attrs = omit_pick_attrs != 0,
        .progress = user ? tile57GoBakeProgress : (tile57_bake_progress)0,
        .progress_user = user,
        .format = format,
    };
    return tile57_bake_pmtiles(cells, count, &opts, out, out_len);
}

// user != NULL → re-enter Go for progress; NULL → the lib's built-in console.
static int tile57_bake_bundle_cb(const char *input, const char *out_dir,
                                 const char *rules_dir, const char *catalog_dir,
                                 const char *created, uint8_t minz, uint8_t maxz,
                                 int omit_pick_attrs, uint8_t format,
                                 void *user, uint32_t *out_cells, double *out_bbox) {
    tile57_bake_opts opts = {
        .rules_dir = rules_dir,
        .catalog_dir = catalog_dir,
        .created = created,
        .minzoom = minz,
        .maxzoom = maxz,
        .omit_pick_attrs = omit_pick_attrs != 0,
        .progress = user ? tile57GoBakeProgress : (tile57_bake_progress)0,
        .progress_user = user,
        .format = format,
    };
    return tile57_bake_bundle(input, out_dir, &opts, out_cells, out_bbox);
}
*/
import "C"

import (
	"fmt"
	"runtime/cgo"
	"unsafe"
)

// BakeOpts are the shared knobs for [BakePmtiles] and [BakeBundle]. The zero value
// is the default: the catalogue embedded in libtile57, no band clamp, and the
// per-feature pick-report attributes included. CatalogDir and Created apply to
// [BakeBundle] only ([BakePmtiles] ignores them).
type BakeOpts struct {
	RulesDir      string // "" = embedded portrayal rules
	CatalogDir    string // "" = embedded S-101 catalogue (BakeBundle only)
	Created       string // "" = manifest "created" unset (BakeBundle only)
	MinZoom       uint8  // 0/0 = no band clamp
	MaxZoom       uint8
	OmitPickAttrs bool       // true = drop the pick-report attrs (class/cell/s57) for a leaner bake
	Format        TileFormat // baked tile encoding; the zero value bakes the engine default (MLT)
}

// BakePmtiles bakes an ENC_ROOT's in-memory cells into ONE zoom-banded PMTiles
// archive (write it to a file and open cheaply via [OpenPMTiles], instead of
// generating tiles live). opts.MinZoom/MaxZoom clamp the per-cell bands (0/0 = no
// clamp); opts.CatalogDir/Created are ignored here. progress, if non-nil, is called
// with a [BakeProgress] per update: stage 0 = loading/portraying cells, stage 1 =
// baking tiles (per-band done/total + band label).
func BakePmtiles(cells []Cell, opts BakeOpts, progress func(BakeProgress)) ([]byte, error) {
	if len(cells) == 0 {
		return nil, fmt.Errorf("tile57: no cells to bake: %w", ErrEmptyInput)
	}
	cRules, freeRules := cStringOrNil(opts.RulesDir)
	defer freeRules()

	arena := &cArena{}
	defer arena.free()
	_, base := arena.cellInputs(cells)

	var user unsafe.Pointer
	if progress != nil {
		h := cgo.NewHandle(progress)
		defer h.Delete()
		user = unsafe.Pointer(&h)
	}

	var out *C.uint8_t
	var outLen C.size_t
	rc := C.tile57_bake_pmtiles_cb(base, C.size_t(len(cells)), cRules,
		C.uint8_t(opts.MinZoom), C.uint8_t(opts.MaxZoom), cOmit(opts.OmitPickAttrs), C.uint8_t(opts.Format), user, &out, &outLen)
	switch rc {
	case 1:
		return tileBytes(out, outLen), nil
	case 0:
		return nil, fmt.Errorf("tile57: bake produced no tiles: %w", ErrNoCoverage)
	default:
		return nil, fmt.Errorf("tile57: bake failed")
	}
}

// BakeBundle bakes an on-disk input (a .000 cell or an ENC_ROOT directory) into a
// self-contained chart bundle under outDir — the canonical, drift-proof package:
//
//	outDir/tiles/chart.pmtiles            (PMTiles + scamin & vector_layers metadata)
//	outDir/assets/colortables.json, linestyles.json, sprite-mln{,@2x}.{json,png}
//	outDir/assets/style-{day,dusk,night}.json   (per-scheme, SCAMIN-bucketed)
//	outDir/manifest.json                  (schema_version, bbox, cells, styles)
//
// opts.RulesDir/CatalogDir "" use the catalogue embedded in libtile57. opts.Created
// "" leaves the manifest timestamp unset. opts.MinZoom/MaxZoom clamp the per-cell
// bands (0/0 → no clamp). progress nil uses the lib's built-in console progress.
// Returns the cell count and bbox (west,south,east,north).
//
// progress reports a [BakeProgress] per update: stage 0 = loading cells
// (Done/Total = cells); stage 1 = baking tiles, where Done/Total are PER BAND
// (reset each band) and Total is that band's planned tile count — so a UI can show
// a per-band percentage. BandIndex/BandCount/BandName give the band label
// ("approach", band 3/6). The planned total slightly over-counts the emitted tiles
// (empty tiles are skipped), matching the Go baker's planned bar.
func BakeBundle(input, outDir string, opts BakeOpts, progress func(BakeProgress)) (cellCount int, bbox [4]float64, err error) {
	if input == "" || outDir == "" {
		return 0, bbox, fmt.Errorf("tile57: BakeBundle needs input and out dir: %w", ErrEmptyInput)
	}
	cIn := C.CString(input)
	defer C.free(unsafe.Pointer(cIn))
	cOut := C.CString(outDir)
	defer C.free(unsafe.Pointer(cOut))
	cRules, fr := cStringOrNil(opts.RulesDir)
	defer fr()
	cCat, fc := cStringOrNil(opts.CatalogDir)
	defer fc()
	cCreated, fcr := cStringOrNil(opts.Created)
	defer fcr()

	var user unsafe.Pointer
	if progress != nil {
		h := cgo.NewHandle(progress)
		defer h.Delete()
		user = unsafe.Pointer(&h)
	}

	var cells C.uint32_t
	var bb [4]C.double
	rc := C.tile57_bake_bundle_cb(cIn, cOut, cRules, cCat, cCreated,
		C.uint8_t(opts.MinZoom), C.uint8_t(opts.MaxZoom), cOmit(opts.OmitPickAttrs), C.uint8_t(opts.Format), user, &cells, &bb[0])
	switch rc {
	case 1:
		return int(cells), [4]float64{float64(bb[0]), float64(bb[1]), float64(bb[2]), float64(bb[3])}, nil
	case 0:
		return 0, bbox, fmt.Errorf("tile57: bundle bake covered nothing: %w", ErrNoCoverage)
	default:
		return 0, bbox, fmt.Errorf("tile57: bundle bake failed")
	}
}

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
