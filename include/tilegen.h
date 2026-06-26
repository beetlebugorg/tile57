/* tilegen — C ABI for the Zig chart tile generator (libtilegen.a).
 *
 * The C++ MapLibre host links this and calls it from a custom mbgl::FileSource
 * to obtain vector-tile bytes. For M5 a source is backed by a PMTiles archive
 * (host supplies the bytes); at M6 a second constructor will generate tiles
 * live from S-57 cells with the same calls.
 *
 * Memory: tg_get_tile allocates the returned buffer; free it with tg_free
 * (pass the same length). All pointers are POD across the seam.
 */
#ifndef TILEGEN_H
#define TILEGEN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tg_source tg_source;

/* Open a PMTiles archive from in-memory bytes (the host owns file IO).
 * Returns an opaque handle, or NULL on error. Close with tg_close. */
tg_source *tg_open_bytes(const uint8_t *data, size_t len);

/* Open a raw S-57 ENC cell (.000); tiles are generated live on demand.
 * Returns an opaque handle, or NULL on error. */
tg_source *tg_open_cell_bytes(const uint8_t *data, size_t len);

void tg_close(tg_source *src);

uint8_t tg_min_zoom(tg_source *src);
uint8_t tg_max_zoom(tg_source *src);

/* Fetch tile (z,x,y) as decompressed MVT bytes.
 * Returns 1 and sets *out / *out_len (free with tg_free) when found,
 * 0 when the tile is absent, or a negative value on error. */
int tg_get_tile(tg_source *src, uint8_t z, uint32_t x, uint32_t y,
                uint8_t **out, size_t *out_len);

void tg_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* TILEGEN_H */
