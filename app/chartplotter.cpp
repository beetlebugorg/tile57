// libchartplotter — the embeddable chart-widget library. Implements the C API in
// include/chartplotter.h: open a window and draw S-52 charts with MapLibre
// Native (sourcing tiles from libtile57 via ChartTileSource), or render a chart
// to a PNG offscreen.
//
// The window half is compiled only when built with GLFW (CHARTPLOTTER_WITH_GLFW,
// set by CMake in the desktop presets); a headless build still provides
// chartplotter_render_png and stubs the window calls.
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
// to ChartTileSource is too: one active chart at a time (one window or one render
// in flight). Set before each Map is constructed.
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
    map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{lat, lon}).withZoom(zoom));

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

#ifdef CHARTPLOTTER_WITH_GLFW

#include "glfw_renderer_frontend.hpp"
#include "glfw_view.hpp"

#include <mbgl/gfx/backend.hpp>
#include <mbgl/renderer/renderer.hpp>
#include <mbgl/util/geo.hpp>

#include <cstdlib>
#include <memory>

namespace {
// Continuous-render observer (opt-in via CHART_CONTINUOUS): re-invalidate each
// frame / on idle so the view keeps presenting on displays where the layer goes
// blank when drawing stops. On-demand (the bare GLFWView) is the default.
class ContinuousObserver final : public mbgl::MapObserver {
public:
    explicit ContinuousObserver(GLFWView &v) : view(v) {}
    void onWillStartRenderingFrame() override { view.onWillStartRenderingFrame(); }
    void onDidFinishLoadingStyle() override { view.onDidFinishLoadingStyle(); }
    void onDidFinishRenderingFrame(const RenderFrameStatus &) override { view.invalidate(); }
    void onDidBecomeIdle() override { view.invalidate(); }

private:
    GLFWView &view;
};
} // namespace

struct chartplotter_view {
    tile57_source *src = nullptr;
    std::unique_ptr<GLFWView> view;
    std::unique_ptr<GLFWRendererFrontend> frontend;
    std::unique_ptr<ContinuousObserver> contObserver;
    std::unique_ptr<mbgl::Map> map;
};

extern "C" chartplotter_view *chartplotter_view_open(const char *chart_path,
                                                     const chartplotter_view_options *opts) {
    if (!chart_path || !opts || !opts->style_path) return nullptr;

    g_src = cpn::openPath(chart_path, opts->rules_dir);
    if (!g_src) {
        std::fprintf(stderr, "could not open chart: %s\n", chart_path);
        return nullptr;
    }

    double bw = 0, bs = 0, be = 0, bn = 0;
    const bool haveBounds = tile57_source_bounds(g_src, &bw, &bs, &be, &bn);

    mbgl::ResourceOptions resourceOptions;
    resourceOptions.withCachePath(":memory:").withAssetPath(".");
    mbgl::ClientOptions clientOptions;

    auto *v = new chartplotter_view();
    v->src = g_src;

    // GLFWView first: it creates the window + backend and owns the RunLoop.
    v->view = std::make_unique<GLFWView>(/*fullscreen*/ false, /*benchmark*/ false,
                                         resourceOptions, clientOptions);
    v->frontend = std::make_unique<GLFWRendererFrontend>(
        std::make_unique<mbgl::Renderer>(v->view->getRendererBackend(), v->view->getPixelRatio()),
        *v->view);

    registerChartSource(); // before the Map builds its resource loader

    const bool continuous = std::getenv("CHART_CONTINUOUS") != nullptr;
    v->contObserver = std::make_unique<ContinuousObserver>(*v->view);
    mbgl::MapObserver &observer = continuous ? static_cast<mbgl::MapObserver &>(*v->contObserver)
                                             : static_cast<mbgl::MapObserver &>(*v->view);
    v->map = std::make_unique<mbgl::Map>(
        *v->frontend, observer,
        mbgl::MapOptions().withSize(v->view->getSize()).withPixelRatio(v->view->getPixelRatio()),
        resourceOptions, clientOptions);

    v->view->setMap(v->map.get());
    v->view->setWindowTitle(opts->title ? opts->title : "chartplotter");

    // Camera: explicit centre+zoom when zoom > 0; otherwise fit the data bounds.
    if (opts->zoom > 0) {
        v->map->jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{opts->lat, opts->lon}).withZoom(opts->zoom));
    } else if (haveBounds) {
        const auto bounds = mbgl::LatLngBounds::hull(mbgl::LatLng{bs, bw}, mbgl::LatLng{bn, be});
        v->map->jumpTo(v->map->cameraForLatLngBounds(bounds, mbgl::EdgeInsets{20, 20, 20, 20}));
    } else {
        v->map->jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{38.978, -76.487}).withZoom(13.0));
    }
    v->map->getStyle().loadJSON(readFile(opts->style_path));
    return v;
}

extern "C" void chartplotter_view_run(chartplotter_view *view) {
    if (view && view->view) view->view->run();
}

extern "C" void chartplotter_view_close(chartplotter_view *view) {
    if (!view) return;
    // Destruction order: map (holds ChartTileSource) before frontend/view. The
    // chart source is intentionally not closed (UAF during Map teardown).
    view->map.reset();
    view->frontend.reset();
    view->contObserver.reset();
    view->view.reset();
    delete view;
}

#else // !CHARTPLOTTER_WITH_GLFW — headless build: window calls are no-ops.

struct chartplotter_view {
    int unused;
};
extern "C" chartplotter_view *chartplotter_view_open(const char *, const chartplotter_view_options *) {
    std::fprintf(stderr, "chartplotter built without window support (no GLFW)\n");
    return nullptr;
}
extern "C" void chartplotter_view_run(chartplotter_view *) {}
extern "C" void chartplotter_view_close(chartplotter_view *) {}

#endif
