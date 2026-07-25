---
title: Errors & lifecycle
slug: /zig-api/errors-lifecycle
---

# Errors & lifecycle

The cross-cutting conventions the other Zig API pages rely on: how calls report
failure, how long a handle lives and on which thread, warming the process-global
registries, freeing returned bytes, and the package version.

## Errors

The Zig surface uses ordinary Zig **error unions** — a fallible call returns `!T`
and you `try` it (or `catch` to handle). There are no status codes; the C ABI's
`tile57_status` / `tile57_error` are a shim the [C API](../c-api.md) layers on top
of these errors. "Nothing produced" is not an error: a call that finds nothing
returns an empty/`null` value, not a failure.

```zig
var chart = tile57.Chart.openPmtilesPath(io, "US5MD1MC.pmtiles") catch |err| {
    std.log.err("open failed: {s}", .{@errorName(err)});
    return err;
};
defer chart.deinit();
```

## Lifetime + threading

No handle is internally synchronized — use one thread per handle. Each must also
outlive every borrower still holding it: the compositor borrows its charts (their
mmap'd readers + decoded coverage), so it must be `deinit`'d before the charts, and
a path-opened chart mmaps its file, so the file must stay in place while the chart
is open. A `Chart` is released with `chart.deinit()`; a `ComposeSource` with
`src.deinit()`.

## Warmup + freeing bytes

```zig
// Populate the process-global read-only registries (feature catalogue +
// complex-linestyle table) on the calling thread. Call ONCE on your main thread
// before opening or baking charts from worker threads, so concurrent
// bake/render is race-free. Idempotent.
tile57.warmup();

// Free ANY byte buffer the engine returned (tiles, style JSON, PNG bytes, …).
tile57.freeBytes(bytes);
```

## Version

`tile57.version` is the package version string (`"0.3.0"`), matching
`build.zig.zon` and the C ABI's `tile57_version()`. The package requires Zig 0.16.
Pre-1.0: no external consumers yet, so the API is not frozen.
