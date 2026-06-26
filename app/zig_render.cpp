// chartplotter-render — headless host that renders the chart with vector tiles
// served by libchartplotter (the Zig tile generator) through ChartTileSource.
// This proves the full Zig -> MapLibre Native integration (custom FileSource over
// the C ABI) and is the render-to-PNG verification path on headless boxes.
//
// Usage: chartplotter-render <archive.pmtiles|cell.000> <style.json> <lat> <lon> <zoom> <out.png> [w h ratio]

#include "chartplotter.h"
#include "chartplotter_diag.h"
#include "chart_tile_source.hpp"

#include <mbgl/gfx/backend.hpp>
#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/storage/file_source_manager.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/style/style.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/util/run_loop.hpp>

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

static chartplotter_source *g_src = nullptr;

static std::string readFile(const char *path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

int main(int argc, char **argv) {
    // S-101 Lua compatibility check: chartplotter-render --s101check <rules-dir>
    if (argc >= 3 && std::string(argv[1]) == "--s101check") {
        std::cerr << "embedded " << chartplotter_diag_lua_version() << "\n";
        int rc = chartplotter_diag_check_rules(argv[2]);
        std::cerr << (rc == 0 ? "S-101 framework: load OK\n" : "S-101 framework: load FAILED\n");
        return rc == 0 ? 0 : 1;
    }
    if (argc >= 3 && std::string(argv[1]) == "--s101run") {
        int rc = chartplotter_diag_run_framework(argv[2]);
        std::cerr << (rc == 0 ? "S-101 framework: run OK\n" : "S-101 framework: run FAILED\n");
        return rc == 0 ? 0 : 1;
    }
    if (argc >= 3 && std::string(argv[1]) == "--s101portray") {
        int rc = chartplotter_diag_portray_demo(argv[2]);
        std::cerr << (rc == 0 ? "S-101 portray: OK\n" : "S-101 portray: FAILED\n");
        return rc == 0 ? 0 : 1;
    }
    if (argc < 7) {
        std::cerr << "usage: chartplotter-render <archive.pmtiles|cell.000> <style.json> <lat> <lon> <zoom> <out.png> [w h ratio]\n";
        return 2;
    }
    const std::string archive = argv[1];
    const std::string stylePath = argv[2];
    const double lat = std::atof(argv[3]);
    const double lon = std::atof(argv[4]);
    const double zoom = std::atof(argv[5]);
    const std::string outPath = argv[6];
    const uint32_t width = argc > 7 ? std::strtoul(argv[7], nullptr, 10) : 1024;
    const uint32_t height = argc > 8 ? std::strtoul(argv[8], nullptr, 10) : 768;
    const float ratio = argc > 9 ? std::strtof(argv[9], nullptr) : 1.0f;

    // Read the archive bytes; libchartplotter copies what it keeps.
    const std::string bytes = readFile(archive.c_str());
    if (bytes.empty()) {
        std::cerr << "could not read archive: " << archive << "\n";
        return 1;
    }
    // AUTO: the library sniffs PMTiles, else opens it as an S-57 cell (live gen).
    const auto *raw = reinterpret_cast<const uint8_t *>(bytes.data());
    g_src = chartplotter_source_open(raw, bytes.size(), CHARTPLOTTER_FORMAT_AUTO, nullptr);
    if (!g_src) {
        std::cerr << "could not open as PMTiles or S-57 cell\n";
        return 1;
    }
    const char *mode = chartplotter_source_format(g_src) == CHARTPLOTTER_FORMAT_PMTILES ? "pmtiles" : "s57-cell (live generation)";
    uint8_t minZoom = 0, maxZoom = 0;
    chartplotter_source_zoom_range(g_src, &minZoom, &maxZoom);
    std::cerr << "chart source opened [" << mode << "]: zoom " << int(minZoom) << ".." << int(maxZoom) << "\n";
    std::cerr << "embedded " << chartplotter_diag_lua_version() << " self-test: " << chartplotter_diag_lua_selftest()
              << " (expect 42)\n";

    // Register the Zig source in the (unused) Mbtiles slot BEFORE the Map builds
    // its resource loader, so zigtiles:// requests route to it.
    mbgl::FileSourceManager::get()->registerFileSourceFactory(
        mbgl::FileSourceType::Mbtiles,
        [](const mbgl::ResourceOptions &, const mbgl::ClientOptions &) -> std::unique_ptr<mbgl::FileSource> {
            return std::make_unique<cpn::ChartTileSource>(g_src);
        });

    mbgl::util::RunLoop loop;
    mbgl::HeadlessFrontend frontend({width, height}, ratio);
    mbgl::Map map(frontend, mbgl::MapObserver::nullObserver(),
                  mbgl::MapOptions()
                      .withMapMode(mbgl::MapMode::Static)
                      .withSize(frontend.getSize())
                      .withPixelRatio(ratio),
                  mbgl::ResourceOptions().withCachePath(":memory:").withAssetPath("."));

    map.getStyle().loadJSON(readFile(stylePath.c_str()));
    map.jumpTo(mbgl::CameraOptions().withCenter(mbgl::LatLng{lat, lon}).withZoom(zoom));

    int rc = 0;
    try {
        auto result = frontend.render(map);
        std::ofstream out(outPath, std::ios::binary);
        out << mbgl::encodePNG(result.image);
        std::cerr << "wrote " << outPath << "\n";
    } catch (const std::exception &e) {
        std::cerr << "render error: " << e.what() << "\n";
        rc = 1;
    }
    // Note: g_src outlives the Map (which holds ChartTileSource instances via the
    // resource loader); we intentionally do NOT chartplotter_source_close here. The process
    // is exiting, so the OS reclaims it — closing first would be a use-after-free
    // during Map teardown.
    return rc;
}
