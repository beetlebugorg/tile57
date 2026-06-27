#pragma once

// Native macOS window host — NO GLFW. Owns an NSWindow, the MTKView-based
// MetalBackend (reused from metal_backend.h), and an mbgl::util::RunLoop. This
// replaces GLFWView on Metal builds so we can test whether GLFW's own window
// (its contentView layer compositing) was the flicker source.
//
// Rendering: the MTKView's internal CVDisplayLink drives drawInMTKView: per
// vsync -> the render callback. The mbgl RunLoop is CFRunLoop-backed on Darwin,
// so [NSApp run] (in run()) pumps both Cocoa events and mbgl's async work.
//
// Input (for now): scroll-to-zoom only — enough to exercise the worst-case
// (zoom) flicker. Full gestures land once flicker is settled.
//
// Cocoa-free interface (PIMPL) so chartplotter.cpp (plain C++) can use it.

#include <mbgl/util/size.hpp>

#include <functional>
#include <memory>

namespace mbgl {
class Map;
namespace gfx {
class RendererBackend;
} // namespace gfx
} // namespace mbgl

class ChartNativeHost {
public:
    ChartNativeHost(const char *title, uint32_t width, uint32_t height);
    ~ChartNativeHost();

    mbgl::gfx::RendererBackend &getRendererBackend();
    mbgl::Size getSize() const;   // logical points (for MapOptions)
    float getPixelRatio() const;

    void setMap(mbgl::Map *map);                  // not owned; for input
    void setRenderCallback(std::function<void()> cb); // MTKView vsync -> render
    void run();                                   // [NSApp run]

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
