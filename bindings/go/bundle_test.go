//go:build cgo

package tile57

import (
	"os"
	"testing"
)

func TestSourceScamin(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	src, err := OpenChartBytes(data)
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
