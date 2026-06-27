// Native macOS window host (no GLFW). See chart_native_host.h.
#include "chart_native_host.h"
#include "metal_backend.h"

#import <Cocoa/Cocoa.h>

#include <mbgl/map/map.hpp>
#include <mbgl/util/run_loop.hpp>

#include <optional>

struct ChartNativeHost::Impl {
    // Created on the main thread first: mbgl's Darwin RunLoop is CFRunLoop-backed,
    // so its async source attaches to the main run loop that [NSApp run] pumps.
    mbgl::util::RunLoop runLoop;
    NSWindow *window = nil;
    std::unique_ptr<MetalBackend> backend;
    mbgl::Map *map = nullptr; // not owned
    id scrollMonitor = nil;
};

ChartNativeHost::ChartNativeHost(const char *title, uint32_t width, uint32_t height)
    : impl(std::make_unique<Impl>()) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        const NSRect rect = NSMakeRect(0, 0, width, height);
        const NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
        impl->window = [[NSWindow alloc] initWithContentRect:rect
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        [impl->window setTitle:[NSString stringWithUTF8String:(title ? title : "chartplotter")]];
        [impl->window center];

        // Reuse the MTKView backend; it adds an MTKView subview to contentView and
        // drives rendering off MTKView's internal CVDisplayLink (vsync).
        impl->backend = std::make_unique<MetalBackend>(impl->window);

        [impl->window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

ChartNativeHost::~ChartNativeHost() {
    @autoreleasepool {
        if (impl->scrollMonitor) {
            [NSEvent removeMonitor:impl->scrollMonitor];
            impl->scrollMonitor = nil;
        }
        impl->backend.reset(); // resource dtor pauses MTKView + nils its delegate
        [impl->window close];
        impl->window = nil;
    }
}

mbgl::gfx::RendererBackend &ChartNativeHost::getRendererBackend() { return *impl->backend; }

mbgl::Size ChartNativeHost::getSize() const {
    const NSSize sz = impl->window.contentView.bounds.size; // logical points
    return {static_cast<uint32_t>(sz.width), static_cast<uint32_t>(sz.height)};
}

float ChartNativeHost::getPixelRatio() const {
    return static_cast<float>(impl->window.backingScaleFactor);
}

void ChartNativeHost::setRenderCallback(std::function<void()> cb) {
    impl->backend->setRenderCallback(std::move(cb));
}

void ChartNativeHost::setMap(mbgl::Map *map) {
    impl->map = map;
    mbgl::Map *m = map;
    // Minimal input: scroll-to-zoom, enough to exercise the worst-case (zoom)
    // flicker. Runs on the main thread (same as the Map/RunLoop). Full gestures
    // once flicker is settled.
    impl->scrollMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                     handler:^NSEvent *(NSEvent *event) {
                                       if (m) {
                                           const double dy = event.scrollingDeltaY;
                                           if (dy != 0.0) m->scaleBy(dy > 0 ? 1.06 : (1.0 / 1.06), std::nullopt);
                                       }
                                       return event;
                                     }];
}

void ChartNativeHost::run() {
    // [NSApp run] pumps the main CFRunLoop, which services Cocoa events, MTKView's
    // display link, and mbgl's RunLoop source. (Cmd-Q to quit for now.)
    [NSApp run];
}
