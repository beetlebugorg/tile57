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

// Obj-C QuartzCore, for the one property metal-cpp does not expose
// (CAMetalLayer.presentsWithTransaction). The metal-cpp CA::MetalLayer* IS the
// underlying Obj-C object, so a __bridge cast reaches it.
#import <QuartzCore/QuartzCore.h>

namespace mbgl {

using namespace mtl;

class MetalRenderableResource final : public mtl::RenderableResource {
public:
  MetalRenderableResource(MetalBackend& backend)
      : rendererBackend(backend),
        commandQueue(NS::TransferPtr(backend.getDevice()->newCommandQueue())),
        swapchain(NS::TransferPtr(CA::MetalLayer::layer())) {
    swapchain->setDevice(backend.getDevice().get());
    // *** PATCH: block for a drawable instead of returning nil under load, so a
    // missing drawable never blanks the frame. ***
    swapchain->setMaximumDrawableCount(3);
    swapchain->setAllowsNextDrawableTimeout(false);
    // *** PATCH (the canonical macOS Metal flicker fix, per Apple's CAMetalLayer
    // docs / "Glitchless Metal Window Resizing"): present the drawable
    // SYNCHRONOUSLY within the CoreAnimation transaction instead of the async
    // commandBuffer->presentDrawable(). Eliminates the tearing/flicker on fast
    // pan/zoom and resize. The matching present sequence is in swap(). metal-cpp
    // doesn't expose this property, so set it on the Obj-C CAMetalLayer. ***
    ((__bridge CAMetalLayer *)swapchain.get()).presentsWithTransaction = YES;
  }

  void setBackendSize(mbgl::Size size_) {
    size = size_;
    swapchain->setDrawableSize(
        {static_cast<CGFloat>(size.width), static_cast<CGFloat>(size.height)});
    buffersInvalid = true;
  }

  mbgl::Size getSize() const { return size; }

  void bind() override {
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
    // *** PATCH: presentsWithTransaction present sequence (Apple-documented Metal
    // flicker fix). Do NOT use commandBuffer->presentDrawable() (that's the async
    // path). Instead commit, wait until the command buffer is SCHEDULED, then
    // present the drawable synchronously — so the swap happens inside the same
    // CoreAnimation transaction as the layout, with no tearing/flicker. ***
    commandBuffer->commit();
    if (surface) {
      commandBuffer->waitUntilScheduled();
      surface->present();
      // presentsWithTransaction queues the present to the current CoreAnimation
      // transaction, which is normally committed by the main CFRunLoop. The GLFW
      // libuv loop never commits it promptly, so the present defers, drawables
      // don't free, and the next nextDrawable() blocks for hundreds of ms (2-8
      // fps with wildly varying frame times). Flush commits the transaction now.
      [CATransaction flush];
    }
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
  MetalBackend& rendererBackend;
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
