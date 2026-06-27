//! engine — the Zig chart tile generator.
//!
//! Bottom-up build order (see ../../docs/docs/architecture.md):
//!   M4: mvt + pmtiles + tile (encode MVT, write PMTiles)   <- in progress
//!   M5: capi (libtile57.a) for live in-process generation
//!   M6: iso8211 + s57 decode -> embedded-Lua S-101 portrayal
//!
//! The Go project at ../../reference/chartplotter-go is the parity oracle.

const std = @import("std");

pub const mvt = @import("mvt.zig");
pub const gzip = @import("gzip.zig");
pub const pmtiles = @import("pmtiles.zig");
pub const tile = @import("tile.zig");
pub const iso8211 = @import("iso8211.zig");
pub const s57 = @import("s57.zig");
pub const s57_mvt = @import("s57_mvt.zig");
pub const s101_instr = @import("s101_instr.zig");
pub const s101_adapt = @import("s101_adapt.zig");
pub const catalogue = @import("catalogue.zig");
pub const bake_enc = @import("bake_enc.zig"); // banded multi-cell ENC_ROOT -> PMTiles
// capi (the C ABI) lives in lib_root.zig so the test/bake exes stay pure Zig.

test {
    _ = mvt;
    _ = gzip;
    _ = pmtiles;
    _ = tile;
    _ = iso8211;
    _ = s57;
    _ = s57_mvt;
    _ = s101_instr;
    _ = s101_adapt;
    _ = catalogue;
    _ = bake_enc;
    _ = @import("mvt_parity_test.zig");
}
