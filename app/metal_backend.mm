// Patched copy of vendor/maplibre-native/platform/glfw/metal_backend.mm.
//
// Upstream's MetalRenderableResource::bind() calls swapchain->nextDrawable()
// with NO nil-check and then dereferences surface->texture(). On macOS / Metal,
// under fast pan/zoom the 3-deep drawable pool is exhausted and nextDrawable()
// returns nil, so the frame renders to a nil drawable -> the WHOLE SCREEN goes
// blank for that frame -> "flicker city" during fast interaction (slow is fine).
//
// Fix: make the CAMetalLayer BLOCK for a drawable instead of timing out to nil
// (setAllowsNextDrawableTimeout(false)) and use the full drawable pool, plus a
// defensive nil-skip on present. This file is compiled in place of the vendored
// metal_backend.mm (see CMakeLists.txt) so the fix lives in our repo and the
// vendored submodule stays pristine. metal_backend.h is reused unchanged.
#include "metal_backend.h"

#include <mbgl/mtl/mtl_fwd.hpp>
#include <mbgl/mtl/renderable_resource.hpp>

#include <Metal/Metal.hpp>
#include <QuartzCore/CAMetalLayer.hpp>

#include <dispatch/dispatch.h>

namespace mbgl {

using namespace mtl;

class MetalRenderableResource final : public mtl::RenderableResource {
public:
  MetalRenderableResource(MetalBackend& backend)
      : rendererBackend(backend),
        commandQueue(NS::TransferPtr(backend.getDevice()->newCommandQueue())),
        swapchain(NS::TransferPtr(CA::MetalLayer::layer())) {
    swapchain->setDevice(backend.getDevice().get());
    // Triple-buffered, async present — matches MapLibre's macOS SDK
    // (MLNMapView+Metal). NOT presentsWithTransaction (stalls on a
    // non-CADisplayLink loop) or per-frame GPU waits.
    swapchain->setMaximumDrawableCount(kMaxFramesInFlight);
    swapchain->setAllowsNextDrawableTimeout(false);
    // *** FRAME PACING — the missing half of triple buffering. ***
    // setMaximumDrawableCount alone does NOT bound how many frames the CPU
    // submits ahead of the GPU. Without a governor, a burst of frames (a zoom's
    // cross-fade is the worst case) lets the CPU run ahead, exhausts the drawable
    // pool, and then nextDrawable() (timeout disabled) blocks mid-burst -> stalls
    // + present races = flicker. This semaphore is the canonical fix: it caps
    // in-flight frames at the pool size. Waited once per frame in bind() (the
    // drawable-acquisition point), signaled from the GPU completion handler in
    // swap(). bind()/swap() are 1:1 per frame (one "main buffer" render pass +
    // one present per frame in renderer_impl), so it can't drift or deadlock.
    inFlight = dispatch_semaphore_create(kMaxFramesInFlight);
  }

  void setBackendSize(mbgl::Size size_) {
    size = size_;
    swapchain->setDrawableSize(
        {static_cast<CGFloat>(size.width), static_cast<CGFloat>(size.height)});
    buffersInvalid = true;
  }

  mbgl::Size getSize() const { return size; }

  void bind() override {
    // Block until the GPU has finished a previous frame, so at most
    // kMaxFramesInFlight are outstanding and the drawable pool never starves.
    // Signaled in swap()'s completion handler. (Called once per frame: the
    // single "main buffer" render pass on the default renderable.)
    dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
    surface = NS::TransferPtr(swapchain->nextDrawable());
    auto texSize = mbgl::Size{static_cast<uint32_t>(swapchain->drawableSize().width),
                              static_cast<uint32_t>(swapchain->drawableSize().height)};

    commandBuffer = NS::TransferPtr(commandQueue->commandBuffer());
    renderPassDescriptor = NS::TransferPtr(MTL::RenderPassDescriptor::renderPassDescriptor());
    // *** PATCH: defensive — only bind the drawable's texture if we got one.
    // With AllowsNextDrawableTimeout=false this should always be valid; the guard
    // just avoids a nil-deref if Metal ever still hands back nil. ***
    if (surface) {
      renderPassDescriptor->colorAttachments()->object(0)->setTexture(surface->texture());
    }

    if (buffersInvalid || !depthTexture || !stencilTexture) {
      buffersInvalid = false;
      depthTexture = rendererBackend.getContext().createTexture2D();
      depthTexture->setSize(texSize);
      depthTexture->setFormat(gfx::TexturePixelType::Depth, gfx::TextureChannelDataType::Float);
      depthTexture->setSamplerConfiguration({gfx::TextureFilterType::Linear,
                                             gfx::TextureWrapType::Clamp,
                                             gfx::TextureWrapType::Clamp});
      static_cast<mtl::Texture2D*>(depthTexture.get())
          ->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageShaderWrite |
                     MTL::TextureUsageRenderTarget);

      stencilTexture = rendererBackend.getContext().createTexture2D();
      stencilTexture->setSize(texSize);
      stencilTexture->setFormat(gfx::TexturePixelType::Stencil,
                                gfx::TextureChannelDataType::UnsignedByte);
      stencilTexture->setSamplerConfiguration({gfx::TextureFilterType::Linear,
                                               gfx::TextureWrapType::Clamp,
                                               gfx::TextureWrapType::Clamp});
      static_cast<mtl::Texture2D*>(stencilTexture.get())
          ->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageShaderWrite |
                     MTL::TextureUsageRenderTarget);
    }

    if (depthTexture) {
      depthTexture->create();
      if (auto* depthTarget = renderPassDescriptor->depthAttachment()) {
        depthTarget->setTexture(
            static_cast<mtl::Texture2D*>(depthTexture.get())->getMetalTexture());
      }
    }
    if (stencilTexture) {
      stencilTexture->create();
      if (auto* stencilTarget = renderPassDescriptor->stencilAttachment()) {
        stencilTarget->setTexture(
            static_cast<mtl::Texture2D*>(stencilTexture.get())->getMetalTexture());
      }
    }
  }

  void swap() override {
    // Release one in-flight slot when the GPU finishes this frame (pairs with the
    // dispatch_semaphore_wait in bind()). Registered before commit so the handler
    // is attached when the buffer is scheduled. Capture the semaphore (not this)
    // so a late callback can't touch a freed resource.
    dispatch_semaphore_t sem = inFlight;
    commandBuffer->addCompletedHandler(^(MTL::CommandBuffer*) { dispatch_semaphore_signal(sem); });

    // Async present (presentDrawable + commit), like MapLibre's macOS
    // MLNMapView+Metal swap(). No presentsWithTransaction / waitUntil* — those
    // stall on the GLFW (non-CADisplayLink) loop. The semaphore (not per-frame
    // waits) is what bounds the queue now.
    if (surface) {
      commandBuffer->presentDrawable(surface.get());
    }
    commandBuffer->commit();
    commandBuffer.reset();
    renderPassDescriptor.reset();
    surface.reset();
  }

  const mtl::RendererBackend& getBackend() const override { return rendererBackend; }

  const mtl::MTLCommandBufferPtr& getCommandBuffer() const override { return commandBuffer; }

  mtl::MTLBlitPassDescriptorPtr getUploadPassDescriptor() const override {
    return NS::TransferPtr(MTL::BlitPassDescriptor::alloc()->init());
  }

  const mtl::MTLRenderPassDescriptorPtr& getRenderPassDescriptor() const override {
    return renderPassDescriptor;
  }

  const CAMetalLayerPtr& getSwapchain() const { return swapchain; }

private:
  // Drawable pool depth == max frames the CPU may queue ahead of the GPU.
  static constexpr long kMaxFramesInFlight = 3;

  MetalBackend& rendererBackend;
  // Bounds in-flight frames to the drawable-pool size (frame pacing). Created in
  // the ctor; intentionally never dispatch_release'd — process-lifetime singleton
  // (one window), ARC is off for this .mm.
  dispatch_semaphore_t inFlight = nullptr;
  MTLCommandQueuePtr commandQueue;
  MTLCommandBufferPtr commandBuffer;
  MTLRenderPassDescriptorPtr renderPassDescriptor;
  CAMetalDrawablePtr surface;
  CAMetalLayerPtr swapchain;
  gfx::Texture2DPtr depthTexture;
  gfx::Texture2DPtr stencilTexture;
  mbgl::Size size;
  bool buffersInvalid = true;
};

}  // namespace mbgl

MetalBackend::MetalBackend(NSWindow* window)
    : mbgl::mtl::RendererBackend(mbgl::gfx::ContextMode::Unique),
      mbgl::gfx::Renderable(mbgl::Size{0, 0},
                            std::make_unique<mbgl::MetalRenderableResource>(*this)) {
  window.contentView.layer = (__bridge CALayer*)getDefaultRenderable()
                                 .getResource<mbgl::MetalRenderableResource>()
                                 .getSwapchain()
                                 .get();
  window.contentView.wantsLayer = YES;
}

mbgl::gfx::Renderable& MetalBackend::getDefaultRenderable() { return *this; }

void MetalBackend::activate() {}
void MetalBackend::deactivate() {}
void MetalBackend::updateAssumedState() {}

void MetalBackend::setSize(mbgl::Size size_) {
  getResource<mbgl::MetalRenderableResource>().setBackendSize(size_);
}

mbgl::Size MetalBackend::getSize() const {
  return getResource<mbgl::MetalRenderableResource>().getSize();
}
