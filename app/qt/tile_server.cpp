#include "tile_server.hpp"

#include "enc_root.hpp" // cpn::openPath, cpn::resolveRulesDir

#include <QFileInfo>
#include <QTcpServer>
#include <QTcpSocket>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace cpn {
namespace {

// Find the live-chart style template: CHARTPLOTTER_STYLE if set, else search for
// style/chart-zig-day.json relative to the CWD and the executable, walking up.
// Find a repo-relative file (e.g. "style/chart-zig-day.json",
// "reference/assets/colortables.json") by walking up from the CWD and the exe dir.
std::string findRepoFile(const std::string &exePath, const std::string &suffix) {
    namespace fs = std::filesystem;
    std::error_code ec;
    std::vector<fs::path> starts;
    starts.push_back(fs::current_path(ec));
    if (!exePath.empty()) {
        const fs::path exe = fs::weakly_canonical(fs::path(exePath), ec);
        if (!ec && exe.has_parent_path()) starts.push_back(exe.parent_path());
    }
    for (const auto &start : starts) {
        for (fs::path p = start;; p = p.parent_path()) {
            const fs::path cand = p / suffix;
            if (fs::exists(cand, ec)) return cand.string();
            if (!p.has_parent_path() || p == p.parent_path()) break;
        }
    }
    return std::string();
}

std::string resolveStyleTemplate(const std::string &exePath) {
    if (const char *env = std::getenv("CHARTPLOTTER_STYLE"); env && *env) return env;
    return findRepoFile(exePath, "style/chart-zig-day.json");
}

std::string readWhole(const std::string &path) {
    if (path.empty()) return {};
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// WebMercator zoom that fits [west,south,east,north] into a wxh pixel viewport.
double fitZoom(double west, double south, double east, double north, double w, double h) {
    const double lonSpan = std::max(1e-6, east - west);
    auto mercY = [](double lat) {
        const double s = std::sin(lat * M_PI / 180.0);
        return std::log((1 + s) / (1 - s)) / 2.0;
    };
    const double ySpan = std::max(1e-6, std::fabs(mercY(north) - mercY(south)));
    const double zx = std::log2((w / 256.0) * (360.0 / lonSpan));
    const double zy = std::log2((h / 256.0) * (2.0 * M_PI / ySpan));
    return std::min(zx, zy) - 0.15; // a touch of padding
}

// The chart source's minzoom from the style template (its first "minzoom"), used as
// the zoom-out floor. Returns `fallback` if absent/unparseable.
double styleSourceMinZoom(const std::string &json, double fallback) {
    const auto key = json.find("\"minzoom\"");
    if (key == std::string::npos) return fallback;
    const auto colon = json.find(':', key);
    if (colon == std::string::npos) return fallback;
    const double v = std::atof(json.c_str() + colon + 1);
    return v > 0.0 ? v : fallback;
}

} // namespace

TileServer::TileServer(QString chartPath, QString exePath, QString styleTemplate, bool haveCamera,
                       double lat, double lon, double zoom, QObject *parent)
    : QObject(parent), chartPath_(std::move(chartPath)), exePath_(std::move(exePath)),
      styleTemplate_(std::move(styleTemplate)), haveCamera_(haveCamera), lat_(lat), lon_(lon),
      zoom_(zoom) {}

TileServer::~TileServer() = default;

void TileServer::run() {
    // Throttle progress emissions so a huge ENC_ROOT doesn't flood the main thread.
    using clock = std::chrono::steady_clock;
    auto last = clock::now();
    auto prog = [&](const char *stage, std::size_t done, std::size_t total) {
        const auto now = clock::now();
        const bool boundary = total == 0 || done == 0 || done == total;
        if (!boundary && std::chrono::duration<double>(now - last).count() < 0.05) return;
        last = now;
        emit progress(QString::fromUtf8(stage), done, total);
    };

    const std::string rules = cpn::resolveRulesDir(exePath_.isEmpty() ? nullptr : exePath_.toUtf8().constData());
    src_ = cpn::openPath(chartPath_.toStdString(), rules.empty() ? nullptr : rules.c_str(), prog);
    if (!src_) {
        emit failed(QStringLiteral("could not open chart source: %1").arg(chartPath_));
        return;
    }

    std::string tmpl = styleTemplate_.toStdString();
    if (tmpl.empty()) tmpl = resolveStyleTemplate(exePath_.toStdString());
    if (tmpl.empty()) {
        emit failed(QStringLiteral("could not find a style template (looked for style/chart-zig-day.json; "
                                   "set CHARTPLOTTER_STYLE=/path/to/style.json)"));
        return;
    }

    // Frame the camera from the data unless the user gave one (read before serving:
    // the source is single-threaded and only this thread may touch it).
    double lat = lat_, lon = lon_, zoom = zoom_;
    if (!haveCamera_) {
        double w = 0, s = 0, e = 0, n = 0, alat = 0, alon = 0, az = 0;
        if (tile57_source_anchor(src_, &alat, &alon, &az)) {
            lat = alat; lon = alon; zoom = az;
        } else if (tile57_source_bounds(src_, &w, &s, &e, &n)) {
            lat = (s + n) / 2.0; lon = (w + e) / 2.0;
            zoom = fitZoom(w, s, e, n, 1024, 768);
        }
    }

    emit progress(QStringLiteral("starting renderer"), 0, 0);

    server_ = new QTcpServer(this);
    connect(server_, &QTcpServer::newConnection, this, &TileServer::onNewConnection);
    if (!server_->listen(QHostAddress::LocalHost, 0)) {
        emit failed(QStringLiteral("tile server failed to listen: %1").arg(server_->errorString()));
        return;
    }
    const quint16 port = server_->serverPort();

    // Point the template's vector source at the live HTTP endpoint.
    std::ifstream f(tmpl, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    std::string json = ss.str();

    const double minZoomFloor = styleSourceMinZoom(json, 0.0);
    const std::string fromUrl = "zigtiles://{z}/{x}/{y}";
    const std::string toUrl = "http://127.0.0.1:" + std::to_string(port) + "/{z}/{x}/{y}";
    for (size_t i = json.find(fromUrl); i != std::string::npos; i = json.find(fromUrl, i + toUrl.size()))
        json.replace(i, fromUrl.size(), toUrl);

    // Hand the raw (URL-rewritten) template + S-52 colortables to the UI thread; it
    // owns the MarinerSettings and (re)builds the style via chartstyle::buildStyle.
    const std::string cts = readWhole(findRepoFile(exePath_.toStdString(), "reference/assets/colortables.json"));

    std::fprintf(stderr, "[chart] serving %s on http://127.0.0.1:%u\n",
                 chartPath_.toUtf8().constData(), port);
    emit ready(QString::fromStdString(json), QString::fromStdString(cts), lat, lon, zoom, minZoomFloor);
}

void TileServer::onNewConnection() {
    while (server_->hasPendingConnections()) {
        QTcpSocket *sock = server_->nextPendingConnection();
        buffers_.insert(sock, QByteArray());
        connect(sock, &QTcpSocket::readyRead, this, &TileServer::onReadyRead);
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        connect(sock, &QObject::destroyed, this, [this, sock] { buffers_.remove(sock); });
    }
}

void TileServer::onReadyRead() {
    auto *sock = qobject_cast<QTcpSocket *>(sender());
    if (!sock) return;
    QByteArray &buf = buffers_[sock];
    buf += sock->readAll();

    // Wait for the full request head; GET tile requests carry no body.
    const int head = buf.indexOf("\r\n\r\n");
    if (head < 0) {
        if (buf.size() > 8192) sock->disconnectFromHost(); // runaway request line
        return;
    }

    // Parse the request line: "GET /<z>/<x>/<y>[.ext] HTTP/1.1".
    const QByteArray line = buf.left(buf.indexOf("\r\n"));
    int z = 0;
    long x = 0, y = 0;
    bool ok = false;
    const int sp = line.indexOf(' ');
    if (sp > 0) {
        const int sp2 = line.indexOf(' ', sp + 1);
        QByteArray path = line.mid(sp + 1, (sp2 > 0 ? sp2 : line.size()) - sp - 1);
        const int dot = path.indexOf('.'); // drop /{z}/{x}/{y}.pbf extension
        if (dot >= 0) path.truncate(dot);
        const int q = path.indexOf('?');
        if (q >= 0) path.truncate(q);
        ok = std::sscanf(path.constData(), "/%d/%ld/%ld", &z, &x, &y) == 3;
    }

    if (!ok) {
        sock->write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        sock->disconnectFromHost();
        return;
    }
    respond(sock, z, x, y);
}

void TileServer::respond(QTcpSocket *sock, int z, long x, long y) {
    emit activity(++inflight_, served_); // a tile is now being generated

    uint8_t *out = nullptr;
    size_t len = 0;
    const tile57_tile_status rc =
        tile57_tile_get(src_, static_cast<uint8_t>(z), static_cast<uint32_t>(x),
                        static_cast<uint32_t>(y), &out, &len);

    if (rc == TILE57_TILE_OK) {
        // Decompressed MVT (application/x-protobuf); mbgl parses the raw protobuf.
        QByteArray header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\n"
                            "Content-Length: " +
                            QByteArray::number(static_cast<qlonglong>(len)) +
                            "\r\nConnection: close\r\n\r\n";
        sock->write(header);
        sock->write(reinterpret_cast<const char *>(out), static_cast<qint64>(len));
        tile57_tile_free(out, len);
    } else if (rc == TILE57_TILE_EMPTY) {
        sock->write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    } else {
        sock->write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
    if (rc == TILE57_TILE_OK || rc == TILE57_TILE_EMPTY) ++served_;
    emit activity(--inflight_, served_); // done generating this tile
    sock->disconnectFromHost();
}

} // namespace cpn
