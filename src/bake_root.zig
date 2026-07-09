//! Module root for the tile57 CLI.
//!
//! Same surface as root.zig (the pure-Zig engine) PLUS portray.zig — the
//! embedded-Lua S-101 portrayal — so the baker emits full S-101 styling rather
//! than the classify() fallback. Kept separate from root.zig so the unit-test
//! build (rooted at root.zig) stays pure Zig with no libc / Lua.
//!
//! root.zig and the `portray` module both import the singleton `s57` module, so
//! they share one `s57.Cell` type — bake.zig can hand the same parsed cell to
//! s57.parseCellWithUpdates / scene.generateTile and portray.portrayCell.
//!
//! The embedded Lua (the C shim + vendored Lua sources) and link_libc live on the
//! `portray` module (src/portray/), which this module imports; the lib does the
//! same, so the Lua attachment isn't duplicated across the two.

const root = @import("root.zig");

pub const mvt = root.mvt;
pub const mlt = root.mlt;
pub const gzip = root.gzip;
pub const pmtiles = root.pmtiles;
pub const tile = root.tile;
pub const iso8211 = root.iso8211;
pub const s57 = root.s57;
pub const scene = root.scene;
pub const s101 = root.s101;
pub const s101_instructions = root.s101_instructions;
pub const s101_adapter = root.s101_adapter;
pub const catalogue = root.catalogue;
pub const bake_enc = root.bake_enc;
pub const geo = @import("geo"); // integer geometry: boolean, plane, partition

pub const portray = @import("portray");
