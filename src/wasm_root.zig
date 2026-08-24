//! Wasm reactor root for the full engine (`zig build wasm-engine`).
//!
//! The same surface as libtile57.a — the whole C ABI, with the embedded Lua
//! portrayal engine — compiled to one wasm32-wasi module. A JS host (browser
//! page or node) supplies the WASI imports and calls the tile57_* exports, so
//! a chartplotter can bake charts and serve tiles fully client-side.
//!
//! The two helpers below exist only on this target. The C ABI's byte-buffer
//! calls allocate their OUTPUTS (released with tile57_free), but a C caller
//! provides its own INPUT buffers — and a JS host has no allocator inside the
//! wasm linear memory. These give it one.

const std = @import("std");

pub const lib = @import("lib_root.zig");

comptime {
    _ = lib; // force the C ABI exports into the wasm export table
}

/// Allocate `len` bytes of wasm linear memory for an input buffer (chart
/// bytes, settings JSON, ...). The JS host writes the bytes at the returned
/// offset, passes it to a tile57_* call, then releases it with
/// tile57_wasm_free. Returns 0 when out of memory.
export fn tile57_wasm_alloc(len: usize) ?[*]u8 {
    const p = std.c.malloc(len) orelse return null;
    return @ptrCast(p);
}

/// Release a buffer from tile57_wasm_alloc. Only for those buffers — engine
/// outputs still go through tile57_free.
export fn tile57_wasm_free(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}
