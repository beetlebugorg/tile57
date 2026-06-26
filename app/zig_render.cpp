// chartshot-zig — headless host that renders the chart with vector tiles served
// by the Zig tile generator (libtilegen.a) through ZigTileSource. This proves
// the full Zig -> MapLibre Native integration (custom FileSource over the C ABI)
// before live S-57 generation replaces the PMTiles-reader backend (M6).
//
// Usage: chartshot-zig <archive.pmtiles> <style.json> <lat> <lon> <zoom> <out.png> [w h ratio]

#include "tilegen.h"
#include "zig_tile_source.hpp"

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

static tg_source *g_src = nullptr;

static std::string readFile(const char *path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

int main(int argc, char **argv) {
    if (argc < 7) {
        std::cerr << "usage: chartshot-zig <archive.pmtiles> <style.json> <lat> <lon> <zoom> <out.png> [w h ratio]\n";
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

    // Open the archive in Zig (host owns the bytes).
    const std::string bytes = readFile(archive.c_str());
    if (bytes.empty()) {
        std::cerr << "could not read archive: " << archive << "\n";
        return 1;
    }
    g_src = tg_open_bytes(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size());
    if (!g_src) {
        std::cerr << "tg_open_bytes failed (not a PMTiles v3 archive?)\n";
        return 1;
    }
    std::cerr << "tilegen source opened: zoom " << int(tg_min_zoom(g_src)) << ".."
              << int(tg_max_zoom(g_src)) << "\n";

    // Register the Zig source in the (unused) Mbtiles slot BEFORE the Map builds
    // its resource loader, so zigtiles:// requests route to it.
    mbgl::FileSourceManager::get()->registerFileSourceFactory(
        mbgl::FileSourceType::Mbtiles,
        [](const mbgl::ResourceOptions &, const mbgl::ClientOptions &) -> std::unique_ptr<mbgl::FileSource> {
            return std::make_unique<cpn::ZigTileSource>(g_src);
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

    try {
        auto result = frontend.render(map);
        std::ofstream out(outPath, std::ios::binary);
        out << mbgl::encodePNG(result.image);
        std::cerr << "wrote " << outPath << "\n";
    } catch (const std::exception &e) {
        std::cerr << "render error: " << e.what() << "\n";
        tg_close(g_src);
        return 1;
    }

    tg_close(g_src);
    return 0;
}
