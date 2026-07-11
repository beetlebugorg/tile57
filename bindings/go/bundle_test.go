//go:build cgo

package tile57

import (
	"testing"
)

func TestSourceScamin(t *testing.T) {
	src, err := OpenBytes(bakeTestCell(t))
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	sc := src.Scamin()
	if len(sc) == 0 {
		t.Fatal("expected a non-empty SCAMIN manifest for the harbour cell")
	}
	// Ascending + the cell's known denominators surface via Meta too.
	for i := 1; i < len(sc); i++ {
		if sc[i] < sc[i-1] {
			t.Fatalf("SCAMIN not ascending: %v", sc)
		}
	}
	if got := src.Meta().Scamin; len(got) != len(sc) {
		t.Fatalf("Meta().Scamin (%v) != Scamin() (%v)", got, sc)
	}
	t.Logf("SCAMIN manifest: %v", sc)
}
