// openPath — open a chart source from a path that may be a single file or an
// ENC_ROOT directory.
//
// The library owns no filesystem access (Zig 0.16 gates fs behind std.Io), so the
// host does the directory walk here and hands the bytes to libtile57:
//   - a file       -> tile57_source_open (PMTiles or one S-57 cell, AUTO)
//   - a directory  -> tile57_source_open_cells: scan for every <CELL>.000
//                     base cell plus its sequential .001… update files, overlaid.
#pragma once

#include "tile57.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <string>
#include <vector>

namespace cpn {

// Resolve the S-101 portrayal rules directory robustly so a host works when run
// from outside the repo root: TILE57_S101_RULES if set, else search for the
// vendored catalogue relative to the CWD and to the executable, walking up
// parents. Returns "" if not found (the caller then passes NULL and the library
// falls back to its relative default).
inline std::string resolveRulesDir(const char *argv0) {
    namespace fs = std::filesystem;
    if (const char *env = std::getenv("TILE57_S101_RULES"); env && *env) return env;
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
    // Bulk read (size then one read()) — NOT std::istreambuf_iterator, which copies
    // byte-by-byte through the stream buffer and is ~10-50x slower over an ENC_ROOT.
    std::ifstream f(p, std::ios::binary | std::ios::ate);
    if (!f) return {};
    const std::streamsize n = f.tellg();
    if (n <= 0) return {};
    std::string buf(static_cast<std::size_t>(n), '\0');
    f.seekg(0);
    f.read(buf.data(), n);
    buf.resize(static_cast<std::size_t>(f.gcount()));
    return buf;
}

// --- bake-on-open cache --------------------------------------------------------
// An ENC_ROOT is baked to ONE PMTiles archive on first open and cached, so later
// opens are instant and the running app holds no per-cell memory. Cache lives in
// $XDG_CACHE_HOME/chartplotter (else ~/.cache/chartplotter), keyed by a content
// signature + the bake max-zoom. Env overrides: CHARTPLOTTER_BAKE_MIN/MAXZOOM
// (default 0..14; the client overzooms past the cap for harbour close-ups) and
// CHARTPLOTTER_LIVE=1 to skip the bake and generate tiles in-process.

inline std::filesystem::path bakeCacheDir() {
    namespace fs = std::filesystem;
    if (const char *x = std::getenv("XDG_CACHE_HOME"); x && *x) return fs::path(x) / "chartplotter";
    if (const char *h = std::getenv("HOME"); h && *h) return fs::path(h) / ".cache" / "chartplotter";
    return fs::temp_directory_path() / "chartplotter";
}

inline int bakeMinZoom() {
    const char *e = std::getenv("CHARTPLOTTER_BAKE_MINZOOM");
    return e ? std::atoi(e) : 0;
}
inline int bakeMaxZoom() {
    const char *e = std::getenv("CHARTPLOTTER_BAKE_MAXZOOM");
    return e ? std::atoi(e) : 14;
}

// Console progress for the on-open bake. stage 0 = loading/portraying, 1 = tiles.
inline void bakeProgress(void *, uint8_t stage, size_t done, size_t total) {
    const char *label = stage == 0 ? "loading cells" : "baking tiles ";
    if (total)
        std::fprintf(stderr, "\r[chart] %s %zu/%zu    ", label, done, total);
    else
        std::fprintf(stderr, "\r[chart] %s %zu    ", label, done);
    std::fflush(stderr);
}

// Bake progress that also forwards to an OpenProgress sink (user = OpenProgress*),
// so a GUI host gets the same loading/tiling counts the console does.
inline void bakeProgressFwd(void *user, uint8_t stage, size_t done, size_t total) {
    bakeProgress(nullptr, stage, done, total);
    if (user)
        (*static_cast<const std::function<void(const char *, std::size_t, std::size_t)> *>(user))(
            stage == 0 ? "loading cells" : "baking tiles", done, total);
}

// Optional progress sink for openPath, so a host (e.g. the Qt viewer's splash) can
// show what a large ENC_ROOT open is doing. `stage` is a short label ("scanning",
// "reading cells", "baking tiles"); done/total count items (total 0 = unknown).
using OpenProgress = std::function<void(const char *stage, std::size_t done, std::size_t total)>;

inline tile57_source *openPath(const std::string &path, const char *rules_dir,
                               const OpenProgress &progress = {}) {
    namespace fs = std::filesystem;
    std::error_code ec;

    // A plain file: PMTiles archive or a single S-57 cell (auto-detected).
    if (!fs::is_directory(path, ec)) {
        if (progress) progress("reading chart", 0, 1);
        const std::string bytes = readFileBytes(path);
        if (bytes.empty()) return nullptr;
        if (progress) progress("reading chart", 1, 1);
        return tile57_source_open(reinterpret_cast<const uint8_t *>(bytes.data()),
                                        bytes.size(), TILE57_FORMAT_AUTO, rules_dir);
    }

    using clock = std::chrono::steady_clock;
    auto secsSince = [](clock::time_point t0) {
        return std::chrono::duration<double>(clock::now() - t0).count();
    };

    // An ENC_ROOT: collect every base cell (*.000), in sorted order.
    const auto tScan = clock::now();
    std::vector<fs::path> bases;
    for (auto it = fs::recursive_directory_iterator(path, ec);
         !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (it->is_regular_file(ec) && it->path().extension() == ".000")
            bases.push_back(it->path());
        if (progress && (bases.size() & 0x3F) == 0) progress("scanning", bases.size(), 0);
    }
    std::sort(bases.begin(), bases.end());
    if (bases.empty()) return nullptr;
    std::fprintf(stderr, "[chart] scanned %zu cells in %.1fs\n", bases.size(), secsSince(tScan));

    // Read each base + its sequential updates. Bytes live in `blobs` (a deque, so
    // element addresses are stable as we keep pushing); the per-cell update
    // pointer/length arrays live in deques for the same reason. libtile57
    // copies everything, so these can be freed once open_cells returns.
    std::deque<std::string> blobs;
    std::deque<std::vector<const uint8_t *>> updPtrs;
    std::deque<std::vector<size_t>> updLens;
    std::vector<tile57_cell_input> inputs;

    // Content signature for the cache key: mix each base cell's size + mtime.
    std::uint64_t sig = 1469598103934665603ull; // FNV-1a offset
    auto mix = [&sig](std::uint64_t v) { sig = (sig ^ v) * 1099511628211ull; };

    const auto tRead = clock::now();
    std::size_t readIdx = 0;
    for (const auto &base : bases) {
        if (progress) progress("reading cells", ++readIdx, bases.size());
        blobs.push_back(readFileBytes(base));
        if (blobs.back().empty()) {
            blobs.pop_back();
            continue;
        }
        const std::string &baseBytes = blobs.back();
        mix(baseBytes.size());
        if (auto t = fs::last_write_time(base, ec); !ec) mix(static_cast<std::uint64_t>(t.time_since_epoch().count()));

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

        tile57_cell_input ci{};
        ci.base = reinterpret_cast<const uint8_t *>(baseBytes.data());
        ci.base_len = baseBytes.size();
        ci.updates = uptr.empty() ? nullptr : uptr.data();
        ci.update_lens = ulen.empty() ? nullptr : ulen.data();
        ci.update_count = uptr.size();
        inputs.push_back(ci);
    }
    if (inputs.empty()) return nullptr;
    std::fprintf(stderr, "[chart] read %zu cells in %.1fs\n", inputs.size(), secsSince(tRead));

    // Default: lazy on-demand generation. tile57_source_open_cells builds a cheap
    // spatial index (band + bbox per cell) and parses + portrays only the cells a
    // requested tile needs, with an LRU — so the whole catalogue opens instantly
    // and holds almost no memory.
    if (const char *bake = std::getenv("CHARTPLOTTER_BAKE"); !(bake && *bake)) {
        if (progress) progress("indexing cells", 0, 0);
        const auto tIndex = clock::now();
        tile57_source *s = tile57_source_open_cells(inputs.data(), inputs.size(), rules_dir);
        std::fprintf(stderr, "[chart] indexed %zu cells in %.1fs\n", inputs.size(), secsSince(tIndex));
        return s;
    }

    // Opt-in (CHARTPLOTTER_BAKE=1): bake the whole ENC_ROOT to one PMTiles archive
    // once, cached by content + max-zoom (smooth panning everywhere after a
    // one-time wait — good for offline use).
    char sigbuf[48];
    std::snprintf(sigbuf, sizeof sigbuf, "%016llx-z%d", static_cast<unsigned long long>(sig), bakeMaxZoom());
    const fs::path cache = bakeCacheDir() / (fs::path(path).filename().string() + "-" + sigbuf + ".pmtiles");

    if (fs::exists(cache, ec)) {
        const std::string bytes = readFileBytes(cache);
        if (!bytes.empty()) {
            std::fprintf(stderr, "[chart] using cached tiles: %s\n", cache.string().c_str());
            return tile57_source_open(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(),
                                      TILE57_FORMAT_PMTILES, rules_dir);
        }
    }

    std::fprintf(stderr, "[chart] baking %zu cells to %s (first run; cached after)\n",
                 inputs.size(), cache.string().c_str());
    std::uint8_t *out = nullptr;
    std::size_t out_len = 0;
    const int rc = tile57_bake_cells(inputs.data(), inputs.size(), rules_dir,
                                     static_cast<uint8_t>(bakeMinZoom()), static_cast<uint8_t>(bakeMaxZoom()),
                                     bakeProgressFwd, const_cast<OpenProgress *>(&progress), &out, &out_len);
    std::fprintf(stderr, "\n");
    if (rc == 1 && out && out_len) {
        std::error_code wec;
        fs::create_directories(cache.parent_path(), wec);
        if (std::ofstream f(cache, std::ios::binary); f)
            f.write(reinterpret_cast<const char *>(out), static_cast<std::streamsize>(out_len));
        tile57_source *src = tile57_source_open(out, out_len, TILE57_FORMAT_PMTILES, rules_dir);
        tile57_tile_free(out, out_len);
        return src;
    }
    std::fprintf(stderr, "[chart] bake produced no tiles; using live in-process generation\n");
    return tile57_source_open_cells(inputs.data(), inputs.size(), rules_dir);
}

} // namespace cpn
