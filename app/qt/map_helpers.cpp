#include "map_helpers.hpp"

#include <QMapLibre/Map>
#include <QMapLibre/Settings>
#include <QMapLibre/Types>

#include <QEvent>
#include <QLabel>
#include <QLocale>
#include <QMouseEvent>
#include <QPointF>
#include <QTimer>

#include <cmath>

namespace cpn {
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

// --- Status HUD (band · scale · zoom · position + overscale), ported ~1:1 from the
// Go web client's hud.mjs / bands.mjs / util.mjs. ---

struct BandInfo {
    const char *label;
    double maxZoom; // native max display zoom; past it the chart is overscaled
};
// bandForZoom (bands.mjs): the finest band whose source paints at zoom z.
BandInfo bandForZoom(double z) {
    if (z >= 16) return {"Berthing", 18};
    if (z >= 14) return {"Harbor", 16};
    if (z >= 12) return {"Approach", 13};
    if (z >= 10) return {"Coastal", 11};
    if (z >= 8) return {"General", 9};
    return {"Overview", 7};
}
// scaleDenomPhysical (util.mjs): the ruler-on-glass 1:N denominator at z/lat, using
// the default 0.2645 mm CSS-pixel pitch and the 512-tile z0 resolution.
double scaleDenomPhysical(double z, double lat) {
    constexpr double M_PER_PX_Z0 = 78271.516964020485, PX_PITCH_MM = 0.2645;
    const double mPerCssPx = M_PER_PX_Z0 * std::cos(lat * M_PI / 180.0) / std::pow(2.0, z);
    return mPerCssPx / (PX_PITCH_MM / 1000.0);
}
// fmtScale (util.mjs): round to 3 significant figures, group thousands.
QString fmtScale(double d) {
    if (!(d > 0) || !std::isfinite(d)) return QStringLiteral("—");
    const double mag = std::pow(10.0, std::max(0.0, std::floor(std::log10(d)) - 2));
    return QLocale().toString(static_cast<qlonglong>(std::llround(d / mag) * static_cast<qlonglong>(mag)));
}
// fmtLatLon (util.mjs): fixed-width degrees-decimal-minutes, e.g. "40°45.0′N 73°24.0′W".
QString fmtLatLon(double lat, double lng) {
    const auto dm = [](double v, int degDigits) {
        double a = std::abs(v);
        int d = static_cast<int>(std::floor(a));
        double m = (a - d) * 60.0;
        if (m >= 59.95) { m = 0; d += 1; }
        return QStringLiteral("%1°%2′").arg(d, degDigits, 10, QLatin1Char('0')).arg(m, 4, 'f', 1, QLatin1Char('0'));
    };
    const double x = std::fmod(std::fmod(lng + 180.0, 360.0) + 360.0, 360.0) - 180.0;
    return dm(lat, 2) + (lat >= 0 ? "N" : "S") + " " + dm(x, 3) + (x >= 0 ? "E" : "W");
}

// A bottom-left status readout, refreshed on every map move.
void installStatusBox(QMapLibre::MapWidget *widget) {
    auto *hud = new QLabel(widget);
    hud->setStyleSheet(QStringLiteral("background: rgba(16,24,32,210); color: #e8eef2; "
                                      "padding: 4px 10px; border-radius: 5px;"));
    hud->setText(QStringLiteral(" "));
    const auto update = [widget, hud] {
        auto *m = widget->map();
        if (!m) return;
        const double z = m->zoom();
        const QMapLibre::Coordinate c = m->coordinate(); // (latitude, longitude)
        const BandInfo b = bandForZoom(z);
        QString t = QStringLiteral("%1   ·   1:%2   ·   z%3   ·   %4")
                        .arg(QString::fromUtf8(b.label), fmtScale(scaleDenomPhysical(z, c.first)),
                             QString::number(z, 'f', 1), fmtLatLon(c.first, c.second));
        // Overscale (S-52 §10.1.10.1): zoomed past the band's native scale → ×N.
        if (z > b.maxZoom + 0.01)
            t += QStringLiteral("   ⚠ overscale ×%1").arg(qRound(std::pow(2.0, z - b.maxZoom)));
        hud->setText(t);
        hud->adjustSize();
        hud->move(10, widget->height() - hud->height() - 10);
        hud->raise();
    };
    auto *poll = new QTimer(widget);
    QObject::connect(poll, &QTimer::timeout, widget, [widget, poll, update] {
        auto *m = widget->map();
        if (!m) return;
        poll->stop();
        QObject::connect(m, &QMapLibre::Map::mapChanged, m, [update](QMapLibre::Map::MapChange) { update(); });
        update();
    });
    poll->start(50);
}

} // namespace

QMapLibre::MapWidget *makeMapWidget(const QString &styleUrl, double lat, double lon, double zoom) {
    QMapLibre::Styles styles;
    styles.emplace_back(styleUrl, QStringLiteral("Chart"));

    QMapLibre::Settings settings;
    settings.setStyles(styles);
    settings.setDefaultCoordinate(QMapLibre::Coordinate(lat, lon)); // (latitude, longitude)
    settings.setDefaultZoom(zoom);

    auto *widget = new QMapLibre::MapWidget(settings);
    new MapFling(widget);     // inertial panning; parented to the widget
    installStatusBox(widget); // band · scale · zoom · position HUD
    return widget;
}

} // namespace cpn
