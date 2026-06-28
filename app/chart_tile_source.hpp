// ChartTileSource — an mbgl::FileSource that serves vector tiles from
// libtile57 (the Zig tile generator) for URLs of the form
// tile57://{z}/{x}/{y}.
//
// It is registered in the (unused) Mbtiles slot of MapLibre's MainResourceLoader
// so tile requests route to it by canRequest(). Backed by a PMTiles reader or
// live-generated tiles, interchangeably.
//
// Tiles are generated synchronously on the request (render/runloop) thread.
// libtile57 caches generated/decoded tiles, so re-requests are cheap and
// the source only needs to be touched from this one thread.
#pragma once

#include <mbgl/storage/file_source.hpp>

#include <memory>

struct tile57_source;

namespace cpn {

class ChartTileSource final : public mbgl::FileSource {
public:
    explicit ChartTileSource(tile57_source *src);
    ~ChartTileSource() override;

    std::unique_ptr<mbgl::AsyncRequest> request(const mbgl::Resource &, Callback) override;
    bool canRequest(const mbgl::Resource &) const override;

    void setResourceOptions(mbgl::ResourceOptions) override;
    mbgl::ResourceOptions getResourceOptions() override;
    void setClientOptions(mbgl::ClientOptions) override;
    mbgl::ClientOptions getClientOptions() override;

private:
    tile57_source *src;
};

} // namespace cpn
