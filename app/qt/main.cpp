// chartplotter-qt — interactive marine-chart viewer built on the Qt6 MapLibre
// widget (QMapLibre::MapWidget, from maplibre-native-qt). It loads a chart
// bundle's MapLibre style.json — which references the bundle's PMTiles tiles +
// portrayal assets — and shows it in a pannable/zoomable window.
//
//   chartplotter-qt <style.json|url> [lat lon zoom]
//   e.g. chartplotter-qt out/assets/style-day.json 38.97 -76.49 13
//
// The chart bundle is produced offline by `chartplotter-bake bundle`. This
// replaces the former GLFW / macOS-Metal MapLibre Native window; the Zig tile
// generator (libtile57) and the offline baker are unchanged.

#include <QApplication>
#include <QFileInfo>
#include <QString>

#include <QMapLibre/Settings>
#include <QMapLibre/Types>
#include <QMapLibreWidgets/MapWidget>

#include <cstdio>
#include <cstdlib>

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);

    if (argc < 2) {
        std::fprintf(stderr,
                     "usage: chartplotter-qt <style.json|url> [lat lon zoom]\n"
                     "  e.g. chartplotter-qt out/assets/style-day.json 38.97 -76.49 13\n");
        return 2;
    }

    // Accept a local path or a URL. A bare path becomes an absolute file:// URL so
    // the style's relative resources (sprite/glyphs/pmtiles) resolve against it.
    QString style = QString::fromUtf8(argv[1]);
    if (!style.contains(QStringLiteral("://"))) {
        style = QStringLiteral("file://") + QFileInfo(style).absoluteFilePath();
    }

    QMapLibre::Styles styles;
    styles.emplace_back(style, QStringLiteral("Chart"));

    QMapLibre::Settings settings;
    settings.setStyles(styles);
    if (argc >= 5) {
        // Coordinate is (latitude, longitude).
        settings.setDefaultCoordinate(QMapLibre::Coordinate(std::atof(argv[2]), std::atof(argv[3])));
        settings.setDefaultZoom(std::atof(argv[4]));
    } else {
        settings.setDefaultCoordinate(QMapLibre::Coordinate(38.97, -76.49));
        settings.setDefaultZoom(12.0);
    }

    auto *widget = new QMapLibre::MapWidget(settings);
    widget->resize(1024, 768);
    widget->setWindowTitle(QStringLiteral("chartplotter-qt"));
    widget->show();

    return QApplication::exec();
}
