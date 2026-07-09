//! style_wasm — a tiny `wasm32-freestanding` entry point around the pure-Zig
//! `chartstyle.buildStyle`, so a browser / Node front-end can turn S-52 "mariner
//! settings" into a concrete MapLibre style.json entirely client-side.
//!
//! The MapLibre style *template* and the S-52 *colortables* are @embedFile'd at
//! build time (generated once by `tile57 style` / `tile57 assets`; see
//! bindings/scripts/gen-style.sh), so the wasm needs NO external file inputs.
//! The JS host only passes the mariner settings as a small JSON blob.
//!
//! ABI — every pointer is a byte OFFSET (usize) into the wasm linear memory, so
//! the JS side deals only in plain numbers:
//!   style_alloc(len)            -> ptr      scratch buffer (0 = OOM); JS writes settings JSON here
//!   style_free(ptr, len)        -> void     release a buffer (input scratch OR a result)
//!   style_build(ptr,len,now)    -> 1|0      build; on success stashes result ptr/len
//!   style_result_ptr()          -> ptr      last result's bytes (UTF-8 style.json)
//!   style_result_len()          -> len      last result's length
//!   style_template_ptr/_len()              the embedded base template (debug/parity)
//!
//! Single-threaded: `style_result_*` reflect the most recent `style_build`. The
//! result is owned by the wasm allocator — the JS side copies it out, then calls
//! style_free(result_ptr, result_len).

const std = @import("std");
const style = @import("style");
const chartstyle = @import("style").chartstyle;
const settings = @import("settings");

// Base MapLibre style template + S-52 colortables, embedded at build time.
const template_json = @embedFile("template_json");
const colortables_json = @embedFile("colortables_json");

// std.heap.wasm_allocator: the freestanding-wasm allocator that grows linear
// memory via @wasmMemoryGrow. Thread-unsafe, which is fine for this module.
const gpa = std.heap.wasm_allocator;

var g_result_ptr: usize = 0;
var g_result_len: usize = 0;

/// Allocate `len` bytes in wasm memory; returns the byte offset (0 on OOM). The
/// JS side writes the settings JSON into this buffer, then frees it after building.
export fn style_alloc(len: usize) usize {
    if (len == 0) return 0;
    const buf = gpa.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

/// Free a buffer previously returned by style_alloc or held at style_result_ptr.
export fn style_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    gpa.free(p[0..len]);
}

/// The embedded base template offset/length (so a host can inspect / diff it).
export fn style_template_ptr() usize {
    return @intFromPtr(template_json.ptr);
}
export fn style_template_len() usize {
    return template_json.len;
}

/// The offset/length of the most recent successful style_build.
export fn style_result_ptr() usize {
    return g_result_ptr;
}
export fn style_result_len() usize {
    return g_result_len;
}

/// Build a MapLibre style.json from a mariner-settings JSON blob.
///   settings_ptr/len : UTF-8 JSON object (see bindings/shared/settings.zig for
///                      the schema; any missing field falls back to its default).
///   now_unix         : current time in Unix epoch SECONDS (passed as f64 so JS
///                      sends a plain number, not a BigInt). Used only to resolve
///                      "today" when the mariner hasn't pinned a date_view.
/// Returns 1 on success (then read style_result_ptr/_len), 0 on failure.
export fn style_build(settings_ptr: usize, settings_len: usize, now_unix: f64) i32 {
    // Arena holds the parsed settings (incl. any date_view string) alive across
    // the whole buildStyle call; the result itself is gpa-owned, separately.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const settings_bytes: []const u8 = if (settings_len == 0) "" else blk: {
        const p: [*]const u8 = @ptrFromInt(settings_ptr);
        break :blk p[0..settings_len];
    };
    const m = settings.parse(arena.allocator(), settings_bytes);
    const now: i64 = @intFromFloat(now_unix);
    const out = style.buildFromTemplate(gpa, template_json, &m, colortables_json, null, now) catch return 0;
    g_result_ptr = @intFromPtr(out.ptr);
    g_result_len = out.len;
    return 1;
}
