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
#include <mbgl/map/map_options.hpp>
#include <mbgl/renderer/renderer.hpp>
#include <mbgl/storage/file_source_manager.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/client_options.hpp>

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

    // Camera: explicit args win; otherwise frame the source (so any cell/archive
    // opens centered on its data), falling back to Annapolis.
    double lat = 38.978, lon = -76.487, zoom = 13.0;
    if (cameraFromArgs) {
        lat = std::atof(argv[3]);
        lon = std::atof(argv[4]);
        zoom = std::atof(argv[5]);
    } else if (tg_center(g_src, &lon, &lat, &zoom)) {
        std::cerr << "centered on source: " << lat << ", " << lon << " z" << zoom << "\n";
    }

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

    // 4) Map in the default (Continuous) mode for interactivity — do NOT set
    //    MapMode::Static (that's for one-shot headless renders).
    mbgl::Map map(rendererFrontend, view,
                  mbgl::MapOptions().withSize(view.getSize()).withPixelRatio(view.getPixelRatio()),
                  resourceOptions, clientOptions);

    view.setMap(&map);
    view.setWindowTitle("chartplotter-native (Zig tiles)");
    map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{lat, lon}).withZoom(zoom));
    map.getStyle().loadJSON(readFile(stylePath.c_str()));

    // 5) Blocking interactive loop (drives rendering off GLFWView's RunLoop).
    view.run();

    // g_src intentionally NOT tg_close()'d (see note above).
    return 0;
}
