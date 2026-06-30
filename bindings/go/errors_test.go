//go:build cgo

package tile57

import (
	"errors"
	"testing"
)

// TestSentinelErrors checks the exported sentinels are matchable via errors.Is, so a
// host can branch on "empty input" / "covered nothing" / "source closed" rather than
// scraping the message string.
func TestSentinelErrors(t *testing.T) {
	// ErrEmptyInput: no cells.
	if _, err := BakeCells(nil, "", 0, 0, PickInclude, nil); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("BakeCells(nil): want ErrEmptyInput, got %v", err)
	}
	if _, err := OpenCells(nil, "", PickInclude); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("OpenCells(nil): want ErrEmptyInput, got %v", err)
	}
	if _, err := OpenBytes(nil, FormatAuto, ""); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("OpenBytes(nil): want ErrEmptyInput, got %v", err)
	}
	if _, err := BuildStyle(nil, MarinerDefaults(), nil, nil, nil, 0); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("BuildStyle(empty template): want ErrEmptyInput, got %v", err)
	}

	// ErrSourceClosed: Tile on a closed source.
	s := &Source{} // ptr nil == closed
	if _, err := s.Tile(0, 0, 0); !errors.Is(err, ErrSourceClosed) {
		t.Errorf("Tile on closed source: want ErrSourceClosed, got %v", err)
	}
}
