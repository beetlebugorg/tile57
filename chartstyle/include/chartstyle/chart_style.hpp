// ChartStyle::buildStyle — turn a MapLibre style template + MarinerSettings into a
// concrete style, client-side. Cross-platform (no Qt/mbgl): a thin C++ port of the
// Go web client's s52-style.mjs builders.
//
// It PATCHES the mariner-driven parts of the template rather than regenerating the
// whole style: depth shading (SEABED01), sounding bold/faint split, danger-symbol
// safety swap, contour-label units, and the data-quality / info-callout ("flyout")
// toggles. Axes that need per-feature tags the Zig engine doesn't bake yet
// (display category, boundary/point style, sector legs, text groups, dates) are
// left for a later phase — the struct already carries them.
#pragma once

#include "chartstyle/mariner.hpp"

#include <string>
#include <vector>

namespace chartstyle {

// templateJson: a MapLibre style (e.g. style/chart-zig-day.json).
// colortablesJson: { "day": {TOKEN: "#rrggbb", ...}, "dusk": {...}, "night": {...} }
//   (S-52 colour tables). Pass "" or an empty object to keep the template's baked
//   depth colours (the shading expression is only regenerated when a palette is
//   available).
// enabledBands: optional band-visibility filter — band/chart visibility is a
//   chart-source concern, kept OUT of MarinerSettings. nullptr = no band filter
//   (show all); otherwise show only features whose `band` rank is in the list (an
//   empty list hides every banded feature). The host fills it from the loaded
//   source's present bands (tile57_source_bands).
// Returns the patched style JSON; on parse failure returns the template unchanged.
std::string buildStyle(const std::string &templateJson, const MarinerSettings &m,
                       const std::string &colortablesJson,
                       const std::vector<int> *enabledBands = nullptr);

} // namespace chartstyle
