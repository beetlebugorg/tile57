//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import "unsafe"

// cArena tracks the C allocations built for one ABI call so they can be freed
// together once the call returns. libtile57 copies all input bytes during the
// call, so the arena's lifetime need only span the call itself. Building inputs
// in C memory (not Go memory) keeps Go pointers out of the C-passed arrays, which
// cgocheck would otherwise reject.
type cArena struct {
	ptrs []unsafe.Pointer
}

func (a *cArena) track(p unsafe.Pointer) unsafe.Pointer {
	if p != nil {
		a.ptrs = append(a.ptrs, p)
	}
	return p
}

func (a *cArena) free() {
	for _, p := range a.ptrs {
		C.free(p)
	}
	a.ptrs = nil
}

// bytes copies a Go slice into malloc'd C memory (NULL for an empty slice).
func (a *cArena) bytes(b []byte) *C.uint8_t {
	if len(b) == 0 {
		return nil
	}
	return (*C.uint8_t)(a.track(C.CBytes(b)))
}

// str copies a Go string into a malloc'd C string.
func (a *cArena) str(s string) *C.char {
	return (*C.char)(a.track(unsafe.Pointer(C.CString(s))))
}

// int32Array copies a Go []int32 into a malloc'd C int32_t array, returning the
// base pointer + count (NULL/0 for an empty slice). Used for the enabled-bands and
// SCAMIN-manifest inputs to tile57_build_style.
func (a *cArena) int32Array(v []int32) (*C.int32_t, C.size_t) {
	n := len(v)
	if n == 0 {
		return nil, 0
	}
	p := (*C.int32_t)(a.track(C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.int32_t(0))))))
	s := unsafe.Slice(p, n)
	for i, x := range v {
		s[i] = C.int32_t(x)
	}
	return p, C.size_t(n)
}

