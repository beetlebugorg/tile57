//go:build cgo

package tile57

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestLinestyleLayersInTemplate(t *testing.T) {
	tmpl, err := StyleTemplate(SchemeDay, "http://x/{z}/{x}/{y}", "http://x/sprite", "http://x/glyphs/{fontstack}/{range}", 0, 0, FormatMLT)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Layers   []map[string]any `json:"layers"`
		Metadata map[string]any   `json:"metadata"`
	}
	if err := json.Unmarshal(tmpl, &doc); err != nil {
		t.Fatal(err)
	}
	ls, sym := 0, 0
	for _, l := range doc.Layers {
		id, _ := l["id"].(string)
		if strings.HasPrefix(id, "lines-ls-") {
			if l["type"] == "symbol" {
				sym++
			} else {
				ls++
			}
		}
	}
	if ls == 0 {
		t.Fatal("no lines-ls-* layers in the template")
	}
	if doc.Metadata["tile57:linestyles"] == nil {
		t.Fatal("no tile57:linestyles metadata carrier")
	}
	t.Logf("%d linestyle line layers, %d symbol layers", ls, sym)

	// The mariner rebuild (BuildStyle) must keep them via the metadata carrier.
	ct, _ := ColortablesDefault()
	built, err := BuildStyle(tmpl, MarinerDefaults(), ct, nil, nil, 39.0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(built), "lines-ls-") {
		t.Fatal("BuildStyle dropped the linestyle layers")
	}
	// And lines-solid must exclude ls_style runs.
	if !strings.Contains(string(built), "ls_style") {
		t.Fatal("built style has no ls_style references at all")
	}
}
