//! The engine's error taxonomy. Every engine entry point that can fail returns one of
//! these; the C ABI maps each to a tile57_status (see capi.zig) and carries
//! describe() as the per-call tile57_error.message. Keep this set, the C
//! tile57_status enum, and capi's statusOf in sync.

pub const Error = error{
    NotFound, // a path or cell was not found
    IoFailed, // a file/directory could not be opened, read, or written
    InvalidCell, // malformed S-57 ENC cell
    InvalidArchive, // malformed PMTiles archive
    InvalidPartition, // malformed or stale ownership partition
    Unsupported, // valid but unsupported input
    RenderFailed, // tile generation or rendering failed
    OutOfMemory, // an allocation failed
};

/// A human-readable description of an engine error — the text a C caller reads
/// from tile57_error.message. Accepts any error (falls back to the error name) so
/// a caller can pass a raw `anyerror` from a catch.
pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.NotFound => "not found",
        error.IoFailed => "I/O error",
        error.InvalidCell => "malformed S-57 cell",
        error.InvalidArchive => "malformed PMTiles archive",
        error.InvalidPartition => "malformed or stale partition",
        error.Unsupported => "unsupported input",
        error.RenderFailed => "render failed",
        error.OutOfMemory => "out of memory",
        // Specific S-57 / ISO 8211 parse failures, propagated as the reason a cell
        // was invalid so a C caller reads the exact cause.
        error.ShortLeader => "ISO 8211 record shorter than its leader",
        error.BadLeader => "malformed ISO 8211 leader",
        error.BadAsciiInt => "malformed ASCII integer field",
        error.BadAsciiDigit => "malformed ASCII digit",
        error.MissingFieldTerminator => "missing ISO 8211 field terminator",
        error.FieldOutOfBounds => "ISO 8211 field runs past the record",
        error.ModifyMissingSpatial => "update references a missing spatial record",
        error.ModifyMissingFeature => "update references a missing feature record",
        error.UnknownRUIN => "unknown record update instruction (RUIN)",
        error.BadFeatureRecord => "malformed feature record",
        error.TileGen => "tile generation failed",
        else => @errorName(e),
    };
}

test "describe covers the taxonomy" {
    const std = @import("std");
    try std.testing.expectEqualStrings("malformed S-57 cell", describe(error.InvalidCell));
    try std.testing.expectEqualStrings("I/O error", describe(error.IoFailed));
    // unknown errors fall back to the name
    try std.testing.expectEqualStrings("SomethingElse", describe(error.SomethingElse));
}
