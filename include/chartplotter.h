/* chartplotter.h — public C API for libchartplotter, an embeddable nautical
 * chart widget.
 *
 * libchartplotter opens a window and draws S-52 charts with MapLibre Native,
 * sourcing vector tiles from libtile57 (the S-57 tile generator). It can also
 * render a chart to a PNG offscreen. A chart path is a PMTiles archive, a raw
 * S-57 .000 cell, or an ENC_ROOT directory (all cells + their updates).
 *
 * This is the high-level "widget" API. The lower-level tile-source ABI (open a
 * source, pull MVT tiles by z/x/y) is libtile57 — see include/tile57.h.
 *
 * Threading: call into a chartplotter_view only from the thread that created it
 * (it owns a window + run loop). chartplotter_view_run blocks until the window
 * closes.
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

/* An interactive chart window. */
typedef struct chartplotter_view chartplotter_view;

typedef struct {
    int width;            /* initial window size; 0 -> a sensible default */
    int height;
    const char *title;    /* window title; NULL -> a default */
    const char *style_path; /* MapLibre style JSON (required) */
    const char *rules_dir;  /* S-101 rules dir; NULL -> auto-resolve */
    double lat;           /* initial camera centre + zoom; if zoom <= 0, the */
    double lon;           /* view fits the chart's data bounds instead. */
    double zoom;
} chartplotter_view_options;

/* Open a window showing `chart_path` (PMTiles / S-57 cell / ENC_ROOT) styled by
 * opts->style_path. Returns NULL on error, or if the library was built without
 * window support (headless-only build). Free with chartplotter_view_close. */
chartplotter_view *chartplotter_view_open(const char *chart_path,
                                          const chartplotter_view_options *opts);

/* Run the interactive event/render loop. Blocks until the window is closed. */
void chartplotter_view_run(chartplotter_view *view);

/* Close the window and release the view. */
void chartplotter_view_close(chartplotter_view *view);

#ifdef __cplusplus
}
#endif

#endif /* CHARTPLOTTER_H */
