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
# Zig tile generator (libchartplotter.a), built by its own `zig build`, linked
# into the C++ host. This is the public C ABI seam (include/chartplotter.h) for
# live in-process tile generation. The Zig sources live under tilegen/ (the
# implementation keeps the descriptive "tile generator" name).
# ---------------------------------------------------------------------------
find_program(ZIG_EXECUTABLE zig HINTS "$ENV{HOME}/.local/bin" "$ENV{HOME}/.local/share/zig-0.16.0")
if(ZIG_EXECUTABLE)
  set(TILEGEN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/tilegen)
  set(CHARTPLOTTER_LIB ${TILEGEN_DIR}/zig-out/lib/libchartplotter.a)
  # Always invoke `zig build` (Zig's own cache makes it a no-op when nothing
  # changed). A glob of src/*.zig is evaluated at configure time and misses new
  # files / the C shim / vendored Lua, so relying on it for deps left the lib
  # stale after a pull. Running unconditionally is cheap and always correct.
  add_custom_target(chartplotter_lib ALL
    BYPRODUCTS ${CHARTPLOTTER_LIB}
    COMMAND ${CMAKE_COMMAND} -E env "ZIG=${ZIG_EXECUTABLE}"
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/zig-build-lib.sh ReleaseFast
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Building libchartplotter.a (zig build + macOS archive re-pack)"
    VERBATIM)

  add_executable(chartplotter-render app/zig_render.cpp app/chart_tile_source.cpp)
  add_dependencies(chartplotter-render chartplotter_lib)
  target_include_directories(chartplotter-render PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/app
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/maplibre-native/platform/default/include)
  target_link_libraries(chartplotter-render PRIVATE mbgl-compiler-options mbgl-core ${CHARTPLOTTER_LIB})

  # -------------------------------------------------------------------------
  # Interactive GLFW window host (M3): the same in-process Zig tile source,
  # but in a real pannable/zoomable window instead of a one-shot PNG.
  #
  # There is no reusable mbgl-glfw *library* (platform/glfw/CMakeLists.txt only
  # builds the mbgl-glfw executable), so we compile the GLFW view/backend source
  # set ourselves with our own main (app/zig_glfw.cpp). Built only when GLFW is
  # enabled (the desktop / macos-desktop presets), where MapLibre has already
  # added its glfw subdir — so `tinyobjloader` is an existing target we just
  # link (do NOT re-include vendor/tinyobjloader.cmake; FetchContent would
  # redeclare it).
  # -------------------------------------------------------------------------
  if(MLN_WITH_GLFW)
    set(MLN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendor/maplibre-native)
    if(NOT WIN32)
      find_package(PkgConfig REQUIRED)
      pkg_search_module(GLFW glfw3 REQUIRED)
    endif()

    add_executable(chartplotter
      app/zig_glfw.cpp
      app/chart_tile_source.cpp
      ${MLN_DIR}/platform/glfw/glfw_view.cpp
      ${MLN_DIR}/platform/glfw/glfw_renderer_frontend.cpp
      ${MLN_DIR}/platform/glfw/test_writer.cpp
      ${MLN_DIR}/platform/glfw/example_custom_drawable_style_layer.cpp
      ${MLN_DIR}/platform/default/src/mbgl/map/map_snapshotter.cpp)
    add_dependencies(chartplotter chartplotter_lib)

    # GLFWView bakes a default asset path in at compile time.
    set_property(SOURCE ${MLN_DIR}/platform/glfw/glfw_view.cpp
      PROPERTY COMPILE_DEFINITIONS MLN_ASSETS_PATH="${MLN_DIR}/platform/glfw/assets/")

    if(APPLE)
      target_sources(chartplotter PRIVATE ${MLN_DIR}/platform/glfw/glfw_apple_init.mm)
    endif()
    if(MLN_WITH_OPENGL)
      find_package(OpenGL REQUIRED)
      target_sources(chartplotter PRIVATE ${MLN_DIR}/platform/glfw/glfw_gl_backend.cpp)
    endif()
    if(MLN_WITH_METAL)
      # Use our patched metal_backend.mm (nextDrawable nil-check + no-timeout, to
      # stop the whole-screen blank/flicker on fast pan/zoom) instead of the
      # vendored one; metal_backend.h is reused unchanged.
      target_sources(chartplotter PRIVATE
        ${MLN_DIR}/platform/glfw/glfw_metal_backend.mm
        ${CMAKE_CURRENT_SOURCE_DIR}/app/metal_backend.mm)
      # QuartzCore provides CATransaction / CAMetalLayer (our metal_backend.mm
      # uses [CATransaction flush] + the CAMetalLayer.presentsWithTransaction
      # property directly). Metal-cpp covers the C++ side but not these Obj-C
      # class symbols.
      target_link_libraries(chartplotter PRIVATE mbgl-vendor-metal-cpp
        "-framework QuartzCore" "-framework Metal" "-framework Foundation")
    endif()
    if(MLN_WITH_EGL)
      target_compile_definitions(chartplotter PRIVATE MBGL_WITH_EGL=1)
    endif()
    if(DEFINED MLN_WITH_X11 AND MLN_WITH_X11)
      target_compile_definitions(chartplotter PRIVATE MLN_WITH_X11=1)
    endif()
    if(DEFINED MLN_WITH_WAYLAND AND MLN_WITH_WAYLAND)
      target_compile_definitions(chartplotter PRIVATE MLN_WITH_WAYLAND=1)
    endif()

    target_include_directories(chartplotter PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/include
      ${CMAKE_CURRENT_SOURCE_DIR}/app
      ${MLN_DIR}/platform/glfw
      ${MLN_DIR}/src
      ${MLN_DIR}/platform/default/include
      ${GLFW_INCLUDE_DIRS})

    target_link_libraries(chartplotter PRIVATE
      Mapbox::Map mbgl-compiler-options mbgl-vendor-rapidjson
      MapLibreNative::Base::cheap-ruler-cpp tinyobjloader
      $<$<BOOL:${GLFW_LIBRARY_DIRS}>:-L${GLFW_LIBRARY_DIRS}> ${GLFW_LIBRARIES}
      ${CHARTPLOTTER_LIB})
    if(NOT WIN32 AND MLN_WITH_OPENGL)
      target_link_libraries(chartplotter PRIVATE OpenGL::GL)
    endif()
  endif()
else()
  message(STATUS "zig not found; skipping chartplotter / chartplotter-render (Zig tile source hosts)")
endif()
