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

// cellInputs builds a C tile57_cell_input array from cells. Returns the typed Go
// view (for length bookkeeping) and the base pointer to hand to C.
func (a *cArena) cellInputs(cells []CellInput) ([]C.tile57_cell_input, *C.tile57_cell_input) {
	n := len(cells)
	base := (*C.tile57_cell_input)(a.track(C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.tile57_cell_input{})))))
	inputs := unsafe.Slice(base, n)
	for i, c := range cells {
		in := &inputs[i]
		in.base = a.bytes(c.Base)
		in.base_len = C.size_t(len(c.Base))
		in.updates = nil
		in.update_lens = nil
		in.update_count = 0
		in.name = nil
		if c.Name != "" {
			in.name = a.str(c.Name)
		}
		if m := len(c.Updates); m > 0 {
			updPtrs := (**C.uint8_t)(a.track(C.malloc(C.size_t(m) * C.size_t(unsafe.Sizeof((*C.uint8_t)(nil))))))
			updLens := (*C.size_t)(a.track(C.malloc(C.size_t(m) * C.size_t(unsafe.Sizeof(C.size_t(0))))))
			ps := unsafe.Slice(updPtrs, m)
			ls := unsafe.Slice(updLens, m)
			for j, u := range c.Updates {
				ps[j] = a.bytes(u)
				ls[j] = C.size_t(len(u))
			}
			in.updates = updPtrs
			in.update_lens = updLens
			in.update_count = C.size_t(m)
		}
	}
	return inputs, base
}

// namedBytes builds a C tile57_named_bytes array (id + bytes) from items.
func (a *cArena) namedBytes(items []NamedBytes) (*C.tile57_named_bytes, C.size_t) {
	n := len(items)
	if n == 0 {
		return nil, 0
	}
	base := (*C.tile57_named_bytes)(a.track(C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.tile57_named_bytes{})))))
	arr := unsafe.Slice(base, n)
	for i, it := range items {
		arr[i].id = a.str(it.ID)
		arr[i].data = a.bytes(it.Data)
		arr[i].len = C.size_t(len(it.Data))
	}
	return base, C.size_t(n)
}
