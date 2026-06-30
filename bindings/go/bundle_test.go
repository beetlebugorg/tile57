//go:build cgo

package tile57

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSourceScamin(t *testing.T) {
	data, err := os.ReadFile(testCell)
	if err != nil {
		t.Skipf("no test cell: %v", err)
	}
	src, err := OpenCells([]CellInput{{Base: data}}, "")
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

func TestBakeBundle(t *testing.T) {
	if _, err := os.Stat(testCell); err != nil {
		t.Skipf("no test cell: %v", err)
	}
	out := t.TempDir()
	// Capture the progress reports to verify the band label detail (host §3): a
	// stage-1 report must carry a band name + a sane band index/count.
	var stage1Named bool
	var maxBandCount int
	progress := func(p BakeProgress) {
		if p.BandCount > maxBandCount {
			maxBandCount = p.BandCount
		}
		if p.Stage == 1 && p.BandName != "" && p.BandIndex < p.BandCount {
			stage1Named = true
		}
	}
	n, bbox, err := BakeBundle(testCell, out, "", "", "", 0, 16, progress)
	if err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("baked 0 cells")
	}
	if maxBandCount == 0 {
		t.Fatal("progress never reported a band count")
	}
	if !stage1Named {
		t.Fatal("progress never reported a stage-1 band label (name + index<count)")
	}
	t.Logf("bundle: %d cell(s), %d band(s), bbox=%v", n, maxBandCount, bbox)
	for _, rel := range []string{
		"tiles/chart.pmtiles",
		"assets/colortables.json",
		"assets/style-day.json",
		"manifest.json",
	} {
		p := filepath.Join(out, rel)
		fi, err := os.Stat(p)
		if err != nil || fi.Size() == 0 {
			t.Fatalf("bundle missing/empty %s: %v", rel, err)
		}
	}
}
