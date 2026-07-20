//! Bundle-sourced replay: turn a decoded baked tile (mvt layers) back into
//! Surface draw calls, so the native pixel/PDF/ASCII path renders a pre-baked
//! archive the same way it renders a live cell. Reads the tile properties the
//! scene emitter wrote; re-walks complex linestyles at the surface's display
//! scale through the linestyle module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mvt = @import("tiles").mvt;
const tile = @import("tiles").tile;
const rs = @import("render").surface;
const linestyle = @import("linestyle.zig");
const SYMBOL_SCALE: f64 = @import("render").sndfrm.SYMBOL_SCALE;

//
// The tile schema is a serialized Surface-call stream, so a baked tile can be
// replayed onto any Surface — the substrate for rendering PMTiles bundles to
// pixels with no source cells. LOSSY by design: the bake-time portrayal
// context is frozen (SafetyContour/Depth 30); the live-swappable props the
// tile path bakes (danger_depth/sym_deep, sym_s/sym_g depth + quality-ring
// prefixes) are re-expanded here, so the mariner's danger swap, sounding
// bold/faint split, and display unit still evaluate LIVE.

fn propOf(props: []const mvt.Prop, key: []const u8) ?mvt.Value {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

fn propInt(props: []const mvt.Prop, key: []const u8, default: i64) i64 {
    const v = propOf(props, key) orelse return default;
    return switch (v) {
        .int => |i| i,
        .uint => |u| @intCast(u),
        .double => |d| @intFromFloat(d),
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn propF64(props: []const mvt.Prop, key: []const u8) ?f64 {
    const v = propOf(props, key) orelse return null;
    return switch (v) {
        .double => |d| d,
        .float => |f| f,
        .int => |i| @floatFromInt(i),
        .uint => |u| @floatFromInt(u),
        else => null,
    };
}

fn propStr(props: []const mvt.Prop, key: []const u8) []const u8 {
    const v = propOf(props, key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn metaFromProps(props: []const mvt.Prop) rs.FeatureMeta {
    return .{
        .display_priority = propInt(props, "display_priority", 0),
        // Emitted only for OverRadar (see scene.appendMeta), so absent => 0
        // UnderRadar. Not reading it is why the baked-tile path used to lose
        // DisplayPlane entirely and replay every feature as UnderRadar.
        .display_plane = propInt(props, "display_plane", 0),
        .display_category = propInt(props, "display_category", 1),
        .vg = propInt(props, "vg", 0),
        .scamin = if (propOf(props, "scamin")) |_| propInt(props, "scamin", 0) else null,
        .class = propStr(props, "class"),
        .s57_json = propStr(props, "s57"), // cursor-pick attribute blob (baked)
        .cell_name = propStr(props, "cell"), // source cell badge (baked)
        .band = @intCast(std.math.clamp(propInt(props, "band", 0), 0, 255)),
        .bnd = propInt(props, "bnd", 2),
        .pts = propInt(props, "pts", 2),
        .masked = propInt(props, "masked", 0) != 0,
        .date_start = propStr(props, "date_start"),
        .date_end = propStr(props, "date_end"),
    };
}

/// Replay one decoded tile's layers as Surface calls (between the caller's
/// begin/endScene). Layer names route exactly as TileSurface emitted them.
pub fn replayTile(a: Allocator, surf: rs.Surface, layers: []const mvt.DecodedLayer) !void {
    for (layers) |layer| {
        const is_areas = std.mem.startsWith(u8, layer.name, "areas");
        const is_patterns = std.mem.startsWith(u8, layer.name, "area_patterns");
        const is_lines = std.mem.startsWith(u8, layer.name, "lines");
        const is_points = std.mem.startsWith(u8, layer.name, "point_symbols");
        const is_soundings = std.mem.eql(u8, layer.name, "soundings");
        const is_text = std.mem.startsWith(u8, layer.name, "text");
        for (layer.features) |f| {
            const meta = metaFromProps(f.properties);
            try surf.beginFeature(&meta);
            defer surf.endFeature() catch {};
            if (is_patterns) {
                try surf.fillPattern(propStr(f.properties, "pattern_name"), f.parts);
            } else if (is_areas) {
                const d1 = propF64(f.properties, "drval1");
                const dr: ?rs.DepthRange = if (d1) |v| .{ .d1 = @floatCast(v), .d2 = @floatCast(propF64(f.properties, "drval2") orelse v) } else null;
                try surf.fillArea(propStr(f.properties, "color_token"), f.parts, dr);
            } else if (is_lines) {
                // Complex (symbolised) linestyle: the bake stored the clipped run
                // un-tessellated (tagged ls_style). Re-walk the period at the render
                // surface's display scale so spacing + brick size track the display.
                const ls_style = propStr(f.properties, "ls_style");
                if (ls_style.len > 0) {
                    if (linestyle.lookup(ls_style)) |info| {
                        const color = propStr(f.properties, "color_token");
                        const arc0 = propF64(f.properties, "ls_arc0") orelse 0;
                        for (f.parts) |part| {
                            if (part.len < 2) continue;
                            const fpts = try a.alloc(tile.FPoint, part.len);
                            for (part, 0..) |p, i| fpts[i] = .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
                            try linestyle.drawComplexRun(a, fpts, arc0, info, color, surf.sizeScale(), true, surf);
                        }
                        continue;
                    }
                    // Style not registered (host without the table): fall back to a
                    // plain dashed stroke so the line never disappears.
                    try surf.strokeLine(propStr(f.properties, "color_token"), propF64(f.properties, "width_px") orelse 1, .dashed, f.parts, null);
                    continue;
                }
                const dash: rs.Dash = if (std.mem.eql(u8, propStr(f.properties, "dash"), "solid")) .solid else .dashed;
                try surf.strokeLine(propStr(f.properties, "color_token"), propF64(f.properties, "width_px") orelse 1, dash, f.parts, propF64(f.properties, "valdco"));
            } else if (is_points) {
                if (f.parts.len == 0 or f.parts[0].len == 0) continue;
                try surf.drawSymbol(
                    propStr(f.properties, "symbol_name"),
                    f.parts[0][0],
                    propF64(f.properties, "rotation_deg") orelse 0,
                    propF64(f.properties, "scale") orelse SYMBOL_SCALE,
                    propInt(f.properties, "rot_north", 0) != 0,
                    .point,
                    propF64(f.properties, "danger_depth"), // live swap re-evaluates
                );
            } else if (is_soundings) {
                if (f.parts.len == 0 or f.parts[0].len == 0) continue;
                const depth = propF64(f.properties, "depth") orelse continue;
                // The quality-ring flags are encoded in the baked glyph list's
                // leading tokens (SNDFRM04 B1 swept / C2/C3 low-accuracy) —
                // recover them so the live recomposition keeps the rings.
                const sym_s = propStr(f.properties, "sym_s");
                const swept = std.mem.indexOf(u8, sym_s, "SB1") != null;
                const low_acc = std.mem.indexOf(u8, sym_s, "SC3") != null;
                try surf.drawSounding(depth, swept, low_acc, f.parts[0][0]);
            } else if (is_text) {
                if (f.parts.len == 0 or f.parts[0].len == 0) continue;
                var ox: f64 = 0;
                var oy: f64 = 0;
                const loff = propStr(f.properties, "loff");
                if (loff.len > 0) {
                    var it = std.mem.splitScalar(u8, loff, ',');
                    const TEXT_BODY_MM = 3.51;
                    ox = (std.fmt.parseFloat(f64, it.next() orelse "0") catch 0) * TEXT_BODY_MM;
                    oy = (std.fmt.parseFloat(f64, it.next() orelse "0") catch 0) * TEXT_BODY_MM;
                }
                const ts = rs.TextStyle{
                    .color = propStr(f.properties, "color_token"),
                    .font_size = propF64(f.properties, "font_size_px") orelse 12,
                    .halign = propStr(f.properties, "halign"),
                    .valign = propStr(f.properties, "valign"),
                    .offset_x = ox,
                    .offset_y = oy,
                    .group = propInt(f.properties, "tgrp", 0),
                };
                try surf.drawText(propStr(f.properties, "text"), &ts, f.parts[0][0]);
            }
        }
    }
}
