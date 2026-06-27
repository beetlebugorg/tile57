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

qt_add_executable(chartplotter-qt main.cpp)
target_link_libraries(chartplotter-qt PRIVATE QMapLibre::Widgets)

# QMapLibre links as @rpath/QMapLibre*.framework but carries no absolute path, so
# the binary needs an rpath to find it at runtime. The frameworks install to
# <prefix>/lib, and QMapLibre_DIR is <prefix>/lib/cmake/QMapLibre — derive the lib
# dir from it and bake it into the install rpath (Qt itself resolves via absolute
# Homebrew paths, so only QMapLibre needs this).
get_filename_component(QMAPLIBRE_LIBDIR "${QMapLibre_DIR}/../.." ABSOLUTE)
set_target_properties(chartplotter-qt PROPERTIES
  INSTALL_RPATH "${QMAPLIBRE_LIBDIR}")

install(TARGETS chartplotter-qt RUNTIME DESTINATION bin)
