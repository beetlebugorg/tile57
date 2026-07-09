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
pub const api = @import("tile57.zig"); // the public Zig API (Chart/bake/style)
pub const capi = @import("capi.zig");
pub const portray = @import("portray");
pub const catalogue = @import("s101").catalogue;
pub const bundle = @import("bundle"); // the chart-bundle pipeline (tile57_bake_bundle rides on capi)

comptime {
    _ = api; // compile-check the public Zig root in the libc build
    _ = capi; // force the C ABI export fns into the archive (incl. tile57_bake_bundle -> bundle)
    _ = portray; // force the tgp_* accessors into the archive
    _ = catalogue; // force the tgc_* accessors into the archive
}
