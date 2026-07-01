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
                                  int omit_pick_attrs,
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
    };
    return tile57_bake_pmtiles(cells, count, &opts, out, out_len);
}

// user != NULL → re-enter Go for progress; NULL → the lib's built-in console.
static int tile57_bake_bundle_cb(const char *input, const char *out_dir,
                                 const char *rules_dir, const char *catalog_dir,
                                 const char *created, uint8_t minz, uint8_t maxz,
                                 int omit_pick_attrs,
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
	OmitPickAttrs bool // true = drop the pick-report attrs (class/cell/s57) for a leaner bake
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
		C.uint8_t(opts.MinZoom), C.uint8_t(opts.MaxZoom), cOmit(opts.OmitPickAttrs), user, &out, &outLen)
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
		C.uint8_t(opts.MinZoom), C.uint8_t(opts.MaxZoom), cOmit(opts.OmitPickAttrs), user, &cells, &bb[0])
	switch rc {
	case 1:
		return int(cells), [4]float64{float64(bb[0]), float64(bb[1]), float64(bb[2]), float64(bb[3])}, nil
	case 0:
		return 0, bbox, fmt.Errorf("tile57: bundle bake covered nothing: %w", ErrNoCoverage)
	default:
		return 0, bbox, fmt.Errorf("tile57: bundle bake failed")
	}
}
