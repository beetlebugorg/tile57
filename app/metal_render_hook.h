#pragma once

// Cocoa-free entry point so chartplotter.cpp (compiled as plain C++, which can't
// #import Cocoa) can wire the MTKView's per-vsync draw without referencing any
// Metal/Obj-C types. Defined in metal_backend.mm (Metal builds only); the passed
// RendererBackend& is downcast to MetalBackend internally.
//
// `cb` is invoked from MTKView's drawInMTKView: (once per vsync) and should
// render exactly one frame (i.e. RendererFrontend::render()).

#include <functional>

namespace mbgl {
namespace gfx {
class RendererBackend;
} // namespace gfx
} // namespace mbgl

void chartSetMetalRenderCallback(mbgl::gfx::RendererBackend &backend, std::function<void()> cb);
