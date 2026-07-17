//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"

extern void tile57GoQueryFeature(void *ctx, char *cls, size_t cls_len,
                                 char *s57, size_t s57_len,
                                 char *chart, size_t chart_len);

static void tile57_go_query_thunk(void *ctx, const char *cls, size_t cls_len,
                                  const char *s57, size_t s57_len,
                                  const char *chart, size_t chart_len) {
	tile57GoQueryFeature(ctx, (char *)cls, cls_len, (char *)s57, s57_len,
	                     (char *)chart, chart_len);
}

static tile57_status tile57_go_compose_query(tile57_compose *c, double lon, double lat,
                                             double zoom, void *ctx, tile57_error *err) {
	tile57_query_cb cb = { ctx, tile57_go_query_thunk };
	return tile57_compose_query(c, lon, lat, zoom, &cb, err);
}

static tile57_status tile57_go_chart_query(tile57_chart *ch, double lon, double lat,
                                           double zoom, void *ctx, tile57_error *err) {
	tile57_query_cb cb = { ctx, tile57_go_query_thunk };
	return tile57_chart_query(ch, lon, lat, zoom, &cb, err);
}
*/
import "C"

import (
	"fmt"
	"runtime/cgo"
	"unsafe"
)

// render.go binds the native VIEW outputs — the engine's own S-52 pixel path —
// for embedders that render without a browser (e.g. a Fyne/native host): a PNG
// of any camera and the cursor pick, on both handles (the chart and the
// compositor offer the same output set).

// PNG renders this chart's view centred on (lon, lat) at web-mercator zoom into
// a width×height PNG through the engine's native S-52 pixel path. See
// [ComposeSource.PNG] for the composed form.
func (s *Source) PNG(lon, lat, zoom float64, width, height uint32, m Mariner) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, fmt.Errorf("tile57: PNG on a closed Source")
	}
	var ar cArena
	defer ar.free()
	cm := m.toC(&ar)
	var out *C.uint8_t
	var n C.size_t
	var cerr C.tile57_error
	if st := C.tile57_chart_png(s.ptr, C.double(lon), C.double(lat), C.double(zoom),
		C.uint32_t(width), C.uint32_t(height), &cm, &out, &n, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return tileBytes(out, n), nil
}

// Query runs this chart's cursor pick at (lon, lat) for a view at `zoom`. See
// [ComposeSource.Query] for the composed form.
func (s *Source) Query(lon, lat, zoom float64) ([]PickedFeature, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return nil, fmt.Errorf("tile57: Query on a closed Source")
	}
	var feats []PickedFeature
	h := cgo.NewHandle(&feats)
	defer h.Delete()
	var cerr C.tile57_error
	if st := C.tile57_go_chart_query(s.ptr, C.double(lon), C.double(lat), C.double(zoom),
		unsafe.Pointer(&h), &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return feats, nil
}

// PNG renders the composed view centred on (lon, lat) at web-mercator zoom into a
// width×height PNG, through the engine's native S-52 pixel path — portrayal,
// symbols, patterns, and text identical to the baked-tile web render. m controls
// the mariner settings (scheme, contours, viewing groups…); use MarinerDefaults()
// for the standard chart.
func (c *ComposeSource) PNG(lon, lat, zoom float64, width, height uint32, m Mariner) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return nil, fmt.Errorf("tile57: PNG on a closed ComposeSource")
	}
	var ar cArena
	defer ar.free()
	cm := m.toC(&ar)
	var out *C.uint8_t
	var n C.size_t
	var cerr C.tile57_error
	if st := C.tile57_compose_png(c.ptr, C.double(lon), C.double(lat), C.double(zoom),
		C.uint32_t(width), C.uint32_t(height), &cm, &out, &n, &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return tileBytes(out, n), nil
}

// PickedFeature is one feature under the cursor from Query — the S-52 §10.8
// object pick, composed across chart boundaries.
type PickedFeature struct {
	Class string // S-57 object-class acronym (e.g. "BOYLAT")
	S57   string // attribute JSON (acronym → value)
	Chart string // source chart name
}

//export tile57GoQueryFeature
func tile57GoQueryFeature(ctx unsafe.Pointer, cls *C.char, clsLen C.size_t,
	s57 *C.char, s57Len C.size_t, chart *C.char, chartLen C.size_t) {
	h := *(*cgo.Handle)(ctx)
	out := h.Value().(*[]PickedFeature)
	*out = append(*out, PickedFeature{
		Class: C.GoStringN(cls, C.int(clsLen)),
		S57:   C.GoStringN(s57, C.int(s57Len)),
		Chart: C.GoStringN(chart, C.int(chartLen)),
	})
}

// Query runs the composed cursor pick at (lon, lat) for a view at `zoom`: every
// feature under the point (areas by point-in-polygon, lines/points within an
// on-screen tolerance) as displayed at that zoom (SCAMIN-gated).
func (c *ComposeSource) Query(lon, lat, zoom float64) ([]PickedFeature, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return nil, fmt.Errorf("tile57: Query on a closed ComposeSource")
	}
	var feats []PickedFeature
	h := cgo.NewHandle(&feats)
	defer h.Delete()
	var cerr C.tile57_error
	if st := C.tile57_go_compose_query(c.ptr, C.double(lon), C.double(lat), C.double(zoom),
		unsafe.Pointer(&h), &cerr); st != C.TILE57_OK {
		return nil, statusError(st, &cerr)
	}
	return feats, nil
}
