cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(chartplotter_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

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
# Zig tile generator (libtilegen.a), built by its own `zig build`, linked into
# the C++ host. This is the C ABI seam (include/tilegen.h) for live in-process
# tile generation.
# ---------------------------------------------------------------------------
find_program(ZIG_EXECUTABLE zig HINTS "$ENV{HOME}/.local/bin" "$ENV{HOME}/.local/share/zig-0.16.0")
if(ZIG_EXECUTABLE)
  set(TILEGEN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/tilegen)
  set(TILEGEN_LIB ${TILEGEN_DIR}/zig-out/lib/libtilegen.a)
  file(GLOB TILEGEN_SRCS ${TILEGEN_DIR}/src/*.zig)
  add_custom_command(
    OUTPUT ${TILEGEN_LIB}
    COMMAND ${ZIG_EXECUTABLE} build -Doptimize=ReleaseFast
    WORKING_DIRECTORY ${TILEGEN_DIR}
    DEPENDS ${TILEGEN_SRCS} ${TILEGEN_DIR}/build.zig
    COMMENT "Building libtilegen.a (zig build)"
    VERBATIM)
  add_custom_target(tilegen_lib DEPENDS ${TILEGEN_LIB})

  add_executable(chartshot-zig app/zig_render.cpp app/zig_tile_source.cpp)
  add_dependencies(chartshot-zig tilegen_lib)
  target_include_directories(chartshot-zig PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/app
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/maplibre-native/platform/default/include)
  target_link_libraries(chartshot-zig PRIVATE mbgl-compiler-options mbgl-core ${TILEGEN_LIB})
else()
  message(STATUS "zig not found; skipping chartshot-zig (Zig tile source host)")
endif()
