#include "zig_tile_source.hpp"
#include "tilegen.h"

#include <mbgl/actor/actor_ref.hpp>
#include <mbgl/storage/file_source_request.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/util/chrono.hpp>
#include <mbgl/util/client_options.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>

namespace cpn {

static constexpr const char *PREFIX = "zigtiles://";

// Fill `response` with the tile for a zigtiles:// request (shared by the sync
// and worker paths). Pure read of the Zig source; safe to call off the main
// thread.
//
// Conditional-request support is what stops the flicker: our tiles are
// deterministic, so each gets a stable etag. When MapLibre re-requests a tile it
// already has (resource.priorEtag matches), we return notModified instead of the
// bytes — MapLibre then KEEPS its already-parsed tile (loadedData skips setData)
// instead of re-parsing it every time. Without this MapLibre re-parses on every
// re-request (15-60x/sec), which is the flicker.
static void fillResponse(tg_source *src, const mbgl::Resource &resource, mbgl::Response &response) {
    int z = 0;
    unsigned x = 0, y = 0;
    const char *rest = resource.url.c_str() + std::strlen(PREFIX);
    if (std::sscanf(rest, "%d/%u/%u", &z, &x, &y) != 3) {
        response.error = std::make_unique<mbgl::Response::Error>(
            mbgl::Response::Error::Reason::Other, "bad zigtiles url");
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
    const int rc = tg_get_tile(src, static_cast<uint8_t>(z), x, y, &out, &len);
    if (rc == 1) {
        response.data = std::make_shared<std::string>(reinterpret_cast<const char *>(out), len);
        tg_free(out, len);
    } else if (rc == 0) {
        response.noContent = true; // empty tile
    } else {
        response.error = std::make_unique<mbgl::Response::Error>(
            mbgl::Response::Error::Reason::Other, "tilegen error");
    }
}

// Worker that generates tiles off the render thread and delivers the response
// back to the request's mailbox (on the originating loop). Used when CHART_ASYNC.
class ZigTileSource::Impl {
public:
    Impl(const mbgl::ActorRef<Impl> &, tg_source *src_) : src(src_) {}
    void request(const mbgl::Resource &resource, const mbgl::ActorRef<mbgl::FileSourceRequest> &req) {
        mbgl::Response response;
        fillResponse(src, resource, response);
        req.invoke(&mbgl::FileSourceRequest::setResponse, response);
    }

private:
    tg_source *src;
};

ZigTileSource::ZigTileSource(tg_source *s) : src(s) {
    if (std::getenv("CHART_ASYNC")) {
        worker = std::make_unique<mbgl::util::Thread<Impl>>("ZigTileSource", s);
    }
}

ZigTileSource::~ZigTileSource() = default;

bool ZigTileSource::canRequest(const mbgl::Resource &resource) const {
    return resource.url.rfind(PREFIX, 0) == 0;
}

std::unique_ptr<mbgl::AsyncRequest> ZigTileSource::request(const mbgl::Resource &resource, Callback callback) {
    auto req = std::make_unique<mbgl::FileSourceRequest>(std::move(callback));
    if (worker) {
        worker->actor().invoke(&Impl::request, resource, req->actor());
    } else {
        mbgl::Response response;
        fillResponse(src, resource, response);
        req->actor().invoke(&mbgl::FileSourceRequest::setResponse, std::move(response));
    }
    return req;
}

void ZigTileSource::setResourceOptions(mbgl::ResourceOptions) {}
mbgl::ResourceOptions ZigTileSource::getResourceOptions() {
    return mbgl::ResourceOptions{};
}
void ZigTileSource::setClientOptions(mbgl::ClientOptions) {}
mbgl::ClientOptions ZigTileSource::getClientOptions() {
    return mbgl::ClientOptions{};
}

} // namespace cpn
