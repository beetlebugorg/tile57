//go:build cgo

package tile57

/*
#include <stdlib.h>
#include "tile57.h"
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// NamedBytes is a named input blob for the asset generators: a file-stem id plus
// the file's bytes (e.g. an S-101 LineStyles or Symbols XML/SVG).
type NamedBytes struct {
	ID   string
	Data []byte
}

// ColortablesDefault returns colortables.json (S-52 colour token -> hex per
// day/dusk/night) from the colour profile baked into libtile57 — no on-disk
// catalogue needed.
func ColortablesDefault() ([]byte, error) {
	var out *C.uint8_t
	var n C.size_t
	if C.tile57_colortables_default(&out, &n) != 1 {
		return nil, fmt.Errorf("tile57: colortables_default failed")
	}
	return tileBytes(out, n), nil
}

// Colortables renders colortables.json from a ColorProfiles colorProfile.xml.
func Colortables(xml []byte) ([]byte, error) {
	if len(xml) == 0 {
		return nil, fmt.Errorf("tile57: empty colorProfile xml: %w", ErrEmptyInput)
	}
	var out *C.uint8_t
	var n C.size_t
	if C.tile57_colortables((*C.uint8_t)(unsafe.Pointer(&xml[0])), C.size_t(len(xml)), &out, &n) != 1 {
		return nil, fmt.Errorf("tile57: colortables failed")
	}
	return tileBytes(out, n), nil
}

// Linestyles renders linestyles.json (dash patterns + placed symbols) from the
// S-101 LineStyles (each NamedBytes.ID is the XML file stem).
func Linestyles(lineStyles []NamedBytes) ([]byte, error) {
	if len(lineStyles) == 0 {
		return nil, fmt.Errorf("tile57: no line styles: %w", ErrEmptyInput)
	}
	arena := &cArena{}
	defer arena.free()
	base, n := arena.namedBytes(lineStyles)
	var out *C.uint8_t
	var outLen C.size_t
	if C.tile57_linestyles(base, n, &out, &outLen) != 1 {
		return nil, fmt.Errorf("tile57: linestyles failed")
	}
	return tileBytes(out, outLen), nil
}

// SpriteAtlas rasterizes the S-101 Symbols (SVG) against a palette stylesheet
// (css = a SvgStyle.css's content) and packs them, returning the sprite.json and
// the atlas PNG.
func SpriteAtlas(svgs []NamedBytes, css []byte) (spriteJSON, spritePNG []byte, err error) {
	if len(svgs) == 0 {
		return nil, nil, fmt.Errorf("tile57: no symbols: %w", ErrEmptyInput)
	}
	arena := &cArena{}
	defer arena.free()
	base, n := arena.namedBytes(svgs)
	cssPtr, cssLen := bytePtr(css)
	var oj, op *C.uint8_t
	var ojn, opn C.size_t
	if C.tile57_sprite_atlas(base, n, cssPtr, cssLen, &oj, &ojn, &op, &opn) != 1 {
		return nil, nil, fmt.Errorf("tile57: sprite_atlas failed")
	}
	return tileBytes(oj, ojn), tileBytes(op, opn), nil
}

// PatternAtlas tiles each S-101 AreaFills XML's referenced symbol on its lattice;
// symbols are the Symbols (SVG) the fills reference. Returns patterns.json + PNG.
func PatternAtlas(fills, symbols []NamedBytes, css []byte) (patternsJSON, patternsPNG []byte, err error) {
	if len(fills) == 0 {
		return nil, nil, fmt.Errorf("tile57: no area fills: %w", ErrEmptyInput)
	}
	arena := &cArena{}
	defer arena.free()
	fb, fn := arena.namedBytes(fills)
	sb, sn := arena.namedBytes(symbols)
	cssPtr, cssLen := bytePtr(css)
	var oj, op *C.uint8_t
	var ojn, opn C.size_t
	if C.tile57_pattern_atlas(fb, fn, sb, sn, cssPtr, cssLen, &oj, &ojn, &op, &opn) != 1 {
		return nil, nil, fmt.Errorf("tile57: pattern_atlas failed")
	}
	return tileBytes(oj, ojn), tileBytes(op, opn), nil
}

// bytePtr returns a C view of a Go byte slice for a read-only input argument
// (valid only for the duration of the C call). (nil, 0) for an empty slice.
func bytePtr(b []byte) (*C.uint8_t, C.size_t) {
	if len(b) == 0 {
		return nil, 0
	}
	return (*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(len(b))
}
