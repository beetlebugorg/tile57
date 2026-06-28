//! Embedded S-101 portrayal rules. The framework + feature-class Lua files under
//! engine/vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules are @embedFile'd
//! into a generated `rules_registry` module at build time (see embedDir in
//! build.zig). This exposes them to the embedded Lua via a C-ABI accessor so the
//! `require` searcher in lua_shim.c can load rule modules straight from memory —
//! the tile57 binary portrays S-57 cells with no on-disk catalogue.

const std = @import("std");
const registry = @import("rules_registry");

/// Look up an embedded Lua module by its `require` name (the file stem, e.g.
/// "DepthArea" or "S100Scripting"). On a hit, sets out_len and returns the source
/// bytes (static, process-lifetime); returns null if no such module is embedded
/// (the Lua searcher then defers to the next searcher / reports "not found").
///
/// A linear scan over the comptime-constant `entries` — no global state — so it's
/// safe to call concurrently from the parallel baker's worker threads, and each
/// distinct module is only resolved once per Lua state (require caches it).
export fn tg_embedded_lua(name_ptr: [*]const u8, name_len: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const name = name_ptr[0..name_len];
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
