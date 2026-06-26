// ChartTileSource — an mbgl::FileSource that serves vector tiles from
// libchartplotter (the Zig tile generator) for URLs of the form
// zigtiles://{z}/{x}/{y}.
//
// It is registered in the (unused) Mbtiles slot of MapLibre's MainResourceLoader
// so tile requests route to it by canRequest(). Backed by a PMTiles reader or
// live-generated tiles, interchangeably.
//
// Tiles are generated synchronously on the request (render/runloop) thread.
// libchartplotter caches generated/decoded tiles, so re-requests are cheap and
// the source only needs to be touched from this one thread.
#pragma once

#include <mbgl/storage/file_source.hpp>

#include <memory>

struct chartplotter_source;

namespace cpn {

class ChartTileSource final : public mbgl::FileSource {
public:
    explicit ChartTileSource(chartplotter_source *src);
    ~ChartTileSource() override;

    std::unique_ptr<mbgl::AsyncRequest> request(const mbgl::Resource &, Callback) override;
    bool canRequest(const mbgl::Resource &) const override;

    void setResourceOptions(mbgl::ResourceOptions) override;
    mbgl::ResourceOptions getResourceOptions() override;
    void setClientOptions(mbgl::ClientOptions) override;
    mbgl::ClientOptions getClientOptions() override;

private:
    chartplotter_source *src;
};

} // namespace cpn
