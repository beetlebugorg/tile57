//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import (
	"unsafe"
)

// ColortablesDefault returns colortables.json (S-52 colour token -> hex per
// day/dusk/night) from the colour profile baked into libtile57 — no on-disk
// catalogue needed.
func ColortablesDefault() ([]byte, error) {
	var out *C.uint8_t
	var n C.size_t
	var cerr C.tile57_error
	if st := C.tile57_colortables_default(&out, &n, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return tileBytes(out, n), nil
}

// Assets bundles the six in-memory portrayal-asset buffers BakeAssets returns —
// the same files BakeBundle writes under a bundle's assets/ directory.
type Assets struct {
	Colortables, Linestyles, SpriteJSON, SpritePNG, PatternJSON, PatternPNG []byte
}

// BakeAssets generates all portrayal assets in memory (colortables + linestyles +
// sprite/pattern atlases) from the library's embedded S-101 catalogue (catalogDir
// == "") or an on-disk PortrayalCatalog directory. Pairs with BakePmtiles +
// BuildStyle for a full in-memory bundle.
func BakeAssets(catalogDir string) (Assets, error) {
	cdir, free := cStringOrNil(catalogDir)
	defer free()
	var ca C.tile57_assets
	var cerr C.tile57_error
	if st := C.tile57_bake_assets(cdir, &ca, &cerr); st != C.TILE57_OK {
		return Assets{}, statusError(st, &cerr)
	}
	defer C.tile57_assets_free(&ca)
	return Assets{
		Colortables: copyBytes(ca.colortables, ca.colortables_len),
		Linestyles:  copyBytes(ca.linestyles, ca.linestyles_len),
		SpriteJSON:  copyBytes(ca.sprite_json, ca.sprite_json_len),
		SpritePNG:   copyBytes(ca.sprite_png, ca.sprite_png_len),
		PatternJSON: copyBytes(ca.pattern_json, ca.pattern_json_len),
		PatternPNG:  copyBytes(ca.pattern_png, ca.pattern_png_len),
	}, nil
}

// copyBytes copies a libtile57-owned (uint8_t*, size_t) buffer into Go memory
// WITHOUT freeing it (the whole tile57_assets is freed at once by
// tile57_assets_free). (nil for an empty/NULL buffer.)
func copyBytes(p *C.uint8_t, n C.size_t) []byte {
	if p == nil || n == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(p), C.int(n))
}
