//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"

extern void tile57GoSurfFill(void *ctx, tile57_feature *f, tile57_world_rings *rings,
                             tile57_color color, int even_odd);
extern void tile57GoSurfLine(void *ctx, tile57_feature *f, tile57_world_rings *lines,
                             float width_px, float dash_on, float dash_off, tile57_color color);
extern void tile57GoSurfSymbol(void *ctx, tile57_feature *f, tile57_world_point anchor,
                               tile57_local_rings *rings, tile57_color color, int even_odd,
                               float stroke_w, int align);
extern void tile57GoSurfText(void *ctx, tile57_feature *f, tile57_world_point anchor,
                             tile57_local_rings *glyphs, tile57_color color, tile57_color halo,
                             float halo_px, int align, int32_t text_group);

static void surf_fill_thunk(void *ctx, const tile57_feature *f, const tile57_world_rings *r,
                            tile57_color c, int eo) {
	tile57GoSurfFill(ctx, (tile57_feature *)f, (tile57_world_rings *)r, c, eo);
}
static void surf_line_thunk(void *ctx, const tile57_feature *f, const tile57_world_rings *l,
                            float w, float don, float doff, tile57_color c) {
	tile57GoSurfLine(ctx, (tile57_feature *)f, (tile57_world_rings *)l, w, don, doff, c);
}
static void surf_symbol_thunk(void *ctx, const tile57_feature *f, tile57_world_point a,
                              const tile57_local_rings *r, tile57_color c, int eo, float sw,
                              tile57_rot_align al) {
	tile57GoSurfSymbol(ctx, (tile57_feature *)f, a, (tile57_local_rings *)r, c, eo, sw, al);
}
static void surf_text_thunk(void *ctx, const tile57_feature *f, tile57_world_point a,
                            const tile57_local_rings *g, tile57_color c, tile57_color h, float hp,
                            tile57_rot_align al, int32_t tg) {
	tile57GoSurfText(ctx, (tile57_feature *)f, a, (tile57_local_rings *)g, c, h, hp, al, tg);
}

// sprite / pattern / text_str stay NULL: the engine then tessellates symbols and
// text as vector outlines (draw_symbol / draw_text) and flat-tints patterned
// areas — the whole chart arrives as fillable rings.
static tile57_status tile57_go_compose_surface(tile57_compose *c, double lon, double lat,
                                               double zoom, double rot, uint32_t w, uint32_t h,
                                               const tile57_mariner *m, void *ctx,
                                               tile57_error *err) {
	tile57_surface_cb cb = {
	    ctx, surf_fill_thunk, surf_line_thunk, surf_symbol_thunk, surf_text_thunk,
	    NULL, NULL, NULL,
	};
	return tile57_compose_surface(c, lon, lat, zoom, rot, w, h, m, &cb, err);
}
static tile57_status tile57_go_chart_surface(tile57_chart *ch, double lon, double lat,
                                             double zoom, double rot, uint32_t w, uint32_t h,
                                             const tile57_mariner *m, void *ctx,
                                             tile57_error *err) {
	tile57_surface_cb cb = {
	    ctx, surf_fill_thunk, surf_line_thunk, surf_symbol_thunk, surf_text_thunk,
	    NULL, NULL, NULL,
	};
	return tile57_chart_surface(ch, lon, lat, zoom, rot, w, h, m, &cb, err);
}
static tile57_status tile57_go_chart_tile_surface(tile57_chart *ch, uint8_t z, uint32_t x,
                                                  uint32_t y, const tile57_mariner *m,
                                                  void *ctx, tile57_error *err) {
	tile57_surface_cb cb = {
	    ctx, surf_fill_thunk, surf_line_thunk, surf_symbol_thunk, surf_text_thunk,
	    NULL, NULL, NULL,
	};
	return tile57_chart_tile_surface(ch, z, x, y, m, &cb, err);
}
*/
import "C"

import (
	"fmt"
	"runtime/cgo"
	"unsafe"
)

// surface.go binds the world-space Surface output — the engine's vector draw
// stream for GPU hosts (spec: "the GPU vector twin"). Geometry arrives in
// web-mercator [0,1] (y down); symbols and text as a world anchor plus a local
// outline in reference px (constant screen size). Every call is tagged with the
// feature's S-57 class, SCAMIN, and draw plane, in paint order.

// RGBA is a resolved straight-alpha colour from the active palette.
type RGBA struct{ R, G, B, A uint8 }

// RotAlign says what a mark's rotation is referenced to. Geometry arrives
// ALREADY rotated to its own angle; the flag tells a host with a rotated view
// (course-up/head-up) whether to ADD the view rotation.
type RotAlign uint8

const (
	// AlignViewport: screen-relative — the mark stays upright on screen; a
	// rotated view must NOT add its rotation (buoys, ordinary labels).
	AlignViewport RotAlign = 0
	// AlignMap: chart-relative — a rotated view ADDS its rotation so the mark
	// turns with the chart (ORIENT symbols, depth-contour values).
	AlignMap RotAlign = 1
)

// DisplayCategory is the S-52 display category a feature arrived on. A host applying
// SCAMIN itself must skip it for DisplayBase (the never-hide safety minimum).
// DisplayPlane is the S-101 DisplayPlane. It outranks DisplayPriority in paint
// order (S-52 PresLib §10.3.4.2).
type DisplayPlane uint8

const (
	PlaneUnderRadar DisplayPlane = 0
	PlaneOverRadar  DisplayPlane = 1
)

type DisplayCategory uint8

const (
	DisplayBase     DisplayCategory = 0
	DisplayStandard DisplayCategory = 1
	DisplayOther    DisplayCategory = 2
)

// WorldPoint is a web-mercator [0,1] position (y down).
type WorldPoint struct{ X, Y float64 }

// LocalPoint is an anchor-relative offset in reference pixels.
type LocalPoint struct{ X, Y float32 }

// SurfaceFeature tags the draw calls that belong to one S-57 feature.
type SurfaceFeature struct {
	Class   string  // object-class acronym ("" if none)
	Scamin  int64   // SCAMIN 1:N denominator (<= 0 → always visible)
	DisplayPriority int32   // S-52 draw priority (S-101 DrawingPriority, 0..30)
	DisplayPlane    DisplayPlane    // S-101 DisplayPlane; outranks DisplayPriority in paint order
	DisplayCategory DisplayCategory // the display category the feature came in on
}

// WorldRings is a multi-ring path in world space: ring k spans
// [RingStarts[k], RingStarts[k+1]) (the last runs to len(Pts)). Rings close
// implicitly.
type WorldRings struct {
	Pts        []WorldPoint
	RingStarts []uint32
}

// LocalRings is a multi-ring outline in reference px around an anchor.
type LocalRings struct {
	Pts        []LocalPoint
	RingStarts []uint32
}

// SurfaceFuncs receives the draw stream. Nil members skip those calls. Slices
// are copies owned by the callee; retain freely.
type SurfaceFuncs struct {
	// FillArea fills world rings; evenOdd selects the even-odd rule.
	FillArea func(f SurfaceFeature, rings WorldRings, color RGBA, evenOdd bool)
	// StrokeLine strokes world polylines widthPx wide; dashes in px (0,0 solid).
	StrokeLine func(f SurfaceFeature, lines WorldRings, widthPx, dashOn, dashOff float32, color RGBA)
	// DrawSymbol draws a point symbol: world anchor + local outline. strokeW > 0
	// means the rings are a polyline stroked that wide (px), else filled. The
	// outline arrives already rotated; align says whether that angle is
	// chart-relative (a rotated view additionally rotates AlignMap outlines).
	DrawSymbol func(f SurfaceFeature, anchor WorldPoint, rings LocalRings, color RGBA, evenOdd bool, strokeW float32, align RotAlign)
	// DrawText draws shaped label glyphs as local outline rings (even-odd), with
	// an optional halo (halo.A == 0 → none). align as in DrawSymbol. textGroup is
	// the label's S-52 text group (§14.5) — a property of the LABEL, not the
	// feature, since one feature can carry several. Group 11 is important text
	// (it ignores the mariner's text switches); 21/26/29 names, 23 light
	// descriptions, 0 none.
	DrawText func(f SurfaceFeature, anchor WorldPoint, glyphs LocalRings, color, halo RGBA, haloPx float32, align RotAlign, textGroup int)
}

// Surface emits the composed view centred on (lon, lat) at zoom for a width×height
// viewport as a vector draw stream — the primitive for a host that renders on the
// GPU and re-portrays nothing on pan/zoom. The portrayal is north-up (view
// rotation 0); a rotating host rotates the world geometry itself and applies
// the per-call RotAlign flags to its marks.
func (c *ComposeSource) Surface(lon, lat, zoom float64, width, height uint32, m Mariner, cb *SurfaceFuncs) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return fmt.Errorf("tile57: Surface on a closed ComposeSource")
	}
	var ar cArena
	defer ar.free()
	cm := m.toC(&ar)
	h := cgo.NewHandle(cb)
	defer h.Delete()
	var cerr C.tile57_error
	if st := C.tile57_go_compose_surface(c.ptr, C.double(lon), C.double(lat), C.double(zoom),
		0, C.uint32_t(width), C.uint32_t(height), &cm, unsafe.Pointer(&h), &cerr); st != C.TILE57_OK {
		return statusError(st, &cerr)
	}
	return nil
}

// Surface is the single-chart form of [ComposeSource.Surface].
func (s *Source) Surface(lon, lat, zoom float64, width, height uint32, m Mariner, cb *SurfaceFuncs) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return fmt.Errorf("tile57: Surface on a closed Source")
	}
	var ar cArena
	defer ar.free()
	cm := m.toC(&ar)
	h := cgo.NewHandle(cb)
	defer h.Delete()
	var cerr C.tile57_error
	if st := C.tile57_go_chart_surface(s.ptr, C.double(lon), C.double(lat), C.double(zoom),
		0, C.uint32_t(width), C.uint32_t(height), &cm, unsafe.Pointer(&h), &cerr); st != C.TILE57_OK {
		return statusError(st, &cerr)
	}
	return nil
}

// TileSurface portrays ONE tile (z, x, y) through the same S-52 portrayal and
// callbacks — the unit a host tessellates once and caches keyed by
// (chart, z, x, y), composing views from cached tiles. Decluttering is per-tile.
func (s *Source) TileSurface(z uint8, x, y uint32, m Mariner, cb *SurfaceFuncs) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptr == nil {
		return fmt.Errorf("tile57: TileSurface on a closed Source")
	}
	var ar cArena
	defer ar.free()
	cm := m.toC(&ar)
	h := cgo.NewHandle(cb)
	defer h.Delete()
	var cerr C.tile57_error
	if st := C.tile57_go_chart_tile_surface(s.ptr, C.uint8_t(z), C.uint32_t(x), C.uint32_t(y),
		&cm, unsafe.Pointer(&h), &cerr); st != C.TILE57_OK {
		return statusError(st, &cerr)
	}
	return nil
}

// --- exported callback bridges ---------------------------------------------

func surfCB(ctx unsafe.Pointer) *SurfaceFuncs {
	return (*(*cgo.Handle)(ctx)).Value().(*SurfaceFuncs)
}

func goFeature(f *C.tile57_feature) SurfaceFeature {
	return SurfaceFeature{Class: C.GoString(f.cls), Scamin: int64(f.scamin),
		DisplayPriority: int32(f.display_priority), DisplayPlane: DisplayPlane(f.display_plane),
		DisplayCategory: DisplayCategory(f.display_category)}
}

// tile57_color is packed 0xRRGGBBAA (a scalar, not a struct — see tile57_color
// in tile57.h). Go hosts still see an RGBA struct.
func goRGBA(c C.tile57_color) RGBA {
	return RGBA{uint8(c >> 24), uint8(c >> 16), uint8(c >> 8), uint8(c)}
}

func goWorldRings(r *C.tile57_world_rings) WorldRings {
	n, rc := int(r.n), int(r.ring_count)
	out := WorldRings{Pts: make([]WorldPoint, n), RingStarts: make([]uint32, rc)}
	pts := unsafe.Slice((*C.tile57_world_point)(r.pts), n)
	for i, p := range pts {
		out.Pts[i] = WorldPoint{float64(p.x), float64(p.y)}
	}
	starts := unsafe.Slice((*C.uint32_t)(r.ring_starts), rc)
	for i, v := range starts {
		out.RingStarts[i] = uint32(v)
	}
	return out
}

func goLocalRings(r *C.tile57_local_rings) LocalRings {
	n, rc := int(r.n), int(r.ring_count)
	out := LocalRings{Pts: make([]LocalPoint, n), RingStarts: make([]uint32, rc)}
	pts := unsafe.Slice((*C.tile57_local_point)(r.pts), n)
	for i, p := range pts {
		out.Pts[i] = LocalPoint{float32(p.x), float32(p.y)}
	}
	starts := unsafe.Slice((*C.uint32_t)(r.ring_starts), rc)
	for i, v := range starts {
		out.RingStarts[i] = uint32(v)
	}
	return out
}

//export tile57GoSurfFill
func tile57GoSurfFill(ctx unsafe.Pointer, f *C.tile57_feature, rings *C.tile57_world_rings,
	color C.tile57_color, evenOdd C.int) {
	cb := surfCB(ctx)
	if cb.FillArea == nil {
		return
	}
	cb.FillArea(goFeature(f), goWorldRings(rings), goRGBA(color), evenOdd != 0)
}

//export tile57GoSurfLine
func tile57GoSurfLine(ctx unsafe.Pointer, f *C.tile57_feature, lines *C.tile57_world_rings,
	widthPx, dashOn, dashOff C.float, color C.tile57_color) {
	cb := surfCB(ctx)
	if cb.StrokeLine == nil {
		return
	}
	cb.StrokeLine(goFeature(f), goWorldRings(lines), float32(widthPx), float32(dashOn), float32(dashOff), goRGBA(color))
}

//export tile57GoSurfSymbol
func tile57GoSurfSymbol(ctx unsafe.Pointer, f *C.tile57_feature, anchor C.tile57_world_point,
	rings *C.tile57_local_rings, color C.tile57_color, evenOdd C.int, strokeW C.float, align C.int) {
	cb := surfCB(ctx)
	if cb.DrawSymbol == nil {
		return
	}
	cb.DrawSymbol(goFeature(f), WorldPoint{float64(anchor.x), float64(anchor.y)},
		goLocalRings(rings), goRGBA(color), evenOdd != 0, float32(strokeW), RotAlign(align))
}

//export tile57GoSurfText
func tile57GoSurfText(ctx unsafe.Pointer, f *C.tile57_feature, anchor C.tile57_world_point,
	glyphs *C.tile57_local_rings, color, halo C.tile57_color, haloPx C.float, align C.int,
	textGroup C.int32_t) {
	cb := surfCB(ctx)
	if cb.DrawText == nil {
		return
	}
	cb.DrawText(goFeature(f), WorldPoint{float64(anchor.x), float64(anchor.y)},
		goLocalRings(glyphs), goRGBA(color), goRGBA(halo), float32(haloPx), RotAlign(align),
		int(textGroup))
}
