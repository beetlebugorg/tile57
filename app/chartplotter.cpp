// libchartplotter — renders an S-52 chart to a PNG offscreen with MapLibre
// Native, sourcing vector tiles from libtile57 (the S-57 tile generator) via
// ChartTileSource. Implements chartplotter_render_png in include/chartplotter.h.
//
// The interactive window now lives in a separate Qt6 app (app/qt, the
// QMapLibre-based chartplotter-qt); this library is the headless render path
// (used by chartplotter-render for parity/verification).
#include "chartplotter.h"

#include "chart_tile_source.hpp"
#include "enc_root.hpp" // cpn::openPath, cpn::resolveRulesDir
#include "tile57.h"

#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/storage/file_source_manager.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/util/run_loop.hpp>

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

namespace {

// The MapLibre FileSource factory is process-global, so the chart source it hands
// to ChartTileSource is too: one active chart at a time (one render in flight).
// Set before each Map is constructed.
tile57_source *g_src = nullptr;

std::string readFile(const char *path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Route zigtiles:// requests to our source by registering ChartTileSource in the
// (unused) Mbtiles slot, before any Map is built.
void registerChartSource() {
    mbgl::FileSourceManager::get()->registerFileSourceFactory(
        mbgl::FileSourceType::Mbtiles,
        [](const mbgl::ResourceOptions &, const mbgl::ClientOptions &) -> std::unique_ptr<mbgl::FileSource> {
            return std::make_unique<cpn::ChartTileSource>(g_src);
        });
}

} // namespace

extern "C" const char *chartplotter_version(void) { return "0.1.0"; }

// Choose an initial camera for a source: fit the data bounds when that lands at a
// usable zoom (a single cell / a regional ENC_ROOT); otherwise — a continental
// ENC_ROOT whose union bbox would fit at ~z2 (below the style's source minzoom, so
// nothing draws) — open on a representative data cell; else a sensible default.
static void frameCamera(mbgl::Map &map, tile57_source *src) {
    double bw = 0, bs = 0, be = 0, bn = 0;
    if (tile57_source_bounds(src, &bw, &bs, &be, &bn)) {
        const auto bounds = mbgl::LatLngBounds::hull(mbgl::LatLng{bs, bw}, mbgl::LatLng{bn, be});
        const auto cam = map.cameraForLatLngBounds(bounds, mbgl::EdgeInsets{20, 20, 20, 20});
        if (cam.zoom && *cam.zoom >= 8.0) {
            map.jumpTo(cam);
            return;
        }
    }
    double alat = 0, alon = 0, azoom = 0;
    if (tile57_source_anchor(src, &alat, &alon, &azoom)) {
        map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{alat, alon}).withZoom(azoom));
        std::fprintf(stderr, "[chart] opening at %.4f,%.4f z%.0f\n", alat, alon, azoom);
        return;
    }
    map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{38.978, -76.487}).withZoom(13.0));
}

extern "C" int chartplotter_render_png(const char *chart_path, const char *style_path,
                                       const char *rules_dir, double lat, double lon, double zoom,
                                       uint32_t width, uint32_t height, float pixel_ratio,
                                       const char *out_png) {
    if (!chart_path || !style_path || !out_png) return 2;
    g_src = cpn::openPath(chart_path, rules_dir);
    if (!g_src) {
        std::fprintf(stderr, "could not open chart: %s\n", chart_path);
        return 1;
    }
    registerChartSource();

    mbgl::util::RunLoop loop;
    mbgl::HeadlessFrontend frontend({width, height}, pixel_ratio);
    mbgl::Map map(frontend, mbgl::MapObserver::nullObserver(),
                  mbgl::MapOptions()
                      .withMapMode(mbgl::MapMode::Static)
                      .withSize(frontend.getSize())
                      .withPixelRatio(pixel_ratio),
                  mbgl::ResourceOptions().withCachePath(":memory:").withAssetPath("."));
    map.getStyle().loadJSON(readFile(style_path));
    // zoom <= 0: auto-frame (same path the window uses), so it can be tested here.
    if (zoom > 0)
        map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{lat, lon}).withZoom(zoom));
    else
        frameCamera(map, g_src);

    int rc = 0;
    try {
        auto result = frontend.render(map);
        std::ofstream out(out_png, std::ios::binary);
        out << mbgl::encodePNG(result.image);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "render error: %s\n", e.what());
        rc = 1;
    }
    // g_src intentionally NOT closed: the Map (tearing down after this returns)
    // holds ChartTileSource referencing it; closing first would be a UAF. The
    // process reclaims it. (One render per process for the headless path.)
    return rc;
}
