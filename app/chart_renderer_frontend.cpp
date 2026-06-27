#include "chart_renderer_frontend.hpp"

#include <mbgl/renderer/renderer.hpp>
#include <mbgl/gfx/backend_scope.hpp>
#include <mbgl/gfx/renderer_backend.hpp>

ChartRendererFrontend::ChartRendererFrontend(std::unique_ptr<mbgl::Renderer> renderer_,
                                             mbgl::gfx::RendererBackend &backend_)
    : renderer(std::move(renderer_)), backend(backend_) {}

ChartRendererFrontend::~ChartRendererFrontend() = default;

void ChartRendererFrontend::reset() {
    if (renderer) renderer.reset();
}

void ChartRendererFrontend::setObserver(mbgl::RendererObserver &observer) {
    if (renderer) renderer->setObserver(&observer);
}

void ChartRendererFrontend::update(std::shared_ptr<mbgl::UpdateParameters> params) {
    // Just stash it. No GLFW invalidate: MTKView's display link renders every
    // vsync and picks up the latest parameters in render() below.
    updateParameters = std::move(params);
}

const mbgl::TaggedScheduler &ChartRendererFrontend::getThreadPool() const {
    return backend.getThreadPool();
}

void ChartRendererFrontend::render() {
    if (!renderer || !updateParameters) return;

    mbgl::gfx::BackendScope guard{backend, mbgl::gfx::BackendScope::ScopeType::Implicit};

    // Copy the shared_ptr so a re-entrant update() (e.g. via onStyleImageMissing)
    // can't free the parameters mid-render. (Same guard GLFWRendererFrontend uses.)
    auto updateParameters_ = updateParameters;
    renderer->render(updateParameters_);
}

mbgl::Renderer *ChartRendererFrontend::getRenderer() {
    return renderer.get();
}
