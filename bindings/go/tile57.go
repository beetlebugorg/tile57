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
// The pipeline mirrors the C header: bake ENC cells to per-cell PMTiles
// ([BakeCell] / [BakeTree]), open each archive as a [Source] ([Open] /
// [OpenBytes]) for metadata, and compose the open charts into one seamless tile
// pyramid with [OpenCompose] / [OpenComposeCharts] for serving. Raw S-57 reading
// (cell inventory, feature extraction, catalogue decode) is handle-free — see
// [Cells], [Features], [FeaturesBytes], [CatalogEntries].
//
// libtile57 is NOT internally synchronized, so every call into a handle is
// guarded by a mutex.
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

// Version returns the libtile57 version string (e.g. "0.2.0").
func Version() string { return C.GoString(C.tile57_version()) }

// statusError turns a non-OK tile57_status (with the optional tile57_error the
// call filled) into a Go error that wraps the matching category sentinel, so a
// host can branch with errors.Is while the message stays specific (often
// "path: reason"). Returns nil for TILE57_OK.
func statusError(st C.tile57_status, cerr *C.tile57_error) error {
	if st == C.TILE57_OK {
		return nil
	}
	msg := ""
	if cerr != nil {
		msg = C.GoString(&cerr.message[0])
	}
	if msg == "" {
		msg = C.GoString(C.tile57_status_str(st))
	}
	var sentinel error
	switch st {
	case C.TILE57_ERR_BADARG:
		sentinel = ErrBadArg
	case C.TILE57_ERR_IO:
		sentinel = ErrIO
	case C.TILE57_ERR_PARSE:
		sentinel = ErrParse
	case C.TILE57_ERR_NOMEM:
		sentinel = ErrNoMem
	case C.TILE57_ERR_UNSUPPORTED:
		sentinel = ErrUnsupported
	case C.TILE57_ERR_RENDER:
		sentinel = ErrRender
	default:
		sentinel = ErrInternal
	}
	return fmt.Errorf("%s (%w)", msg, sentinel)
}

// TileFormat is a tile encoding (tile57_tile_type). The zero value means "the
// engine default" (MLT).
type TileFormat uint8

const (
	FormatDefault TileFormat = 0                      // engine default (MLT)
	FormatMVT     TileFormat = C.TILE57_TILE_TYPE_MVT // Mapbox Vector Tile
	FormatMLT     TileFormat = C.TILE57_TILE_TYPE_MLT // MapLibre Tile (the default bake format)
)

// Encoding returns the MapLibre vector-source `encoding` value for the format
// ("mlt" or "mvt") — the hint a host puts on its style sources / TileJSON so
// maplibre-gl (>=5.12) picks the matching decoder.
func (f TileFormat) Encoding() string {
	if f == FormatMLT {
		return "mlt"
	}
	return "mvt"
}

// Meta is a chart source's display metadata — the shape a host tile server needs to
// publish a TileJSON: zoom range, geographic bounds (degrees), whether tile bodies
// are gzip-compressed (always false here — tile57 serves decompressed tiles), the
// distinct SCAMIN denominators present (see [Source.Scamin]), and the tile encoding
// ("mvt" or "mlt" — the TileJSON/style `encoding` hint). A host with its own
// metadata type copies these fields across.
type Meta struct {
	MinZoom, MaxZoom uint8
	W, S, E, N       float64  // lon/lat bounds (degrees)
	Gzipped          bool     // tile bodies gzip-compressed (always false for tile57)
	Scamin           []uint32 // distinct SCAMIN denominators present (ascending)
	TileType         string   // "mvt" | "mlt" — the archive's stored encoding
}

// Source is an open libtile57 chart: ONE baked PMTiles archive. Construct it with
// [Open] (mmap'd path) or [OpenBytes] (copied); release it with [Source.Close]. It
// is safe for concurrent use: the underlying handle is not thread-safe, so calls
// are serialized internally.
type Source struct {
	mu     sync.Mutex
	ptr    *C.tile57
	scamin []uint32 // cached SCAMIN manifest (resolved once on first use)
	scaminDone bool
}

// Open opens a baked PMTiles archive from a file path, mmap'd — a whole chart
// library can be open without being resident. The file must stay in place while
// the Source is open.
func Open(path string) (*Source, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: empty path: %w", ErrEmptyInput)
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	var ptr *C.tile57
	var cerr C.tile57_error
	if st := C.tile57_open(cPath, &ptr, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return &Source{ptr: ptr}, nil
}

// OpenBytes opens a baked PMTiles archive from in-memory bytes (e.g. straight from
// [BakeCell], before any file exists). Bytes are copied.
func OpenBytes(pmtiles []byte) (*Source, error) {
	if len(pmtiles) == 0 {
		return nil, fmt.Errorf("tile57: empty archive bytes: %w", ErrEmptyInput)
	}
	var ptr *C.tile57
	var cerr C.tile57_error
	if st := C.tile57_open_bytes((*C.uint8_t)(unsafe.Pointer(&pmtiles[0])), C.size_t(len(pmtiles)), &ptr, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return &Source{ptr: ptr}, nil
}

// ChartInfo is a chart's fixed metadata — zoom range, bands, bounds, a good
// initial camera, the archive's tile encoding, and the compilation scale the bake
// embedded. HasBounds/HasAnchor guard the respective fields.
type ChartInfo struct {
	MinZoom, MaxZoom                 uint8
	Bands                            uint32
	HasBounds                        bool
	West, South, East, North         float64
	HasAnchor                        bool
	AnchorLat, AnchorLon, AnchorZoom float64
	// TileType is the archive's stored encoding (FormatMVT or FormatMLT).
	TileType TileFormat
	// NativeScale is the compilation scale (1:N) embedded by the per-cell bake;
	// 0 = unknown (a composed/foreign archive — derive from the zoom band).
	NativeScale int32
}

// Info returns the chart's fixed metadata in one call.
func (s *Source) Info() ChartInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ci C.tile57_info
	C.tile57_get_info(s.ptr, &ci)
	return ChartInfo{
		MinZoom: uint8(ci.min_zoom), MaxZoom: uint8(ci.max_zoom),
		Bands:     uint32(ci.bands),
		HasBounds: bool(ci.has_bounds),
		West:      float64(ci.west), South: float64(ci.south), East: float64(ci.east), North: float64(ci.north),
		HasAnchor: bool(ci.has_anchor),
		AnchorLat: float64(ci.anchor_lat), AnchorLon: float64(ci.anchor_lon), AnchorZoom: float64(ci.anchor_zoom),
		TileType:    TileFormat(ci.tile_type),
		NativeScale: int32(ci.native_scale),
	}
}

// Meta reports the source's display metadata (zoom range, bounds, SCAMIN manifest).
// tile57 serves decompressed tiles, so Gzipped is always false. Bounds fall back to
// the world extent when the archive reports none.
func (s *Source) Meta() Meta {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := Meta{W: -180, S: -85, E: 180, N: 85}
	if s.ptr == nil {
		return m
	}
	var ci C.tile57_info
	C.tile57_get_info(s.ptr, &ci)
	m.MinZoom, m.MaxZoom = uint8(ci.min_zoom), uint8(ci.max_zoom)
	if bool(ci.has_bounds) {
		m.W, m.S, m.E, m.N = float64(ci.west), float64(ci.south), float64(ci.east), float64(ci.north)
	}
	m.TileType = TileFormat(ci.tile_type).Encoding()
	m.Scamin = s.scaminLocked()
	return m
}

// Scamin returns the distinct SCAMIN denominators present in the source (the live
// SCAMIN manifest, ascending, from the archive metadata), so the client builds one
// native fractional-minzoom bucket layer per value. Cached after the first call.
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
	var cerr C.tile57_error
	if C.tile57_scamin(s.ptr, &out, &n, &cerr) == C.TILE57_OK && out != nil && n > 0 {
		vals := unsafe.Slice(out, int(n))
		res := make([]uint32, n)
		for i, v := range vals {
			res[i] = uint32(v)
		}
		C.tile57_free(unsafe.Pointer(out), n*C.size_t(unsafe.Sizeof(C.int32_t(0))))
		s.scamin = res
	}
	return s.scamin
}

// Close releases the source and all cached tiles. It is idempotent. Per the ABI's
// lifetime rule, callers must not Close while any borrower (a compositor built
// over this Source, a goroutine mid-call) can still read from it.
func (s *Source) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr != nil {
		C.tile57_close(s.ptr)
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
	C.tile57_free(unsafe.Pointer(p), n)
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
