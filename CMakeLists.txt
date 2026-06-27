cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(chartplotter_native LANGUAGES C CXX)

# On Apple, the Metal backend + GLFW Metal glue (glfw_metal_backend.mm,
# metal_backend.mm, glfw_apple_init.mm) are Objective-C++. The top-level
# project() language set governs the whole tree, so enable OBJC/OBJCXX here or
# CMake has no rule to compile .mm files (CMAKE_OBJCXX_COMPILE_OBJECT unset).
# Linux is untouched (it compiles the .cpp GL backend, no .mm).
if(APPLE)
  enable_language(OBJC)
  enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON) # for clangd / editors

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

# Use ccache automatically if available (not required).
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
  set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
endif()

# ---------------------------------------------------------------------------
# MapLibre Native (embedded as a subdirectory; built by its own CMake).
#
# Renderer is platform-specific:
#   - Apple  -> Metal
#   - Linux  -> OpenGL via EGL (surfaceless headless backend works displayless)
#
# Build configs (see CMakePresets.json): a headless one (GLFW off -> mbgl-render
# to PNG) and a desktop one (GLFW on -> mbgl-glfw interactive window). All
# defaults below are plain CACHE entries (no FORCE) so a preset or -D... wins.
# ---------------------------------------------------------------------------
if(APPLE)
  set(MLN_WITH_METAL    ON  CACHE BOOL "")   # Metal is the macOS/iOS backend
  set(MLN_WITH_OPENGL   OFF CACHE BOOL "")
  set(MLN_WITH_EGL      OFF CACHE BOOL "")
  set(MLN_DARWIN_USE_LIBUV ON CACHE BOOL "") # libuv run loop on darwin
else()
  set(MLN_WITH_OPENGL   ON  CACHE BOOL "")
  set(MLN_WITH_EGL      ON  CACHE BOOL "")   # surfaceless headless backend
  set(MLN_WITH_METAL    OFF CACHE BOOL "")
  set(MLN_WITH_X11      OFF CACHE BOOL "")
  set(MLN_WITH_WAYLAND  OFF CACHE BOOL "")   # desktop preset turns this ON (Linux)
endif()

set(MLN_WITH_VULKAN   OFF CACHE BOOL "")
set(MLN_WITH_PMTILES  ON  CACHE BOOL "")   # native pmtiles:// source (M1)
set(MLN_WITH_GLFW     OFF CACHE BOOL "")   # desktop preset turns this ON
set(MLN_WITH_WERROR   OFF CACHE BOOL "")   # clang 22 is bleeding-edge
set(MLN_WITH_NODE     OFF CACHE BOOL "")
set(MLN_WITH_QT       OFF CACHE BOOL "")

add_subdirectory(vendor/maplibre-native)

# ---------------------------------------------------------------------------
# Zig tile generator (libtile57.a), built by its own `zig build`, linked
# into the C++ host. This is the tile-source C ABI seam (include/tile57.h) for
# live in-process tile generation. The Zig sources live under engine/.
# ---------------------------------------------------------------------------
find_program(ZIG_EXECUTABLE zig HINTS "$ENV{HOME}/.local/bin" "$ENV{HOME}/.local/share/zig-0.16.0")
if(ZIG_EXECUTABLE)
  set(ENGINE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/engine)
  set(TILE57_LIB ${ENGINE_DIR}/zig-out/lib/libtile57.a)
  # Always invoke `zig build` (Zig's own cache makes it a no-op when nothing
  # changed). A glob of src/*.zig is evaluated at configure time and misses new
  # files / the C shim / vendored Lua, so relying on it for deps left the lib
  # stale after a pull. Running unconditionally is cheap and always correct.
  add_custom_target(tile57_lib ALL
    BYPRODUCTS ${TILE57_LIB}
    COMMAND ${CMAKE_COMMAND} -E env "ZIG=${ZIG_EXECUTABLE}"
            "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/zig-build-lib.sh ReleaseFast
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Building libtile57.a (zig build + macOS archive re-pack)"
    VERBATIM)

  # -------------------------------------------------------------------------
  # libchartplotter — the embeddable chart-widget library (CMake target
  # `chartplotter_widget`, artifact libchartplotter.a). It wraps MapLibre Native
  # + libtile57 behind the C API in include/chartplotter.h: render a chart to a
  # PNG offscreen (always), and — when built with GLFW (the desktop presets) —
  # open an interactive window (chartplotter_view_*). The exes are thin mains.
  #
  # There is no reusable mbgl-glfw *library* (platform/glfw only builds the
  # mbgl-glfw exe), so the window half compiles MapLibre's GLFW view/backend
  # source set into this library, guarded by CHARTPLOTTER_WITH_GLFW. (tinyobjloader
  # / cheap-ruler are existing targets from MapLibre's glfw subdir — just link
  # them; do NOT re-include vendor/tinyobjloader.cmake.)
  # -------------------------------------------------------------------------
  set(MLN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendor/maplibre-native)

  add_library(chartplotter_widget STATIC app/chartplotter.cpp app/chart_tile_source.cpp)
  set_target_properties(chartplotter_widget PROPERTIES OUTPUT_NAME chartplotter)
  add_dependencies(chartplotter_widget tile57_lib)
  target_include_directories(chartplotter_widget PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_include_directories(chartplotter_widget PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/app
    ${MLN_DIR}/platform/default/include)
  target_link_libraries(chartplotter_widget PUBLIC mbgl-core ${TILE57_LIB})
  target_link_libraries(chartplotter_widget PRIVATE mbgl-compiler-options)

  if(MLN_WITH_GLFW)
    if(NOT WIN32)
      find_package(PkgConfig REQUIRED)
      pkg_search_module(GLFW glfw3 REQUIRED)
    endif()
    target_compile_definitions(chartplotter_widget PRIVATE CHARTPLOTTER_WITH_GLFW=1)
    target_sources(chartplotter_widget PRIVATE
      ${MLN_DIR}/platform/glfw/glfw_view.cpp
      ${MLN_DIR}/platform/glfw/glfw_renderer_frontend.cpp
      ${MLN_DIR}/platform/glfw/test_writer.cpp
      ${MLN_DIR}/platform/glfw/example_custom_drawable_style_layer.cpp
      ${MLN_DIR}/platform/default/src/mbgl/map/map_snapshotter.cpp)
    # GLFWView bakes a default asset path in at compile time.
    set_property(SOURCE ${MLN_DIR}/platform/glfw/glfw_view.cpp
      PROPERTY COMPILE_DEFINITIONS MLN_ASSETS_PATH="${MLN_DIR}/platform/glfw/assets/")
    if(APPLE)
      target_sources(chartplotter_widget PRIVATE ${MLN_DIR}/platform/glfw/glfw_apple_init.mm)
    endif()
    if(MLN_WITH_OPENGL)
      find_package(OpenGL REQUIRED)
      target_sources(chartplotter_widget PRIVATE ${MLN_DIR}/platform/glfw/glfw_gl_backend.cpp)
    endif()
    if(MLN_WITH_METAL)
      # Our MTKView-based metal_backend.mm (app/metal_backend.h, ported from
      # MapLibre's own MLNMapView+Metal.mm) replaces the GLFW example's hand-rolled
      # CAMetalLayer backend: MTKView's internal CVDisplayLink drives rendering at
      # vsync (fixes the present-timing flicker + blank-on-idle). CHARTPLOTTER_METAL
      # switches the host (chartplotter.cpp) onto the MTKView render path +
      # ChartRendererFrontend. metal-cpp is header-only and mbgl-core links Metal
      # PRIVATE, so we link the Apple frameworks here (QuartzCore + Metal +
      # Foundation for the metal-cpp objects/CAMetalLayer, MetalKit for MTKView).
      target_compile_definitions(chartplotter_widget PRIVATE CHARTPLOTTER_METAL=1)
      target_sources(chartplotter_widget PRIVATE
        ${MLN_DIR}/platform/glfw/glfw_metal_backend.mm
        ${CMAKE_CURRENT_SOURCE_DIR}/app/metal_backend.mm
        ${CMAKE_CURRENT_SOURCE_DIR}/app/chart_renderer_frontend.cpp)
      target_link_libraries(chartplotter_widget PUBLIC mbgl-vendor-metal-cpp
        "-framework QuartzCore" "-framework Metal" "-framework Foundation"
        "-framework MetalKit")
    endif()
    if(MLN_WITH_EGL)
      target_compile_definitions(chartplotter_widget PRIVATE MBGL_WITH_EGL=1)
    endif()
    if(DEFINED MLN_WITH_X11 AND MLN_WITH_X11)
      target_compile_definitions(chartplotter_widget PRIVATE MLN_WITH_X11=1)
    endif()
    if(DEFINED MLN_WITH_WAYLAND AND MLN_WITH_WAYLAND)
      target_compile_definitions(chartplotter_widget PRIVATE MLN_WITH_WAYLAND=1)
    endif()
    target_include_directories(chartplotter_widget PRIVATE
      ${MLN_DIR}/platform/glfw ${MLN_DIR}/src ${GLFW_INCLUDE_DIRS})
    target_link_libraries(chartplotter_widget PUBLIC
      Mapbox::Map mbgl-vendor-rapidjson MapLibreNative::Base::cheap-ruler-cpp tinyobjloader
      $<$<BOOL:${GLFW_LIBRARY_DIRS}>:-L${GLFW_LIBRARY_DIRS}> ${GLFW_LIBRARIES})
    if(NOT WIN32 AND MLN_WITH_OPENGL)
      target_link_libraries(chartplotter_widget PUBLIC OpenGL::GL)
    endif()
  endif()

  # Thin exes over libchartplotter.
  add_executable(chartplotter-render app/chartplotter_render_main.cpp)
  target_include_directories(chartplotter-render PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/app)
  target_link_libraries(chartplotter-render PRIVATE chartplotter_widget mbgl-compiler-options)

  if(MLN_WITH_GLFW)
    add_executable(chartplotter app/chartplotter_main.cpp)
    target_include_directories(chartplotter PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/app)
    target_link_libraries(chartplotter PRIVATE chartplotter_widget mbgl-compiler-options)
  endif()
else()
  message(STATUS "zig not found; skipping chartplotter / chartplotter-render (Zig tile source hosts)")
endif()
