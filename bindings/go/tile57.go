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
// A [Source] opens a path, in-memory ENC cell, or baked PMTiles bundle and serves
// decompressed Mapbox Vector Tiles by (z, x, y); its method set (Tile, Info, Meta,
// Scamin, …) satisfies a host's tile-source interface directly. libtile57
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

// Version returns the libtile57 version string (e.g. "0.1.0").
func Version() string { return C.GoString(C.tile57_version()) }

// TileFormat is a tile encoding (tile57_tile_type / tile57_bake_opts.format).
// The zero value means "the engine default" (MLT) in bake options.
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
// distinct SCAMIN denominators present (the live SCAMIN manifest; see [Source.Scamin]),
// and the tile encoding Tile returns ("mvt" or "mlt" — the TileJSON/style `encoding`
// hint). A host with its own metadata type copies these fields across.
type Meta struct {
	MinZoom, MaxZoom uint8
	W, S, E, N       float64  // lon/lat bounds (degrees)
	Gzipped          bool     // tile bodies gzip-compressed (always false for tile57)
	Scamin           []uint32 // distinct SCAMIN denominators present (ascending)
	TileType         string   // "mvt" | "mlt" — the encoding Tile returns
}

// Source is an open libtile57 chart. Construct it with [Open], [OpenChartBytes], or
// [OpenPMTiles]; release it with [Source.Close]. It is safe for concurrent use: the
// underlying handle is not thread-safe, so calls are serialized internally.
type Source struct {
	mu  sync.Mutex
	ptr *C.tile57_chart
	// scamin caches the SCAMIN manifest — for a cell/ENC_ROOT source the ABI scans
	// every cell's features to compute it, so it is resolved once on first use.
	scamin     []uint32
	scaminDone bool
}

// Cell is one ENC cell for [BakePmtiles]: the base .000 bytes
// plus its sequential update files (.001, .002, … in order).
type Cell struct {
	Base    []byte
	Updates [][]byte
	// Name is the source cell name (e.g. "US4MD81M"), emitted as the `cell`
	// pick-report property on every feature from this cell. "" = omit it.
	Name string
}

// Open opens an on-disk ENC_ROOT directory (or a single .000 file) as a STREAMING
// chart: the engine enumerates + peeks the cells at open, then reads cell bytes on
// demand (working set only), so memory tracks what tiles need rather than the whole
// ENC_ROOT. Rules are the library's embedded catalogue. (chart-api.md)
func Open(path string) (*Source, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: empty path: %w", ErrEmptyInput)
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	ptr := C.tile57_chart_open(cPath)
	if ptr == nil {
		return nil, fmt.Errorf("tile57: failed to open chart at %q", path)
	}
	return &Source{ptr: ptr}, nil
}

// OpenChartBytes opens one in-memory ENC cell (base .000 bytes) as a resident chart.
// Bytes are copied. (chart-api.md)
func OpenChartBytes(base []byte) (*Source, error) {
	if len(base) == 0 {
		return nil, fmt.Errorf("tile57: empty cell bytes: %w", ErrEmptyInput)
	}
	ptr := C.tile57_chart_open_bytes((*C.uint8_t)(unsafe.Pointer(&base[0])), C.size_t(len(base)))
	if ptr == nil {
		return nil, fmt.Errorf("tile57: failed to open cell (%d bytes)", len(base))
	}
	return &Source{ptr: ptr}, nil
}

// OpenPMTiles opens a baked PMTiles bundle from a file path. (chart-api.md)
func OpenPMTiles(path string) (*Source, error) {
	if path == "" {
		return nil, fmt.Errorf("tile57: empty path: %w", ErrEmptyInput)
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	ptr := C.tile57_chart_open_pmtiles(cPath)
	if ptr == nil {
		return nil, fmt.Errorf("tile57: failed to open pmtiles at %q", path)
	}
	return &Source{ptr: ptr}, nil
}

// ChartInfo is a chart's fixed metadata (chart-api.md) — zoom range, bands, bounds,
// a good initial camera, and the tile encoding Tile returns. HasBounds/HasAnchor
// guard the respective fields.
type ChartInfo struct {
	MinZoom, MaxZoom                 uint8
	Bands                            uint32
	HasBounds                        bool
	West, South, East, North         float64
	HasAnchor                        bool
	AnchorLat, AnchorLon, AnchorZoom float64
	// TileType is the encoding Tile returns (FormatMVT or FormatMLT): a PMTiles-
	// backed source reports its archive's stored type; a cell-backed source its
	// live generation format (see [Source.SetTileFormat]).
	TileType TileFormat
}

// Info returns the chart's fixed metadata in one call.
func (s *Source) Info() ChartInfo {
	var ci C.tile57_chart_info
	C.tile57_chart_get_info(s.ptr, &ci)
	return ChartInfo{
		MinZoom: uint8(ci.min_zoom), MaxZoom: uint8(ci.max_zoom),
		Bands:     uint32(ci.bands),
		HasBounds: bool(ci.has_bounds),
		West:      float64(ci.west), South: float64(ci.south), East: float64(ci.east), North: float64(ci.north),
		HasAnchor: bool(ci.has_anchor),
		AnchorLat: float64(ci.anchor_lat), AnchorLon: float64(ci.anchor_lon), AnchorZoom: float64(ci.anchor_zoom),
		TileType: TileFormat(ci.tile_type),
	}
}

// SetTileFormat selects the encoding for LIVE-generated tiles on a cell-backed
// source (FormatDefault = the engine default, MLT). Cell-backed sources open
// generating MVT, so an MLT-capable host opts in here. No-op for a baked PMTiles
// source (its stored encoding is fixed). Changing the format drops the tile cache.
func (s *Source) SetTileFormat(f TileFormat) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr != nil {
		C.tile57_chart_set_tile_format(s.ptr, C.uint8_t(f))
	}
}

// Tile fetches tile (z, x, y) as decompressed vector-tile bytes in the source's
// tile encoding (see [ChartInfo.TileType] / [Meta.TileType]; stored bytes verbatim
// for a PMTiles source, the live generation format for a cell source). (nil, nil)
// means a blank tile (valid but empty) — the TileSource "no tile here" convention.
func (s *Source) Tile(z uint8, x, y uint32) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, ErrSourceClosed
	}
	var out *C.uint8_t
	var outLen C.size_t
	st := C.tile57_chart_tile(s.ptr, C.uint8_t(z), C.uint32_t(x), C.uint32_t(y), &out, &outLen)
	switch st {
	case C.TILE57_TILE_OK:
		return tileBytes(out, outLen), nil
	case C.TILE57_TILE_EMPTY:
		return nil, nil
	default:
		return nil, fmt.Errorf("tile57: tile %d/%d/%d generation error (status %d)", z, x, y, int(st))
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
	var ci C.tile57_chart_info
	C.tile57_chart_get_info(s.ptr, &ci)
	m.MinZoom, m.MaxZoom = uint8(ci.min_zoom), uint8(ci.max_zoom)
	if bool(ci.has_bounds) {
		m.W, m.S, m.E, m.N = float64(ci.west), float64(ci.south), float64(ci.east), float64(ci.north)
	}
	m.TileType = TileFormat(ci.tile_type).Encoding()
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
	if C.tile57_chart_scamin(s.ptr, &out, &n) == 1 && out != nil && n > 0 {
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

// ClearCache drops the in-memory tile cache to bound memory in long-running hosts.
func (s *Source) ClearCache() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr != nil {
		C.tile57_chart_clear_cache(s.ptr)
	}
}

// Close releases the source and all cached tiles. It is idempotent. Per the ABI's
// lifetime rule, callers must not Close while any goroutine can still call Tile;
// the server Closes a set only after deregistering it.
func (s *Source) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr != nil {
		C.tile57_chart_close(s.ptr)
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
