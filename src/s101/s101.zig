//! s101 — the S-101 portrayal model: the distilled S-101 catalogue plus the
//! S-57 -> S-101 adaptation and instruction layers. Pure Zig (no libc/Lua); the
//! Lua portrayal *runner* lives in the separate `portray` module. The embedded
//! catalogue / S-57-code JSON is attached in build.zig via addCatalogueJson.
//!
//!   * catalogue    — the distilled S-101 feature/attribute catalogue
//!   * adapter      — S-57 cell features -> S-101 feature/attribute records
//!   * instructions — the portrayal instruction stream (points, lines, text)

pub const catalogue = @import("catalogue.zig");
pub const adapter = @import("adapter.zig");
pub const instructions = @import("instructions.zig");

test {
    _ = catalogue;
    _ = adapter;
    _ = instructions;
}
