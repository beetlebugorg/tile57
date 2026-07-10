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

// ComposeSource is a resident runtime compositor over open charts: the ownership
// partition loaded once, so Tile composes any tile on demand. It BORROWS its
// charts — they must outlive it — except charts opened for it by [OpenCompose],
// which it owns and closes. Tile is serialised by an internal mutex (the
// compositor reads through the charts, which are not thread-safe).
type ComposeSource struct {
	mu    sync.Mutex
	ptr   *C.tile57_compose
	owned []*Source // charts OpenCompose opened for us; closed on Close
}

// ComposeMeta is a ComposeSource's served zoom range + union coverage bounds (degrees).
type ComposeMeta struct {
	MinZoom, MaxZoom         uint8
	Cells                    uint32
	West, South, East, North float64
}

// OpenComposeCharts opens a resident compositor over already-open charts,
// BORROWING them: every chart must outlive the compositor (Close the compositor
// first), and while it serves, don't call those charts' own methods from other
// goroutines. Charts whose archives embed no coverage are skipped; if none
// carries coverage the open fails with ErrNoCoverage. If partitionPath is
// non-empty it names a partition sidecar (from [ComposeSource.SavePartition]; the
// `tile57 bake` CLI writes partition.tpart) to load and skip the owned-face
// build; a missing/stale one falls back to building.
func OpenComposeCharts(charts []*Source, partitionPath string) (*ComposeSource, error) {
	if len(charts) == 0 {
		return nil, fmt.Errorf("tile57: OpenComposeCharts needs at least one chart: %w", ErrEmptyInput)
	}
	var ar cArena
	defer ar.free()
	// A C array of chart handles — pointer-free from Go's view (cgocheck-safe).
	cc := (**C.tile57)(ar.track(C.malloc(C.size_t(len(charts)) * C.size_t(unsafe.Sizeof((*C.tile57)(nil))))))
	cv := unsafe.Slice(cc, len(charts))
	for i, s := range charts {
		if s == nil || s.ptr == nil {
			return nil, fmt.Errorf("tile57: OpenComposeCharts: chart %d is nil/closed: %w", i, ErrEmptyInput)
		}
		cv[i] = s.ptr
	}
	var cpart *C.char
	if partitionPath != "" {
		cpart = ar.str(partitionPath)
	}
	var ptr *C.tile57_compose
	var cerr C.tile57_error
	if st := C.tile57_compose_open(cc, C.size_t(len(charts)), cpart, &ptr, &cerr); st != C.TILE57_OK {
		// "No coverage-carrying chart" is TILE57_ERR_UNSUPPORTED; surface it as
		// ErrNoCoverage so a host can branch, keeping the specific message.
		if st == C.TILE57_ERR_UNSUPPORTED {
			return nil, fmt.Errorf("%s: %w", C.GoString(&cerr.message[0]), ErrNoCoverage)
		}
		return nil, statusError(st, &cerr)
	}
	return &ComposeSource{ptr: ptr}, nil
}

// OpenCompose opens a resident compositor over the per-cell PMTiles at paths (each
// written by [BakeCell] / [BakeTree]): every path is opened as a chart (mmap'd, so
// the cell set is never fully resident) and the compositor OWNS those charts —
// Close releases them too. See [OpenComposeCharts] to compose over charts you
// keep. partitionPath as in OpenComposeCharts.
func OpenCompose(paths []string, partitionPath string) (*ComposeSource, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("tile57: OpenCompose needs at least one path: %w", ErrEmptyInput)
	}
	charts := make([]*Source, 0, len(paths))
	closeAll := func() {
		for _, s := range charts {
			_ = s.Close()
		}
	}
	for _, p := range paths {
		s, err := Open(p)
		if err != nil {
			closeAll()
			return nil, fmt.Errorf("tile57: OpenCompose: %w", err)
		}
		charts = append(charts, s)
	}
	cs, err := OpenComposeCharts(charts, partitionPath)
	if err != nil {
		closeAll()
		return nil, err
	}
	cs.owned = charts
	return cs, nil
}

// Tile composes the tile (z,x,y) on demand, returning raw (decompressed) MLT bytes plus `owned` —
// whether the ownership partition says a cell SHOULD render here. body!=nil → composed (owned). body
// ==nil && owned → a cell owns this ground but produced nothing (transient while its per-cell bake
// runs; an error state once bakes are done). body==nil && !owned → true empty ocean (safe to cache).
// Thread-safe (serialised).
func (c *ComposeSource) Tile(z uint8, x, y uint32) (body []byte, owned bool, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return nil, false, fmt.Errorf("tile57: Tile on a closed ComposeSource")
	}
	var out *C.uint8_t
	var outLen C.size_t
	var cowned C.bool
	var cerr C.tile57_error
	if st := C.tile57_compose_tile(c.ptr, C.uint8_t(z), C.uint32_t(x), C.uint32_t(y), &out, &outLen, &cowned, &cerr); st != C.TILE57_OK {
		return nil, false, statusError(st, &cerr)
	}
	if out == nil {
		return nil, bool(cowned), nil
	}
	return tileBytes(out, outLen), true, nil
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
// compose open can load (as partitionPath) to skip the owned-face build.
func (c *ComposeSource) SavePartition(path string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return fmt.Errorf("tile57: SavePartition on a closed ComposeSource")
	}
	var ar cArena
	defer ar.free()
	var cerr C.tile57_error
	if st := C.tile57_compose_save_partition(c.ptr, ar.str(path), &cerr); st != C.TILE57_OK {
		return statusError(st, &cerr)
	}
	return nil
}

// Close releases the compositor, then any charts [OpenCompose] opened for it.
// Borrowed charts (from [OpenComposeCharts]) stay open. Idempotent.
func (c *ComposeSource) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr != nil {
		C.tile57_compose_close(c.ptr)
		c.ptr = nil
	}
	for _, s := range c.owned {
		_ = s.Close()
	}
	c.owned = nil
	return nil
}
