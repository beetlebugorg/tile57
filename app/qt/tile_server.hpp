// ChartBackend (class TileServer) — runs ALL chart startup AND tile serving on one
// background thread, so the main thread is free for UI.
//
// QMapLibre links its own mbgl-core with hidden visibility, so the headless
// FileSourceManager hijack (app/chart_tile_source.*) can't be reused — its symbols
// aren't exported. Instead this opens the chart with libtile57 and serves the same
// tiles over HTTP (GET /{z}/{x}/{y} -> decompressed MVT); the style's vector source
// points at http://127.0.0.1:<port>/, which QMapLibre fetches normally.
//
// Lifecycle: construct, moveToThread(worker), connect signals, then wire
// QThread::started -> run(). run() opens/indexes/bakes the source (emitting
// progress), starts the HTTP server, stages the rewritten style, and emits ready();
// the thread's event loop then serves tiles. The tile57_source is opened and used
// only on this thread (it is not internally synchronized — see tile57.h).
#pragma once

#include "tile57.h"

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QString>

class QTcpServer;
class QTcpSocket;

namespace cpn {

class TileServer : public QObject {
    Q_OBJECT
public:
    // chartPath: ENC_ROOT / cell / pmtiles. exePath: argv[0] (for locating the
    // S-101 rules + style template). styleTemplate: explicit template or "" to
    // auto-resolve. haveCamera/lat/lon/zoom: an explicit camera, else framed.
    TileServer(QString chartPath, QString exePath, QString styleTemplate, bool haveCamera,
               double lat, double lon, double zoom, QObject *parent = nullptr);
    ~TileServer() override;

public slots:
    void run(); // open the source, start serving, emit ready()/failed()

signals:
    void progress(const QString &stage, quint64 done, quint64 total);
    // The raw (tile-URL-rewritten) style template + S-52 colortables, handed to the
    // UI thread, which owns the MarinerSettings and (re)builds the style live.
    // presentBands is the bitmask of navigational bands in the source (for the
    // data-driven band-filter column; 0 = single cell / pmtiles).
    void ready(const QString &templateJson, const QString &colortablesJson, double lat, double lon,
               double zoom, double minZoomFloor, quint32 presentBands);
    void failed(const QString &reason);
    // Live tile activity for a loading indicator (cross-thread, queued).
    void activity(int inflight, quint64 served);

private slots:
    void onNewConnection();
    void onReadyRead();

private:
    void respond(QTcpSocket *sock, int z, long x, long y);

    const QString chartPath_;
    const QString exePath_;
    const QString styleTemplate_;
    const bool haveCamera_;
    double lat_, lon_, zoom_;

    tile57_source *src_ = nullptr;
    QTcpServer *server_ = nullptr;
    int inflight_ = 0;
    quint64 served_ = 0;
    QHash<QTcpSocket *, QByteArray> buffers_; // per-connection request accumulation
};

} // namespace cpn
