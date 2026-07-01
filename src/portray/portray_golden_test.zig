//! Golden portrayal-instruction test — conformance-testability assertion #5
//! (specs/conformance-testability.md §1, §6.5). Drive the REAL embedded S-101 Lua
//! rules over a tiny in-memory fixture cell and assert the pre-raster S-100 Part-9
//! instruction stream that `portrayCell` returns, BEFORE any MVT/raster mapping.
//!
//! This is the end-to-end seam: it validates that the adapter's attribute synthesis
//! (openingBridge from CATBRG, the BRIDGE->Bridge routing) and value handling reach
//! the rules and produce the right drawing instructions — something the adapter-level
//! unit tests (which stop at the CNode tree) cannot see. Lives in its own file because
//! `portray` links libc + the vendored Lua + the embedded rule registry, so it rides a
//! dedicated test artifact rather than the libc-free pure-package tests.
//!
//! No geometry is built: the instruction stream is emitted from a feature's attributes
//! and primitive type; geometry is attached later (s57_mvt), downstream of this seam.

const std = @import("std");
const s57 = @import("s57");
const portray = @import("portray");

fn has(stream: ?[]const u8, needle: []const u8) bool {
    const s = stream orelse return false;
    return std.mem.indexOf(u8, s, needle) != null;
}

test "golden Part-9 stream: opening vs fixed Bridge, DepthArea (BRIDGE->Bridge + openingBridge)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const depare_attrs = [_]s57.Attr{
        .{ .code = s57.ATTR_DRVAL1, .value = "5" },
        .{ .code = s57.ATTR_DRVAL2, .value = "10" },
    };
    const opening = [_]s57.Attr{.{ .code = s57.ATTR_CATBRG, .value = "2" }}; // opening span
    const fixed = [_]s57.Attr{.{ .code = s57.ATTR_CATBRG, .value = "1" }}; // fixed span
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 42, .attrs = &depare_attrs }, // DEPARE -> DepthArea
        .{ .rcnm = 100, .rcid = 2, .prim = 2, .objl = s57.OBJL_BRIDGE, .attrs = &opening }, // opening bridge
        .{ .rcnm = 100, .rcid = 3, .prim = 2, .objl = s57.OBJL_BRIDGE, .attrs = &fixed }, // fixed bridge
    };
    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = std.AutoHashMap(u32, usize).init(a),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    // "" rules_dir -> the embedded Lua rule registry (no on-disk catalogue).
    portray.setQuiet(true); // silence the per-cell "[s101] portrayed …" stderr summary
    const streams = try portray.portrayCell(a, &cell, "");
    try std.testing.expectEqual(@as(usize, 3), streams.len);

    // [0] DepthArea: a depth ColorFill at a real drawing priority (rule fired).
    try std.testing.expect(has(streams[0], "ColorFill:"));
    try std.testing.expect(has(streams[0], "DrawingPriority:"));

    // [1] opening bridge: the CHGRD structure line AND the BRIDGE01 opening symbol —
    // proves BRIDGE routed to Bridge and openingBridge=true (synthesized from CATBRG=2)
    // coerced to a real boolean and fired Bridge.lua's `== true` branch.
    try std.testing.expect(has(streams[1], "CHGRD"));
    try std.testing.expect(has(streams[1], "PointInstruction:BRIDGE01"));

    // [2] fixed bridge (CATBRG=1): the CHGRD line, but NO opening symbol.
    try std.testing.expect(has(streams[2], "CHGRD"));
    try std.testing.expect(!has(streams[2], "BRIDGE01"));
}

test "golden Part-9 stream: M_QUAL quality fills (DQUAL from CATZOC, NODATA03 when absent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zoc_b = [_]s57.Attr{.{ .code = s57.ATTR_CATZOC, .value = "3" }}; // ZOC B
    const feats = [_]s57.Feature{
        .{ .rcnm = 100, .rcid = 1, .prim = 3, .objl = 308, .attrs = &zoc_b }, // M_QUAL, assessed
        .{ .rcnm = 100, .rcid = 2, .prim = 3, .objl = 308 }, // M_QUAL, bare (no CATZOC)
    };
    var cell = s57.Cell{
        .params = .{},
        .vectors = &.{},
        .features = &feats,
        .nodes = std.AutoHashMap(u64, s57.LonLat).init(a),
        .edges = std.AutoHashMap(u32, usize).init(a),
        .sounding_vecs = std.AutoHashMap(u64, usize).init(a),
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer cell.arena.deinit();

    portray.setQuiet(true);
    const streams = try portray.portrayCell(a, &cell, "");
    try std.testing.expectEqual(@as(usize, 2), streams.len);

    // [0] CATZOC=3 -> the DQUALB01 fill (unchanged by the Gap D deconstruction).
    try std.testing.expect(has(streams[0], "AreaFillReference:DQUALB01"));

    // [1] no CATZOC -> the NODATA03 "quality unknown" fill (S-52's bare-M_QUAL lookup
    // line): the always-emitted zoneOfConfidence entry takes the rule's else branch.
    // Before the deconstruction this feature emitted no fill at all (a silent miss).
    try std.testing.expect(has(streams[1], "AreaFillReference:NODATA03"));
}
