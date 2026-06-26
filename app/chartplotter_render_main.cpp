// chartplotter-render — thin CLI over libchartplotter: render a chart to a PNG.
//
// Usage: chartplotter-render <archive.pmtiles|cell.000|ENC_ROOT> <style.json>
//                           <lat> <lon> <zoom> <out.png> [w h ratio]
// Plus the S-101 bring-up self-tests: --s101check / --s101run / --s101portray <rules-dir>.
#include "chartplotter.h"
#include "enc_root.hpp"   // cpn::resolveRulesDir
#include "tile57_diag.h"  // S-101 self-tests

#include <cstdlib>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
    if (argc >= 3 && std::string(argv[1]) == "--s101check") {
        std::cerr << "embedded " << tile57_diag_lua_version() << "\n";
        int rc = tile57_diag_check_rules(argv[2]);
        std::cerr << (rc == 0 ? "S-101 framework: load OK\n" : "S-101 framework: load FAILED\n");
        return rc == 0 ? 0 : 1;
    }
    if (argc >= 3 && std::string(argv[1]) == "--s101run") {
        int rc = tile57_diag_run_framework(argv[2]);
        std::cerr << (rc == 0 ? "S-101 framework: run OK\n" : "S-101 framework: run FAILED\n");
        return rc == 0 ? 0 : 1;
    }
    if (argc >= 3 && std::string(argv[1]) == "--s101portray") {
        int rc = tile57_diag_portray_demo(argv[2]);
        std::cerr << (rc == 0 ? "S-101 portray: OK\n" : "S-101 portray: FAILED\n");
        return rc == 0 ? 0 : 1;
    }
    if (argc < 7) {
        std::cerr << "usage: chartplotter-render <archive.pmtiles|cell.000|ENC_ROOT> <style.json> "
                     "<lat> <lon> <zoom> <out.png> [w h ratio]\n";
        return 2;
    }
    const std::string archive = argv[1];
    const std::string style = argv[2];
    const double lat = std::atof(argv[3]);
    const double lon = std::atof(argv[4]);
    const double zoom = std::atof(argv[5]);
    const std::string out = argv[6];
    const uint32_t w = argc > 7 ? std::strtoul(argv[7], nullptr, 10) : 1024;
    const uint32_t h = argc > 8 ? std::strtoul(argv[8], nullptr, 10) : 768;
    const float ratio = argc > 9 ? std::strtof(argv[9], nullptr) : 1.0f;

    const std::string rules = cpn::resolveRulesDir(argv[0]);
    if (rules.empty())
        std::cerr << "warning: S-101 rules not found — set TILE57_S101_RULES, run from the repo "
                     "root, or `git submodule update --init`\n";

    int rc = chartplotter_render_png(archive.c_str(), style.c_str(),
                                     rules.empty() ? nullptr : rules.c_str(),
                                     lat, lon, zoom, w, h, ratio, out.c_str());
    if (rc == 0) std::cerr << "wrote " << out << "\n";
    return rc;
}
