/* chartplotter.h — public C API for libchartplotter, the headless chart
 * renderer.
 *
 * libchartplotter renders an S-52 chart to a PNG offscreen with MapLibre Native,
 * sourcing vector tiles from libtile57 (the S-57 tile generator). A chart path is
 * a PMTiles archive, a raw S-57 .000 cell, or an ENC_ROOT directory (all cells +
 * their updates).
 *
 * The interactive window is a separate Qt6 app (chartplotter-qt, app/qt). The
 * lower-level tile-source ABI (open a source, pull MVT tiles by z/x/y) is
 * libtile57 — see include/tile57.h.
 */
#ifndef CHARTPLOTTER_H
#define CHARTPLOTTER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CHARTPLOTTER_VERSION_MAJOR 0
#define CHARTPLOTTER_VERSION_MINOR 1
#define CHARTPLOTTER_VERSION_PATCH 0
const char *chartplotter_version(void); /* "0.1.0" */

/* Render a chart to a PNG offscreen — no window (headless EGL / Metal). The
 * `rules_dir` is the S-101 portrayal rules directory (NULL auto-resolves it).
 * Returns 0 on success, non-zero on error. */
int chartplotter_render_png(const char *chart_path, const char *style_path,
                            const char *rules_dir,
                            double lat, double lon, double zoom,
                            uint32_t width, uint32_t height, float pixel_ratio,
                            const char *out_png);

#ifdef __cplusplus
}
#endif

#endif /* CHARTPLOTTER_H */
