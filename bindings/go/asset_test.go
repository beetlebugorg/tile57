//go:build cgo

package tile57

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// catalogDir is the synced S-101 PortrayalCatalog embedded by `make sync-s101`.
const catalogDir = "../../vendor/S-101_Portrayal-Catalogue/PortrayalCatalog"

func namedDir(t *testing.T, sub, ext string) []NamedBytes {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(catalogDir, sub))
	if err != nil {
		t.Skipf("no catalogue %s: %v", sub, err)
	}
	var out []NamedBytes
	for _, e := range entries {
		if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ext) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(catalogDir, sub, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, NamedBytes{ID: strings.TrimSuffix(e.Name(), filepath.Ext(e.Name())), Data: b})
	}
	return out
}

func TestAssetGenerators(t *testing.T) {
	xml, err := os.ReadFile(filepath.Join(catalogDir, "ColorProfiles/colorProfile.xml"))
	if err != nil {
		t.Skipf("no catalogue: %v", err)
	}
	ct, err := Colortables(xml)
	if err != nil || len(ct) == 0 || ct[0] != '{' {
		t.Fatalf("Colortables: %v (%d bytes)", err, len(ct))
	}

	lines := namedDir(t, "LineStyles", ".xml")
	ls, err := Linestyles(lines)
	if err != nil || len(ls) == 0 {
		t.Fatalf("Linestyles: %v (%d styles -> %d bytes)", err, len(lines), len(ls))
	}

	css, err := os.ReadFile(filepath.Join(catalogDir, "Symbols/daySvgStyle.css"))
	if err != nil {
		t.Fatal(err)
	}
	symbols := namedDir(t, "Symbols", ".svg")
	sJSON, sPNG, err := SpriteAtlas(symbols, css)
	if err != nil || len(sJSON) == 0 || !isPNG(sPNG) {
		t.Fatalf("SpriteAtlas: %v (%d symbols -> json=%d png=%d)", err, len(symbols), len(sJSON), len(sPNG))
	}
	t.Logf("sprite atlas: %d symbols, json=%d bytes, png=%d bytes", len(symbols), len(sJSON), len(sPNG))

	fills := namedDir(t, "AreaFills", ".xml")
	pJSON, pPNG, err := PatternAtlas(fills, symbols, css)
	if err != nil || len(pJSON) == 0 || !isPNG(pPNG) {
		t.Fatalf("PatternAtlas: %v (%d fills -> json=%d png=%d)", err, len(fills), len(pJSON), len(pPNG))
	}
	t.Logf("pattern atlas: %d fills, json=%d bytes, png=%d bytes", len(fills), len(pJSON), len(pPNG))
}

func isPNG(b []byte) bool {
	return len(b) > 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G'
}
