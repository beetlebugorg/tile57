// chart-glfw-zig — interactive window host. Opens a real GLFW window with
// pan/zoom (MapLibre Native's GLFWView) whose vector tiles are served by the
// Zig tile generator (libtilegen.a) through ZigTileSource. This is the M3
// deliverable: the headless chartshot-zig proved the Zig -> MapLibre pipeline;
// this makes it a live, pannable chart.
//
// It mirrors vendor/maplibre-native/platform/glfw/main.cpp but: (1) registers
// our custom FileSource in the (unused) Mbtiles slot BEFORE the Map builds its
// resource loader, exactly as app/zig_render.cpp does; (2) loads a local style
// JSON via loadJSON (so absolute glyph/sprite paths resolve); (3) opens either
// a PMTiles archive or a raw S-57 cell (live generation) as the tile backend.
//
// Usage: chart-glfw-zig <archive.pmtiles|cell.000> <style.json> [lat lon zoom]

#include "tilegen.h"
#include "zig_tile_source.hpp"

#include "glfw_renderer_frontend.hpp"
#include "glfw_view.hpp"

#include <mbgl/gfx/backend.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/renderer/renderer.hpp>
#include <mbgl/storage/file_source_manager.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/geo.hpp>

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

// g_src lives for the whole process: the Map (which holds ZigTileSource
// instances via the resource loader) outlives main()'s cleanup, so we never
// tg_close() it — doing so would be a use-after-free during Map teardown
// (same rationale as app/zig_render.cpp).
static tg_source *g_src = nullptr;

static std::string readFile(const char *path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Continuous-render observer. GLFWView renders on-demand (only when "dirty"), but
// on macOS 26 / Metal 4 the CAMetalLayer goes BLANK once drawing stops on idle
// (confirmed: upstream mbgl-glfw does it too; the chart returns on any pan/zoom).
// Re-invalidate after each frame / on idle so the view keeps presenting (stays
// at 60fps with vsync — unlike --benchmark, which disables vsync). We pass this
// to the Map instead of GLFWView and forward the two events GLFWView handles, so
// nothing else changes (input is via GLFW callbacks, not the observer).
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

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: chart-glfw-zig <archive.pmtiles|cell.000> <style.json> [lat lon zoom]\n";
        return 2;
    }
    const std::string archive = argv[1];
    const std::string stylePath = argv[2];
    const bool cameraFromArgs = argc > 5;

    // Open the archive in Zig (host owns the bytes). Try PMTiles first; fall
    // back to a raw S-57 cell (live in-process generation).
    const std::string bytes = readFile(archive.c_str());
    if (bytes.empty()) {
        std::cerr << "could not read archive: " << archive << "\n";
        return 1;
    }
    const auto *raw = reinterpret_cast<const uint8_t *>(bytes.data());
    g_src = tg_open_bytes(raw, bytes.size());
    const char *mode = "pmtiles";
    if (!g_src) {
        g_src = tg_open_cell_bytes(raw, bytes.size());
        mode = "s57-cell (live generation)";
    }
    if (!g_src) {
        std::cerr << "could not open as PMTiles or S-57 cell: " << archive << "\n";
        return 1;
    }
    std::cerr << "tilegen source opened [" << mode << "]: zoom " << int(tg_min_zoom(g_src))
              << ".." << int(tg_max_zoom(g_src)) << "\n";

    // Source bounds (for framing the camera once the Map/window size is known).
    double bw = 0, bs = 0, be = 0, bn = 0;
    const bool haveBounds = tg_bounds(g_src, &bw, &bs, &be, &bn);

    mbgl::ResourceOptions resourceOptions;
    resourceOptions.withCachePath(":memory:").withAssetPath(".");
    mbgl::ClientOptions clientOptions;

    // 1) GLFWView FIRST: it creates the window + backend and OWNS the RunLoop
    //    (do NOT create a separate mbgl::util::RunLoop here, unlike the headless
    //    host). GLFWView is itself the MapObserver.
    GLFWView view(/*fullscreen*/ false, /*benchmark*/ false, resourceOptions, clientOptions);

    // 2) Renderer frontend bound to the view's backend.
    GLFWRendererFrontend rendererFrontend{
        std::make_unique<mbgl::Renderer>(view.getRendererBackend(), view.getPixelRatio()), view};

    // 3) *** Register the Zig FileSource in the unused Mbtiles slot BEFORE the
    //    Map is constructed, so zigtiles:// requests route to it. ***
    mbgl::FileSourceManager::get()->registerFileSourceFactory(
        mbgl::FileSourceType::Mbtiles,
        [](const mbgl::ResourceOptions &, const mbgl::ClientOptions &) -> std::unique_ptr<mbgl::FileSource> {
            return std::make_unique<cpn::ZigTileSource>(g_src);
        });

    // 4) Map in the default (Continuous) MapMode for interactivity. Observer:
    //    on-demand (the bare GLFWView) by default; the continuous-render wrapper
    //    only when CHART_CONTINUOUS is set — so we can isolate whether forcing a
    //    render every frame is what triggers the per-frame tile re-request flood.
    // On-demand render (default): draw only when something changes (camera,
    // tiles, animation). During pan/zoom the camera changes every frame so it
    // still presents every frame (smooth); when idle it stops (low CPU) and the
    // last frame stays on screen. This works now that the flicker is fixed at its
    // source (conditional tile requests, no re-parse churn) — we no longer need
    // to brute-force a present every frame. CHART_CONTINUOUS opts back in.
    ContinuousObserver contObserver(view);
    const bool continuous = std::getenv("CHART_CONTINUOUS") != nullptr;
    std::cerr << "render: " << (continuous ? "continuous (CHART_CONTINUOUS)" : "on-demand") << "\n";
    mbgl::MapObserver &observer =
        continuous ? static_cast<mbgl::MapObserver &>(contObserver) : static_cast<mbgl::MapObserver &>(view);
    mbgl::Map map(rendererFrontend, observer,
                  mbgl::MapOptions().withSize(view.getSize()).withPixelRatio(view.getPixelRatio()),
                  resourceOptions, clientOptions);

    view.setMap(&map);
    view.setWindowTitle("chartplotter-native (Zig tiles)");

    // Camera: explicit lat/lon/zoom args win; otherwise fit the source's bounds
    // to the window (correct center + zoom via MapLibre's projection-aware fit),
    // falling back to Annapolis if the source has no usable extent.
    if (cameraFromArgs) {
        map.jumpTo(mbgl::CameraOptions()
                       .withCenter(mbgl::LatLng{std::atof(argv[3]), std::atof(argv[4])})
                       .withZoom(std::atof(argv[5])));
    } else if (haveBounds) {
        const auto bounds = mbgl::LatLngBounds::hull(mbgl::LatLng{bs, bw}, mbgl::LatLng{bn, be});
        map.jumpTo(map.cameraForLatLngBounds(bounds, mbgl::EdgeInsets{20, 20, 20, 20}));
        std::cerr << "framed source bounds: [" << bs << "," << bw << " .. " << bn << "," << be << "]\n";
    } else {
        map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{38.978, -76.487}).withZoom(13.0));
    }
    map.getStyle().loadJSON(readFile(stylePath.c_str()));

    // 5) Blocking interactive loop (drives rendering off GLFWView's RunLoop).
    view.run();

    // g_src intentionally NOT tg_close()'d (see note above).
    return 0;
}
