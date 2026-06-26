//! Offline tile baker CLI (placeholder).
//!
//! Once the decode -> portrayal -> tile pipeline lands (M6) this will read S-57
//! cells and write a .pmtiles archive. For now the MVT encoder (tilegen.mvt) is
//! the working piece; this CLI just reports status.

const std = @import("std");
const tilegen = @import("tilegen");

pub fn main() !void {
    std.debug.print(
        "tilegen bake — not yet implemented.\n" ++
            "Working: tilegen.mvt (MVT v2 encoder/decoder). Next: pmtiles + tile (M4).\n",
        .{},
    );
    _ = tilegen.mvt;
}
