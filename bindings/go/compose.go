//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"
)

// ComposeSource is a resident runtime compositor: the per-cell PMTiles held mmap'd and the
// ownership partition loaded once, so Serve composes any tile on demand (byte-faithful to the
// batch ComposeFiles). It is the on-demand counterpart of ComposeFiles — for a live tile server
// rather than producing a full archive. Serve is serialised by an internal mutex (the underlying
// per-reader leaf cache is not safe for concurrent access).
type ComposeSource struct {
	mu  sync.Mutex
	ptr *C.tile57_compose_source
}

// ComposeMeta is a ComposeSource's served zoom range + union coverage bounds (degrees).
type ComposeMeta struct {
	MinZoom, MaxZoom          uint8
	Cells                     uint32
	West, South, East, North  float64
}

// OpenCompose opens a resident compositor over the per-cell PMTiles at paths (each written by
// [BakeCell] / `tile57 compose --keep-cells`), mmap'd so the cell set is never fully resident. If
// partitionPath is non-empty it names a partition sidecar (from `tile57 compose --save-partition`)
// to load and skip the owned-face build; a missing/stale one falls back to building. Close it when
// done — callers must not Close while any goroutine can still call Serve.
func OpenCompose(paths []string, partitionPath string) (*ComposeSource, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("tile57: OpenCompose needs at least one path: %w", ErrEmptyInput)
	}
	var ar cArena
	defer ar.free()
	// A C array of C strings — pointer-free from Go's view (cgocheck-safe).
	cpaths := (**C.char)(ar.track(C.malloc(C.size_t(len(paths)) * C.size_t(unsafe.Sizeof((*C.char)(nil))))))
	pv := unsafe.Slice(cpaths, len(paths))
	for i, p := range paths {
		pv[i] = ar.str(p)
	}
	var cpart *C.char
	if partitionPath != "" {
		cpart = ar.str(partitionPath)
	}
	var ptr *C.tile57_compose_source
	var cerr C.tile57_error
	if st := C.tile57_compose_open(cpaths, C.size_t(len(paths)), cpart, &ptr, &cerr); st != C.TILE57_OK {
		// No coverage-carrying archive is reported as TILE57_ERR_PARSE; surface it
		// as ErrNoCoverage so a host can branch, keeping the specific message.
		if st == C.TILE57_ERR_PARSE {
			return nil, fmt.Errorf("%s: %w", C.GoString(&cerr.message[0]), ErrNoCoverage)
		}
		return nil, statusError(st, &cerr)
	}
	return &ComposeSource{ptr: ptr}, nil
}

// Serve composes the tile (z,x,y) on demand, returning raw (decompressed) MLT bytes plus `owned` —
// whether the ownership partition says a cell SHOULD render here. body!=nil → served (owned). body
// ==nil && owned → a cell owns this ground but produced nothing (transient while its per-cell bake
// runs; an error state once bakes are done). body==nil && !owned → true empty ocean (safe to cache).
// Thread-safe (serialised).
func (c *ComposeSource) Serve(z uint8, x, y uint32) (body []byte, owned bool, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return nil, false, fmt.Errorf("tile57: Serve on a closed ComposeSource")
	}
	var out *C.uint8_t
	var outLen C.size_t
	rc := C.tile57_compose_serve(c.ptr, C.uint8_t(z), C.uint32_t(x), C.uint32_t(y), &out, &outLen)
	switch rc {
	case 1:
		return tileBytes(out, outLen), true, nil // served (content implies owned)
	case 2:
		return nil, true, nil // owned but empty
	case 0:
		return nil, false, nil // not owned — true empty
	default:
		return nil, false, fmt.Errorf("tile57: compose serve failed at %d/%d/%d", z, x, y)
	}
}

// Meta returns the compositor's served zoom range + union coverage bounds.
func (c *ComposeSource) Meta() ComposeMeta {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return ComposeMeta{}
	}
	var m C.tile57_compose_meta
	C.tile57_compose_meta_get(c.ptr, &m)
	return ComposeMeta{
		MinZoom: uint8(m.min_zoom),
		MaxZoom: uint8(m.max_zoom),
		Cells:   uint32(m.cells),
		West:    float64(m.west),
		South:   float64(m.south),
		East:    float64(m.east),
		North:   float64(m.north),
	}
}

// SavePartition serializes the resident ownership partition to path — a sidecar a later
// OpenCompose can load (as partitionPath) to skip the owned-face build.
func (c *ComposeSource) SavePartition(path string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return fmt.Errorf("tile57: SavePartition on a closed ComposeSource")
	}
	var ar cArena
	defer ar.free()
	if C.tile57_compose_save_partition(c.ptr, ar.str(path)) != 1 {
		return fmt.Errorf("tile57: SavePartition to %q failed", path)
	}
	return nil
}

// Close releases the compositor (munmaps the archives, frees the partition). Idempotent.
func (c *ComposeSource) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr != nil {
		C.tile57_compose_close(c.ptr)
		c.ptr = nil
	}
	return nil
}
