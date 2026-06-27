//! s100 — S-100 portrayal model. The distilled S-101 catalogue plus the
//! S-57 → S-101 adaptation and instruction layers. Pure Zig (no libc/Lua);
//! the Lua portrayal *runner* lives in engine's portray.zig. Mirrors the Go
//! oracle's `pkg/s100/*`. Built as a standalone Zig module; the embedded
//! catalogue/s57-codes JSON is attached in build.zig via addCatalogueJson.
//! See ../../../specs/bundle-bake.md.

pub const catalogue = @import("catalogue.zig");
pub const s101_adapt = @import("s101_adapt.zig");
pub const s101_instr = @import("s101_instr.zig");

test {
    _ = catalogue;
    _ = s101_adapt;
    _ = s101_instr;
}
