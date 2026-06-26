// chartplotter — thin CLI over libchartplotter: open an interactive chart window.
//
// Usage: chartplotter <archive.pmtiles|cell.000|ENC_ROOT> <style.json> [lat lon zoom]
// Drag to pan, scroll to zoom. With no lat/lon/zoom, the view fits the data bounds.
#include "chartplotter.h"
#include "enc_root.hpp" // cpn::resolveRulesDir

#include <cstdlib>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: chartplotter <archive.pmtiles|cell.000|ENC_ROOT> <style.json> "
                     "[lat lon zoom]\n";
        return 2;
    }
    const std::string rules = cpn::resolveRulesDir(argv[0]);
    if (rules.empty())
        std::cerr << "warning: S-101 rules not found — set TILE57_S101_RULES, run from the repo "
                     "root, or `git submodule update --init`\n";

    chartplotter_view_options opts{};
    opts.style_path = argv[2];
    opts.rules_dir = rules.empty() ? nullptr : rules.c_str();
    opts.title = "chartplotter-native";
    if (argc > 5) {
        opts.lat = std::atof(argv[3]);
        opts.lon = std::atof(argv[4]);
        opts.zoom = std::atof(argv[5]);
    } else {
        opts.zoom = 0; // fit the data bounds
    }

    chartplotter_view *view = chartplotter_view_open(argv[1], &opts);
    if (!view) {
        std::cerr << "could not open chart: " << argv[1] << "\n";
        return 1;
    }
    chartplotter_view_run(view);
    chartplotter_view_close(view);
    return 0;
}
