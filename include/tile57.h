/* tile57.h — public C ABI for libtile57.
 *
 * libtile57 is an embeddable nautical-chart tile source. You open a source
 * from in-memory bytes (a PMTiles archive or a raw S-57 ENC cell) and it serves
 * decompressed Mapbox Vector Tiles by (z, x, y). The bytes are produced by the
 * Zig tile generator (the engine/ sources) and consumed by any MVT
 * renderer — in this repo, MapLibre Native via the bundled ChartTileSource
 * adapter (app/chart_tile_source.*), but the ABI itself is renderer-agnostic.
 *
 * Lifetime: a tile57_source must OUTLIVE every renderer/adapter still holding it.
 *   In the MapLibre hosts the source is captured by a long-lived FileSource and
 *   is intentionally never closed before process exit (closing first would be a
 *   use-after-free during Map teardown). Call tile57_source_close only once nothing
 *   can still call tile57_tile_get on it.
 *
 * Threading: a tile57_source is NOT internally synchronized. Do not call into the
 *   same source from multiple threads concurrently (the tile cache is mutated by
 *   tile57_tile_get without a lock). Distinct sources are independent.
 *
 * Memory: tile57_tile_get allocates *out; release it with tile57_tile_free, passing the
 *   same length. All pointers are POD across the seam.
 *
 * The S-101 portrayal self-test / bring-up entry points live in a separate
 * header, tile57_diag.h (developer tooling, not part of the embedding API).
 */
#ifndef TILE57_H
#define TILE57_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library version. tile57_version() returns the string form, e.g. "0.1.0". */
#define TILE57_VERSION_MAJOR 0
#define TILE57_VERSION_MINOR 1
#define TILE57_VERSION_PATCH 0
const char *tile57_version(void);

/* Opaque chart tile source. */
typedef struct tile57_source tile57_source;

/* Source backend / on-disk format. */
typedef enum {
    TILE57_FORMAT_AUTO = 0,     /* sniff: PMTiles first, then S-57 cell */
    TILE57_FORMAT_PMTILES = 1,  /* a PMTiles archive */
    TILE57_FORMAT_S57_CELL = 2, /* a raw S-57 ENC cell (.000); tiles generated live */
} tile57_format;

/* Open a chart tile source from in-memory bytes.
 *   format:    TILE57_FORMAT_AUTO tries PMTiles then S-57; a specific value skips the
 *              sniff (and fails if the bytes are not that format).
 *   rules_dir: S-101 portrayal rules directory, used only for S-57 cells. NULL
 *              selects the built-in default (the TILE57_S101_RULES env var
 *              if set, otherwise the vendored official catalogue).
 * The bytes are copied; the caller may free `data` immediately after this returns.
 * Returns an opaque handle, or NULL on error. Close with tile57_source_close. */
tile57_source *tile57_source_open(const uint8_t *data, size_t len,
                          tile57_format format, const char *rules_dir);

/* One ENC cell for tile57_source_open_cells: the base .000 bytes plus its
 * sequential update files (.001, .002, … in order). `updates`/`update_lens` are
 * parallel arrays of length `update_count`; pass update_count = 0 (and NULL
 * arrays) for a base-only cell. All bytes are copied. */
typedef struct {
    const uint8_t *base;
    size_t base_len;
    const uint8_t *const *updates;
    const size_t *update_lens;
    size_t update_count;
} tile57_cell_input;

/* Open an ENC_ROOT as a multi-cell source: every cell is overlaid when a tile is
 * generated, so a region spanning several cells renders them all. The host scans
 * the directory and reads the files (it owns file IO); this parses + portrays
 * each cell. `rules_dir` is as in tile57_source_open. Returns an opaque
 * handle, or NULL if no cell parses. Close with tile57_source_close. */
tile57_source *tile57_source_open_cells(
    const tile57_cell_input *cells, size_t count, const char *rules_dir);

/* Progress callback for tile57_bake_cells. stage 0 = loading/portraying cells,
 * stage 1 = baking tiles; done/total count cells (stage 0) or tiles (stage 1). */
typedef void (*tile57_bake_progress)(void *user, uint8_t stage, size_t done, size_t total);

/* Bake a whole ENC_ROOT (the same cells as tile57_source_open_cells) into ONE
 * PMTiles archive, zoom-banded per cell by compilation scale, so the result opens
 * cheaply (tile57_source_open with TILE57_FORMAT_PMTILES) instead of holding every
 * cell live. minzoom/maxzoom clamp the per-cell bands (pass 0/24 for no clamp).
 * `progress` may be NULL. On success returns 1 with the archive in *out and
 * *out_len (free with tile57_tile_free); 0 if nothing covered; -1 on error. Like
 * the live open, this parses + portrays every cell, so peak memory tracks the
 * ENC_ROOT size; run it once and cache the archive. */
int tile57_bake_cells(
    const tile57_cell_input *cells, size_t count, const char *rules_dir,
    uint8_t minzoom, uint8_t maxzoom,
    tile57_bake_progress progress, void *user,
    uint8_t **out, size_t *out_len);

/* The resolved backend format (meaningful after a TILE57_FORMAT_AUTO open). */
tile57_format tile57_source_format(tile57_source *src);

/* Release a source and all cached tiles. Must not be called while any renderer
 * may still call tile57_tile_get on it (see lifetime note above). */
void tile57_source_close(tile57_source *src);

/* Min/max zoom the source serves (PMTiles: archive range; cell: 0..18). */
void tile57_source_zoom_range(tile57_source *src, uint8_t *min_z, uint8_t *max_z);

/* Bitmask of the navigational bands present in the source (bit r = band rank r has
 * a cell; 0=berthing/finest .. 5=overview/coarsest). 0 for a single cell / PMTiles.
 * Lets a host build a data-driven band filter listing only the loaded bands. */
uint32_t tile57_source_bands(tile57_source *src);

/* Geographic bounds (west, south, east, north degrees); true when known, so a
 * host can frame the data with its own fit-to-window logic. PMTiles -> archive
 * bounds; cell -> data extent. False for degenerate or near-global extents (the
 * host should then choose its own camera). */
bool tile57_source_bounds(tile57_source *src,
                      double *west, double *south, double *east, double *north);

/* A good initial camera (center lat/lon + zoom) on real data, for when fitting the
 * whole source would zoom out uselessly (a continental ENC_ROOT). Returns true and
 * sets the out-params for a lazy ENC_ROOT source; false otherwise (the caller
 * should use fit-to-bounds). */
bool tile57_source_anchor(tile57_source *src, double *lat, double *lon, double *zoom);

/* Result of tile57_tile_get. */
typedef enum {
    TILE57_TILE_OK = 1,     /* *out / *out_len set (free with tile57_tile_free) */
    TILE57_TILE_EMPTY = 0,  /* tile is valid but has no features */
    TILE57_TILE_ERROR = -1, /* generation / decode failure */
} tile57_tile_status;

/* Fetch tile (z, x, y) as decompressed MVT bytes. Results are cached per source,
 * so re-requesting a tile (as renderers do) is cheap and deterministic. */
tile57_tile_status tile57_tile_get(tile57_source *src, uint8_t z, uint32_t x, uint32_t y,
                           uint8_t **out, size_t *out_len);

/* Free a buffer returned by tile57_tile_get (pass the same length). */
void tile57_tile_free(uint8_t *ptr, size_t len);

/* Drop the in-memory tile cache to bound memory in long-running hosts. Safe to
 * call any time; subsequent tile57_tile_get calls simply regenerate/decode. */
void tile57_source_clear_cache(tile57_source *src);

#ifdef __cplusplus
}
#endif

#endif /* TILE57_H */
