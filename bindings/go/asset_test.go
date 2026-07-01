//go:build cgo

package tile57

import (
	"testing"
)

// TestBakeAssets exercises the in-memory portrayal-asset bake against the
// library's embedded S-101 catalogue: all six buffers must be non-empty, the JSON
// ones must start with '{', and the atlas PNGs must carry the PNG magic.
func TestBakeAssets(t *testing.T) {
	a, err := BakeAssets("")
	if err != nil {
		t.Fatalf("BakeAssets: %v", err)
	}
	jsons := []struct {
		name string
		b    []byte
	}{
		{"Colortables", a.Colortables},
		{"Linestyles", a.Linestyles},
		{"SpriteJSON", a.SpriteJSON},
		{"PatternJSON", a.PatternJSON},
	}
	for _, j := range jsons {
		if len(j.b) == 0 || j.b[0] != '{' {
			t.Errorf("%s: want non-empty JSON object, got %d bytes", j.name, len(j.b))
		}
	}
	if !isPNG(a.SpritePNG) {
		t.Errorf("SpritePNG: not a PNG (%d bytes)", len(a.SpritePNG))
	}
	if !isPNG(a.PatternPNG) {
		t.Errorf("PatternPNG: not a PNG (%d bytes)", len(a.PatternPNG))
	}
	t.Logf("assets: colortables=%d linestyles=%d sprite json=%d png=%d pattern json=%d png=%d",
		len(a.Colortables), len(a.Linestyles), len(a.SpriteJSON), len(a.SpritePNG), len(a.PatternJSON), len(a.PatternPNG))
}

func isPNG(b []byte) bool {
	return len(b) > 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G'
}
