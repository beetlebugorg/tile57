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

// The whole pipeline over the in-repo fixture: bake the cell, open it as a chart,
// compose over the chart (borrowed), serve the coverage-centre tile, and round-trip
// the partition sidecar through a path-based (owning) open.
func TestComposeSingleCell(t *testing.T) {
	pm := bakeTestCell(t)
	path := filepath.Join(t.TempDir(), "US5MD1MC.pmtiles")
	if err := os.WriteFile(path, pm, 0o644); err != nil {
		t.Fatal(err)
	}
	chart, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer chart.Close()

	src, err := OpenComposeCharts([]*Source{chart})
	if err != nil {
		t.Fatalf("OpenComposeCharts: %v", err)
	}
	m := src.Meta()
	if m.Charts != 1 {
		t.Fatalf("compose charts = %d, want 1", m.Charts)
	}
	// The fill-up bake serves from z0, but a single harbour cell is sub-pixel at
	// world zooms (its low-zoom tiles are legitimately empty) — probe a zoom
	// where the cell has real extent.
	z := uint8(10)
	if z < m.MinZoom {
		z = m.MinZoom
	}
	cx, cy := lonLatToTile((m.West+m.East)/2, (m.South+m.North)/2, z)
	tile, owned, err := src.Tile(z, cx, cy)
	if err != nil {
		t.Fatalf("Tile: %v", err)
	}
	if len(tile) == 0 || !owned {
		t.Fatalf("centre tile z%d/%d/%d: %d bytes owned=%v, want content", z, cx, cy, len(tile), owned)
	}
	if err := src.Close(); err != nil {
		t.Fatal(err)
	}

	// Path-based open owns its charts. The ownership partition is the engine's
	// business — found beside the archives, reused or rebuilt — so there is
	// nothing to save or pass here; the serve must simply match.
	src2, err := OpenCompose([]string{path})
	if err != nil {
		t.Fatalf("OpenCompose: %v", err)
	}
	defer src2.Close()
	tile2, owned2, err := src2.Tile(z, cx, cy)
	if err != nil {
		t.Fatalf("Tile(sidecar): %v", err)
	}
	if !owned2 || len(tile2) != len(tile) {
		t.Fatalf("sidecar-loaded serve differs: %d bytes owned=%v (want %d bytes)", len(tile2), owned2, len(tile))
	}
	t.Logf("compose z%d..%d served %d bytes at z%d/%d/%d (sidecar round-trip ok)",
		m.MinZoom, m.MaxZoom, len(tile), z, cx, cy)
}

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

	src, err := OpenCompose(paths)
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()

	m := src.Meta()
	t.Logf("compose: %d charts, z%d..%d, bounds [%.3f, %.3f, %.3f, %.3f]",
		m.Charts, m.MinZoom, m.MaxZoom, m.West, m.South, m.East, m.North)
	if m.Charts == 0 {
		t.Fatal("no coverage-carrying charts")
	}

	// Serve the tile at the coverage centre, a few zooms into the range — the centre of real
	// coverage should have content, so a non-blank tile proves the serve path end-to-end.
	z := m.MinZoom + 3
	if z > m.MaxZoom {
		z = m.MaxZoom
	}
	cx, cy := lonLatToTile((m.West+m.East)/2, (m.South+m.North)/2, z)
	tile, owned, err := src.Tile(z, cx, cy)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("served z%d/%d/%d: %d bytes (raw MLT), owned=%v", z, cx, cy, len(tile), owned)
	if len(tile) == 0 {
		t.Fatalf("centre tile z%d/%d/%d is blank — expected content", z, cx, cy)
	}
	if !owned {
		t.Fatalf("centre tile z%d/%d/%d has content but owned=false", z, cx, cy)
	}

	// A tile far outside coverage must be blank (nil) AND not owned (true empty ocean), not an error.
	blank, blankOwned, err := src.Tile(z, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if blank != nil {
		t.Fatalf("tile z%d/0/0 should be blank, got %d bytes", z, len(blank))
	}
	if blankOwned {
		t.Fatalf("tile z%d/0/0 (far outside coverage) should be unowned", z)
	}
}
