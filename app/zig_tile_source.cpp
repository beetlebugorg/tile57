#include "zig_tile_source.hpp"
#include "tilegen.h"

#include <mbgl/actor/actor_ref.hpp>
#include <mbgl/storage/file_source_request.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/util/client_options.hpp>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>

namespace cpn {

static constexpr const char *PREFIX = "zigtiles://";

// Fill `response` with the tile for a zigtiles:// URL (shared by the sync and
// worker paths). Pure read of the Zig source; safe to call off the main thread.
static void fillResponse(tg_source *src, const std::string &url, mbgl::Response &response) {
    int z = 0;
    unsigned x = 0, y = 0;
    const char *rest = url.c_str() + std::strlen(PREFIX);
    if (std::sscanf(rest, "%d/%u/%u", &z, &x, &y) == 3) {
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
    } else {
        response.error = std::make_unique<mbgl::Response::Error>(
            mbgl::Response::Error::Reason::Other, "bad zigtiles url");
    }
}

// Worker that generates tiles off the render thread and delivers the response
// back to the request's mailbox (on the originating loop). Used when CHART_ASYNC.
class ZigTileSource::Impl {
public:
    Impl(const mbgl::ActorRef<Impl> &, tg_source *src_) : src(src_) {}
    void request(const mbgl::Resource &resource, const mbgl::ActorRef<mbgl::FileSourceRequest> &req) {
        mbgl::Response response;
        fillResponse(src, resource.url, response);
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
    // [diag] request rate: if this climbs fast while IDLE, MapLibre is
    // re-requesting (and re-parsing) held tiles -> the residual flicker.
    static std::atomic<uint64_t> n{0};
    const uint64_t c = ++n;
    if (c % 60 == 0) std::fprintf(stderr, "[zigtiles] %llu requests\n", (unsigned long long)c);
    auto req = std::make_unique<mbgl::FileSourceRequest>(std::move(callback));
    if (worker) {
        worker->actor().invoke(&Impl::request, resource, req->actor());
    } else {
        mbgl::Response response;
        fillResponse(src, resource.url, response);
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
