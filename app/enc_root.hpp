// openPath — open a chart source from a path that may be a single file or an
// ENC_ROOT directory.
//
// The library owns no filesystem access (Zig 0.16 gates fs behind std.Io), so the
// host does the directory walk here and hands the bytes to libchartplotter:
//   - a file       -> chartplotter_source_open (PMTiles or one S-57 cell, AUTO)
//   - a directory  -> chartplotter_source_open_cells: scan for every <CELL>.000
//                     base cell plus its sequential .001… update files, overlaid.
#pragma once

#include "chartplotter.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace cpn {

// Resolve the S-101 portrayal rules directory robustly so a host works when run
// from outside the repo root: CHARTPLOTTER_S101_RULES if set, else search for the
// vendored catalogue relative to the CWD and to the executable, walking up
// parents. Returns "" if not found (the caller then passes NULL and the library
// falls back to its relative default).
inline std::string resolveRulesDir(const char *argv0) {
    namespace fs = std::filesystem;
    if (const char *env = std::getenv("CHARTPLOTTER_S101_RULES"); env && *env) return env;
    const fs::path suffix = "vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules";
    std::error_code ec;
    std::vector<fs::path> starts;
    starts.push_back(fs::current_path(ec));
    if (argv0) {
        const fs::path exe = fs::weakly_canonical(fs::path(argv0), ec);
        if (!ec && exe.has_parent_path()) starts.push_back(exe.parent_path());
    }
    for (const auto &start : starts) {
        for (fs::path p = start;; p = p.parent_path()) {
            const fs::path cand = p / suffix;
            if (fs::exists(cand / "S100Scripting.lua", ec)) return cand.string();
            if (!p.has_parent_path() || p == p.parent_path()) break;
        }
    }
    return std::string();
}

inline std::string readFileBytes(const std::filesystem::path &p) {
    std::ifstream f(p, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

inline chartplotter_source *openPath(const std::string &path, const char *rules_dir) {
    namespace fs = std::filesystem;
    std::error_code ec;

    // A plain file: PMTiles archive or a single S-57 cell (auto-detected).
    if (!fs::is_directory(path, ec)) {
        const std::string bytes = readFileBytes(path);
        if (bytes.empty()) return nullptr;
        return chartplotter_source_open(reinterpret_cast<const uint8_t *>(bytes.data()),
                                        bytes.size(), CHARTPLOTTER_FORMAT_AUTO, rules_dir);
    }

    // An ENC_ROOT: collect every base cell (*.000), in sorted order.
    std::vector<fs::path> bases;
    for (auto it = fs::recursive_directory_iterator(path, ec);
         !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (it->is_regular_file(ec) && it->path().extension() == ".000")
            bases.push_back(it->path());
    }
    std::sort(bases.begin(), bases.end());
    if (bases.empty()) return nullptr;

    // Read each base + its sequential updates. Bytes live in `blobs` (a deque, so
    // element addresses are stable as we keep pushing); the per-cell update
    // pointer/length arrays live in deques for the same reason. libchartplotter
    // copies everything, so these can be freed once open_cells returns.
    std::deque<std::string> blobs;
    std::deque<std::vector<const uint8_t *>> updPtrs;
    std::deque<std::vector<size_t>> updLens;
    std::vector<chartplotter_cell_input> inputs;

    for (const auto &base : bases) {
        blobs.push_back(readFileBytes(base));
        if (blobs.back().empty()) {
            blobs.pop_back();
            continue;
        }
        const std::string &baseBytes = blobs.back();

        updPtrs.emplace_back();
        updLens.emplace_back();
        auto &uptr = updPtrs.back();
        auto &ulen = updLens.back();
        for (int n = 1; n <= 999; ++n) { // stop at the first missing update (sequential)
            char ext[8];
            std::snprintf(ext, sizeof ext, ".%03d", n);
            fs::path up = base;
            up.replace_extension(ext);
            if (!fs::exists(up, ec)) break;
            blobs.push_back(readFileBytes(up));
            if (blobs.back().empty()) {
                blobs.pop_back();
                break;
            }
            uptr.push_back(reinterpret_cast<const uint8_t *>(blobs.back().data()));
            ulen.push_back(blobs.back().size());
        }

        chartplotter_cell_input ci{};
        ci.base = reinterpret_cast<const uint8_t *>(baseBytes.data());
        ci.base_len = baseBytes.size();
        ci.updates = uptr.empty() ? nullptr : uptr.data();
        ci.update_lens = ulen.empty() ? nullptr : ulen.data();
        ci.update_count = uptr.size();
        inputs.push_back(ci);
    }
    if (inputs.empty()) return nullptr;
    return chartplotter_source_open_cells(inputs.data(), inputs.size(), rules_dir);
}

} // namespace cpn
