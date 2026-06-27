#pragma once

// MTKView-based Metal backend, mirroring MapLibre's OWN macOS host
// (vendor/.../platform/macos/src/MLNMapView+Metal.mm) instead of the GLFW
// example's hand-rolled CAMetalLayer (the old backend, which flickered).
//
// Why MTKView: it owns the drawable pool, the depth/stencil (a combined
// Depth32Float_Stencil8), and the render-pass descriptor, and — crucially —
// drives rendering from an internal CVDisplayLink that calls our delegate's
// drawInMTKView: once per vsync. That display-link drive (NOT a software timer)
// is what fixes the present-timing flicker + blank-on-idle: the GLFW host's
// 60Hz libuv frameTick was never phase-locked to the panel.
//
// Integration: the MTKView is added as a subview of the GLFW window's
// contentView, so GLFW keeps the window + input while MTKView owns rendering.
// Rendering happens ONLY inside drawInMTKView: (where currentDrawable /
// currentRenderPassDescriptor are valid), via the callback set from
// chartplotter.cpp (which drives the RendererFrontend). GLFW itself never
// renders (its rendererFrontend is left null), so there is no double-drive.
//
// NOTE: this header is included by both app/metal_backend.mm and the forked
// app/glfw_metal_backend.mm so both translation units see one MetalBackend
// definition (no ODR mismatch). The vendored platform/glfw/metal_backend.h is
// no longer used by our build.

#include <mbgl/mtl/renderer_backend.hpp>
#include <mbgl/gfx/renderable.hpp>
#include <mbgl/mtl/texture2d.hpp>
#include <mbgl/gfx/context.hpp>

#import <Cocoa/Cocoa.h>

#include <functional>

class MetalBackend final : public mbgl::mtl::RendererBackend, public mbgl::gfx::Renderable {
public:
    MetalBackend(NSWindow *window);

    mbgl::gfx::Renderable &getDefaultRenderable() override;
    void activate() override;
    void deactivate() override;
    void updateAssumedState() override;
    void setSize(mbgl::Size size_);
    mbgl::Size getSize() const;

    // Invoked from the MTKView delegate's drawInMTKView: (once per vsync) to
    // render one frame. Wired by chartplotter.cpp to call RendererFrontend::render.
    void setRenderCallback(std::function<void()> cb);
};
