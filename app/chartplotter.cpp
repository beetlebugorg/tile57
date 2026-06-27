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

#ifdef CHARTPLOTTER_WITH_GLFW

#include "glfw_renderer_frontend.hpp"
#include "glfw_view.hpp"

#if defined(CHARTPLOTTER_METAL)
// Metal: render via an MTKView (display-link/vsync driven) instead of GLFW's
// timer loop. These are Cocoa-free headers, safe to include in this .cpp.
#include "chart_renderer_frontend.hpp"
#include "metal_render_hook.h"
#endif

#include <mbgl/gfx/backend.hpp>
#include <mbgl/renderer/renderer.hpp>
#include <mbgl/renderer/renderer_frontend.hpp>
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
    std::unique_ptr<mbgl::RendererFrontend> frontend; // GLFW- or Chart- (Metal) RendererFrontend
    std::unique_ptr<ContinuousObserver> contObserver; // non-Metal only
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

    mbgl::ResourceOptions resourceOptions;
    resourceOptions.withCachePath(":memory:").withAssetPath(".");
    mbgl::ClientOptions clientOptions;

    auto *v = new chartplotter_view();
    v->src = g_src;

    // GLFWView first: it creates the window + backend and owns the RunLoop.
    v->view = std::make_unique<GLFWView>(/*fullscreen*/ false, /*benchmark*/ false,
                                         resourceOptions, clientOptions);
#if defined(CHARTPLOTTER_METAL)
    // Metal: the MTKView inside MetalBackend drives rendering off its internal
    // CVDisplayLink (vsync), mirroring MapLibre's own macOS host. Use a frontend
    // that does NOT poke GLFW's dirty flag and do NOT call setRenderFrontend — so
    // GLFW never renders and MTKView is the sole, vsync-phase-locked driver (this
    // is the fix for the timer-vs-refresh flicker + blank-on-idle). Wire MTKView's
    // per-vsync draw to the frontend.
    {
        auto fe = std::make_unique<ChartRendererFrontend>(
            std::make_unique<mbgl::Renderer>(v->view->getRendererBackend(), v->view->getPixelRatio()),
            v->view->getRendererBackend());
        chartSetMetalRenderCallback(v->view->getRendererBackend(), [p = fe.get()] { p->render(); });
        v->frontend = std::move(fe);
    }

    registerChartSource(); // before the Map builds its resource loader

    v->map = std::make_unique<mbgl::Map>(
        *v->frontend, mbgl::MapObserver::nullObserver(),
        mbgl::MapOptions().withSize(v->view->getSize()).withPixelRatio(v->view->getPixelRatio()),
        resourceOptions, clientOptions);
#else
    v->frontend = std::make_unique<GLFWRendererFrontend>(
        std::make_unique<mbgl::Renderer>(v->view->getRendererBackend(), v->view->getPixelRatio()),
        *v->view);

    registerChartSource(); // before the Map builds its resource loader

    // Continuous redraw by default: the on-demand path leaves the window blank when
    // idle on some backends (the old CHART_CONTINUOUS escape hatch is now the
    // default). The etag/notModified path already prevents re-parse, so continuous
    // is smooth and flicker-free; set CHART_ONDEMAND=1 for the lower-idle-CPU
    // on-demand mode where it works.
    const bool continuous = std::getenv("CHART_ONDEMAND") == nullptr;
    v->contObserver = std::make_unique<ContinuousObserver>(*v->view);
    mbgl::MapObserver &observer = continuous ? static_cast<mbgl::MapObserver &>(*v->contObserver)
                                             : static_cast<mbgl::MapObserver &>(*v->view);
    v->map = std::make_unique<mbgl::Map>(
        *v->frontend, observer,
        mbgl::MapOptions().withSize(v->view->getSize()).withPixelRatio(v->view->getPixelRatio()),
        resourceOptions, clientOptions);
#endif

    v->view->setMap(v->map.get());
    v->view->setWindowTitle(opts->title ? opts->title : "chartplotter");

    // Clamp navigation to the chart scale range ~1:10,000,000 .. 1:4,000
    // (Web-Mercator z = log2(559082264 / scaleDenominator)).
    v->map->setBounds(mbgl::BoundOptions().withMinZoom(5.8).withMaxZoom(17.1));

    // Camera: explicit centre+zoom when given; otherwise fit the data bounds, or
    // open on a representative cell when the bounds are too large to fit usefully.
    if (opts->zoom > 0)
        v->map->jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{opts->lat, opts->lon}).withZoom(opts->zoom));
    else
        frameCamera(*v->map, g_src);
    v->map->getStyle().loadJSON(readFile(opts->style_path));
    return v;
}

extern "C" void chartplotter_view_run(chartplotter_view *view) {
    if (view && view->view) view->view->run();
}

extern "C" void chartplotter_view_close(chartplotter_view *view) {
    if (!view) return;
#if defined(CHARTPLOTTER_METAL)
    // Clear the MTKView render callback before the frontend dies, so a display-link
    // draw can't call into a freed ChartRendererFrontend. (Same thread, so no
    // in-flight draw races this.)
    if (view->view) chartSetMetalRenderCallback(view->view->getRendererBackend(), {});
#endif
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
