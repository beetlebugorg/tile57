// ChartTileSource — an mbgl::FileSource that serves vector tiles from
// libchartplotter (the Zig tile generator) for URLs of the form
// zigtiles://{z}/{x}/{y}.
//
// It is registered in the (unused) Mbtiles slot of MapLibre's MainResourceLoader
// so tile requests route to it by canRequest(). Backed by a PMTiles reader or
// live-generated tiles, interchangeably.
//
// Generation runs synchronously on the request (render/runloop) thread by
// default. Set CHART_ASYNC to run it on a dedicated worker thread instead (off
// the render thread), which can smooth fast pan/zoom where many tiles are
// requested at once.
#pragma once

#include <mbgl/storage/file_source.hpp>
#include <mbgl/util/thread.hpp>

#include <memory>

struct cp_source;

namespace cpn {

class ChartTileSource final : public mbgl::FileSource {
public:
    explicit ChartTileSource(cp_source *src);
    ~ChartTileSource() override;

    std::unique_ptr<mbgl::AsyncRequest> request(const mbgl::Resource &, Callback) override;
    bool canRequest(const mbgl::Resource &) const override;

    void setResourceOptions(mbgl::ResourceOptions) override;
    mbgl::ResourceOptions getResourceOptions() override;
    void setClientOptions(mbgl::ClientOptions) override;
    mbgl::ClientOptions getClientOptions() override;

private:
    class Impl;
    cp_source *src;
    std::unique_ptr<mbgl::util::Thread<Impl>> worker; // null -> synchronous
};

} // namespace cpn
