#include "chart_window.hpp"

#include "band_panel.hpp"
#include "map_helpers.hpp"
#include "mariner_panel.hpp"
#include "tile_server.hpp"

#include "chartstyle/chart_style.hpp"

#include <QMapLibre/Map>
#include <QMapLibreWidgets/MapWidget>

#include <QDialog>
#include <QDir>
#include <QGroupBox>
#include <QLabel>
#include <QScrollArea>
#include <QTemporaryFile>
#include <QTimer>
#include <QToolButton>
#include <QVBoxLayout>

#include <memory>

namespace cpn {
namespace {

// Build the concrete style from the template + mariner settings + enabled bands.
std::string styledJson(const QString &templateJson, const chartstyle::MarinerSettings &s,
                       const QString &colortables, const std::vector<int> *enabledBands) {
    return chartstyle::buildStyle(templateJson.toStdString(), s, colortables.toStdString(), enabledBands);
}

// Stage a style JSON in a temp file and return its file:// URL — the only way to
// hand QMapLibre::Settings an inline style for the INITIAL load (live updates use
// Map::setStyleJson). Kept for the process lifetime.
QString stageStyleFile(const std::string &json) {
    auto *tmp = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/chartplotter-qt-XXXXXX.json"));
    if (!tmp->open()) return {};
    tmp->write(json.data(), static_cast<qint64>(json.size()));
    tmp->flush();
    return QStringLiteral("file://") + tmp->fileName();
}

// Below the source's minzoom MapLibre has no tile to draw (blank), so snap back. The
// Map only exists after GPU init, so poll for it, then clamp on every map change.
void installZoomFloor(QMapLibre::MapWidget *widget, double floor) {
    if (floor <= 0.0) return;
    auto *poll = new QTimer(widget);
    QObject::connect(poll, &QTimer::timeout, widget, [widget, poll, floor] {
        auto *m = widget->map();
        if (!m) return;
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

// A small top-left overlay shown while tiles are being generated; fades out shortly
// after activity stops.
void installTileIndicator(QMapLibre::MapWidget *widget, TileServer *backend) {
    auto *status = new QLabel(widget);
    status->setStyleSheet(QStringLiteral(
        "background: rgba(16,24,32,210); color: white; padding: 5px 10px; border-radius: 5px;"));
    status->move(12, 12);
    status->hide();
    auto *hideTimer = new QTimer(status);
    hideTimer->setSingleShot(true);
    QObject::connect(hideTimer, &QTimer::timeout, status, &QWidget::hide);
    QObject::connect(backend, &TileServer::activity, status, [status, hideTimer](int inflight, quint64 served) {
        if (inflight > 0) {
            status->setText(QStringLiteral("Loading tiles…  %1").arg(qulonglong(served)));
            status->adjustSize();
            status->show();
            status->raise();
            hideTimer->stop();
        } else {
            hideTimer->start(700);
        }
    });
}

} // namespace

ChartWindow::ChartWindow(QString templateJson, QString colortables, quint32 presentBands,
                         TileServer *backend, double lat, double lon, double zoom, double minZoomFloor,
                         QWidget *parent)
    : QMainWindow(parent), templateJson_(std::move(templateJson)), colortables_(std::move(colortables)) {
    setWindowTitle(QStringLiteral("chartplotter-qt"));

    // Initial style: built from the defaults + all bands, staged for the URL load.
    const QString initialUrl =
        stageStyleFile(styledJson(templateJson_, settings_, colortables_, nullptr));
    map_ = makeMapWidget(initialUrl, lat, lon, zoom);
    setCentralWidget(map_);
    installZoomFloor(map_, minZoomFloor);
    installTileIndicator(map_, backend);

    // --- Settings popup: a non-modal dialog opened by a corner button, holding the
    // band-filter column (if the source has bands) + the mariner-settings panel. ---
    auto *panel = new cpn::MarinerPanel(settings_);
    cpn::BandPanel *bandPanel = nullptr;

    auto *dialog = new QDialog(this, Qt::Tool | Qt::FramelessWindowHint);
    dialog->setWindowTitle(QStringLiteral("Display settings"));
    auto *dlgLayout = new QVBoxLayout(dialog);
    dlgLayout->setContentsMargins(0, 0, 0, 0);
    auto *scroll = new QScrollArea;
    scroll->setWidgetResizable(true);
    scroll->setFrameShape(QFrame::NoFrame);
    auto *content = new QWidget;
    auto *contentCol = new QVBoxLayout(content);
    contentCol->setContentsMargins(12, 12, 12, 12);
    contentCol->setSpacing(14);

    if (presentBands != 0) {
        bandPanel = new cpn::BandPanel(presentBands);
        if (bandPanel->hasBands()) {
            hasBands_ = true;
            enabledBands_ = bandPanel->enabled();
            auto *chartsBox = new QGroupBox(QStringLiteral("Charts"));
            auto *chartsCol = new QVBoxLayout(chartsBox);
            chartsCol->setContentsMargins(0, 0, 0, 0);
            chartsCol->addWidget(bandPanel);
            contentCol->addWidget(chartsBox);
            QObject::connect(bandPanel, &cpn::BandPanel::changed, this,
                             [this](const std::vector<int> &e) { enabledBands_ = e; restyle(); });
        }
    }
    contentCol->addWidget(panel);
    scroll->setWidget(content);
    dlgLayout->addWidget(scroll);
    dialog->resize(320, 720);
    dialog->hide();

    QObject::connect(panel, &cpn::MarinerPanel::changed, this,
                     [this](const chartstyle::MarinerSettings &s) { settings_ = s; restyle(); });

    // The corner toggle button. Repositions to the top-right on each map change.
    auto *btn = new QToolButton(map_);
    btn->setText(QStringLiteral("☰ Settings"));
    btn->setStyleSheet(QStringLiteral("QToolButton { background: rgba(16,24,32,210); color: white; "
                                      "padding: 6px 12px; border-radius: 5px; }"));
    btn->adjustSize();
    btn->move(map_->width() - btn->width() - 12, 12);
    btn->show();
    QObject::connect(btn, &QToolButton::clicked, this, [this, dialog, btn] {
        if (dialog->isVisible()) {
            dialog->hide();
            return;
        }
        const QPoint tr = btn->mapToGlobal(QPoint(btn->width(), btn->height() + 6));
        dialog->move(tr.x() - dialog->width(), tr.y());
        dialog->show();
        dialog->raise();
    });
    // Keep the button pinned top-right as the window resizes (cheap, on map change).
    auto *reposition = new QTimer(this);
    reposition->setInterval(200);
    QObject::connect(reposition, &QTimer::timeout, btn,
                     [this, btn] { btn->move(map_->width() - btn->width() - 12, 12); });
    reposition->start();

    resize(1280, 800);
}

void ChartWindow::restyle() {
    if (auto *m = map_->map())
        m->setStyleJson(QString::fromStdString(
            styledJson(templateJson_, settings_, colortables_, hasBands_ ? &enabledBands_ : nullptr)));
}

} // namespace cpn
