// ZigTileSource — an mbgl::FileSource that serves vector tiles from the Zig
// tile generator (libtilegen.a) for URLs of the form zigtiles://{z}/{x}/{y}.
//
// It is registered in the (unused) Mbtiles slot of MapLibre's MainResourceLoader
// so tile requests route to it by canRequest(). For M5 it is backed by a Zig
// PMTiles reader; at M6 the same source serves live-generated tiles unchanged.
#pragma once

#include <mbgl/storage/file_source.hpp>
#include <mbgl/util/thread.hpp>

#include <memory>

struct tg_source;

namespace cpn {

class ZigTileSource final : public mbgl::FileSource {
public:
    explicit ZigTileSource(tg_source *src);
    ~ZigTileSource() override;

    std::unique_ptr<mbgl::AsyncRequest> request(const mbgl::Resource &, Callback) override;
    bool canRequest(const mbgl::Resource &) const override;

    void setResourceOptions(mbgl::ResourceOptions) override;
    mbgl::ResourceOptions getResourceOptions() override;
    void setClientOptions(mbgl::ClientOptions) override;
    mbgl::ClientOptions getClientOptions() override;

private:
    // Tile generation runs on a dedicated worker thread (mbgl idiom: util::Thread
    // <Impl>), so it never blocks the render/runloop thread (the cause of flicker
    // during zoom), and stays single-threaded so the PMTiles reader's shared
    // arena isn't raced.
    class Impl;
    std::unique_ptr<mbgl::util::Thread<Impl>> impl;
};

} // namespace cpn
