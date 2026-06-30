//! Static-library root for libtile57.a (the C++ MapLibre host links this).
//!
//! Kept separate from root.zig so the Zig-linked test/bake executables stay
//! pure Zig (no libc) — only this lib pulls in the C ABI exports and the
//! embedded Lua / shim C sources, which are archived into libtile57.a and
//! linked by clang++ in the host (avoiding Zig's linker tripping on the
//! system crt's .sframe relocations).

// The full engine surface (root.zig + portray) via the named "engine" module, NOT a
// root.zig file-import: bundle (below) pulls in engine_full, which owns root.zig, so a
// second file-import here would double-claim the file (one-module-per-file per artifact).
pub const engine = @import("engine");
pub const api = @import("tile57.zig"); // the public Zig API (Source/bake/style)
pub const capi = @import("capi.zig");
pub const portray = @import("portray");
pub const catalogue = @import("s100").catalogue;
pub const bundle = @import("bundle"); // the chart-bundle pipeline (bake_bundle), for the C ABI

comptime {
    _ = api; // compile-check the public Zig root in the libc build
    _ = capi; // force the C ABI export fns into the archive
    _ = portray; // force the tgp_* accessors into the archive
    _ = catalogue; // force the tgc_* accessors into the archive
    _ = bundle; // compile-check the bundle pipeline in the host/libc build (C ABI next)
}
