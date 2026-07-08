//go:build cgo

package tile57

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBakePartitionDebug(t *testing.T) {
	if _, err := os.Stat(testCell); err != nil {
		t.Skipf("no test cell: %v", err)
	}
	// testCell lives in testdata/, so that directory is a one-cell ENC_ROOT.
	out := filepath.Join(t.TempDir(), "partition.pmtiles")
	n, err := BakePartitionDebug("testdata", out, 0, 9, BandGoverning)
	if err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("baked 0 cells")
	}
	fi, err := os.Stat(out)
	if err != nil || fi.Size() == 0 {
		t.Fatalf("partition pmtiles missing/empty: %v", err)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) < 7 || string(b[:7]) != "PMTiles" {
		t.Fatalf("output is not a PMTiles archive (first bytes %q)", b[:min(7, len(b))])
	}

	// A single band's own map bakes too (harbor = the finest partition).
	outBand := filepath.Join(t.TempDir(), "harbor.pmtiles")
	if _, err := BakePartitionDebug("testdata", outBand, 0, 11, BandHarbor); err != nil {
		t.Fatalf("per-band bake failed: %v", err)
	}
	t.Logf("partition-debug: %d cell(s) -> %d bytes", n, fi.Size())
}
