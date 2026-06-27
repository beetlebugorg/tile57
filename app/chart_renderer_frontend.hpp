#pragma once

// A RendererFrontend that does NOT drive GLFW's render loop. It mirrors
// GLFWRendererFrontend but drops the GLFWView coupling: update() just stores the
// latest parameters (no glfwView.invalidate()), and render() is called from the
// MTKView delegate (per vsync) instead of GLFW's frameTick. This is what lets
// MTKView be the sole render driver on macOS/Metal while GLFW keeps the window
// and input. (On non-Metal builds we keep using GLFWRendererFrontend.)

#include <mbgl/renderer/renderer_frontend.hpp>

#include <memory>

namespace mbgl {
class Renderer;
namespace gfx {
class RendererBackend;
} // namespace gfx
} // namespace mbgl

class ChartRendererFrontend : public mbgl::RendererFrontend {
public:
    ChartRendererFrontend(std::unique_ptr<mbgl::Renderer>, mbgl::gfx::RendererBackend &);
    ~ChartRendererFrontend() override;

    void reset() override;
    void setObserver(mbgl::RendererObserver &) override;
    void update(std::shared_ptr<mbgl::UpdateParameters>) override;
    const mbgl::TaggedScheduler &getThreadPool() const override;

    // Render the latest update. Called from the MTKView delegate (vsync), inside
    // a frame where the drawable / render-pass descriptor are valid.
    void render();

    mbgl::Renderer *getRenderer();

private:
    std::unique_ptr<mbgl::Renderer> renderer;
    mbgl::gfx::RendererBackend &backend;
    std::shared_ptr<mbgl::UpdateParameters> updateParameters;
};
