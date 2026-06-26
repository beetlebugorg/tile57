//! tilegen — the Zig chart tile generator.
//!
//! Bottom-up build order (see ../../docs/PLAN.md):
//!   M4: mvt + pmtiles + tile (encode MVT, write PMTiles)   <- in progress
//!   M5: capi (libtilegen.a) for live in-process generation
//!   M6: iso8211 + s57 decode -> embedded-Lua S-101 portrayal
//!
//! The Go project at ../../reference/chartplotter-go is the parity oracle.

const std = @import("std");

pub const mvt = @import("mvt.zig");
pub const gzip = @import("gzip.zig");
pub const pmtiles = @import("pmtiles.zig");

test {
    _ = mvt;
    _ = gzip;
    _ = pmtiles;
    _ = @import("mvt_parity_test.zig");
}
