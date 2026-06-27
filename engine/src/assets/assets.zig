//! assets — offline portrayal-asset generation for the chart bundle. Mirrors the
//! Go oracle's internal/engine/assets (EmitS101): the rendering half of the
//! tile/style contract, emitted from the same S-101 catalogue that drives the
//! tiles so the two can't drift. See ../../../specs/bundle-bake.md.
//!
//! Pure Zig (no libc/fs): callers read the catalogue bytes and pass them in, the
//! same shape as s100/catalogue.zig. RGB lives ONLY in colortables.json; the
//! tiles stay colour *tokens*.
//!
//! Implemented now: colortables.json (token -> hex, per day/dusk/night palette),
//! the MapLibre style.json layer set (style.zig), and manifest.json (pins
//! schema_version; couples tiles <-> portrayal). TODO, tracked in
//! specs/bundle-bake.md: linestyles.json, sprite/pattern atlases (SVG raster),
//! and glyphs (SDF) — to light up the symbol/text/pattern layers.

const std = @import("std");

/// The tile-vocabulary version both halves of a bundle are stamped with: the MVT
/// layer/property set in s57_mvt.zig and the style/colortables that render it.
/// Bump on ANY change to layer names or feature property keys.
pub const SCHEMA_VERSION = "tile57/1";

// MapLibre style.json generation lives in style.zig.
pub const StyleOpts = @import("style.zig").StyleOpts;
pub const styleJson = @import("style.zig").styleJson;

// ---- colortables.json ----------------------------------------------------

const Palette = struct { xml_name: []const u8, key: []const u8 };

// The three S-101 palettes, emitted in this order. xml_name matches the
// <palette name="..."> in colorProfile.xml; key is the colortables.json field.
const palettes = [_]Palette{
    .{ .xml_name = "Day", .key = "day" },
    .{ .xml_name = "Dusk", .key = "dusk" },
    .{ .xml_name = "Night", .key = "night" },
};

const Entry = struct { token: []const u8, hex: [7]u8 };

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.token, b.token);
}

// Read the decimal byte inside the first <tag>NNN</tag> within `s`. Used for the
// <red>/<green>/<blue> children of an <item>'s <srgb> block — those tags are
// unique to <srgb> (the sibling <cie> block carries <x>/<y>/<L>), so a plain
// forward scan over the item is unambiguous.
fn tagByte(s: []const u8, comptime tag: []const u8) ?u8 {
    const open = "<" ++ tag ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const rest = s[i + open.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const num = std.mem.trim(u8, rest[0..close], " \t\r\n");
    return std.fmt.parseInt(u8, num, 10) catch null;
}

// Return the slice of `xml` covering one <palette name="NAME"> … </palette>.
fn findPalette(xml: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "<palette name=\"{s}\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, xml, needle) orelse return null;
    const after = xml[start..];
    const end = std.mem.indexOf(u8, after, "</palette>") orelse after.len;
    return after[0..end];
}

fn collectItems(alloc: std.mem.Allocator, block: []const u8, entries: *std.ArrayList(Entry)) !void {
    const open = "<item token=\"";
    var rest = block;
    while (std.mem.indexOf(u8, rest, open)) |ti| {
        const after = rest[ti + open.len ..];
        const q = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const token = after[0..q];
        const item_end = std.mem.indexOf(u8, after, "</item>") orelse after.len;
        const item = after[0..item_end];
        rest = after[item_end..];
        const r = tagByte(item, "red") orelse continue;
        const g = tagByte(item, "green") orelse continue;
        const b = tagByte(item, "blue") orelse continue;
        var e: Entry = .{ .token = token, .hex = undefined };
        _ = std.fmt.bufPrint(&e.hex, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch continue;
        try entries.append(alloc, e);
    }
}

/// Parse an S-101 ColorProfiles/colorProfile.xml and emit colortables.json:
///   {"day":{TOKEN:"#rrggbb",…},"dusk":{…},"night":{…}}
/// Tokens are sorted within each palette (stable, diff-friendly, matches the Go
/// oracle's reference/assets/colortables.json). Returns allocator-owned bytes.
pub fn colorTablesJson(alloc: std.mem.Allocator, xml: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\n");
    for (palettes, 0..) |p, pi| {
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(alloc);
        if (findPalette(xml, p.xml_name)) |block| try collectItems(alloc, block, &entries);
        std.mem.sort(Entry, entries.items, {}, lessEntry);

        try out.appendSlice(alloc, "  \"");
        try out.appendSlice(alloc, p.key);
        try out.appendSlice(alloc, "\": {");
        if (entries.items.len == 0) {
            try out.appendSlice(alloc, "}");
        } else {
            try out.appendSlice(alloc, "\n");
            for (entries.items, 0..) |e, ei| {
                try out.appendSlice(alloc, "    \"");
                try out.appendSlice(alloc, e.token);
                try out.appendSlice(alloc, "\": \"");
                try out.appendSlice(alloc, e.hex[0..]);
                try out.appendSlice(alloc, if (ei + 1 < entries.items.len) "\",\n" else "\"\n");
            }
            try out.appendSlice(alloc, "  }");
        }
        try out.appendSlice(alloc, if (pi + 1 < palettes.len) ",\n" else "\n");
    }
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

// ---- manifest.json -------------------------------------------------------

/// Inputs for the bundle manifest. Relative paths only (the bundle is
/// relocatable). bbox is [west, south, east, north]; anchor is [lon, lat].
pub const Manifest = struct {
    generator: []const u8,
    created: []const u8 = "", // ISO 8601; Zig has no wall clock, so passed in
    catalogue_version: []const u8 = "",
    tiles_rel: []const u8,
    colortables_rel: []const u8,
    minzoom: u8,
    maxzoom: u8,
    bbox: [4]f64,
    anchor: [2]f64,
    cells: []const []const u8,
    styles: ?Styles = null, // per-palette style.json paths, if emitted

    pub const Styles = struct { day: []const u8, dusk: []const u8, night: []const u8 };
};

/// Emit the bundle manifest.json. Loaded first by a renderer, which refuses a
/// bundle whose schema_version it doesn't speak — turning tile/style coupling
/// into a checked invariant. Returns allocator-owned bytes.
pub fn manifestJson(alloc: std.mem.Allocator, m: Manifest) ![]u8 {
    // Pre-build the cells array ("c1", "c2", …) so the body is one allocPrint.
    var cells = std.ArrayList(u8).empty;
    defer cells.deinit(alloc);
    for (m.cells, 0..) |c, i| {
        try cells.appendSlice(alloc, "\"");
        try cells.appendSlice(alloc, c);
        try cells.appendSlice(alloc, if (i + 1 < m.cells.len) "\", " else "\"");
    }
    // Optional per-palette styles block, appended after "colortables".
    const styles_field: []const u8 = if (m.styles) |st|
        try std.fmt.allocPrint(alloc,
            \\,
            \\    "styles": {{ "day": "{s}", "dusk": "{s}", "night": "{s}" }}
        , .{ st.day, st.dusk, st.night })
    else
        "";
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "bundle_version": 1,
        \\  "schema_version": "{s}",
        \\  "generator": "{s}",
        \\  "created": "{s}",
        \\  "catalogue_version": "{s}",
        \\  "data": {{
        \\    "tiles": "{s}",
        \\    "minzoom": {d},
        \\    "maxzoom": {d},
        \\    "bbox": [{d:.6}, {d:.6}, {d:.6}, {d:.6}],
        \\    "anchor": [{d:.6}, {d:.6}],
        \\    "cells": [{s}]
        \\  }},
        \\  "portrayal": {{
        \\    "colortables": "{s}"{s}
        \\  }}
        \\}}
    , .{
        SCHEMA_VERSION,    m.generator, m.created,         m.catalogue_version,
        m.tiles_rel,       m.minzoom,   m.maxzoom,         m.bbox[0],
        m.bbox[1],         m.bbox[2],   m.bbox[3],         m.anchor[0],
        m.anchor[1],       cells.items, m.colortables_rel, styles_field,
    });
}

// ---- tests ---------------------------------------------------------------

test "colorTablesJson: sorted tokens, lowercase hex, all three palettes" {
    const xml =
        \\<cp:colorProfile>
        \\  <palette name="Day" css="daySvgStyle.css">
        \\    <item token="DEPDW"><cie><xyL><x>0.28</x></xyL></cie>
        \\      <srgb><red>201</red><green>237</green><blue>255</blue></srgb></item>
        \\    <item token="CHBLK"><srgb><red>0</red><green>0</green><blue>0</blue></srgb></item>
        \\  </palette>
        \\  <palette name="Night" css="nightSvgStyle.css">
        \\    <item token="DEPDW"><srgb><red>10</red><green>20</green><blue>30</blue></srgb></item>
        \\  </palette>
        \\</cp:colorProfile>
    ;
    const out = try colorTablesJson(std.testing.allocator, xml);
    defer std.testing.allocator.free(out);
    const expected =
        \\{
        \\  "day": {
        \\    "CHBLK": "#000000",
        \\    "DEPDW": "#c9edff"
        \\  },
        \\  "dusk": {},
        \\  "night": {
        \\    "DEPDW": "#0a141e"
        \\  }
        \\}
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "manifestJson: pins schema_version and couples tiles to portrayal" {
    const out = try manifestJson(std.testing.allocator, .{
        .generator = "chartplotter-bake 0.1.0",
        .created = "2026-06-27T00:00:00Z",
        .catalogue_version = "S-101 PC 1.4.0",
        .tiles_rel = "tiles/chart.pmtiles",
        .colortables_rel = "assets/colortables.json",
        .minzoom = 8,
        .maxzoom = 16,
        .bbox = .{ -76.55, 38.90, -76.40, 39.02 },
        .anchor = .{ -76.475, 38.96 },
        .cells = &.{ "US5MD1MC", "US4MD81M" },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\": \"tile57/1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tiles\": \"tiles/chart.pmtiles\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"colortables\": \"assets/colortables.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"US5MD1MC\", \"US4MD81M\"") != null);
    // valid JSON round-trips
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
}
