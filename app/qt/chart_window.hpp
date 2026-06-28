// ChartWindow — the live ENC viewer window. Hosts the map, a settings popup (the
// S-52 mariner display options + a data-driven band-filter column) that restyle the
// chart live, the zoom-out floor, and the tile-loading indicator. Constructed by
// main() when the tile-server worker signals ready().
#pragma once

#include "tile57.h"

#include <QMainWindow>
#include <QString>

#include <vector>

namespace QMapLibre {
class MapWidget;
}

namespace cpn {

class TileServer;

class ChartWindow : public QMainWindow {
    Q_OBJECT
public:
    // templateJson/colortables: the raw style template + S-52 palettes from the
    // worker. presentBands: tile57_source_bands bitmask (for the band column).
    // backend: the tile server (for the loading indicator). minZoomFloor: clamp.
    ChartWindow(QString templateJson, QString colortables, quint32 presentBands, TileServer *backend,
                double lat, double lon, double zoom, double minZoomFloor, QWidget *parent = nullptr);

private:
    void restyle(); // rebuild the style from settings_ + enabledBands_ and apply it

    QString templateJson_;
    QString colortables_;
    tile57_mariner settings_;
    std::vector<int> enabledBands_;
    bool hasBands_ = false;
    QMapLibre::MapWidget *map_ = nullptr;
};

} // namespace cpn
