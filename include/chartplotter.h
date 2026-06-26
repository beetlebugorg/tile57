/* chartplotter.h — public C ABI for libchartplotter.
 *
 * libchartplotter is an embeddable nautical-chart tile source. You open a source
 * from in-memory bytes (a PMTiles archive or a raw S-57 ENC cell) and it serves
 * decompressed Mapbox Vector Tiles by (z, x, y). The bytes are produced by the
 * Zig tile generator (the "tilegen" implementation) and consumed by any MVT
 * renderer — in this repo, MapLibre Native via the bundled ChartTileSource
 * adapter (app/chart_tile_source.*), but the ABI itself is renderer-agnostic.
 *
 * Lifetime: a chartplotter_source must OUTLIVE every renderer/adapter still holding it.
 *   In the MapLibre hosts the source is captured by a long-lived FileSource and
 *   is intentionally never closed before process exit (closing first would be a
 *   use-after-free during Map teardown). Call chartplotter_source_close only once nothing
 *   can still call chartplotter_tile_get on it.
 *
 * Threading: a chartplotter_source is NOT internally synchronized. Do not call into the
 *   same source from multiple threads concurrently (the tile cache is mutated by
 *   chartplotter_tile_get without a lock). Distinct sources are independent.
 *
 * Memory: chartplotter_tile_get allocates *out; release it with chartplotter_tile_free, passing the
 *   same length. All pointers are POD across the seam.
 *
 * The S-101 portrayal self-test / bring-up entry points live in a separate
 * header, chartplotter_diag.h (developer tooling, not part of the embedding API).
 */
#ifndef CHARTPLOTTER_H
#define CHARTPLOTTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library version. chartplotter_version() returns the string form, e.g. "0.1.0". */
#define CHARTPLOTTER_VERSION_MAJOR 0
#define CHARTPLOTTER_VERSION_MINOR 1
#define CHARTPLOTTER_VERSION_PATCH 0
const char *chartplotter_version(void);

/* Opaque chart tile source. */
typedef struct chartplotter_source chartplotter_source;

/* Source backend / on-disk format. */
typedef enum {
    CHARTPLOTTER_FORMAT_AUTO = 0,     /* sniff: PMTiles first, then S-57 cell */
    CHARTPLOTTER_FORMAT_PMTILES = 1,  /* a PMTiles archive */
    CHARTPLOTTER_FORMAT_S57_CELL = 2, /* a raw S-57 ENC cell (.000); tiles generated live */
} chartplotter_format;

/* Open a chart tile source from in-memory bytes.
 *   format:    CHARTPLOTTER_FORMAT_AUTO tries PMTiles then S-57; a specific value skips the
 *              sniff (and fails if the bytes are not that format).
 *   rules_dir: S-101 portrayal rules directory, used only for S-57 cells. NULL
 *              selects the built-in default (the CHARTPLOTTER_S101_RULES env var
 *              if set, otherwise the vendored official catalogue).
 * The bytes are copied; the caller may free `data` immediately after this returns.
 * Returns an opaque handle, or NULL on error. Close with chartplotter_source_close. */
chartplotter_source *chartplotter_source_open(const uint8_t *data, size_t len,
                          chartplotter_format format, const char *rules_dir);

/* The resolved backend format (meaningful after a CHARTPLOTTER_FORMAT_AUTO open). */
chartplotter_format chartplotter_source_format(chartplotter_source *src);

/* Release a source and all cached tiles. Must not be called while any renderer
 * may still call chartplotter_tile_get on it (see lifetime note above). */
void chartplotter_source_close(chartplotter_source *src);

/* Min/max zoom the source serves (PMTiles: archive range; cell: 0..18). */
void chartplotter_source_zoom_range(chartplotter_source *src, uint8_t *min_z, uint8_t *max_z);

/* Geographic bounds (west, south, east, north degrees); true when known, so a
 * host can frame the data with its own fit-to-window logic. PMTiles -> archive
 * bounds; cell -> data extent. False for degenerate or near-global extents (the
 * host should then choose its own camera). */
bool chartplotter_source_bounds(chartplotter_source *src,
                      double *west, double *south, double *east, double *north);

/* Result of chartplotter_tile_get. */
typedef enum {
    CHARTPLOTTER_TILE_OK = 1,     /* *out / *out_len set (free with chartplotter_tile_free) */
    CHARTPLOTTER_TILE_EMPTY = 0,  /* tile is valid but has no features */
    CHARTPLOTTER_TILE_ERROR = -1, /* generation / decode failure */
} chartplotter_tile_status;

/* Fetch tile (z, x, y) as decompressed MVT bytes. Results are cached per source,
 * so re-requesting a tile (as renderers do) is cheap and deterministic. */
chartplotter_tile_status chartplotter_tile_get(chartplotter_source *src, uint8_t z, uint32_t x, uint32_t y,
                           uint8_t **out, size_t *out_len);

/* Free a buffer returned by chartplotter_tile_get (pass the same length). */
void chartplotter_tile_free(uint8_t *ptr, size_t len);

/* Drop the in-memory tile cache to bound memory in long-running hosts. Safe to
 * call any time; subsequent chartplotter_tile_get calls simply regenerate/decode. */
void chartplotter_source_clear_cache(chartplotter_source *src);

#ifdef __cplusplus
}
#endif

#endif /* CHARTPLOTTER_H */
