//go:build cgo

package tile57

/*
#include "tile57.h"
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

// BakeProgress is one progress report from [BakeCells] / [BakeBundle].
type BakeProgress struct {
	Stage uint8 // 0 = loading/portraying cells, 1 = baking tiles
	Done  int   // cells loaded (stage 0) or tiles baked in this band (stage 1)
	Total int   // total cells (stage 0) or the band's planned tile count (stage 1; 0 = unknown)
	// BandIndex/BandCount locate the current band among the bands that actually bake
	// (0-based index; count = how many bands have cells), so a UI can show "band i/n".
	BandIndex int
	BandCount int
	// BandName is the navigational-purpose name of the current band ("berthing",
	// "harbor", "approach", "coastal", "general", "overview"), or "" if not band-specific.
	BandName string
}

// tile57GoBakeProgress is the C-callable progress callback libtile57 invokes
// during tile57_bake_cells / tile57_bake_bundle. The host's Go progress func is
// carried across the seam as a cgo.Handle, pointed to by `user`. NULL user = no
// progress wanted.
//
//export tile57GoBakeProgress
func tile57GoBakeProgress(user unsafe.Pointer, stage C.uint8_t, done, total C.size_t, bandIndex, bandCount C.uint8_t, bandName *C.char) {
	if user == nil {
		return
	}
	h := *(*cgo.Handle)(user)
	if cb, ok := h.Value().(func(BakeProgress)); ok && cb != nil {
		name := ""
		if bandName != nil {
			name = C.GoString(bandName)
		}
		cb(BakeProgress{
			Stage:     uint8(stage),
			Done:      int(done),
			Total:     int(total),
			BandIndex: int(bandIndex),
			BandCount: int(bandCount),
			BandName:  name,
		})
	}
}
