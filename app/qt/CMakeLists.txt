# chartplotter-qt — the Qt6 MapLibre chart viewer. A standalone CMake project
# (independent of the libtile57/mbgl build) that links QMapLibre (the Qt6
# MapLibre widget, from vendor/maplibre-native-qt). Build QMapLibre first with
# scripts/build-qmaplibre.sh, which also builds this; or configure manually with
# -DCMAKE_PREFIX_PATH=<qmaplibre-install>.
cmake_minimum_required(VERSION 3.19)

project(chartplotter_qt LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets)
qt_standard_project_setup()
find_package(QMapLibre REQUIRED COMPONENTS Widgets)

qt_add_executable(chartplotter-qt main.cpp map_helpers.cpp)
target_link_libraries(chartplotter-qt PRIVATE QMapLibre::Widgets)

# Live ENC support: when the outer build passes TILE57_LIB (the Zig tile
# generator), compile the localhost tile server and link libtile57 so the viewer
# can open an ENC_ROOT / S-57 cell / PMTiles directly. The HTTP endpoint uses
# Qt6::Network. Without TILE57_LIB the viewer still builds (style files only).
if(TILE57_LIB)
  find_package(Qt6 REQUIRED COMPONENTS Network)
  target_sources(chartplotter-qt PRIVATE
    tile_server.cpp mariner_panel.cpp band_panel.cpp chart_window.cpp)
  target_include_directories(chartplotter-qt PRIVATE
    ${CHARTPLOTTER_INCLUDE_DIR}  # include/  -> tile57.h
    ${CHARTPLOTTER_APP_DIR})     # app/      -> enc_root.hpp
  target_link_libraries(chartplotter-qt PRIVATE ${TILE57_LIB} Qt6::Network)
  target_compile_definitions(chartplotter-qt PRIVATE CHARTPLOTTER_WITH_TILE57)
  # Style generation now ships inside libtile57 (tile57_build_style); the viewer
  # calls the C ABI — no separate C++ chartstyle module.
endif()

# QMapLibre links as @rpath/QMapLibre*.framework but carries no absolute path, so
# the binary needs an rpath to find it at runtime. The frameworks install to
# <prefix>/lib, and QMapLibre_DIR is <prefix>/lib/cmake/QMapLibre — derive the lib
# dir from it and bake it into the install rpath (Qt itself resolves via absolute
# Homebrew paths, so only QMapLibre needs this).
get_filename_component(QMAPLIBRE_LIBDIR "${QMapLibre_DIR}/../.." ABSOLUTE)
set_target_properties(chartplotter-qt PROPERTIES
  INSTALL_RPATH "${QMAPLIBRE_LIBDIR}")

install(TARGETS chartplotter-qt RUNTIME DESTINATION bin)
