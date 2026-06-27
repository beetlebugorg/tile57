// MTKView-based Metal backend (see metal_backend.h for the why). This is a port
// of MapLibre's own macOS renderable resource
// (vendor/.../platform/macos/src/MLNMapView+Metal.mm), adapted to live inside a
// GLFW window: MTKView is added as a subview of the GLFW contentView, and its
// internal CVDisplayLink drives drawInMTKView: once per vsync. We render ONLY
// inside that callback (where currentDrawable/currentRenderPassDescriptor are
// valid), forwarding to a render callback wired by chartplotter.cpp.
#include "metal_backend.h"
#include "metal_render_hook.h"

#include <mbgl/mtl/renderable_resource.hpp>

#include <cstdio>
#include <cstdlib>

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

#import <Metal/Metal.hpp>

#include <functional>

namespace mbgl {
class MetalRenderableResource;
} // namespace mbgl

// MTKView delegate: drawInMTKView: fires once per vsync (MTKView's internal
// CVDisplayLink). We forward to the resource, which invokes the render callback.
@interface ChartMTKViewDelegate : NSObject <MTKViewDelegate>
- (instancetype)initWithResource:(mbgl::MetalRenderableResource *)res;
@end

namespace mbgl {

class MetalRenderableResource final : public mtl::RenderableResource {
public:
  MetalRenderableResource(MetalBackend &backend_)
      : backend(backend_), delegate([[ChartMTKViewDelegate alloc] initWithResource:this]) {}

  ~MetalRenderableResource() {
    // Stop the display link from calling a dangling delegate after teardown.
    if (mtlView) {
      mtlView.paused = YES;
      mtlView.delegate = nil;
    }
  }

  void bind() override {
    if (!commandQueue) {
      commandQueue = [mtlView.device newCommandQueue];
    }
    if (!commandBuffer) {
      commandBuffer = [commandQueue commandBuffer];
      commandBufferPtr = NS::RetainPtr((__bridge MTL::CommandBuffer *)commandBuffer);
    }
  }

  const mtl::RendererBackend &getBackend() const override { return backend; }

  const mtl::MTLCommandBufferPtr &getCommandBuffer() const override { return commandBufferPtr; }

  mtl::MTLBlitPassDescriptorPtr getUploadPassDescriptor() const override {
    return NS::TransferPtr(MTL::BlitPassDescriptor::alloc()->init());
  }

  // MTKView builds the render-pass descriptor (color drawable + combined
  // depth/stencil) for us; valid only while inside drawInMTKView:.
  const mtl::MTLRenderPassDescriptorPtr &getRenderPassDescriptor() const override {
    if (!cachedRenderPassDescriptor) {
      MTLRenderPassDescriptor *d = mtlView.currentRenderPassDescriptor;
      cachedRenderPassDescriptor = NS::RetainPtr((__bridge MTL::RenderPassDescriptor *)d);
    }
    return cachedRenderPassDescriptor;
  }

  void swap() override {
    id<CAMetalDrawable> drawable = [mtlView currentDrawable];
    if (drawable) {
      [commandBuffer presentDrawable:drawable];
    }
    [commandBuffer commit];
    commandBuffer = nil;
    commandBufferPtr.reset();
    cachedRenderPassDescriptor.reset();
  }

  mbgl::Size framebufferSize() const {
    if (!mtlView) return size;
    return {static_cast<uint32_t>(mtlView.drawableSize.width),
            static_cast<uint32_t>(mtlView.drawableSize.height)};
  }

  // Called from the delegate's drawInMTKView: (vsync). Renders one frame, but
  // only when a drawable is available (a nil descriptor -> renderer derefs nil).
  void onDraw() {
    static bool logged = false;
    if (!logged) {
      std::fprintf(stderr, "[native] drawInMTKView: cb=%d rpd=%d drawableSize=%.0fx%.0f\n",
                   renderCallback ? 1 : 0, mtlView.currentRenderPassDescriptor != nil ? 1 : 0,
                   (double)mtlView.drawableSize.width, (double)mtlView.drawableSize.height);
      logged = true;
    }
    // Isolation test (CHART_TEST_CLEAR=1): clear to red + present, bypassing
    // mbgl. Red window => MTKView presentation works and the blank is mbgl's
    // render target/handoff; still blank => MTKView itself isn't presenting.
    if (std::getenv("CHART_TEST_CLEAR")) {
      MTLRenderPassDescriptor *rpd = mtlView.currentRenderPassDescriptor;
      if (rpd) {
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> cb = [testQueue() commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        [enc endEncoding];
        if (mtlView.currentDrawable) [cb presentDrawable:mtlView.currentDrawable];
        [cb commit];
      }
      return;
    }
    if (!renderCallback) return;
    if (mtlView.currentRenderPassDescriptor == nil) return;
    renderCallback();
  }

  // Lazily-created queue for the CHART_TEST_CLEAR isolation path only.
  id<MTLCommandQueue> testQueue() {
    if (!testCommandQueue) testCommandQueue = [mtlView.device newCommandQueue];
    return testCommandQueue;
  }
  void setRenderCallback(std::function<void()> cb) { renderCallback = std::move(cb); }

  MetalBackend &backend;
  ChartMTKViewDelegate *delegate = nil;
  MTKView *mtlView = nil;
  id<MTLCommandQueue> commandQueue = nil;
  id<MTLCommandQueue> testCommandQueue = nil; // CHART_TEST_CLEAR only
  id<MTLCommandBuffer> commandBuffer = nil;
  mtl::MTLCommandBufferPtr commandBufferPtr;
  mutable mtl::MTLRenderPassDescriptorPtr cachedRenderPassDescriptor;
  std::function<void()> renderCallback;
  mbgl::Size size{0, 0};
};

} // namespace mbgl

@implementation ChartMTKViewDelegate {
  mbgl::MetalRenderableResource *_resource;
}
- (instancetype)initWithResource:(mbgl::MetalRenderableResource *)res {
  if (self = [super init]) {
    _resource = res;
  }
  return self;
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}
- (void)drawInMTKView:(MTKView *)view {
  _resource->onDraw();
}
@end

MetalBackend::MetalBackend(NSWindow *window)
    : mbgl::mtl::RendererBackend(mbgl::gfx::ContextMode::Unique),
      mbgl::gfx::Renderable(mbgl::Size{0, 0},
                            std::make_unique<mbgl::MetalRenderableResource>(*this)) {
  auto &resource = getResource<mbgl::MetalRenderableResource>();

  id<MTLDevice> device = (__bridge id<MTLDevice>)getDevice().get();
  MTKView *view = [[MTKView alloc] initWithFrame:window.contentView.bounds device:device];
  view.delegate = resource.delegate;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  view.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  view.layer.opaque = YES;
  // Display-link driven (vsync), continuous: MTKView's internal CVDisplayLink
  // calls drawInMTKView: every refresh. This is the whole point — no software
  // timer, so presents are phase-locked to the panel (fixes flicker + idle-blank).
  view.enableSetNeedsDisplay = NO;
  view.paused = NO;
  resource.mtlView = view;

  // Make the MTKView the window's content view. A bare added subview can render
  // (display link fires, drawable is valid) yet never composite to screen =
  // blank window; being the contentView avoids that and auto-sizes to the window.
  window.contentView = view;
}

mbgl::gfx::Renderable &MetalBackend::getDefaultRenderable() { return *this; }

void MetalBackend::activate() {}
void MetalBackend::deactivate() {}
void MetalBackend::updateAssumedState() {}

void MetalBackend::setSize(mbgl::Size size_) {
  getResource<mbgl::MetalRenderableResource>().size = size_;
}

mbgl::Size MetalBackend::getSize() const {
  return getResource<mbgl::MetalRenderableResource>().framebufferSize();
}

void MetalBackend::setRenderCallback(std::function<void()> cb) {
  getResource<mbgl::MetalRenderableResource>().setRenderCallback(std::move(cb));
}

// Cocoa-free hook (declared in metal_render_hook.h) for chartplotter.cpp.
void chartSetMetalRenderCallback(mbgl::gfx::RendererBackend &backend, std::function<void()> cb) {
  static_cast<MetalBackend &>(backend).setRenderCallback(std::move(cb));
}
