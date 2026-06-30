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

// tile57GoBakeProgress is the C-callable progress callback libtile57 invokes
// during tile57_bake_cells. The host's Go progress func is carried across the
// seam as a cgo.Handle, pointed to by `user`. NULL user = no progress wanted.
//
//export tile57GoBakeProgress
func tile57GoBakeProgress(user unsafe.Pointer, stage C.uint8_t, done, total C.size_t) {
	if user == nil {
		return
	}
	h := *(*cgo.Handle)(user)
	if cb, ok := h.Value().(func(stage uint8, done, total int)); ok && cb != nil {
		cb(uint8(stage), int(done), int(total))
	}
}
