//! Wasm reactor root for the full engine (`zig build wasm-engine`).
//!
//! The same surface as libtile57.a - the whole C ABI, with the embedded Lua
//! portrayal engine - compiled to one wasm32-wasi module. A JS host (browser
//! page or node) supplies the WASI imports and calls the tile57_* exports, so
//! a chartplotter can bake charts and serve tiles fully client-side.
//!
//! The two helpers below exist only on this target. The C ABI's byte-buffer
//! calls allocate their OUTPUTS (released with tile57_free), but a C caller
//! provides its own INPUT buffers - and a JS host has no allocator inside the
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

/// Release a buffer from tile57_wasm_alloc. Only for those buffers - engine
/// outputs still go through tile57_free.
export fn tile57_wasm_free(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}

// ---- the cursor pick, flattened for a JS host -----------------------------
//
// tile57_chart_query / tile57_compose_query report through a C callback, and
// a JS host cannot provide one (a JS function is not a wasm funcref). The
// callback must live INSIDE the module, so this export runs the query with an
// internal accumulator and returns the features as ONE JSON array:
//     [{"cls":"LIGHTS","s57":{...},"chart":"US5BDRAB"}, ...]
// Release *out with tile57_wasm_free. The C exports are extern-declared here
// (same module, resolved at link) to keep this file POD-only.

const QueryCb = extern struct {
    ctx: ?*anyopaque,
    feature: ?*const fn (?*anyopaque, [*c]const u8, usize, [*c]const u8, usize, [*c]const u8, usize) callconv(.c) void,
};
extern fn tile57_chart_query(chart: ?*anyopaque, lon: f64, lat: f64, zoom: f64, cb: *const QueryCb, err: ?*anyopaque) c_int;
extern fn tile57_compose_query(c: ?*anyopaque, lon: f64, lat: f64, zoom: f64, cb: *const QueryCb, err: ?*anyopaque) c_int;

const QueryAcc = struct {
    list: std.ArrayList(u8) = .empty,
    first: bool = true,
    failed: bool = false,
};

fn accAppend(acc: *QueryAcc, bytes: []const u8) void {
    acc.list.appendSlice(std.heap.c_allocator, bytes) catch {
        acc.failed = true;
    };
}

// Escape a plain string (a class acronym, a chart name) into JSON.
fn accAppendJsonString(acc: *QueryAcc, s: []const u8) void {
    accAppend(acc, "\"");
    for (s) |ch| switch (ch) {
        '"' => accAppend(acc, "\\\""),
        '\\' => accAppend(acc, "\\\\"),
        0x00...0x1f => {
            var buf: [8]u8 = undefined;
            accAppend(acc, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch "?");
        },
        else => accAppend(acc, &.{ch}),
    };
    accAppend(acc, "\"");
}

fn onQueryFeature(ctx: ?*anyopaque, cls: [*c]const u8, cls_len: usize, s57: [*c]const u8, s57_len: usize, chart: [*c]const u8, chart_len: usize) callconv(.c) void {
    const acc: *QueryAcc = @ptrCast(@alignCast(ctx orelse return));
    if (acc.failed) return;
    if (!acc.first) accAppend(acc, ",");
    acc.first = false;
    accAppend(acc, "{\"cls\":");
    accAppendJsonString(acc, if (cls) |p| p[0..cls_len] else "");
    // The attribute payload is already JSON - embed it raw (empty -> {}).
    accAppend(acc, ",\"s57\":");
    const raw = if (s57) |p| p[0..s57_len] else "";
    accAppend(acc, if (raw.len == 0) "{}" else raw);
    accAppend(acc, ",\"chart\":");
    accAppendJsonString(acc, if (chart) |p| p[0..chart_len] else "");
    accAppend(acc, "}");
}

/// The pick at (lon, lat) as JSON. `compose` when nonzero, else `chart`.
export fn tile57_wasm_query(compose: ?*anyopaque, chart: ?*anyopaque, lon: f64, lat: f64, zoom: f64, out: ?*?[*]u8, out_len: ?*usize) i32 {
    const o = out orelse return 1;
    const ol = out_len orelse return 1;
    o.* = null;
    ol.* = 0;
    var acc = QueryAcc{};
    accAppend(&acc, "[");
    const cb = QueryCb{ .ctx = &acc, .feature = &onQueryFeature };
    const status = if (compose != null)
        tile57_compose_query(compose, lon, lat, zoom, &cb, null)
    else
        tile57_chart_query(chart, lon, lat, zoom, &cb, null);
    accAppend(&acc, "]");
    if (status != 0 or acc.failed) {
        acc.list.deinit(std.heap.c_allocator);
        return if (status != 0) status else 4; // 4 = TILE57_ERR_NOMEM
    }
    const slice = acc.list.toOwnedSlice(std.heap.c_allocator) catch {
        acc.list.deinit(std.heap.c_allocator);
        return 4;
    };
    o.* = slice.ptr;
    ol.* = slice.len;
    return 0;
}
