// chartplotter-qt — interactive marine-chart viewer built on the Qt6 MapLibre
// widget (QMapLibre::MapWidget, from maplibre-native-qt). Two ways to open a chart:
//
//   chartplotter-qt <style.json|url> [lat lon zoom]
//       Load a pre-baked MapLibre style (its sources reference baked PMTiles).
//
//   chartplotter-qt <ENC_ROOT|cell.000|archive.pmtiles> [style.json] [lat lon zoom]
//       Open an S-57 chart live via libtile57: tiles are generated in-process and
//       served to the widget over a localhost HTTP endpoint. All of that startup runs
//       on a background thread; a splash shows load progress until the map is ready,
//       then a ChartWindow hosts the map + the live mariner-settings popup.
//
// This file is intentionally thin — arg parsing, the load splash, the worker thread,
// and the two open modes. The map widget + HUD live in map_helpers; the live viewer
// window (settings popup, band filter, restyle) in chart_window.

#include "map_helpers.hpp"

#include <QApplication>
#include <QFileInfo>
#include <QMapLibreWidgets/MapWidget>
#include <QString>

#include <cstdio>
#include <cstdlib>

#ifdef CHARTPLOTTER_WITH_TILE57
#include "chart_window.hpp"
#include "tile_server.hpp"

#include <QColor>
#include <QCoreApplication>
#include <QPixmap>
#include <QSplashScreen>
#include <QThread>
#endif

namespace {

#ifdef CHARTPLOTTER_WITH_TILE57
// A path is a "style" if it's a regular .json file (or a URL); anything else (a
// directory, a .000 cell, a .pmtiles archive) is opened as a live chart source.
bool looksLikeStyle(const QString &path) {
    if (path.contains(QStringLiteral("://"))) return true;
    QFileInfo fi(path);
    return fi.isFile() && path.endsWith(QStringLiteral(".json"), Qt::CaseInsensitive);
}
#endif

} // namespace

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);

    if (argc < 2) {
        std::fprintf(stderr,
                     "usage: chartplotter-qt <style.json|ENC_ROOT|cell.000|archive.pmtiles> [style.json] [lat lon zoom]\n"
                     "  style:  chartplotter-qt out/assets/style-day.json 38.97 -76.49 13\n"
                     "  live:   chartplotter-qt path/to/ENC_ROOT 38.97 -76.49 13\n");
        return 2;
    }

    const QString arg1 = QString::fromUtf8(argv[1]);

#ifdef CHARTPLOTTER_WITH_TILE57
    if (!looksLikeStyle(arg1)) {
        // ---- Live chart mode. All startup happens on the worker thread; the main
        // thread only drives the splash and (on ready) builds the ChartWindow. ----

        // Optional explicit style template as arg2, then [lat lon zoom].
        int camIdx = 2;
        QString styleTemplate;
        if (argc >= 3 && looksLikeStyle(QString::fromUtf8(argv[2]))) {
            styleTemplate = QString::fromUtf8(argv[2]);
            camIdx = 3;
        }
        const bool haveCamera = argc >= camIdx + 3;
        double lat = 38.97, lon = -76.49, zoom = 12.0;
        if (haveCamera) {
            lat = std::atof(argv[camIdx]);
            lon = std::atof(argv[camIdx + 1]);
            zoom = std::atof(argv[camIdx + 2]);
        }

        QPixmap pm(480, 96);
        pm.fill(QColor(16, 24, 32));
        auto *splash = new QSplashScreen(pm);
        splash->showMessage(QStringLiteral("Opening chart…"), Qt::AlignCenter, Qt::white);
        splash->show();

        auto *thread = new QThread();
        auto *backend = new cpn::TileServer(arg1, QString::fromUtf8(argv[0]), styleTemplate,
                                            haveCamera, lat, lon, zoom);
        backend->moveToThread(thread);
        QObject::connect(thread, &QThread::started, backend, &cpn::TileServer::run);
        QObject::connect(qApp, &QCoreApplication::aboutToQuit, thread, [thread] {
            thread->quit();
            thread->wait();
        });

        QObject::connect(backend, &cpn::TileServer::progress, splash,
                         [splash](const QString &stage, quint64 done, quint64 total) {
                             const QString m = total ? QStringLiteral("%1   %2 / %3").arg(stage).arg(done).arg(total)
                                                     : QStringLiteral("%1   %2").arg(stage).arg(done);
                             splash->showMessage(QStringLiteral("Opening chart…\n\n") + m, Qt::AlignCenter, Qt::white);
                         });
        QObject::connect(backend, &cpn::TileServer::failed, qApp, [](const QString &why) {
            std::fprintf(stderr, "%s\n", why.toUtf8().constData());
            QCoreApplication::exit(1);
        });
        QObject::connect(backend, &cpn::TileServer::ready, qApp,
                         [splash, backend](const QString &templateJson, const QString &colortables, double lat,
                                           double lon, double zoom, double minZoomFloor, quint32 presentBands) {
                             auto *win = new cpn::ChartWindow(templateJson, colortables, presentBands, backend,
                                                              lat, lon, zoom, minZoomFloor);
                             win->show();
                             splash->finish(win);
                             splash->deleteLater();
                         });

        thread->start();
        return app.exec();
    }
#endif // CHARTPLOTTER_WITH_TILE57

    // ---- Style mode: a local path or URL. A bare path becomes an absolute file://
    // URL so the style's relative resources resolve against it. ----
    bool haveCamera = argc >= 5;
    double lat = 38.97, lon = -76.49, zoom = 12.0;
    if (haveCamera) {
        lat = std::atof(argv[2]);
        lon = std::atof(argv[3]);
        zoom = std::atof(argv[4]);
    }
    QString style = arg1;
    if (!style.contains(QStringLiteral("://")))
        style = QStringLiteral("file://") + QFileInfo(style).absoluteFilePath();

    auto *widget = cpn::makeMapWidget(style, lat, lon, zoom);
    widget->resize(1024, 768);
    widget->setWindowTitle(QStringLiteral("chartplotter-qt"));
    widget->show();
    return app.exec();
}
