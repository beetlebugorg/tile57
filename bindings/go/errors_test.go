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
	// ErrEmptyInput: empty input.
	if _, err := OpenBytes(nil); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("OpenBytes(nil): want ErrEmptyInput, got %v", err)
	}
	// Category sentinels ride the C status: a missing file is ErrIO, garbage
	// archive bytes are ErrParse.
	if _, err := Open("testdata/definitely-missing.pmtiles"); !errors.Is(err, ErrIO) {
		t.Errorf("Open(missing): want ErrIO, got %v", err)
	}
	if _, err := OpenBytes([]byte("not a pmtiles archive")); !errors.Is(err, ErrParse) {
		t.Errorf("OpenBytes(garbage): want ErrParse, got %v", err)
	}
	if _, err := Open(""); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("Open(\"\"): want ErrEmptyInput, got %v", err)
	}
	if _, err := BuildStyle(nil, MarinerDefaults(), nil, nil, nil, 0); !errors.Is(err, ErrEmptyInput) {
		t.Errorf("BuildStyle(empty template): want ErrEmptyInput, got %v", err)
	}
}
