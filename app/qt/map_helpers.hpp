// map_helpers — shared MapWidget construction used by both the style-file viewer
// and the live ENC viewer. Builds a QMapLibre::MapWidget with inertial panning
// ("throw the map") and the status HUD (band · scale · zoom · position + overscale)
// installed. No libtile57 dependency, so it builds in a style-only configuration.
#pragma once

#include <QMapLibreWidgets/MapWidget>
#include <QString>

namespace cpn {

// Create a MapWidget on a style URL + initial camera, with fling + HUD installed.
// The caller sizes and shows it (directly, or inside a window).
QMapLibre::MapWidget *makeMapWidget(const QString &styleUrl, double lat, double lon, double zoom);

} // namespace cpn
