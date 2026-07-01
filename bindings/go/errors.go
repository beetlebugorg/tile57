//go:build cgo

package tile57

import "errors"

// Sentinel errors hosts can branch on with errors.Is. The package wraps these with
// %w, so the human-readable message stays specific while the category is testable.
var (
	// ErrNoCoverage is returned by BakePmtiles / BakeBundle when the bake completed
	// successfully but produced no tiles — the inputs covered nothing in range. This
	// is a routine, recoverable outcome (skip this region), NOT a failure: a host
	// should distinguish it from a hard error and continue.
	ErrNoCoverage = errors.New("tile57: bake covered nothing")

	// ErrSourceClosed is returned by Source methods invoked after Close.
	ErrSourceClosed = errors.New("tile57: source closed")

	// ErrEmptyInput is returned when a call is handed no usable input — no cells,
	// empty bytes, an empty style template, or empty asset inputs.
	ErrEmptyInput = errors.New("tile57: empty input")
)
