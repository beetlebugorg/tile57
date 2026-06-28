#include "chart_tile_source.hpp"
#include "tile57.h"

#include <mbgl/storage/file_source_request.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/util/chrono.hpp>
#include <mbgl/util/client_options.hpp>

#include <cstdio>
#include <cstring>
#include <string>
#include <utility>

namespace cpn {

static constexpr const char *PREFIX = "tile57://";

// Fill `response` with the tile for a tile57:// request.
//
// Conditional-request support is what stops the flicker: our tiles are
// deterministic, so each gets a stable etag. When MapLibre re-requests a tile it
// already has (resource.priorEtag matches), we return notModified instead of the
// bytes — MapLibre then KEEPS its already-parsed tile (loadedData skips setData)
// instead of re-parsing it every time. Without this MapLibre re-parses on every
// re-request (15-60x/sec), which is the flicker.
static void fillResponse(tile57_source *src, const mbgl::Resource &resource, mbgl::Response &response) {
    int z = 0;
    unsigned x = 0, y = 0;
    const char *rest = resource.url.c_str() + std::strlen(PREFIX);
    if (std::sscanf(rest, "%d/%u/%u", &z, &x, &y) != 3) {
        response.error = std::make_unique<mbgl::Response::Error>(
            mbgl::Response::Error::Reason::Other, "bad tile57 url");
        return;
    }

    char buf[40];
    std::snprintf(buf, sizeof buf, "%d/%u/%u", z, x, y);
    const std::string etag(buf);
    response.etag = etag;
    // Far-but-sane expiry (NOT Timestamp::max(), which overflowed) — deterministic
    // tiles never go stale, so MapLibre's cache can keep them.
    response.expires = mbgl::util::now() + std::chrono::hours(24 * 365);

    if (resource.priorEtag && *resource.priorEtag == etag) {
        response.notModified = true; // unchanged -> MapLibre reuses its parsed tile
        return;
    }

    uint8_t *out = nullptr;
    size_t len = 0;
    const tile57_tile_status rc = tile57_tile_get(src, static_cast<uint8_t>(z), x, y, &out, &len);
    if (rc == TILE57_TILE_OK) {
        response.data = std::make_shared<std::string>(reinterpret_cast<const char *>(out), len);
        tile57_tile_free(out, len);
    } else if (rc == TILE57_TILE_EMPTY) {
        response.noContent = true; // empty tile
    } else {
        response.error = std::make_unique<mbgl::Response::Error>(
            mbgl::Response::Error::Reason::Other, "chart tile error");
    }
}

ChartTileSource::ChartTileSource(tile57_source *s) : src(s) {}

ChartTileSource::~ChartTileSource() = default;

bool ChartTileSource::canRequest(const mbgl::Resource &resource) const {
    return resource.url.rfind(PREFIX, 0) == 0;
}

std::unique_ptr<mbgl::AsyncRequest> ChartTileSource::request(const mbgl::Resource &resource, Callback callback) {
    auto req = std::make_unique<mbgl::FileSourceRequest>(std::move(callback));
    mbgl::Response response;
    fillResponse(src, resource, response);
    req->actor().invoke(&mbgl::FileSourceRequest::setResponse, std::move(response));
    return req;
}

void ChartTileSource::setResourceOptions(mbgl::ResourceOptions) {}
mbgl::ResourceOptions ChartTileSource::getResourceOptions() {
    return mbgl::ResourceOptions{};
}
void ChartTileSource::setClientOptions(mbgl::ClientOptions) {}
mbgl::ClientOptions ChartTileSource::getClientOptions() {
    return mbgl::ClientOptions{};
}

} // namespace cpn
