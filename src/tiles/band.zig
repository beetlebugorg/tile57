//! Navigational-purpose bands: the map from an S-57 cell's compilation scale to
//! the Web-Mercator zoom range it serves. Pure integer math, shared by the baker
//! (which bakes each cell over its band's zooms) and the compositor (which reads
//! the band to decide overscale fill-up), so neither owns the mapping.

/// Native [minzoom, maxzoom] Web-Mercator span for a navigational-purpose band.
pub const ZoomRange = struct { min: u8, max: u8 };

/// Navigational-purpose bands, finest -> coarsest (the order bands must be baked
/// in for best-band dedup).
pub const Band = enum(u8) { berthing = 0, harbor, approach, coastal, general, overview };

/// All bands finest -> coarsest (the bake call order).
pub const bands_fine_to_coarse = [_]Band{ .berthing, .harbor, .approach, .coastal, .general, .overview };

/// Map a compilation-scale denominator (CSCL, 1:N) to its band.
pub fn bandOf(cscl: i32) Band {
    const n: i64 = if (cscl <= 0) 50_000 else cscl;
    if (n <= 8_000) return .berthing;
    if (n <= 32_000) return .harbor;
    if (n <= 130_000) return .approach;
    if (n <= 500_000) return .coastal;
    if (n <= 2_300_000) return .general;
    return .overview;
}

/// Overscale fill-up depth DEFAULT: how many zooms past its native max a band's
/// own cells keep baking (only where nothing finer already emitted). Every
/// extension zoom ~4x that band's tile count over its uncovered footprint
/// (measured: +2 turned a 5.6k-tile approach pass into 41k), so the default is
/// ONE crisp overscale zoom; TILE57_FILLUP_DZ=0..2 overrides per bake
/// (Baker.fillup_dz). 0 never blanks — the client camera stops at the probed
/// data depth and MapLibre stretches one level past it.
pub const FILLUP_DZ: u8 = 1;

/// Absolute fill-up ceiling: extension zooms never exceed this. The fill-up
/// serves the MID-ZOOM seam where a coarse chart is the finest coverage (the
/// blank bay at z12-15); letting fine bands extend too (harbor->z17-18,
/// berthing->z19-20) quadruples the tile count per extra zoom across every
/// harbor footprint for content nobody needs — a district pack ballooned from
/// ~800k to 13M+ planned tiles. A band's NATIVE window is never clamped by this;
/// past its data the camera stops at the probed depth instead.
pub const FILLUP_CEIL: u8 = 15;

/// A band's native zoom span. Adjacent bands overlap by one zoom; best-band dedup
/// resolves the overlap to the finer band.
pub fn bandZooms(band: Band) ZoomRange {
    return switch (band) {
        .berthing => .{ .min = 16, .max = 18 },
        .harbor => .{ .min = 13, .max = 16 },
        .approach => .{ .min = 11, .max = 13 },
        .coastal => .{ .min = 9, .max = 11 },
        .general => .{ .min = 7, .max = 9 },
        .overview => .{ .min = 0, .max = 7 },
    };
}

test "bandOf maps compilation scale to band" {
    const std = @import("std");
    try std.testing.expectEqual(Band.harbor, bandOf(20_000));
    try std.testing.expectEqual(Band.approach, bandOf(50_000));
    try std.testing.expectEqual(Band.overview, bandOf(3_000_000));
    try std.testing.expectEqual(Band.approach, bandOf(0)); // unknown -> 50k default
}

test "bandZooms is finest-to-coarsest with one-zoom overlap" {
    const std = @import("std");
    try std.testing.expectEqual(ZoomRange{ .min = 11, .max = 13 }, bandZooms(.approach));
    try std.testing.expectEqual(ZoomRange{ .min = 9, .max = 11 }, bandZooms(.coastal));
}
