#include "zig_tile_source.hpp"
#include "tilegen.h"

#include <mbgl/actor/actor_ref.hpp>
#include <mbgl/storage/file_source_request.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/util/client_options.hpp>

#include <cstdio>
#include <cstring>
#include <string>
#include <utility>

namespace cpn {

static constexpr const char *PREFIX = "zigtiles://";

// Runs on a dedicated worker thread (via util::Thread<Impl>): generates the tile
// (PMTiles decode or live S-57 -> MVT) off the render/runloop thread, then
// delivers the response back to the request's mailbox (on the originating loop).
class ZigTileSource::Impl {
public:
    Impl(const mbgl::ActorRef<Impl> &, tg_source *src_) : src(src_) {}

    void request(const mbgl::Resource &resource, const mbgl::ActorRef<mbgl::FileSourceRequest> &req) {
        mbgl::Response response;
        int z = 0;
        unsigned x = 0, y = 0;
        const char *rest = resource.url.c_str() + std::strlen(PREFIX);
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
        req.invoke(&mbgl::FileSourceRequest::setResponse, response);
    }

private:
    tg_source *src;
};

ZigTileSource::ZigTileSource(tg_source *s)
    : impl(std::make_unique<mbgl::util::Thread<Impl>>("ZigTileSource", s)) {}

ZigTileSource::~ZigTileSource() = default;

bool ZigTileSource::canRequest(const mbgl::Resource &resource) const {
    return resource.url.rfind(PREFIX, 0) == 0;
}

std::unique_ptr<mbgl::AsyncRequest> ZigTileSource::request(const mbgl::Resource &resource, Callback callback) {
    auto req = std::make_unique<mbgl::FileSourceRequest>(std::move(callback));
    impl->actor().invoke(&Impl::request, resource, req->actor());
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
