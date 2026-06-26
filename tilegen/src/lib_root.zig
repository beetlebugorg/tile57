//! Static-library root for libtilegen.a (the C++ MapLibre host links this).
//!
//! Kept separate from root.zig so the Zig-linked test/bake executables stay
//! pure Zig (no libc) — only this lib pulls in the C ABI exports and the
//! embedded Lua / shim C sources, which are archived into libtilegen.a and
//! linked by clang++ in the host (avoiding Zig's linker tripping on the
//! system crt's .sframe relocations).

pub const tilegen = @import("root.zig");
pub const capi = @import("capi.zig");

comptime {
    _ = capi; // force the C ABI export fns into the archive
}
