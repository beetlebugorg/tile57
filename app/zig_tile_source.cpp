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
#include <cstring>
#include <string>
#include <utility>

namespace cpn {

static constexpr const char *PREFIX = "zigtiles://";

ZigTileSource::ZigTileSource(tg_source *s) : src(s) {}

bool ZigTileSource::canRequest(const mbgl::Resource &resource) const {
    return resource.url.rfind(PREFIX, 0) == 0;
}

std::unique_ptr<mbgl::AsyncRequest> ZigTileSource::request(const mbgl::Resource &resource, Callback callback) {
    auto req = std::make_unique<mbgl::FileSourceRequest>(std::move(callback));

    mbgl::Response response;
    // Tiles are deterministic (a fixed PMTiles archive or the loaded cell), so
    // they never go stale — give them a far-future expiry so MapLibre doesn't
    // treat them as needing revalidation and re-request/re-render them.
    response.expires = mbgl::Timestamp::max();
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

    // Deliver on the current RunLoop (FileSourceRequest handles cancellation).
    req->actor().invoke(&mbgl::FileSourceRequest::setResponse, std::move(response));
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
