// chartplotter-qt — interactive marine-chart viewer built on the Qt6 MapLibre
// widget (QMapLibre::MapWidget, from maplibre-native-qt). Two ways to open a chart:
//
//   chartplotter-qt <style.json|url> [lat lon zoom]
//       Load a pre-baked MapLibre style (its sources reference baked PMTiles).
//
//   chartplotter-qt <ENC_ROOT|cell.000|archive.pmtiles> [style.json] [lat lon zoom]
//       Open an S-57 chart live via libtile57: tiles are generated in-process and
//       served to the widget over a localhost HTTP endpoint. The style template is
//       optional (defaults to style/chart-zig-day.json; override with the arg or
//       CHARTPLOTTER_STYLE). All of that startup runs on a background thread so the
//       UI stays responsive; a splash shows load progress until the map is ready.
//
//   e.g. chartplotter-qt path/to/ENC_ROOT 38.97 -76.49 13
//
// The live path needs libtile57 (and the S-101 rules); it's compiled in when the
// build links it (CHARTPLOTTER_WITH_TILE57). Without it, only style files load.

#include <QApplication>
#include <QFileInfo>
#include <QString>

#include <QMapLibre/Map>
#include <QMapLibre/Settings>
#include <QMapLibre/Types>
#include <QMapLibreWidgets/MapWidget>

#include <QEvent>
#include <QMouseEvent>
#include <QPointF>
#include <QTimer>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>

#ifdef CHARTPLOTTER_WITH_TILE57
#include "mariner_panel.hpp"
#include "tile_server.hpp"

#include "chartstyle/chart_style.hpp"
#include "chartstyle/mariner.hpp"

#include <QColor>
#include <QCoreApplication>
#include <QDir>
#include <QDockWidget>
#include <QLabel>
#include <QMainWindow>
#include <QPixmap>
#include <QSplashScreen>
#include <QTemporaryFile>
#include <QThread>

#include <string>
#endif

namespace {

// Inertial panning ("throw the map"): MapWidget pans on drag but stops dead on
// release. This event filter tracks pointer velocity during a left-drag and, on
// release, animates a decelerating moveBy so the map glides to a stop. It never
// consumes events, so the widget's own drag/zoom still work. (We can't subclass
// MapWidget — its typeinfo isn't exported from the framework — so a filter it is.)
class MapFling : public QObject {
public:
    explicit MapFling(QMapLibre::MapWidget *w) : QObject(w), widget_(w) {
        timer_ = new QTimer(this);
        timer_->setInterval(16); // ~60 fps
        QObject::connect(timer_, &QTimer::timeout, this, [this] { tick(); });
        w->installEventFilter(this);
    }

protected:
    bool eventFilter(QObject *, QEvent *ev) override {
        switch (ev->type()) {
        case QEvent::MouseButtonPress: {
            timer_->stop(); // grabbing the map halts any glide
            auto *me = static_cast<QMouseEvent *>(ev);
            if (me->button() == Qt::LeftButton) {
                dragging_ = true;
                lastPos_ = me->position();
                lastT_ = me->timestamp();
                vel_ = QPointF(0, 0);
            }
            break;
        }
        case QEvent::MouseMove: {
            auto *me = static_cast<QMouseEvent *>(ev);
            if (dragging_ && (me->buttons() & Qt::LeftButton) && !(me->modifiers() & Qt::ShiftModifier)) {
                const QPointF pos = me->position();
                const quint64 t = me->timestamp();
                const double dt = double(t - lastT_);
                if (dt > 0 && dt < 200) {
                    const QPointF inst = (pos - lastPos_) / dt; // px/ms, matches moveBy's drag delta
                    constexpr double a = 0.4;                   // EMA toward the latest sample
                    vel_ = inst * a + vel_ * (1 - a);
                }
                lastPos_ = pos;
                lastT_ = t;
            }
            break;
        }
        case QEvent::MouseButtonRelease: {
            auto *me = static_cast<QMouseEvent *>(ev);
            if (me->button() == Qt::LeftButton && dragging_) {
                dragging_ = false;
                if (double(me->timestamp() - lastT_) > 80.0) vel_ = QPointF(0, 0); // paused before release
                const double speed = std::hypot(vel_.x(), vel_.y());
                constexpr double kMin = 0.05, kCap = 6.0; // px/ms
                if (speed > kMin) {
                    if (speed > kCap) vel_ *= kCap / speed;
                    timer_->start();
                }
            }
            break;
        }
        default:
            break;
        }
        return false; // observe only
    }

private:
    void tick() {
        auto *m = widget_->map();
        if (!m) {
            timer_->stop();
            return;
        }
        constexpr double dt = 16.0;
        m->moveBy(vel_ * dt);
        vel_ *= 0.95; // friction per tick
        if (std::hypot(vel_.x(), vel_.y()) * dt < 0.1) timer_->stop();
    }

    QMapLibre::MapWidget *widget_;
    QTimer *timer_;
    bool dragging_ = false;
    QPointF lastPos_, vel_;
    quint64 lastT_ = 0;
};

// Create a MapWidget on a style URL with an initial camera + inertial panning. The
// caller sizes/shows it (directly, or inside a QMainWindow). Shared by both modes.
QMapLibre::MapWidget *makeMapWidget(const QString &styleUrl, double lat, double lon, double zoom) {
    QMapLibre::Styles styles;
    styles.emplace_back(styleUrl, QStringLiteral("Chart"));

    QMapLibre::Settings settings;
    settings.setStyles(styles);
    settings.setDefaultCoordinate(QMapLibre::Coordinate(lat, lon)); // (latitude, longitude)
    settings.setDefaultZoom(zoom);

    auto *widget = new QMapLibre::MapWidget(settings);
    new MapFling(widget); // inertial panning; parented to the widget
    return widget;
}

#ifdef CHARTPLOTTER_WITH_TILE57
// A path is a "style" if it's a regular .json file (or a URL); anything else (a
// directory, a .000 cell, a .pmtiles archive) is opened as a live chart source.
bool looksLikeStyle(const QString &path) {
    if (path.contains(QStringLiteral("://"))) return true;
    QFileInfo fi(path);
    return fi.isFile() && path.endsWith(QStringLiteral(".json"), Qt::CaseInsensitive);
}

// Below the chart source's minzoom MapLibre has no tile to draw (blank screen), so
// snap zoom back to the floor. The Map only exists once the widget's GPU has
// initialized, so poll for it, then clamp on every map change.
void installZoomFloor(QMapLibre::MapWidget *widget, double floor) {
    if (floor <= 0.0) return;
    auto *poll = new QTimer(widget);
    QObject::connect(poll, &QTimer::timeout, widget, [widget, poll, floor] {
        auto *m = widget->map();
        if (!m) return; // not ready yet — keep polling
        poll->stop();
        // Re-entrancy guard: setZoom() fires mapChanged again synchronously
        // (onCameraWillChange) BEFORE the zoom updates, so an unguarded handler
        // re-reads the still-below-floor zoom and recurses until the stack blows.
        auto clamping = std::make_shared<bool>(false);
        QObject::connect(m, &QMapLibre::Map::mapChanged, m, [m, floor, clamping](QMapLibre::Map::MapChange) {
            if (*clamping || m->zoom() >= floor - 1e-3) return;
            *clamping = true;
            m->setZoom(floor);
            *clamping = false;
        });
    });
    poll->start(50);
}

// A small overlay that shows while tiles are being generated and fades out shortly
// after activity stops.
void installTileIndicator(QMapLibre::MapWidget *widget, cpn::TileServer *backend) {
    auto *status = new QLabel(widget);
    status->setStyleSheet(QStringLiteral(
        "background: rgba(16,24,32,210); color: white; padding: 5px 10px; border-radius: 5px;"));
    status->move(12, 12);
    status->hide();
    auto *hideTimer = new QTimer(status);
    hideTimer->setSingleShot(true);
    QObject::connect(hideTimer, &QTimer::timeout, status, &QWidget::hide);
    QObject::connect(backend, &cpn::TileServer::activity, status,
                     [status, hideTimer](int inflight, quint64 served) {
                         if (inflight > 0) {
                             status->setText(QStringLiteral("Loading tiles…  %1").arg(qulonglong(served)));
                             status->adjustSize();
                             status->show();
                             status->raise();
                             hideTimer->stop();
                         } else {
                             hideTimer->start(700); // hide ~0.7s after the last tile
                         }
                     });
}

// Build the concrete style from the template + mariner settings (client-side, via
// the cross-platform chartstyle module). Without chartstyle, the template is used
// as-is.
std::string styledJson(const QString &templateJson, const chartstyle::MarinerSettings &s,
                       const QString &colortables) {
#ifdef CHARTPLOTTER_WITH_CHARTSTYLE
    return chartstyle::buildStyle(templateJson.toStdString(), s, colortables.toStdString());
#else
    (void)s;
    (void)colortables;
    return templateJson.toStdString();
#endif
}

// Stage a style JSON string in a temp file and return its file:// URL (the only way
// to hand QMapLibre::Settings an inline style for the initial load; live updates use
// Map::setStyleJson). The file persists for the process lifetime.
QString stageStyleFile(const std::string &json) {
    auto *tmp = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/chartplotter-qt-XXXXXX.json"));
    if (!tmp->open()) return {};
    tmp->write(json.data(), static_cast<qint64>(json.size()));
    tmp->flush();
    return QStringLiteral("file://") + tmp->fileName();
}
#endif // CHARTPLOTTER_WITH_TILE57

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
        // thread only drives the splash and (on ready) builds the widget. ----

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
                             splash->showMessage(QStringLiteral("Opening chart…\n\n") + m,
                                                 Qt::AlignCenter, Qt::white);
                         });
        QObject::connect(backend, &cpn::TileServer::failed, qApp,
                         [](const QString &why) {
                             std::fprintf(stderr, "%s\n", why.toUtf8().constData());
                             QCoreApplication::exit(1);
                         });
        QObject::connect(
            backend, &cpn::TileServer::ready, qApp,
            [splash, backend](const QString &templateJson, const QString &colortables, double lat,
                              double lon, double zoom, double minZoomFloor) {
                const chartstyle::MarinerSettings initial; // Go-matching defaults
                const QString initialUrl = stageStyleFile(styledJson(templateJson, initial, colortables));
                auto *widget = makeMapWidget(initialUrl, lat, lon, zoom);

                // Host the map in a window with a docked mariner-settings panel.
                auto *win = new QMainWindow;
                win->setWindowTitle(QStringLiteral("chartplotter-qt"));
                win->setCentralWidget(widget);
                auto *dock = new QDockWidget(QStringLiteral("Mariner settings"), win);
                auto *panel = new cpn::MarinerPanel(initial, dock);
                dock->setWidget(panel);
                dock->setAllowedAreas(Qt::LeftDockWidgetArea | Qt::RightDockWidgetArea);
                win->addDockWidget(Qt::RightDockWidgetArea, dock);
                win->resize(1280, 800);
                win->show();

                splash->finish(win);
                splash->deleteLater();
                installZoomFloor(widget, minZoomFloor);
                installTileIndicator(widget, backend);

                // Live restyle: rebuild the style from the new settings and apply it
                // without touching the camera or the tile source.
                QObject::connect(panel, &cpn::MarinerPanel::changed, widget,
                                 [widget, templateJson, colortables](const chartstyle::MarinerSettings &s) {
                                     if (auto *m = widget->map())
                                         m->setStyleJson(QString::fromStdString(
                                             styledJson(templateJson, s, colortables)));
                                 });
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

    auto *widget = makeMapWidget(style, lat, lon, zoom);
    widget->resize(1024, 768);
    widget->setWindowTitle(QStringLiteral("chartplotter-qt"));
    widget->show();
    return app.exec();
}
