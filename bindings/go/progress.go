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

// BakeProgress is one progress report from [BakePmtiles] / [BakeBundle].
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

// ComposeProgress is one progress report from [ComposeFiles] as the streaming compose walks the
// zoom ladder. Done/Total are opaque work weights (the deepest zoom dominates the total), so
// Done/Total is a smooth 0..1 fraction; Zoom is the level currently composing, within
// [MinZoom, MaxZoom] — enough for a host to show a bar + ETA and a "zoom N of M" line.
type ComposeProgress struct {
	Zoom    int
	MinZoom int
	MaxZoom int
	Done    uint64
	Total   uint64
}

// tile57GoComposeProgress is the C-callable progress callback libtile57 invokes during
// tile57_compose_files. The host's Go progress func is carried across the seam as a cgo.Handle
// pointed to by `user`. NULL user = no progress wanted.
//
//export tile57GoComposeProgress
func tile57GoComposeProgress(user unsafe.Pointer, zoom, minZoom, maxZoom C.uint32_t, done, total C.uint64_t) {
	if user == nil {
		return
	}
	h := *(*cgo.Handle)(user)
	if cb, ok := h.Value().(func(ComposeProgress)); ok && cb != nil {
		cb(ComposeProgress{
			Zoom:    int(zoom),
			MinZoom: int(minZoom),
			MaxZoom: int(maxZoom),
			Done:    uint64(done),
			Total:   uint64(total),
		})
	}
}

// tile57GoBakeProgress is the C-callable progress callback libtile57 invokes
// during tile57_bake_pmtiles / tile57_bake_bundle. The host's Go progress func is
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
