//go:build cgo

package tile57

/*
#include "tile57.h"

// Trampoline: the C ring callback calls back into this exported Go function.
// (cgo exports can't carry const, so the helper casts to the header's type.)
extern void tile57GoCoverageRing(void *ctx, double *lonlat, size_t npts);

// Build the callback table C-side so no C function pointer crosses into Go.
static tile57_status t57CoverageGo(tile57 *chart, void *handle, tile57_error *err) {
	tile57_coverage_cb cb = {handle, (void (*)(void *, const double *, size_t))tile57GoCoverageRing};
	return tile57_coverage(chart, &cb, err);
}
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

//export tile57GoCoverageRing
func tile57GoCoverageRing(ctx unsafe.Pointer, lonlat *C.double, npts C.size_t) {
	rings, ok := cgo.Handle(uintptr(ctx)).Value().(*[][][2]float64)
	if !ok || npts == 0 {
		return
	}
	pts := unsafe.Slice(lonlat, int(npts)*2)
	ring := make([][2]float64, int(npts))
	for i := range ring {
		ring[i] = [2]float64{float64(pts[2*i]), float64(pts[2*i+1])}
	}
	*rings = append(*rings, ring)
}

// Coverage returns the chart's M_COVR data-coverage polygons (one exterior ring
// per polygon, lon/lat points) from the coverage the bake embedded in the archive
// metadata — the real coverage a host reports so a quilt fills gaps to coarser
// cells. Nil when the archive embeds none (a composed/foreign archive).
func (s *Source) Coverage() ([][][2]float64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, ErrSourceClosed
	}
	var rings [][][2]float64
	h := cgo.NewHandle(&rings)
	defer h.Delete()
	var cerr C.tile57_error
	if st := C.t57CoverageGo(s.ptr, unsafe.Pointer(h), &cerr); st != C.TILE57_OK { //nolint:govet // cgo.Handle as void* ctx
		return nil, statusError(st, &cerr)
	}
	return rings, nil
}
