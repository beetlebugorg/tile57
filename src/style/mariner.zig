//! mariner — the S-52 mariner display settings and the builders that turn those
//! settings into MapLibre expressions. This is the settings model, not a style
//! generator: maplibre.zig assembles the full style.json and calls these builders
//! for the mariner-driven parts.
//!
//! The settings drive SEABED01 depth shading, the sounding bold/faint split
//! (SNDFRM04), the danger-symbol safety swap (OBSTRN06/WRECKS05), contour label
//! units (SAFCON01), the per-scheme recolour (background/fills/lines/text + halos/
//! contour labels), and the display filters AND-ed onto every `source:"chart"`
//! layer (category + M_QUAL, band, boundary/point style, INFORM01/CHDATD01 callout
//! toggles, date validity, meta-bounds, text groups).
//!
//! Pure Zig (no libc): the host passes in the template + colortables bytes; the C
//! ABI wrapper lives in capi.zig. Colour `match` arms are emitted in sorted-token
//! order so the output is byte-stable across builds.

const std = @import("std");

const Value = std.json.Value;
const Array = std.json.Array;
const ObjectMap = std.json.ObjectMap;

const M_TO_FT: f64 = 3.280839895;
const FALLBACK = "#ff00ff";

// ---- public model --------------------------------------------------------

pub const Scheme = enum(c_int) { day = 0, dusk = 1, night = 2 };
pub const DepthUnit = enum(c_int) { meters = 0, feet = 1 };
pub const BoundaryStyle = enum(c_int) { symbolized = 0, plain = 1 }; // S-52 §8.6.1

/// The S-52 mariner display options. Defaults match the recreational web
/// client's defaults.
pub const Settings = struct {
    // -- colour scheme (S-52 day/dusk/night palette) --
    scheme: Scheme = .day,

    // -- depth (SEABED01, client-side shading; metres) --
    shallow_contour: f64 = 2.0,
    safety_contour: f64 = 10.0, // the mariner's own-ship safety contour
    deep_contour: f64 = 30.0,
    safety_depth: f64 = 10.0, // SNDFRM04 bold/faint sounding split
    four_shade_water: bool = true,
    depth_unit: DepthUnit = .meters,

    // -- display category (S-52 §10.3.4, multi-select) --
    display_base: bool = true,
    display_standard: bool = true,
    display_other: bool = false,

    // Spot soundings, independent of the category above (S-52 files SOUNDG under OTHER, but
    // every ECDIS — OpenCPN included — offers soundings as their own switch, and the everyday
    // setting is STANDARD + soundings ON). Without this a host that wants soundings has to
    // turn the whole OTHER category on and take the seabed, the cables and the rest of the
    // low-priority clutter with them. `null` = follow the display category, as before.
    show_soundings: ?bool = null,

    // -- overlays / opt-in markers (off by default) --
    data_quality: bool = false,
    show_inform_callouts: bool = false,
    show_meta_bounds: bool = false,
    show_isolated_dangers_shallow: bool = false,

    // -- overscale indication (S-52 §10.1.10, ON by default) --
    // AP(OVERSC01) vertical-line hatch over regions whose best displayed data is
    // enlarged past its compilation scale (the baked `oscl` gate). Toggling only
    // flips the `overscale` layer's visibility — the layer set is unchanged, so
    // the style-diff path emits one setLayoutProperty op.
    show_overscale: bool = true,

    // -- symbolization style --
    boundary_style: BoundaryStyle = .symbolized,
    simplified_points: bool = false,
    show_full_sector_lines: bool = false,

    // -- text groups (S-52 §14.5) --
    text_names: bool = true,
    show_light_descriptions: bool = true,
    text_other: bool = true,

    // -- viewing groups (S-52 §14.5, fine-grained per-VG control). A DENY-LIST: the
    // groups the mariner has turned OFF. null/empty = every viewing group shown
    // (default); a non-empty list hides features whose raw `vg` (the tile property,
    // already baked) is in the off-set and shows everything else — so any new
    // catalogue group defaults visible. Features without a `vg` always show. Matches
    // the host's `viewingGroupsOff` model.
    viewing_groups_off: ?[]const i32 = null,

    // -- date-dependent display (S-52 §10.4.1.1) --
    date_dependent: bool = true,
    highlight_date_dependent: bool = false,
    date_view: []const u8 = "", // pinned viewing date "YYYYMMDD" (empty = today)

    // -- SCAMIN gating override (host ?ignoreScamin debug toggle) — NOT an S-52
    // display setting; a render-time transport flag the C ABI carries through to
    // the style builder. When true, the style drops SCAMIN scale-gating so every
    // feature shows in-band regardless of its 1:N min-display-scale. Default off.
    ignore_scamin: bool = false,

    // -- gate SCAMIN with a live client-driven filter instead of per-value bucket
    // layers — NOT an S-52 display setting; a render-time transport flag the C ABI
    // carries to the style builder. When true, the style emits one
    // *_scamin layer per render-type (no minzoom buckets) and the client rewrites the
    // SCAMIN clause on boundary crossings. Default off = per-value buckets.
    scamin_filter_gate: bool = false,

    // -- physical-scale multiplier (host §4 _featureSizeScale) — NOT an S-52 setting;
    // a render-time transport flag applied to icon-size / line-width / text-size so
    // the host can match TRUE physical size from its calibrated CSS-pixel pitch.
    // 1.0 = catalogue sizes verbatim (byte-identical output).
    size_scale: f64 = 1.0,

    // -- per-category size multipliers (NOT S-52 settings) — an extra factor ON TOP
    // of size_scale for TEXT labels / SOUNDINGS only, so a mariner can enlarge just
    // those for legibility. Folded into the same device scale that sizes the glyph
    // AND its declutter box (and, for a sounding, the per-digit spacing), so the
    // enlarged mark still collides correctly — the thing that scales it is the thing
    // that declutters it. 1.0 = no extra scale (byte-identical output).
    text_size_scale: f64 = 1.0,
    sounding_size_scale: f64 = 1.0,
};

// ---- expression DSL ---------------------------------------------------------

// nlohmann dumps a double with a decimal point always (10.0, not 10); Zig's {d}
// gives the shortest round-trip without a trailing ".0". Append ".0" when the
// shortest form looks like an integer, so the emitted numbers match the C++ output
// byte-for-byte. (inf/nan don't occur for contour/depth values.)
fn fmtFloat(a: std.mem.Allocator, x: f64) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{d}", .{x});
    for (s) |c| switch (c) {
        '.', 'e', 'E', 'n', 'i' => return s, // already a float / inf / nan form
        else => {},
    };
    return std.fmt.allocPrint(a, "{s}.0", .{s});
}

// Small builder over an arena: every helper allocates its Value nodes here.
pub const B = struct {
    a: std.mem.Allocator,

    fn s(_: B, str: []const u8) Value {
        return .{ .string = str };
    }
    fn int(_: B, n: i64) Value {
        return .{ .integer = n };
    }
    fn boolean(_: B, v: bool) Value {
        return .{ .bool = v };
    }
    fn flt(b: B, x: f64) !Value {
        return .{ .number_string = try fmtFloat(b.a, x) };
    }
    fn arr(b: B, items: []const Value) !Value {
        var list = Array.init(b.a);
        try list.appendSlice(items);
        return .{ .array = list };
    }
    fn get(b: B, prop: []const u8) !Value {
        return b.arr(&.{ b.s("get"), b.s(prop) });
    }
    fn coalesce(b: B, expr: Value, fallback: Value) !Value {
        return b.arr(&.{ b.s("coalesce"), expr, fallback });
    }
};

// ---- colour resolution ------------------------------------------------------

fn lessStr(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

// Resolve a colour-token-valued expression to an RGB for the active scheme:
// ["match", tokenExpr, TOK,hex, …(sorted), fallback]. Palette keys are emitted in
// sorted order to mirror nlohmann's std::map iteration (byte-equal arms).
pub fn colorMatch(b: B, tokenExpr: Value, palette: *const ObjectMap, fallback: []const u8) !Value {
    var list = Array.init(b.a);
    try list.append(b.s("match"));
    try list.append(tokenExpr);
    const keys = try b.a.dupe([]const u8, palette.keys());
    std.mem.sort([]const u8, keys, {}, lessStr);
    for (keys) |k| {
        try list.append(b.s(k));
        try list.append(palette.get(k).?);
    }
    try list.append(b.s(fallback));
    return .{ .array = list };
}

// Fill colour for a colour token that may carry a ",<alpha>" suffix — S-101 ColorFill
// emits "TOKEN,alpha" (e.g. TRFCF,0.75 traffic-separation zones; CHGRF,0.5; NODTA,0.5).
// Match the palette on the BASE token (else "TRFCF,0.75" != "TRFCF" -> opaque fallback)
// and fold the alpha into an rgba fill-colour (fill-opacity isn't data-driven in
// MapLibre; fill-color is). A token with no comma is matched whole (no regression).
// Mirrors the web colorTokenFill (s52-style.mjs).
pub fn colorTokenFill(b: B, prop: []const u8, palette: *const ObjectMap) !Value {
    const ct = try b.coalesce(try b.get(prop), b.s(""));
    const var_ct = try b.arr(&.{ b.s("var"), b.s("ct") });
    const var_ci = try b.arr(&.{ b.s("var"), b.s("ci") });
    const var_c = try b.arr(&.{ b.s("var"), b.s("c") });
    const ci_expr = try b.arr(&.{ b.s("index-of"), b.s(","), var_ct });
    // no comma -> match the whole token (to-color unifies the case branch types)
    const no_alpha = try b.arr(&.{ b.s("to-color"), try colorMatch(b, var_ct, palette, FALLBACK) });
    // comma -> match the base token, fold the numeric suffix into rgba alpha
    const base = try b.arr(&.{ b.s("slice"), var_ct, b.int(0), var_ci });
    const c_color = try b.arr(&.{ b.s("to-color"), try colorMatch(b, base, palette, FALLBACK) });
    const r = try b.arr(&.{ b.s("at"), b.int(0), try b.arr(&.{ b.s("to-rgba"), var_c }) });
    const g = try b.arr(&.{ b.s("at"), b.int(1), try b.arr(&.{ b.s("to-rgba"), var_c }) });
    const bl = try b.arr(&.{ b.s("at"), b.int(2), try b.arr(&.{ b.s("to-rgba"), var_c }) });
    const ci1 = try b.arr(&.{ b.s("+"), var_ci, b.int(1) });
    const alpha = try b.arr(&.{ b.s("to-number"), try b.arr(&.{ b.s("slice"), var_ct, ci1 }) });
    const rgba = try b.arr(&.{ b.s("rgba"), r, g, bl, alpha });
    const alpha_branch = try b.arr(&.{ b.s("let"), b.s("c"), c_color, rgba });
    const lt0 = try b.arr(&.{ b.s("<"), var_ci, b.int(0) });
    const case_expr = try b.arr(&.{ b.s("case"), lt0, no_alpha, alpha_branch });
    // NEST the lets: the inner "ci" binding references var "ct" from the OUTER let's
    // scope. MapLibre forbids a binding from referencing a SIBLING binding — a flat
    // ["let","ct",..,"ci",<uses var ct>,..] fails at runtime with "Unknown variable ct".
    const inner = try b.arr(&.{ b.s("let"), b.s("ci"), ci_expr, case_expr });
    return b.arr(&.{ b.s("let"), b.s("ct"), ct, inner });
}

// A single resolved colour token for the scheme (concrete value).
pub fn token(palette: *const ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    if (palette.get(name)) |v| if (v == .string) return v.string;
    return fallback;
}

pub fn lineColor(b: B, palette: *const ObjectMap) !Value {
    return colorMatch(b, try b.coalesce(try b.get("color_token"), b.s("")), palette, FALLBACK);
}

// Text ink. Day uses the per-feature S-52 ink; dusk/night use a bright neutral.
pub fn textColor(b: B, scheme: Scheme, palette: *const ObjectMap) !Value {
    if (scheme == .day)
        return colorMatch(b, try b.coalesce(try b.get("color_token"), b.s("")), palette, "#000000");
    return b.s(if (scheme == .night) "#aab7bf" else "#dde7ec");
}

pub fn textHaloColor(b: B, scheme: Scheme) Value {
    return b.s(if (scheme == .day) "rgba(255,255,255,0.9)" else "rgba(0,0,0,0.85)");
}

// Contour (depth) labels: CHGRD by day, bright neutral at dusk/night.
pub fn contourLabelColor(b: B, scheme: Scheme, palette: *const ObjectMap) !Value {
    if (scheme == .day) return b.s(token(palette, "CHGRD", "#5a5a44"));
    return b.s(if (scheme == .night) "#aab7bf" else "#dde7ec");
}

// ---- depth shading (SEABED01) ----------------------------------------------

// DRVAL1/DRVAL2 vs the mariner's contours -> a depth colour token. Deepest band
// first (first match in a `case` wins). `>= X && > X` on both bounds per spec.
pub fn seabedTokenExpr(b: B, m: *const Settings) !Value {
    const d1 = try b.coalesce(try b.get("drval1"), b.int(-1));
    const d2 = try b.coalesce(try b.get("drval2"), b.int(0));
    const band = struct {
        fn make(bb: B, dd1: Value, dd2: Value, x: f64) !Value {
            const ge = try bb.arr(&.{ bb.s(">="), dd1, try bb.flt(x) });
            const gt = try bb.arr(&.{ bb.s(">"), dd2, try bb.flt(x) });
            return bb.arr(&.{ bb.s("all"), ge, gt });
        }
    }.make;
    if (!m.four_shade_water) {
        return b.arr(&.{
            b.s("case"),
            try band(b, d1, d2, m.safety_contour),
            b.s("DEPDW"),
            try band(b, d1, d2, 0.0),
            b.s("DEPVS"),
            b.s("DEPIT"),
        });
    }
    return b.arr(&.{
        b.s("case"),
        try band(b, d1, d2, m.deep_contour),
        b.s("DEPDW"),
        try band(b, d1, d2, m.safety_contour),
        b.s("DEPMD"),
        try band(b, d1, d2, m.shallow_contour),
        b.s("DEPMS"),
        try band(b, d1, d2, 0.0),
        b.s("DEPVS"),
        b.s("DEPIT"),
    });
}

// Fill colour for the `areas` layer: depth areas (carry drval1) shade live via
// SEABED01; everything else uses its baked colour token.
pub fn areasFillColor(b: B, palette: *const ObjectMap, m: *const Settings) !Value {
    return b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("has"), b.s("drval1") }),
        try colorMatch(b, try seabedTokenExpr(b, m), palette, FALLBACK),
        try colorTokenFill(b, "color_token", palette),
    });
}

// ---- icon / label image expressions ----------------------------------------

// SNDFRM04: a sounding <= the live safety depth uses the bold SOUNDS glyphs, else
// the faint SOUNDG glyphs. The safety split compares the raw metres `depth` (S-52
// metres); when the mariner selects feet, the displayed digits come from the baked
// whole-feet glyph variant (sym_s_ft/sym_g_ft) instead — a recreational unit option,
// not ECDIS (see scene.appendSoundingProps), mirroring contourLabelField.
pub fn soundingsIconImage(b: B, m: *const Settings) !Value {
    const ss = if (m.depth_unit == .feet) "sym_s_ft" else "sym_s";
    const sg = if (m.depth_unit == .feet) "sym_g_ft" else "sym_g";
    const depthLE = try b.arr(&.{ b.s("<="), try b.coalesce(try b.get("depth"), b.int(0)), try b.flt(m.safety_depth) });
    return b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("has"), b.s(ss) }),
        try b.arr(&.{ b.s("case"), depthLE, try b.get(ss), try b.get(sg) }),
        try b.get("symbol_names"),
    });
}

// OBSTRN06/WRECKS05: a danger symbol deeper than the live safety contour swaps to
// the less-prominent DANGER02 (sym_deep). pivot_center draws the "ctr:" variant.
pub fn pointSymbolImage(b: B, m: *const Settings) !Value {
    const name = try b.arr(&.{
        b.s("case"),
        try b.arr(&.{
            b.s("all"),
            try b.arr(&.{ b.s("has"), b.s("sym_deep") }),
            try b.arr(&.{ b.s(">"), try b.coalesce(try b.get("danger_depth"), b.int(0)), try b.flt(m.safety_contour) }),
        }),
        try b.get("sym_deep"),
        try b.get("symbol_name"),
    });
    return b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("=="), try b.coalesce(try b.get("pivot_center"), b.int(0)), b.int(1) }),
        try b.arr(&.{ b.s("concat"), b.s("ctr:"), name }),
        name,
    });
}

// SAFCON01: the depth-contour value label. Metres are whole (valdco is whole metres);
// feet is a CONVERSION shown as WHOLE feet, TRUNCATED down (floor(x)) — never rounded
// up. A 2 m contour reads "6" ft (6.56 truncated), not "6.5" or "7": a depth always
// errs shallow (toward the surface), the safe direction, matching SNDFRM04's whole-feet
// truncation.
pub fn contourLabelField(b: B, m: *const Settings) !Value {
    const v = if (m.depth_unit == .feet)
        try b.arr(&.{ b.s("floor"), try b.arr(&.{ b.s("*"), try b.get("valdco"), try b.flt(M_TO_FT) }) })
    else
        try b.arr(&.{ b.s("round"), try b.get("valdco") });
    return b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("has"), b.s("valdco") }),
        try b.arr(&.{ b.s("to-string"), v }),
        b.s(""),
    });
}

// ---- client-side display filters -------------------------------------------

// Display category (S-52 §10.3.4) + M_QUAL data-quality overlay.
pub fn categoryFilter(b: B, m: *const Settings) !Value {
    var en = Array.init(b.a);
    if (m.display_base) try en.append(b.int(0));
    if (m.display_standard) try en.append(b.int(1));
    if (m.display_other) try en.append(b.int(2));
    const isoCat: i64 = if (m.show_isolated_dangers_shallow) 1 else 0;
    const cat = try b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("=="), try b.get("symbol_name"), b.s("ISODGR01") }),
        b.int(isoCat),
        try b.coalesce(try b.get("cat"), b.int(1)),
    });
    const inCat = try b.arr(&.{ b.s("in"), cat, try b.arr(&.{ b.s("literal"), .{ .array = en } }) });
    const isQual = try b.arr(&.{ b.s("=="), try b.get("class"), b.s("M_QUAL") });
    if (m.data_quality)
        return b.arr(&.{ b.s("any"), isQual, try b.arr(&.{ b.s("all"), inCat, try b.arr(&.{ b.s("!"), isQual }) }) });
    return b.arr(&.{ b.s("all"), inCat, try b.arr(&.{ b.s("!"), isQual }) });
}

// NOAA band visibility: show a feature only if its baked `band` rank is enabled.
pub fn bandFilter(b: B, enabled: []const i32) !Value {
    var en = Array.init(b.a);
    for (enabled) |r| try en.append(b.int(r));
    return b.arr(&.{ b.s("in"), try b.coalesce(try b.get("band"), b.int(0)), try b.arr(&.{ b.s("literal"), .{ .array = en } }) });
}

// Boundary symbolization (S-52 §8.6.1): show common (2) + the active style.
pub fn boundaryFilter(b: B, m: *const Settings) !Value {
    const rank: i64 = if (m.boundary_style == .plain) 0 else 1;
    return b.arr(&.{
        b.s("in"),
        try b.coalesce(try b.get("bnd"), b.int(2)),
        try b.arr(&.{ b.s("literal"), try b.arr(&.{ b.int(2), b.int(rank) }) }),
    });
}

// Point-symbol style (S-52 §11.2.2): show common (2) + the active style.
pub fn pointStyleFilter(b: B, m: *const Settings) !Value {
    const rank: i64 = if (m.simplified_points) 1 else 0;
    return b.arr(&.{
        b.s("in"),
        try b.coalesce(try b.get("pts"), b.int(2)),
        try b.arr(&.{ b.s("literal"), try b.arr(&.{ b.int(2), b.int(rank) }) }),
    });
}

// S-52 §14.5 text-group selection. Important text (11) is always on.
pub fn textGroupFilter(b: B, m: *const Settings) !Value {
    const g = try b.coalesce(try b.get("tgrp"), b.int(-1));
    const namedSet = struct {
        fn make(bb: B) !Value {
            return bb.arr(&.{ bb.int(21), bb.int(26), bb.int(29) });
        }
    }.make;
    var any = Array.init(b.a);
    try any.append(b.s("any"));
    try any.append(try b.arr(&.{ b.s("=="), g, b.int(11) })); // important — always on
    if (m.text_names)
        try any.append(try b.arr(&.{ b.s("match"), g, try namedSet(b), b.boolean(true), b.boolean(false) }));
    if (m.show_light_descriptions)
        try any.append(try b.arr(&.{ b.s("=="), g, b.int(23) }));
    if (m.text_other)
        try any.append(try b.arr(&.{
            b.s("all"),
            try b.arr(&.{ b.s("!="), g, b.int(11) }),
            try b.arr(&.{ b.s("!="), g, b.int(23) }),
            try b.arr(&.{ b.s("match"), g, try namedSet(b), b.boolean(false), b.boolean(true) }),
        }));
    return .{ .array = any };
}

// S-52 §14.5 fine-grained viewing-group selection — a DENY-LIST (the host's
// `viewingGroupsOff` model). null/empty off-set =>
// no filter (every group shown). Otherwise a feature shows iff it has no `vg`
// (unbanded — always shown) OR its `vg` is NOT in the off-set, so any group the
// host didn't list stays visible. Byte-identical to the host's s52-style.mjs
// expression, so whichever backend builds the style produces the same filter.
pub fn viewingGroupFilter(b: B, m: *const Settings) !?Value {
    const off = m.viewing_groups_off orelse return null;
    if (off.len == 0) return null;
    var en = Array.init(b.a);
    for (off) |v| try en.append(b.int(v));
    return try b.arr(&.{
        b.s("any"),
        try b.arr(&.{ b.s("!"), try b.arr(&.{ b.s("has"), b.s("vg") }) }),
        try b.arr(&.{ b.s("!"), try b.arr(&.{ b.s("in"), try b.get("vg"), try b.arr(&.{ b.s("literal"), .{ .array = en } }) }) }),
    });
}

// Date-dependent display (S-52 §10.4.1.1). `today` is "YYYYMMDD".
pub fn dateFilter(b: B, today_str: []const u8) !Value {
    const mmdd = if (today_str.len >= 8) today_str[4..] else today_str;
    const T = try b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("=="), try b.coalesce(try b.get("date_recurring"), b.int(0)), b.int(1) }),
        b.s(mmdd),
        b.s(today_str),
    });
    const varT = try b.arr(&.{ b.s("var"), b.s("T") });
    const varS = try b.arr(&.{ b.s("var"), b.s("S") });
    const varE = try b.arr(&.{ b.s("var"), b.s("E") });
    const hasS = try b.arr(&.{ b.s("has"), b.s("date_start") });
    const hasE = try b.arr(&.{ b.s("has"), b.s("date_end") });
    const geTS = try b.arr(&.{ b.s(">="), varT, varS });
    const leTE = try b.arr(&.{ b.s("<="), varT, varE });
    const inRange = try b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("<="), varS, varE }),
        try b.arr(&.{ b.s("all"), geTS, leTE }),
        try b.arr(&.{ b.s("any"), geTS, leTE }),
    });
    const body = try b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("all"), hasS, hasE }),
        inRange,
        hasS,
        geTS,
        hasE,
        leTE,
        b.boolean(true),
    });
    const letExpr = try b.arr(&.{
        b.s("let"),
        b.s("T"),
        T,
        b.s("S"),
        try b.coalesce(try b.get("date_start"), b.s("")),
        b.s("E"),
        try b.coalesce(try b.get("date_end"), b.s("")),
        body,
    });
    return b.arr(&.{
        b.s("any"),
        try b.arr(&.{ b.s("!"), try b.arr(&.{ b.s("has"), b.s("date_recurring") }) }),
        letExpr,
    });
}

// The viewing date "YYYYMMDD": the mariner's pinned date if set, else `now_unix`
// (Unix epoch seconds, supplied by the host) rendered as a UTC calendar date.
pub fn viewingDate(b: B, m: *const Settings, now_unix: i64) ![]const u8 {
    if (m.date_view.len == 8) {
        var digits = true;
        for (m.date_view) |c| digits = digits and (c >= '0' and c <= '9');
        if (digits) return m.date_view;
    }
    // C++ uses localtime; Zig 0.16 keeps wall-clock behind Io and this module is
    // pure, so the host injects the epoch seconds and this renders them as UTC. A
    // date-boundary day off at worst, only when the mariner hasn't pinned a date.
    const secs: u64 = @intCast(@max(now_unix, 0));
    const eday = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = eday.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(b.a, "{d:0>4}{d:0>2}{d:0>2}", .{ yd.year, md.month.numeric(), @as(u32, md.day_index) + 1 });
}

// The S-52 display filters AND-ed onto EVERY source:"chart" layer (category +
// M_QUAL, band, boundary/point style, INFORM01/CHDATD01 callout toggles, date
// validity, meta-bounds). Text-group selection is per-text-layer (textGroupFilter),
// so it is NOT included here. Used by the single-pass style builder (style.zig) to
// compose each layer's filter inline — the consolidation that retired buildStyle's
// template-patch pass. Allocated in `a` (caller's arena).
pub fn commonChartFilters(a: std.mem.Allocator, m: *const Settings, enabled_bands: ?[]const i32, now_unix: i64) ![]Value {
    const b = B{ .a = a };
    var clauses = Array.init(a);
    try clauses.append(try categoryFilter(b, m));
    if (enabled_bands) |eb| try clauses.append(try bandFilter(b, eb));
    try clauses.append(try boundaryFilter(b, m));
    try clauses.append(try pointStyleFilter(b, m));
    if (try viewingGroupFilter(b, m)) |vgf| try clauses.append(vgf); // §14.5 (future use; no-op when null)
    if (!m.show_inform_callouts)
        try clauses.append(try b.arr(&.{ b.s("!="), try b.coalesce(try b.get("symbol_name"), b.s("")), b.s("INFORM01") }));
    if (!m.highlight_date_dependent)
        try clauses.append(try b.arr(&.{ b.s("!="), try b.coalesce(try b.get("symbol_name"), b.s("")), b.s("CHDATD01") }));
    if (m.date_dependent)
        try clauses.append(try dateFilter(b, try viewingDate(b, m, now_unix)));
    if (!m.show_meta_bounds)
        try clauses.append(try b.arr(&.{
            b.s("!"),
            try b.arr(&.{
                b.s("in"),
                try b.coalesce(try b.get("class"), b.s("")),
                try b.arr(&.{ b.s("literal"), try b.arr(&.{ b.s("M_NPUB"), b.s("M_NSYS"), b.s("M_COVR"), b.s("M_CSCL") }) }),
            }),
        }));
    return clauses.items;
}
