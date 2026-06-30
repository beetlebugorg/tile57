//go:build cgo

// Package tile57 is the canonical Go binding to libtile57 — the native Zig
// "tile57" chart engine (this repo, chartplotter-native). It ships WITH the engine
// (bindings/go) so it tracks the C ABI in <tile57.h> as the ABI evolves; a host
// imports it and works in Go only, never touching cgo, the header, or the Zig build.
//
// Requirements: CGO (CGO_ENABLED=1) and the static library. Build it once from the
// repo root with `zig build`, producing zig-out/lib/libtile57.a — the cgo directives
// below link it by a path relative to this package, so an importing module needs a
// `replace` pointing at a local checkout (see this package's README).
//
// A [Source] opens a PMTiles archive or one-or-more raw S-57 cells and serves
// decompressed Mapbox Vector Tiles by (z, x, y); its method set (Tile, Meta,
// ZoomRange, Bounds, …) satisfies a host's tile-source interface directly. libtile57
// is NOT internally synchronized, so every call into a Source is guarded by a mutex.
package tile57

/*
#cgo CFLAGS: -I${SRCDIR}/../../include
#cgo LDFLAGS: ${SRCDIR}/../../zig-out/lib/libtile57.a -lm -lpthread
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"
)

// Format selects (or reports) a Source's on-disk backend.
type Format int

const (
	FormatAuto    Format = C.TILE57_FORMAT_AUTO     // sniff PMTiles then S-57
	FormatPMTiles Format = C.TILE57_FORMAT_PMTILES  // a PMTiles archive
	FormatS57Cell Format = C.TILE57_FORMAT_S57_CELL // a raw S-57 ENC cell
)

// Version returns the libtile57 version string (e.g. "0.1.0").
func Version() string { return C.GoString(C.tile57_version()) }

// Meta is a chart source's display metadata — the shape a host tile server needs to
// publish a TileJSON: zoom range, geographic bounds (degrees), whether tile bodies
// are gzip-compressed (always false here — tile57 serves decompressed MVT), and the
// distinct SCAMIN denominators present (the live SCAMIN manifest; see [Source.Scamin]).
// A host with its own metadata type copies these fields across.
type Meta struct {
	MinZoom, MaxZoom uint8
	W, S, E, N       float64  // lon/lat bounds (degrees)
	Gzipped          bool     // tile bodies gzip-compressed (always false for tile57)
	Scamin           []uint32 // distinct SCAMIN denominators present (ascending)
}

// Source is an open libtile57 chart tile source. Construct it with [OpenBytes] or
// [OpenCells]; release it with [Source.Close]. It is safe for concurrent use: the
// underlying handle is not thread-safe, so calls are serialized internally.
type Source struct {
	mu  sync.Mutex
	ptr *C.tile57_source
	// scamin caches the SCAMIN manifest — for a cell/ENC_ROOT source the ABI scans
	// every cell's features to compute it, so it is resolved once on first use.
	scamin     []uint32
	scaminDone bool
}

// CellInput is one ENC cell for [OpenCells] / [BakeCells]: the base .000 bytes
// plus its sequential update files (.001, .002, … in order).
type CellInput struct {
	Base    []byte
	Updates [][]byte
	// Name is the source cell name (e.g. "US4MD81M"), emitted as the `cell`
	// pick-report property on every feature from this cell. "" = omit it.
	Name string
}

// OpenBytes opens a tile source from in-memory bytes (a PMTiles archive or a raw
// S-57 cell). rulesDir overrides the S-101 portrayal rules directory (used only
// for S-57 cells); "" selects the built-in default. The bytes are copied.
func OpenBytes(data []byte, format Format, rulesDir string) (*Source, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("tile57: empty source bytes")
	}
	cRules, freeRules := cStringOrNil(rulesDir)
	defer freeRules()
	ptr := C.tile57_source_open(
		(*C.uint8_t)(unsafe.Pointer(&data[0])), C.size_t(len(data)),
		C.tile57_format(format), cRules)
	if ptr == nil {
		return nil, fmt.Errorf("tile57: failed to open source (%d bytes)", len(data))
	}
	return &Source{ptr: ptr}, nil
}

// OpenCells opens an ENC_ROOT as a multi-cell source: every cell is overlaid when
// a tile is generated, so a region spanning several cells renders them all. All
// bytes are copied. rulesDir is as in [OpenBytes]. omitPickAttrs drops the
// per-feature pick-report properties (class/cell/s57) when true; pass false to keep
// them (the default — a working cursor-pick report).
func OpenCells(cells []CellInput, rulesDir string, omitPickAttrs bool) (*Source, error) {
	if len(cells) == 0 {
		return nil, fmt.Errorf("tile57: no cells")
	}
	cRules, freeRules := cStringOrNil(rulesDir)
	defer freeRules()

	// Build the C cell array entirely in C memory (CBytes / malloc), so the array
	// passed to C holds only C pointers — Go pointers in C-passed memory would trip
	// cgocheck. libtile57 copies everything during the call, so we free it after.
	arena := &cArena{}
	defer arena.free()
	inputs, base := arena.cellInputs(cells)
	ptr := C.tile57_source_open_cells(base, C.size_t(len(inputs)), cRules, cOmit(omitPickAttrs))
	if ptr == nil {
		return nil, fmt.Errorf("tile57: failed to open %d cell(s)", len(cells))
	}
	return &Source{ptr: ptr}, nil
}

// Tile fetches tile (z, x, y) as decompressed MVT bytes. (nil, nil) means a blank
// tile (valid but empty) — the TileSource "no tile here" convention.
func (s *Source) Tile(z uint8, x, y uint32) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, fmt.Errorf("tile57: source closed")
	}
	var out *C.uint8_t
	var outLen C.size_t
	st := C.tile57_tile_get(s.ptr, C.uint8_t(z), C.uint32_t(x), C.uint32_t(y), &out, &outLen)
	switch st {
	case C.TILE57_TILE_OK:
		return tileBytes(out, outLen), nil
	case C.TILE57_TILE_EMPTY:
		return nil, nil
	default:
		return nil, fmt.Errorf("tile57: tile %d/%d/%d generation error", z, x, y)
	}
}

// Meta reports the source's display metadata (zoom range, bounds, SCAMIN manifest).
// tile57 serves decompressed MVT, so Gzipped is always false. Bounds fall back to the
// world extent when libtile57 reports them as degenerate/near-global. The SCAMIN
// manifest is resolved (and cached) here — for a cell/ENC_ROOT source that scans
// every cell once, so the first Meta call on a large set does real work.
func (s *Source) Meta() Meta {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := Meta{W: -180, S: -85, E: 180, N: 85}
	if s.ptr == nil {
		return m
	}
	var mn, mx C.uint8_t
	C.tile57_source_zoom_range(s.ptr, &mn, &mx)
	m.MinZoom, m.MaxZoom = uint8(mn), uint8(mx)
	var w, so, e, n C.double
	if bool(C.tile57_source_bounds(s.ptr, &w, &so, &e, &n)) {
		m.W, m.S, m.E, m.N = float64(w), float64(so), float64(e), float64(n)
	}
	m.Scamin = s.scaminLocked()
	return m
}

// Scamin returns the distinct SCAMIN denominators present in the source (the live
// SCAMIN manifest, ascending), so the client builds one native fractional-minzoom
// bucket layer per value. Cached: a cell/ENC_ROOT source scans every cell's
// features to compute it.
func (s *Source) Scamin() []uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.scaminLocked()
}

// scaminLocked computes (once) and returns the cached SCAMIN manifest. The caller
// must hold s.mu.
func (s *Source) scaminLocked() []uint32 {
	if s.scaminDone || s.ptr == nil {
		return s.scamin
	}
	s.scaminDone = true
	var out *C.int32_t
	var n C.size_t
	if C.tile57_source_scamin(s.ptr, &out, &n) == 1 && out != nil && n > 0 {
		vals := unsafe.Slice(out, int(n))
		res := make([]uint32, n)
		for i, v := range vals {
			res[i] = uint32(v)
		}
		C.tile57_tile_free((*C.uint8_t)(unsafe.Pointer(out)), n*C.size_t(unsafe.Sizeof(C.int32_t(0))))
		s.scamin = res
	}
	return s.scamin
}

// ZoomRange reports the min/max zoom the source serves.
func (s *Source) ZoomRange() (min, max uint8) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return 0, 0
	}
	var mn, mx C.uint8_t
	C.tile57_source_zoom_range(s.ptr, &mn, &mx)
	return uint8(mn), uint8(mx)
}

// Bands is a bitmask of the navigational bands present (bit r = band rank r has a
// cell; 0=berthing/finest .. 5=overview/coarsest). 0 for a single cell / PMTiles.
func (s *Source) Bands() uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return 0
	}
	return uint32(C.tile57_source_bands(s.ptr))
}

// Bounds reports the source's geographic extent (west, south, east, north in
// degrees); ok is false when libtile57 reports a degenerate/near-global extent
// (the caller should then choose its own camera).
func (s *Source) Bounds() (west, south, east, north float64, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return 0, 0, 0, 0, false
	}
	var w, so, e, n C.double
	ok = bool(C.tile57_source_bounds(s.ptr, &w, &so, &e, &n))
	return float64(w), float64(so), float64(e), float64(n), ok
}

// Anchor returns a good initial camera (center lat/lon + zoom) for a lazy
// ENC_ROOT source where fitting the whole extent would zoom out uselessly; ok is
// false when the caller should fit-to-bounds instead.
func (s *Source) Anchor() (lat, lon, zoom float64, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return 0, 0, 0, false
	}
	var la, lo, z C.double
	ok = bool(C.tile57_source_anchor(s.ptr, &la, &lo, &z))
	return float64(la), float64(lo), float64(z), ok
}

// Format reports the resolved backend (meaningful after a FormatAuto open).
func (s *Source) Format() Format {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return FormatAuto
	}
	return Format(C.tile57_source_format(s.ptr))
}

// ClearCache drops the in-memory tile cache to bound memory in long-running hosts.
func (s *Source) ClearCache() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr != nil {
		C.tile57_source_clear_cache(s.ptr)
	}
}

// Close releases the source and all cached tiles. It is idempotent. Per the ABI's
// lifetime rule, callers must not Close while any goroutine can still call Tile;
// the server Closes a set only after deregistering it.
func (s *Source) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr != nil {
		C.tile57_source_close(s.ptr)
		s.ptr = nil
	}
	return nil
}

// tileBytes copies a libtile57-owned (uint8_t*, size_t) buffer into Go memory and
// frees the C buffer with the matching length.
func tileBytes(p *C.uint8_t, n C.size_t) []byte {
	if p == nil {
		return nil
	}
	var b []byte
	if n > 0 {
		b = C.GoBytes(unsafe.Pointer(p), C.int(n))
	}
	C.tile57_tile_free(p, n)
	return b
}

// cStringOrNil returns a C string (or NULL for "") and a free function.
func cStringOrNil(s string) (*C.char, func()) {
	if s == "" {
		return nil, func() {}
	}
	c := C.CString(s)
	return c, func() { C.free(unsafe.Pointer(c)) }
}
