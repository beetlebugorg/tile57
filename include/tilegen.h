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

#include <stdbool.h>
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

/* Geographic bounds (west, south, east, north degrees), returns true when known,
 * so a host can frame the data with its own fit-to-window logic. PMTiles ->
 * archive bounds; cell -> data extent. False if degenerate / near-global. */
bool tg_bounds(tg_source *src, double *w, double *s, double *e, double *n);

/* Fetch tile (z,x,y) as decompressed MVT bytes.
 * Returns 1 and sets *out / *out_len (free with tg_free) when found,
 * 0 when the tile is absent, or a negative value on error. */
int tg_get_tile(tg_source *src, uint8_t z, uint32_t x, uint32_t y,
                uint8_t **out, size_t *out_len);

void tg_free(uint8_t *ptr, size_t len);

/* Embedded Lua (S-101 portrayal). tg_lua_selftest runs a trivial chunk and
 * returns 42 on success (negative on error); tg_lua_version returns e.g.
 * "Lua 5.4". Proves the interpreter is embedded and linked. */
long tg_lua_selftest(void);
const char *tg_lua_version(void);

/* Load the S-101 framework (S100Scripting/PortrayalModel/PortrayalAPI/Default/
 * main) from a Rules directory in embedded Lua. Returns 0 on success, negative
 * on error (diagnostics to stderr). Validates Lua 5.4 compatibility. */
int tg_lua_check_rules(const char *dir);

/* Run the S-101 framework with stub Host callbacks + empty feature set, proving
 * it executes (not just loads) in embedded Lua. Returns 0 on success. */
int tg_lua_run_framework(const char *dir);

/* Run the real DepthArea rule against a synthetic feature with a minimal
 * hardcoded catalogue; prints the emitted S-101 instruction stream to stderr.
 * Returns 0 on success. Proof-of-portrayal before the full Host binding. */
int tg_lua_portray_demo(const char *dir);

#ifdef __cplusplus
}
#endif

#endif /* TILEGEN_H */
