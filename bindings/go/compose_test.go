//go:build cgo

package tile57

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// lonLatToTile lives in tile57_test.go (same package).

// Set TILE57_COMPOSE_TESTDIR to a dir of per-cell *.cell.tmp/*.pmtiles archives (e.g. from
// `tile57 compose <ENC_ROOT> -o out.pmtiles --keep-cells`), optionally TILE57_COMPOSE_PARTITION to
// a sidecar (`--save-partition`). Skips when unset — no machine paths baked into the test.
func TestOpenComposeServe(t *testing.T) {
	dir := os.Getenv("TILE57_COMPOSE_TESTDIR")
	if dir == "" {
		t.Skip("set TILE57_COMPOSE_TESTDIR to a dir of per-cell *.cell.tmp/*.pmtiles archives")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if n := e.Name(); strings.HasSuffix(n, ".cell.tmp") || strings.HasSuffix(n, ".pmtiles") {
			paths = append(paths, filepath.Join(dir, n))
		}
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		t.Fatalf("no per-cell archives in %s", dir)
	}

	src, err := OpenCompose(paths, os.Getenv("TILE57_COMPOSE_PARTITION"))
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()

	m := src.Meta()
	t.Logf("compose: %d cells, z%d..%d, bounds [%.3f, %.3f, %.3f, %.3f]",
		m.Cells, m.MinZoom, m.MaxZoom, m.West, m.South, m.East, m.North)
	if m.Cells == 0 {
		t.Fatal("no coverage-carrying cells")
	}

	// Serve the tile at the coverage centre, a few zooms into the range — the centre of real
	// coverage should have content, so a non-blank tile proves the serve path end-to-end.
	z := m.MinZoom + 3
	if z > m.MaxZoom {
		z = m.MaxZoom
	}
	cx, cy := lonLatToTile((m.West+m.East)/2, (m.South+m.North)/2, z)
	tile, err := src.Serve(z, cx, cy)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("served z%d/%d/%d: %d bytes (raw MLT)", z, cx, cy, len(tile))
	if len(tile) == 0 {
		t.Fatalf("centre tile z%d/%d/%d is blank — expected content", z, cx, cy)
	}

	// A tile far outside coverage must be blank (nil), not an error.
	blank, err := src.Serve(z, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if blank != nil {
		t.Fatalf("tile z%d/0/0 should be blank, got %d bytes", z, len(blank))
	}
}
