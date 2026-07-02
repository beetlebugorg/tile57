//! Render-engine resolver: turns the S-52 semantics carried by Surface calls
//! into drawable facts for pixel surfaces — color token -> RGB at the scene
//! palette, and the mariner display gates (display category, viewing groups,
//! SCAMIN) evaluated at the scene zoom.
//!
//! Tile surfaces (MVT/MLT) never resolve: they serialize tokens/names verbatim
//! and the MapLibre client resolves live (assets/colortables.json + the
//! chartstyle expressions). The resolver mirrors those exact semantics so the
//! two styling paths can't silently drift; each gate cites the expression it
//! mirrors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");
const chartstyle = @import("assets").chartstyle;

pub const MarinerSettings = chartstyle.MarinerSettings;

// ---- colors ---------------------------------------------------------------

/// The three S-52 palettes (S-101 ColorProfiles/colorProfile.xml).
pub const PaletteId = enum(u2) { day, dusk, night };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// Token -> RGB for all three palettes, parsed once from colorProfile.xml —
/// the same source assets.colorTablesJson serializes for the MapLibre client
/// (parse mirrored from src/assets/assets.zig; keep in sync). Token keys are
/// slices INTO `xml`, so the xml must outlive the Colors (the embedded
/// catalogue profile is static, so this is free in practice).
pub const Colors = struct {
    maps: [3]std.StringHashMapUnmanaged(Rgb),

    const xml_names = [3][]const u8{ "Day", "Dusk", "Night" };

    pub fn init(a: Allocator, xml: []const u8) !Colors {
        var c = Colors{ .maps = .{ .empty, .empty, .empty } };
        errdefer c.deinit(a);
        for (xml_names, 0..) |name, i| {
            const block = findPalette(xml, name) orelse continue;
            try collectItems(a, block, &c.maps[i]);
        }
        return c;
    }

    pub fn deinit(self: *Colors, a: Allocator) void {
        for (&self.maps) |*m| m.deinit(a);
    }

    /// Resolve a color token (e.g. "DEPMS") at a palette; null for an unknown
    /// token — the caller decides the fallback (the style uses magenta #ff00ff
    /// to make unmapped tokens visible; a pixel surface should do the same).
    pub fn get(self: *const Colors, palette: PaletteId, token: []const u8) ?Rgb {
        return self.maps[@intFromEnum(palette)].get(token);
    }
};

// Read the decimal byte inside the first <tag>NNN</tag> within `s` — the
// <red>/<green>/<blue> children of an <item>'s <srgb> block (unambiguous: the
// sibling <cie> block carries <x>/<y>/<L>). Mirrors assets.zig tagByte.
fn tagByte(s: []const u8, comptime tag: []const u8) ?u8 {
    const open = "<" ++ tag ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const rest = s[i + open.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const num = std.mem.trim(u8, rest[0..close], " \t\r\n");
    return std.fmt.parseInt(u8, num, 10) catch null;
}

// The slice of `xml` covering one <palette name="NAME"> … </palette>.
fn findPalette(xml: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "<palette name=\"{s}\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, xml, needle) orelse return null;
    const after = xml[start..];
    const end = std.mem.indexOf(u8, after, "</palette>") orelse after.len;
    return after[0..end];
}

fn collectItems(a: Allocator, block: []const u8, map: *std.StringHashMapUnmanaged(Rgb)) !void {
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
        try map.put(a, token, .{ .r = r, .g = g, .b = b });
    }
}

// ---- display gates ----------------------------------------------------------

/// S-52 §10.3.4 display-category gate — mirrors chartstyle.categoryFilter:
/// the effective category is the feature's `cat` (0 base / 1 standard /
/// 2 other; null defaults to standard, like the style's coalesce), except
/// ISODGR01 which rides the isolated-dangers-shallow toggle instead of its
/// baked category. M_QUAL is the data-quality overlay: shown iff the overlay
/// is on (then regardless of category), hidden otherwise.
pub fn categoryVisible(cat: ?i64, class: []const u8, symbol_name: ?[]const u8, m: *const MarinerSettings) bool {
    if (std.mem.eql(u8, class, "M_QUAL")) return m.data_quality;
    var c = cat orelse 1;
    if (symbol_name) |sn| {
        if (std.mem.eql(u8, sn, "ISODGR01")) c = if (m.show_isolated_dangers_shallow) 1 else 0;
    }
    return switch (c) {
        0 => m.display_base,
        1 => m.display_standard,
        2 => m.display_other,
        else => false,
    };
}

/// 1:N scale denominator of the whole world in one 256px tile at z0 — the
/// constant the style's SCAMIN gate divides by (assets/style.zig SCAMIN_GATE).
pub const DENOM_Z0 = 279541132.0;

/// SCAMIN gate at a (fractional) display zoom — mirrors the style expression
/// `zoom >= log2(DENOM_Z0 / scamin)` (assets/style.zig SCAMIN_GATE). A feature
/// without SCAMIN (null) always shows.
pub fn scaminVisible(scamin: ?i64, zoom: f64) bool {
    const s = scamin orelse return true;
    if (s <= 0) return true;
    return zoom >= std.math.log2(DENOM_Z0 / @as(f64, @floatFromInt(s)));
}

/// Band-handoff (smax) gate — the mirror image of scaminVisible: a carried
/// coarser-band copy shows only while the display is still COARSER than its
/// handoff denominator (denom(zoom) > smax, i.e. zoom < log2(DENOM_Z0 / smax)),
/// then hands off to the finer band's own content. Untagged features (0) always
/// show. Mirrors the style smax clause (assets/style.zig writeSmaxClause).
pub fn smaxVisible(smax: i64, zoom: f64) bool {
    if (smax <= 0) return true;
    return zoom < std.math.log2(DENOM_Z0 / @as(f64, @floatFromInt(smax)));
}

/// Overscale gate (S-52 §10.1.10) — the AP(OVERSC01) hatch over a cell's M_COVR
/// coverage shows only while the display is FINER than the cell's (quantized)
/// compilation scale: denom(zoom) < oscl, i.e. zoom > log2(DENOM_Z0 / oscl).
/// Exactly at 1:oscl the display is at compilation scale — no indication (the
/// style clause is a strict `>`: oscl > DENOM). oscl 0 (unknown) never shows.
/// Mirrors the style oscl clause (assets/style.zig writeOsclClause).
pub fn osclVisible(oscl: i64, zoom: f64) bool {
    if (oscl <= 0) return false;
    return zoom > std.math.log2(DENOM_Z0 / @as(f64, @floatFromInt(oscl)));
}

/// Viewing-group gate (S-52 §14.5) — the deny-list model of
/// chartstyle.MarinerSettings.viewing_groups_off (the host's viewingGroupsOff model):
/// a feature with no viewing group (vg 0) always shows; otherwise it hides iff
/// its group is in the mariner's off-list. Any group not listed defaults ON.
pub fn viewingGroupVisible(vg: i64, off: ?[]const i32) bool {
    if (vg == 0) return true;
    const list = off orelse return true;
    for (list) |g| {
        if (g == vg) return false;
    }
    return true;
}

/// S-52 §14.5 text-group gate — mirrors chartstyle.textGroupFilter: important
/// text (group 11) is always on; 21/26/29 ride text_names; 23 rides
/// show_light_descriptions; everything else rides text_other.
pub fn textGroupVisible(group: i64, m: *const MarinerSettings) bool {
    if (group == 11) return true;
    if (group == 21 or group == 26 or group == 29) return m.text_names;
    if (group == 23) return m.show_light_descriptions;
    return m.text_other;
}

/// Combined per-feature gate for pixel surfaces: display category + viewing
/// group + SCAMIN at the scene zoom. `symbol_name` is the symbol about to be
/// drawn (null for fills/lines/text) — only consulted for the ISODGR01 case.
pub fn visible(meta: *const rs.FeatureMeta, symbol_name: ?[]const u8, zoom: f64, m: *const MarinerSettings) bool {
    if (!categoryVisible(meta.cat, meta.class, symbol_name, m)) return false;
    if (!viewingGroupVisible(meta.vg, m.viewing_groups_off)) return false;
    if (!m.ignore_scamin and !scaminVisible(meta.scamin, zoom)) return false;
    if (!m.ignore_scamin and !smaxVisible(meta.smax, zoom)) return false;
    // The AP(OVERSC01) overscale hatch (S-52 §10.1.10): the mariner toggle, plus
    // the oscl scale gate. Hidden under ignore_scamin (the debug toggle drops all
    // scale gating — an always-on hatch would bury the debug view), mirroring the
    // style builder, which omits the overscale layer entirely there.
    if (meta.overscale) {
        if (!m.show_overscale or m.ignore_scamin) return false;
        if (!osclVisible(meta.oscl, zoom)) return false;
    }
    // S-52 display-variant passes (mirrors chartstyle.boundaryFilter /
    // pointStyleFilter): a feature portrayed twice carries bnd 1/0 (symbolized/
    // plain boundary) or pts 0/1 (paper/simplified points); show the common
    // pass (2) + the mariner's active style — otherwise both passes double-draw.
    const bnd_rank: i64 = if (m.boundary_style == .plain) 0 else 1;
    if (meta.bnd != 2 and meta.bnd != bnd_rank) return false;
    const pts_rank: i64 = if (m.simplified_points) 1 else 0;
    if (meta.pts != 2 and meta.pts != pts_rank) return false;
    return true;
}

// ---- tests ------------------------------------------------------------------

const fixture_xml =
    \\<cp:colorProfile>
    \\ <palette name="Day">
    \\  <item token="DEPMS"><srgb><red>197</red><green>225</green><blue>225</blue></srgb></item>
    \\  <item token="CHBLK"><srgb><red>0</red><green>0</green><blue>0</blue></srgb></item>
    \\ </palette>
    \\ <palette name="Dusk">
    \\  <item token="DEPMS"><srgb><red>65</red><green>85</green><blue>90</blue></srgb></item>
    \\ </palette>
    \\ <palette name="Night">
    \\  <item token="DEPMS"><srgb><red>25</red><green>35</green><blue>40</blue></srgb></item>
    \\ </palette>
    \\</cp:colorProfile>
;

test "Colors: token -> RGB per palette, unknown -> null" {
    const a = std.testing.allocator;
    var c = try Colors.init(a, fixture_xml);
    defer c.deinit(a);
    try std.testing.expectEqual(Rgb{ .r = 197, .g = 225, .b = 225 }, c.get(.day, "DEPMS").?);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, c.get(.day, "CHBLK").?);
    try std.testing.expectEqual(Rgb{ .r = 65, .g = 85, .b = 90 }, c.get(.dusk, "DEPMS").?);
    try std.testing.expectEqual(Rgb{ .r = 25, .g = 35, .b = 40 }, c.get(.night, "DEPMS").?);
    try std.testing.expectEqual(@as(?Rgb, null), c.get(.dusk, "CHBLK")); // dusk fixture lacks it
    try std.testing.expectEqual(@as(?Rgb, null), c.get(.day, "NOSUCH"));
}

test "categoryVisible mirrors chartstyle.categoryFilter" {
    const def = MarinerSettings{}; // base+standard on, other off, no overlays
    try std.testing.expect(categoryVisible(0, "DEPARE", null, &def));
    try std.testing.expect(categoryVisible(1, "DEPARE", null, &def));
    try std.testing.expect(!categoryVisible(2, "DEPARE", null, &def));
    try std.testing.expect(categoryVisible(null, "DEPARE", null, &def)); // null -> standard
    // M_QUAL: data-quality overlay only.
    try std.testing.expect(!categoryVisible(0, "M_QUAL", null, &def));
    const dq = MarinerSettings{ .data_quality = true };
    try std.testing.expect(categoryVisible(2, "M_QUAL", null, &dq)); // shown regardless of cat
    // ISODGR01 rides its own toggle: off -> cat 0 (base on -> visible);
    // base ALSO off -> hidden; toggle on -> cat 1 (standard).
    try std.testing.expect(categoryVisible(2, "UWTROC", "ISODGR01", &def));
    const no_base = MarinerSettings{ .display_base = false };
    try std.testing.expect(!categoryVisible(2, "UWTROC", "ISODGR01", &no_base));
    const iso = MarinerSettings{ .display_base = false, .show_isolated_dangers_shallow = true };
    try std.testing.expect(categoryVisible(2, "UWTROC", "ISODGR01", &iso));
}

test "scaminVisible mirrors the style SCAMIN_GATE" {
    // 1:30000 gates at log2(279541132/30000) ~= 13.186.
    try std.testing.expect(!scaminVisible(30000, 13.0));
    try std.testing.expect(scaminVisible(30000, 13.2));
    try std.testing.expect(scaminVisible(null, 0)); // no SCAMIN -> always
    try std.testing.expect(scaminVisible(0, 0)); // degenerate 0 -> always
}

test "smaxVisible is scaminVisible's mirror: carried copy hides past the handoff" {
    // A copy carried with smax 260000 shows while the display is coarser than
    // 1:260000 (zoom < log2(279541132/260000) ~= 10.07) and hides beyond.
    try std.testing.expect(smaxVisible(260000, 9.5));
    try std.testing.expect(!smaxVisible(260000, 10.5));
    // Exactly at the crossing the copy hands off (scaminVisible turns true there).
    const cross = std.math.log2(DENOM_Z0 / 260000.0);
    try std.testing.expect(!smaxVisible(260000, cross));
    try std.testing.expect(scaminVisible(260000, cross));
    try std.testing.expect(smaxVisible(0, 0)); // untagged -> always
}

test "osclVisible: the overscale hatch shows only past the compilation scale" {
    // 1:260000 data: the display reads finer than 1:260000 past zoom
    // log2(279541132/260000) ~= 10.07 — the hatch turns ON there (denom < oscl).
    const cross = std.math.log2(DENOM_Z0 / 260000.0);
    try std.testing.expect(!osclVisible(260000, 9.5));
    try std.testing.expect(osclVisible(260000, 10.5));
    // Exactly AT compilation scale there is no overscale (strict >, like the
    // style clause [">", oscl, DENOM]).
    try std.testing.expect(!osclVisible(260000, cross));
    // Unknown scale never hatches.
    try std.testing.expect(!osclVisible(0, 16.0));
}

test "visible: the overscale hatch honours show_overscale + the oscl gate" {
    const m = MarinerSettings{};
    const hatch = rs.FeatureMeta{ .cat = 0, .oscl = 260000, .overscale = true };
    try std.testing.expect(!visible(&hatch, null, 9.5, &m)); // display coarser: no hatch
    try std.testing.expect(visible(&hatch, null, 12.0, &m)); // overscaled: hatch shows
    const off = MarinerSettings{ .show_overscale = false };
    try std.testing.expect(!visible(&hatch, null, 12.0, &off));
    const ign = MarinerSettings{ .ignore_scamin = true };
    try std.testing.expect(!visible(&hatch, null, 12.0, &ign)); // debug view: no hatch
    // An ordinary fill carrying the oscl TAG (not the hatch) is never oscl-gated.
    const fill = rs.FeatureMeta{ .cat = 0, .oscl = 260000 };
    try std.testing.expect(visible(&fill, null, 9.5, &m));
    try std.testing.expect(visible(&fill, null, 12.0, &m));
}

test "viewingGroupVisible: deny-list, vg 0 always shows" {
    const off = [_]i32{ 21030, 26050 };
    try std.testing.expect(viewingGroupVisible(0, &off));
    try std.testing.expect(!viewingGroupVisible(21030, &off));
    try std.testing.expect(viewingGroupVisible(27010, &off));
    try std.testing.expect(viewingGroupVisible(21030, null)); // no list -> all on
}

test "visible combines gates + honours ignore_scamin" {
    const m = MarinerSettings{};
    const meta = rs.FeatureMeta{ .cat = 1, .vg = 0, .scamin = 30000, .class = "BOYLAT" };
    try std.testing.expect(!visible(&meta, "BOYLAT01", 12.0, &m)); // SCAMIN gates it
    try std.testing.expect(visible(&meta, "BOYLAT01", 14.0, &m));
    const ig = MarinerSettings{ .ignore_scamin = true };
    try std.testing.expect(visible(&meta, "BOYLAT01", 12.0, &ig));
}
