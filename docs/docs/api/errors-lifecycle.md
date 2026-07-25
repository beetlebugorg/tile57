---
title: Errors & lifecycle
slug: /c-api/errors-lifecycle
---

# Errors & lifecycle

The cross-cutting conventions every other C API page relies on: how calls report
failure, how long a handle lives and on which thread, warming the process-global
registries, freeing returned buffers, and the ABI's version guarantee.

## Errors

Every call that can fail returns a `tile57_status` — `TILE57_OK` (0) or a coarse
cause — and takes an optional caller-owned `tile57_error*` it fills with the
status plus a specific message on failure (a stack local is fine; nothing to
free). Results come back through out-parameters, which are always defined on
return: the result on `TILE57_OK`, `NULL`/0 otherwise. "Nothing produced" is
NOT a failure — a call that finds nothing returns `TILE57_OK` with a
`NULL`/zero out.

```c
typedef enum {
    TILE57_OK = 0,          /* success */
    TILE57_ERR_BADARG,      /* a NULL or out-of-range argument */
    TILE57_ERR_IO,          /* a file/directory could not be opened, read, or written */
    TILE57_ERR_PARSE,       /* malformed input (S-57 chart, PMTiles, partition, JSON) */
    TILE57_ERR_NOMEM,       /* an allocation failed */
    TILE57_ERR_UNSUPPORTED, /* valid but unusable input */
    TILE57_ERR_RENDER,      /* tile generation or rendering failed */
    TILE57_ERR_INTERNAL,    /* an unexpected engine failure */
} tile57_status;

const char *tile57_status_str(tile57_status status);  /* static strerror-style text */

#define TILE57_ERROR_MSG_MAX 256
typedef struct {
    tile57_status status;
    char message[TILE57_ERROR_MSG_MAX];  /* NUL-terminated; "" when no detail */
} tile57_error;
```

```c
tile57_chart *chart = NULL;
tile57_error err;
if (tile57_chart_open("US5MD1MC.pmtiles", &chart, &err) != TILE57_OK) {
    fprintf(stderr, "open failed: %s\n", err.message);  /* "path: reason" */
}
```

## Lifetime + threading

:::warning Lifetime + threading
No handle is internally synchronized — use one thread per handle. Each must
also outlive every borrower still holding it: a compositor borrows its charts
(close the compositor first, then the charts), and a path-opened chart mmaps
its file, so the file must stay in place while the chart is open. Calls that
return bytes allocate `*out`; free it with `tile57_free(ptr)`. Input
bytes are copied, so the caller may free them right after the call.
:::

## Warmup + free

```c
/* Populate the process-global read-only registries (feature catalogue +
 * complex-linestyle table) on the calling thread. Call ONCE on your main thread
 * before opening or baking charts from worker threads, so concurrent bake/render is
 * race-free. Idempotent. */
void tile57_warmup(void);

/* Free ANY buffer the engine returned (tiles, style JSON, the scamin array,
 * colortables, …) — length-prefixed, so the pointer is all it needs. */
void tile57_free(void *ptr);
```

## Diagnostics header

[`include/tile57_diag.h`](../../../include/tile57_diag.h) (`tile57_diag_*`) exposes
the embedded-Lua / S-101 framework bring-up self-tests — developer tooling, not
part of the embedding API.

## Versioning

Pre-1.0 (`0.3.0`). No external consumers yet, so the ABI is not frozen.
