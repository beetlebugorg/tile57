//! Embedded S-101 portrayal rules. The framework + feature-class Lua files under
//! engine/vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules are @embedFile'd
//! into a generated `rules_registry` module at build time (see embedDir in
//! build.zig). This exposes them to the embedded Lua via a C-ABI accessor so the
//! `require` searcher in lua_shim.c can load rule modules straight from memory —
//! the tile57 binary portrays S-57 cells with no on-disk catalogue.
//!
//! Engine-owned corrections (see `overrides` below) shadow a rule's embedded source
//! by name WITHOUT editing the vendored submodule, which is kept pristine.

const std = @import("std");
const registry = @import("rules_registry");

// --- Engine-owned corrections to the vendored IHO catalogue ------------------------------
// The catalogue is an upstream `iho-ohi` submodule we do NOT patch. To fix a genuine upstream
// rule bug we instead COMPTIME-replace the offending text in the rule's embedded source and
// shadow the vendored entry by name below, so the fix ships in the binary, the submodule stays
// pristine, and it SELF-HEALS: if the target text ever disappears upstream (they fix it, or
// restructure the file), the replace is a no-op and we ship the vendored bytes verbatim.
//
// Correction 1 — TidalStreamFloodEbb.lua:20: the ebb branch reads `feature..orientationValue`
// (a stray `..`). Lua parses it as `feature .. orientationValue`, concatenating the feature
// TABLE -> "attempt to concatenate a table value" -> the rule errors -> Default() paints
// QUESMRK1 on every ebb-category (CAT_TS=2) tidal stream. The flood/idle branches correctly
// use `feature.orientationValue` (lines 8, 32). Replace `..` with `.`.

fn origBytes(comptime name: []const u8) []const u8 {
    for (registry.entries) |e| if (std.mem.eql(u8, e.name, name)) return e.bytes;
    @compileError("override target not embedded: " ++ name);
}

fn correctedLen(comptime orig: []const u8, comptime from: []const u8, comptime to: []const u8) usize {
    @setEvalBranchQuota(1_000_000); // scanning a multi-KB rule source blows the default 1000
    return orig.len - std.mem.count(u8, orig, from) * (from.len - to.len);
}

/// A comptime copy of `orig` with every `from` replaced by `to`, returned BY VALUE so it
/// materializes as static const data. A no-op copy when `from` is absent — self-heals if
/// upstream fixes the typo (or restructures the file so the target text is gone).
fn correctedSource(comptime orig: []const u8, comptime from: []const u8, comptime to: []const u8) [correctedLen(orig, from, to)]u8 {
    @setEvalBranchQuota(1_000_000);
    var buf: [correctedLen(orig, from, to)]u8 = undefined;
    _ = std.mem.replace(u8, orig, from, to, &buf);
    return buf;
}

const tidal_fixed = correctedSource(origBytes("TidalStreamFloodEbb"), "feature..orientationValue", "feature.orientationValue");

const Override = struct { name: []const u8, bytes: []const u8 };
const overrides = [_]Override{
    .{ .name = "TidalStreamFloodEbb", .bytes = &tidal_fixed },
};

/// Look up an embedded Lua module by its `require` name (the file stem, e.g.
/// "DepthArea" or "S100Scripting"). Engine `overrides` take precedence over the
/// vendored registry. On a hit, sets out_len and returns the source bytes (static,
/// process-lifetime); returns null if no such module is embedded (the Lua searcher
/// then defers to the next searcher / reports "not found").
///
/// A linear scan over comptime-constant tables — no global state — so it's safe to
/// call concurrently from the parallel baker's worker threads, and each distinct
/// module is only resolved once per Lua state (require caches it).
export fn tg_embedded_lua(name_ptr: [*]const u8, name_len: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const name = name_ptr[0..name_len];
    for (overrides) |o| {
        if (std.mem.eql(u8, o.name, name)) {
            out_len.* = o.bytes.len;
            return o.bytes.ptr;
        }
    }
    for (registry.entries) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            out_len.* = e.bytes.len;
            return e.bytes.ptr;
        }
    }
    return null;
}

/// Count of embedded rule modules (diagnostics / sanity checks).
export fn tg_embedded_lua_count() callconv(.c) usize {
    return registry.entries.len;
}

test "TidalStreamFloodEbb override removes the `feature..orientationValue` typo" {
    // The vendored source carries the stray `..`; the shipped (override) source must not.
    const orig = comptime origBytes("TidalStreamFloodEbb");
    try std.testing.expect(std.mem.indexOf(u8, orig, "feature..orientationValue") != null);
    try std.testing.expect(std.mem.indexOf(u8, &tidal_fixed, "feature..orientationValue") == null);
    try std.testing.expect(std.mem.indexOf(u8, &tidal_fixed, "feature.orientationValue") != null);
}
