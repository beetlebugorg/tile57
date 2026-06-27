cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(chartplotter_native LANGUAGES C CXX)

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
# MapLibre Native (embedded as a subdirectory; built by its own CMake) — the
# offscreen render path only (chartplotter-render -> PNG). The interactive window
# is a separate Qt6 app (app/qt, built via scripts/build-qmaplibre.sh) that links
# QMapLibre instead of mbgl directly.
#
# Renderer is platform-specific:
#   - Apple  -> Metal
#   - Linux  -> OpenGL via EGL (surfaceless headless backend works displayless)
#
# Defaults below are plain CACHE entries (no FORCE) so a preset or -D... wins.
# ---------------------------------------------------------------------------
# The render backend is platform-fixed (exactly one allowed), so FORCE it — this
# also clears a stale value if the build dir was configured for another backend.
if(APPLE)
  set(MLN_WITH_METAL    ON  CACHE BOOL "" FORCE)  # Metal: the only macOS render backend
  set(MLN_WITH_OPENGL   OFF CACHE BOOL "" FORCE)
  set(MLN_WITH_EGL      OFF CACHE BOOL "")
  set(MLN_DARWIN_USE_LIBUV ON CACHE BOOL "")      # libuv run loop on darwin
else()
  set(MLN_WITH_OPENGL   ON  CACHE BOOL "" FORCE)  # OpenGL/EGL: the only Linux render backend
  set(MLN_WITH_EGL      ON  CACHE BOOL "")         # surfaceless headless backend
  set(MLN_WITH_METAL    OFF CACHE BOOL "" FORCE)
endif()

set(MLN_WITH_VULKAN   OFF CACHE BOOL "" FORCE)
set(MLN_WITH_WEBGPU   OFF CACHE BOOL "" FORCE)
set(MLN_WITH_PMTILES  ON  CACHE BOOL "")   # native pmtiles:// source
set(MLN_WITH_WERROR   OFF CACHE BOOL "")   # clang/gcc are bleeding-edge here
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
  # libchartplotter — the headless chart-render library (CMake target
  # `chartplotter_widget`, artifact libchartplotter.a). It wraps MapLibre Native
  # + libtile57 behind the C API in include/chartplotter.h: render a chart to a
  # PNG offscreen (ChartTileSource serves tiles from libtile57). chartplotter-render
  # is a thin main over it. The interactive window is the Qt6 app in app/qt.
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

  # Thin exe: chart -> PNG (headless EGL / Metal).
  add_executable(chartplotter-render app/chartplotter_render_main.cpp)
  target_include_directories(chartplotter-render PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/app)
  target_link_libraries(chartplotter-render PRIVATE chartplotter_widget mbgl-compiler-options)
else()
  message(STATUS "zig not found; skipping chartplotter-render (needs libtile57)")
endif()

# ---------------------------------------------------------------------------
# Optional: the Qt6 chart viewer, `chartplotter-qt`.
#
# QMapLibre (vendor/maplibre-native-qt) builds its OWN mbgl-core, so it can't be
# add_subdirectory'd next to our vendored maplibre-native (target collision). We
# build it as an isolated ExternalProject, then build app/qt against it — so one
# `cmake && ninja` does everything. It's heavy (compiles a whole map renderer),
# so it's opt-in: -DCHARTPLOTTER_WITH_QT=ON (the desktop / macos-desktop presets).
# Renderer + Qt location are auto-detected, so there are no flags to pass.
# ---------------------------------------------------------------------------
option(CHARTPLOTTER_WITH_QT "Build the Qt6 chart viewer chartplotter-qt (builds QMapLibre; heavy)" OFF)
if(CHARTPLOTTER_WITH_QT)
  include(ExternalProject)

  # Find Qt6 (auto-add Homebrew's qt prefix on macOS) + its cmake toolchain.
  if(APPLE)
    execute_process(COMMAND brew --prefix qt
      OUTPUT_VARIABLE BREW_QT OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(BREW_QT)
      list(PREPEND CMAKE_PREFIX_PATH ${BREW_QT})
    endif()
  endif()
  find_package(Qt6 REQUIRED COMPONENTS Widgets)
  set(QT_TOOLCHAIN ${Qt6_DIR}/qt.toolchain.cmake)

  set(QMLB_SRC ${CMAKE_CURRENT_SOURCE_DIR}/vendor/maplibre-native-qt)
  set(QMLB_PREFIX ${CMAKE_BINARY_DIR}/qmaplibre)

  # Renderer MUST match Qt's RHI backend: Metal on macOS, OpenGL on Linux. (An
  # OpenGL mbgl crashes against a Metal QRhiCommandBuffer.)
  if(APPLE)
    set(QMLB_RENDERER -DMLN_WITH_METAL=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0)
  else()
    set(QMLB_RENDERER -DMLN_WITH_OPENGL=ON)
  endif()

  # maplibre-native-qt vendors its own maplibre-native — fetch it (heavy, once).
  if(NOT EXISTS ${QMLB_SRC}/vendor/maplibre-native/CMakeLists.txt)
    message(STATUS "chartplotter-qt: fetching maplibre-native-qt submodules (heavy, one-time)")
    execute_process(
      COMMAND git submodule update --init --recursive vendor/maplibre-native-qt
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      RESULT_VARIABLE _qmlb_sm)
    if(NOT _qmlb_sm EQUAL 0)
      message(FATAL_ERROR "git submodule fetch for maplibre-native-qt failed")
    endif()
  endif()

  # 1. QMapLibre (Widgets only — Location/Quick want Qt6Location/Qt6Quick).
  ExternalProject_Add(qmaplibre
    SOURCE_DIR ${QMLB_SRC}
    CMAKE_GENERATOR Ninja
    CMAKE_ARGS
      -DCMAKE_TOOLCHAIN_FILE=${QT_TOOLCHAIN}
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POLICY_VERSION_MINIMUM=3.19
      -DCMAKE_INSTALL_PREFIX=${QMLB_PREFIX}
      -DQT_VERSION_MAJOR=6
      ${QMLB_RENDERER}
      -DMLN_QT_WITH_INTERNAL_ICU=ON
      -DMLN_QT_WITH_WIDGETS=ON
      -DMLN_QT_WITH_LOCATION=OFF
      -DMLN_QT_WITH_QUICK_PLUGIN=OFF
      -DMLN_WITH_WERROR=OFF
    BUILD_ALWAYS OFF)

  # 2. The viewer (app/qt), find_package'd against the installed QMapLibre.
  #    Installs to ${CMAKE_BINARY_DIR}/bin/chartplotter-qt. Target name matches the
  #    binary (`ninja chartplotter-qt`).
  ExternalProject_Add(chartplotter-qt
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/app/qt
    DEPENDS qmaplibre
    CMAKE_GENERATOR Ninja
    CMAKE_ARGS
      -DCMAKE_TOOLCHAIN_FILE=${QT_TOOLCHAIN}
      -DCMAKE_PREFIX_PATH=${QMLB_PREFIX}
      -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}
    BUILD_ALWAYS ON)

  message(STATUS "chartplotter-qt: enabled -> ${CMAKE_BINARY_DIR}/bin/chartplotter-qt")
endif()
