//! Module root for the chartplotter-bake CLI.
//!
//! Same surface as root.zig (the pure-Zig engine) PLUS portray.zig — the
//! embedded-Lua S-101 portrayal — so the baker emits full S-101 styling rather
//! than the classify() fallback. Kept separate from root.zig so the unit-test
//! build (rooted at root.zig) stays pure Zig with no libc / Lua.
//!
//! root.zig and portray.zig are imported relatively here, so both — and the
//! s57.zig each pulls in — belong to this one module instance and share a single
//! `s57.Cell` type. That lets bake.zig hand the same parsed cell to both
//! s57.parseCellWithUpdates / s57_mvt.generateTile and portray.portrayCell.
//!
//! The C/Lua sources (csrc/lua_shim.c + vendored Lua) and link_libc are attached
//! to this module in build.zig, exactly as for libtile57.a (lib_root.zig).

const root = @import("root.zig");

pub const mvt = root.mvt;
pub const gzip = root.gzip;
pub const pmtiles = root.pmtiles;
pub const tile = root.tile;
pub const iso8211 = root.iso8211;
pub const s57 = root.s57;
pub const s57_mvt = root.s57_mvt;
pub const s101_instr = root.s101_instr;
pub const s101_adapt = root.s101_adapt;
pub const catalogue = root.catalogue;
pub const bake_enc = root.bake_enc;

pub const portray = @import("portray.zig");
