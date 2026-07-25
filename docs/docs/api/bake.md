---
title: Bake
slug: /c-api/bake
---

# Bake: ENC charts → per-chart archives

Tile production is a two-step composite model. First bake each chart to its
own PMTiles at its compilation scale; the archive embeds the chart's M_COVR
coverage, compilation scale, and identity in its metadata. Then open a
**compositor** over the archives and serve any `(z, x, y)` tile on demand —
the compositor stitches the overlapping charts through an ownership partition,
handling cross-band zoom (see [Compose](./compose.md)).

```c
/* Bake ONE chart (+ its .001.. updates, read from disk) to PMTiles bytes over its
 * native band zoom range. Returned in *out/*out_len (free with tile57_free);
 * NULL/0 when the chart produced no tiles. */
tile57_status tile57_bake_chart_bytes(const char *path, uint8_t **out, size_t *out_len,
                                     tile57_error *err);

/* Bake `n` charts IN PARALLEL across up to `workers` threads (a MEMORY bound —
 * pass a small count). out_bytes[i]/out_lens[i] receive chart i's archive or
 * NULL/0; *out_baked (NULL to ignore) counts the charts that produced bytes. */
tile57_status tile57_bake_charts(const char *const *paths, size_t n, uint32_t workers,
                                uint8_t **out_bytes, size_t *out_lens,
                                size_t *out_baked, tile57_error *err);

/* Walk in_dir for *.000 charts and bake each IN PARALLEL to the SAME relative
 * path under out_dir with a .pmtiles extension (+ an <out>.sha sidecar).
 * INCREMENTAL: a chart whose archive is already at least as new as its whole
 * input (.000 + update chain) is skipped, so a re-run over an unchanged tree
 * bakes nothing — *out_baked counts THIS run, and 0 over a warm cache is
 * success. progress (or NULL) fires per chart, possibly from worker threads;
 * returning false CANCELS the bake (at chart granularity — the charts in flight
 * finish). A cancelled bake is TILE57_OK with *out_baked = what it completed. */
typedef bool (*tile57_bake_progress)(void *ctx, uint32_t done, uint32_t total);
tile57_status tile57_bake_tree(const char *in_dir, const char *out_dir, uint32_t workers,
                               tile57_bake_progress progress, void *progress_ctx,
                               uint32_t *out_baked, tile57_error *err);

/* Read a PMTiles archive's metadata JSON blob (decompressed); NULL/0 when the
 * archive carries none. A per-chart bake embeds the chart's coverage + cscl +
 * date/name under a "coverage" key. */
tile57_status tile57_pmtiles_metadata(const uint8_t *pmtiles, size_t len,
                                      uint8_t **out, size_t *out_len,
                                      tile57_error *err);
```

Every baked feature carries the pick-report properties `class` (object-class
acronym), `cell` (source chart stem), and `s57` (the full S-57 attribute set as a
JSON object) — what [`tile57_chart_query`](./render.md#query-the-features-under-a-point-object-query--pick)
and a host inspector read back.

The `tile57 bake <cell.000 | ENC_ROOT> -o out/` CLI produces this structure
directly: `out/tiles/<STEM>.pmtiles` per chart plus `out/partition.tpart`.

## Read raw S-57 source data

The bake section also reads the source data directly — no handle, no bake — for
a host's import UI:

```c
/* Per-chart metadata of the S-57 data at `path` (one .000, updates applied, or a
 * whole ENC_ROOT) as a JSON array: [{"name","scale","edition","update",
 * "issueDate","agency","bbox"}, ...] — a host's chart-database scan. */
tile57_status tile57_enc_charts(const char *path, uint8_t **out, size_t *out_len,
                               tile57_error *err);

/* Features for comma-separated object-class acronyms (e.g. "DEPARE,DRGARE") as
 * a GeoJSON FeatureCollection: lon/lat geometry, properties = {"class", plus the
 * full S-57 acronym->value attribute map}. NULL/0 when nothing matched. */
tile57_status tile57_enc_features(const char *path, const char *classes,
                                  uint8_t **out, size_t *out_len, tile57_error *err);

/* The same over in-memory base .000 bytes (from a zip member, say). */
tile57_status tile57_enc_features_bytes(const uint8_t *base, size_t len,
                                        const char *classes,
                                        uint8_t **out, size_t *out_len, tile57_error *err);

/* Decode a CATALOG.031 exchange-set catalogue into a JSON array of its CATD
 * entries — file path, longName (chart title), impl (BIN/ASC/TXT), bbox. */
tile57_status tile57_enc_catalog(const uint8_t *catalog_031, size_t len,
                                 uint8_t **out, size_t *out_len, tile57_error *err);
```

The CLI mirrors these as `tile57 cells`, `tile57 features`, and
`tile57 catalog`.
