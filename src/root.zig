//! The pure-Zig engine surface: the format, geometry, and encoding packages that
//! need no libc. It is the root of the unit-test build, which stays free of libc
//! and the embedded Lua so `zig build test` links no system C runtime.
//!
//! The S-101 Lua portrayal runner lives in the separate `portray` module, added
//! on top of this surface by `bake_root.zig` (the CLI) and `lib_root.zig`
//! (libtile57.a). See build.zig for how the roots compose.

const std = @import("std");

pub const mvt = @import("tiles").mvt;
pub const mlt = @import("tiles").mlt;
pub const gzip = @import("tiles").gzip;
pub const pmtiles = @import("tiles").pmtiles;
pub const tile = @import("tiles").tile;
pub const iso8211 = @import("s57").iso8211;
pub const s57 = @import("s57");
pub const scene = @import("scene");
pub const s100 = @import("s100");
pub const s101_instr = s100.s101_instr;
pub const s101_adapt = s100.s101_adapt;
pub const catalogue = s100.catalogue;
pub const bake_enc = @import("scene").bake_enc; // banded multi-cell ENC_ROOT -> PMTiles
pub const style = @import("style"); // colortables, line styles, and style.json generation
pub const chartstyle = @import("style").chartstyle; // mariner-driven MapLibre style patching
// capi (the C ABI) lives in lib_root.zig so the test/bake exes stay pure Zig.

test {
    _ = mvt;
    _ = gzip;
    _ = pmtiles;
    _ = tile;
    _ = iso8211;
    _ = s57;
    _ = scene;
    _ = s101_instr;
    _ = s101_adapt;
    _ = catalogue;
    _ = bake_enc;
    _ = style;
    _ = chartstyle;
    _ = @import("mvt_parity_test.zig");
}
