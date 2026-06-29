//! chartstyle — MapLibre chart-style generation, client-side. A faithful 1:1 Zig
//! port of the C++ chartstyle/ module (chart_style.cpp + mariner.hpp), which is
//! itself a port of the Go web client's s52-style.mjs builders.
//!
//! It PATCHES the mariner-driven parts of a MapLibre style template rather than
//! regenerating the whole style: SEABED01 depth shading, the sounding bold/faint
//! split (SNDFRM04), the danger-symbol safety swap (OBSTRN06/WRECKS05), contour
//! label units (SAFCON01), the per-scheme recolour (background/fills/lines/text +
//! halos/contour labels), and the client-side display filters AND-ed onto every
//! `source:"chart"` layer (category + M_QUAL, band, boundary/point style, INFORM01/
//! CHDATD01 callout toggles, date validity, meta-bounds, text groups).
//!
//! Pure Zig (no libc): the host reads the template + colortables bytes and passes
//! them in; the C ABI wrapper lives in capi.zig. std.json.Value uses an
//! insertion-ordered ObjectMap, so the patched style keeps the template's key
//! order (the C++/nlohmann build alphabetises keys via std::map — semantically
//! identical, just a different serialisation). Colour `match` arms ARE emitted in
//! sorted-token order to mirror nlohmann's palette iteration, so they're byte-equal
//! to the C++ output. See ../../../chartstyle/src/chart_style.cpp for the oracle.

const std = @import("std");

const Value = std.json.Value;
const Array = std.json.Array;
const ObjectMap = std.json.ObjectMap;

const M_TO_FT: f64 = 3.280839895;
const FALLBACK = "#ff00ff";

// ---- public model (mirrors chartstyle/include/chartstyle/mariner.hpp) -------

pub const Scheme = enum(c_int) { day = 0, dusk = 1, night = 2 };
pub const DepthUnit = enum(c_int) { meters = 0, feet = 1 };
pub const BoundaryStyle = enum(c_int) { symbolized = 0, plain = 1 }; // S-52 §8.6.1

/// The S-52 mariner display options. Defaults match mariner.hpp (the Go web
/// client's defaults).
pub const MarinerSettings = struct {
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

    // -- overlays / opt-in markers (off by default) --
    data_quality: bool = false,
    show_inform_callouts: bool = false,
    show_meta_bounds: bool = false,
    show_isolated_dangers_shallow: bool = false,

    // -- symbolization style --
    boundary_style: BoundaryStyle = .symbolized,
    simplified_points: bool = false,
    show_full_sector_lines: bool = false,

    // -- text groups (S-52 §14.5) --
    text_names: bool = true,
    show_light_descriptions: bool = true,
    text_other: bool = true,

    // -- viewing groups (S-52 §14.5, fine-grained per-VG control) — FUTURE USE.
    // null = every viewing group shown (current behaviour); a non-null list = show
    // only features whose raw `vg` (the tile property, already baked) is selected.
    // Features without a `vg` always show. No client UI wired yet — the style hook
    // exists so per-viewing-group filtering can be turned on without an engine change.
    viewing_groups: ?[]const i32 = null,

    // -- date-dependent display (S-52 §10.4.1.1) --
    date_dependent: bool = true,
    highlight_date_dependent: bool = false,
    date_view: []const u8 = "", // pinned viewing date "YYYYMMDD" (empty = today)
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
pub fn seabedTokenExpr(b: B, m: *const MarinerSettings) !Value {
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
            try band(b, d1, d2, m.safety_contour), b.s("DEPDW"),
            try band(b, d1, d2, 0.0),              b.s("DEPVS"),
            b.s("DEPIT"),
        });
    }
    return b.arr(&.{
        b.s("case"),
        try band(b, d1, d2, m.deep_contour),    b.s("DEPDW"),
        try band(b, d1, d2, m.safety_contour),  b.s("DEPMD"),
        try band(b, d1, d2, m.shallow_contour), b.s("DEPMS"),
        try band(b, d1, d2, 0.0),               b.s("DEPVS"),
        b.s("DEPIT"),
    });
}

// Fill colour for the `areas` layer: depth areas (carry drval1) shade live via
// SEABED01; everything else uses its baked colour token.
pub fn areasFillColor(b: B, palette: *const ObjectMap, m: *const MarinerSettings) !Value {
    return b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("has"), b.s("drval1") }),
        try colorMatch(b, try seabedTokenExpr(b, m), palette, FALLBACK),
        try colorMatch(b, try b.coalesce(try b.get("color_token"), b.s("")), palette, FALLBACK),
    });
}

// ---- icon / label image expressions ----------------------------------------

// SNDFRM04: a sounding <= the live safety depth uses the bold SOUNDS glyphs, else
// the faint SOUNDG glyphs.
pub fn soundingsIconImage(b: B, m: *const MarinerSettings) !Value {
    const depthLE = try b.arr(&.{ b.s("<="), try b.coalesce(try b.get("depth"), b.int(0)), try b.flt(m.safety_depth) });
    return b.arr(&.{
        b.s("case"),
        try b.arr(&.{ b.s("has"), b.s("sym_s") }),
        try b.arr(&.{ b.s("case"), depthLE, try b.get("sym_s"), try b.get("sym_g") }),
        try b.get("symbol_names"),
    });
}

// OBSTRN06/WRECKS05: a danger symbol deeper than the live safety contour swaps to
// the less-prominent DANGER02 (sym_deep). pivot_center draws the "ctr:" variant.
pub fn pointSymbolImage(b: B, m: *const MarinerSettings) !Value {
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

// SAFCON01: the depth-contour value label, in whole metres or whole feet.
pub fn contourLabelField(b: B, m: *const MarinerSettings) !Value {
    const v = if (m.depth_unit == .feet)
        try b.arr(&.{ b.s("round"), try b.arr(&.{ b.s("*"), try b.get("valdco"), try b.flt(M_TO_FT) }) })
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
pub fn categoryFilter(b: B, m: *const MarinerSettings) !Value {
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
pub fn boundaryFilter(b: B, m: *const MarinerSettings) !Value {
    const rank: i64 = if (m.boundary_style == .plain) 0 else 1;
    return b.arr(&.{
        b.s("in"),
        try b.coalesce(try b.get("bnd"), b.int(2)),
        try b.arr(&.{ b.s("literal"), try b.arr(&.{ b.int(2), b.int(rank) }) }),
    });
}

// Point-symbol style (S-52 §11.2.2): show common (2) + the active style.
pub fn pointStyleFilter(b: B, m: *const MarinerSettings) !Value {
    const rank: i64 = if (m.simplified_points) 1 else 0;
    return b.arr(&.{
        b.s("in"),
        try b.coalesce(try b.get("pts"), b.int(2)),
        try b.arr(&.{ b.s("literal"), try b.arr(&.{ b.int(2), b.int(rank) }) }),
    });
}

// S-52 §14.5 text-group selection. Important text (11) is always on.
pub fn textGroupFilter(b: B, m: *const MarinerSettings) !Value {
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

// S-52 §14.5 fine-grained viewing-group selection (FUTURE USE). null when the
// mariner selects all viewing groups (no filter). When a set is given, a feature
// shows iff it has no `vg` (unbanded — always shown) or its `vg` is in the set.
pub fn viewingGroupFilter(b: B, m: *const MarinerSettings) !?Value {
    const sel = m.viewing_groups orelse return null;
    var en = Array.init(b.a);
    for (sel) |v| try en.append(b.int(v));
    return try b.arr(&.{
        b.s("any"),
        try b.arr(&.{ b.s("!"), try b.arr(&.{ b.s("has"), b.s("vg") }) }),
        try b.arr(&.{ b.s("in"), try b.get("vg"), try b.arr(&.{ b.s("literal"), .{ .array = en } }) }),
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
        try b.arr(&.{ b.s("all"), hasS, hasE }), inRange,
        hasS, geTS,
        hasE, leTE,
        b.boolean(true),
    });
    const letExpr = try b.arr(&.{
        b.s("let"),
        b.s("T"), T,
        b.s("S"), try b.coalesce(try b.get("date_start"), b.s("")),
        b.s("E"), try b.coalesce(try b.get("date_end"), b.s("")),
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
pub fn viewingDate(b: B, m: *const MarinerSettings, now_unix: i64) ![]const u8 {
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
pub fn commonChartFilters(a: std.mem.Allocator, m: *const MarinerSettings, enabled_bands: ?[]const i32, now_unix: i64) ![]Value {
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

// ---- layer patching ---------------------------------------------------------

fn isId(L: *const Value, ids: []const []const u8) bool {
    const idv = L.object.get("id") orelse return false;
    if (idv != .string) return false;
    for (ids) |w| if (std.mem.eql(u8, idv.string, w)) return true;
    return false;
}

// Get (creating if absent) the named sub-object ("paint"/"layout") of a layer.
fn objField(b: B, L: *Value, field: []const u8) !*Value {
    if (L.object.getPtr(field)) |p| {
        if (p.* != .object) p.* = .{ .object = .empty };
        return p;
    }
    try L.object.put(b.a, field, .{ .object = .empty });
    return L.object.getPtr(field).?;
}

fn setSub(b: B, L: *Value, field: []const u8, key: []const u8, v: Value) !void {
    const p = try objField(b, L, field);
    try p.object.put(b.a, key, v);
}

// True when the layer has paint.<key>.
fn paintHas(L: *const Value, key: []const u8) bool {
    if (L.object.get("paint")) |p| if (p == .object) return p.object.get(key) != null;
    return false;
}

fn layerSourceIs(L: *const Value, name: []const u8) bool {
    const sv = L.object.get("source") orelse return false;
    return sv == .string and std.mem.eql(u8, sv.string, name);
}

// AND extra clauses into a layer's existing filter (clauses first, base last).
fn andInto(b: B, L: *Value, clauses: []const Value) !void {
    var all = Array.init(b.a);
    try all.append(b.s("all"));
    for (clauses) |c| try all.append(c);
    if (L.object.get("filter")) |existing| try all.append(existing);
    try L.object.put(b.a, "filter", .{ .array = all });
}

/// Build a MapLibre style JSON from a template + mariner settings + S-52
/// colortables. `enabled_bands` null = no band filter (show all); else only
/// features whose `band` rank is in the slice are shown. `now_unix` is the host's
/// current time (Unix epoch seconds), used only to resolve "today" when the
/// mariner hasn't pinned a date. On parse failure returns the template unchanged.
/// Returns `out_alloc`-owned bytes.
pub fn buildStyle(
    out_alloc: std.mem.Allocator,
    template_json: []const u8,
    m: *const MarinerSettings,
    colortables_json: []const u8,
    enabled_bands: ?[]const i32,
    now_unix: i64,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(out_alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const b = B{ .a = a };

    var style = std.json.parseFromSliceLeaky(Value, a, template_json, .{}) catch
        return out_alloc.dupe(u8, template_json);
    var cts: Value = .{ .object = .empty };
    if (colortables_json.len != 0)
        cts = std.json.parseFromSliceLeaky(Value, a, colortables_json, .{}) catch
            return out_alloc.dupe(u8, template_json);

    if (style != .object) return out_alloc.dupe(u8, template_json);
    const layers = style.object.getPtr("layers") orelse return out_alloc.dupe(u8, template_json);
    if (layers.* != .array) return out_alloc.dupe(u8, template_json);

    const scheme_key = switch (m.scheme) {
        .night => "night",
        .dusk => "dusk",
        .day => "day",
    };
    var empty: ObjectMap = .empty;
    const palette: *const ObjectMap = blk: {
        if (cts == .object) if (cts.object.getPtr(scheme_key)) |pv| {
            if (pv.* == .object) break :blk &pv.object;
        };
        break :blk &empty;
    };
    const palette_empty = palette.count() == 0;

    for (layers.array.items) |*L| {
        if (L.* != .object) continue;

        // -- colour scheme: regenerate every palette-driven colour. Only when a
        // palette is available, else keep the template's baked colours. --
        if (!palette_empty) {
            const is_contour_label = isId(L, &.{ "contour-labels-lines", "contour-labels-lines_scamin" });
            if (isId(L, &.{"background"}))
                try setSub(b, L, "paint", "background-color", b.s(token(palette, "DEPDW", "#c9edff")));
            if (isId(L, &.{ "fill-areas", "fill-areas_scamin" }))
                try setSub(b, L, "paint", "fill-color", try areasFillColor(b, palette, m));
            if (paintHas(L, "line-color"))
                try setSub(b, L, "paint", "line-color", try lineColor(b, palette));
            if (paintHas(L, "text-color"))
                try setSub(b, L, "paint", "text-color", if (is_contour_label)
                    try contourLabelColor(b, m.scheme, palette)
                else
                    try textColor(b, m.scheme, palette));
            if (paintHas(L, "text-halo-color"))
                try setSub(b, L, "paint", "text-halo-color", textHaloColor(b, m.scheme));
        }
        if (isId(L, &.{"soundings"}))
            try setSub(b, L, "layout", "icon-image", try soundingsIconImage(b, m));
        if (isId(L, &.{ "point_symbols", "point_symbols_scamin", "point_symbols-north", "point_symbols_scamin-north" }))
            try setSub(b, L, "layout", "icon-image", try pointSymbolImage(b, m));
        if (isId(L, &.{ "contour-labels-lines", "contour-labels-lines_scamin" }))
            try setSub(b, L, "layout", "text-field", try contourLabelField(b, m));

        // -- client-side display portrayal, AND-ed onto each chart-source layer --
        if (layerSourceIs(L, "chart")) {
            var clauses = Array.init(a);
            try clauses.append(try categoryFilter(b, m));
            if (enabled_bands) |eb| try clauses.append(try bandFilter(b, eb));
            try clauses.append(try boundaryFilter(b, m));
            try clauses.append(try pointStyleFilter(b, m));
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
            if (isId(L, &.{ "text", "light-text", "text-scamin", "light-text-scamin" }))
                try clauses.append(try textGroupFilter(b, m));
            try andInto(b, L, clauses.items);
        }
    }

    var aw: std.Io.Writer.Allocating = .init(out_alloc);
    errdefer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    try js.write(style);
    return aw.toOwnedSlice();
}

// ---- tests ------------------------------------------------------------------

const test_template =
    \\{"version":8,"sources":{"chart":{"type":"vector","url":"pmtiles://x"}},"layers":[
    \\{"id":"background","type":"background","paint":{"background-color":"#000"}},
    \\{"id":"fill-areas","type":"fill","source":"chart","source-layer":"areas","paint":{"fill-color":"#111"}},
    \\{"id":"lines-solid","type":"line","source":"chart","source-layer":"lines","paint":{"line-color":"#222","line-width":1},"filter":["==","dash","solid"]},
    \\{"id":"contour-labels-lines","type":"symbol","source":"chart","source-layer":"lines","layout":{"text-field":"x"},"paint":{"text-color":"#333","text-halo-color":"#fff"}},
    \\{"id":"soundings","type":"symbol","source":"soundings","layout":{"icon-image":"x"}},
    \\{"id":"point_symbols","type":"symbol","source":"chart","source-layer":"point_symbols","layout":{"icon-image":"x"}},
    \\{"id":"text","type":"symbol","source":"chart","source-layer":"text","paint":{"text-color":"#444","text-halo-color":"#fff"}}
    \\]}
;

const test_colortables =
    \\{"day":{"DEPDW":"#c9edff","DEPMD":"#9bc4e0","DEPMS":"#6aa5cf","DEPVS":"#3a86bf","DEPIT":"#bfe6ff","CHGRD":"#5a5a44","CHBLK":"#000000"},"dusk":{"DEPDW":"#0a141e"},"night":{"DEPDW":"#050a0f"}}
;

test "buildStyle: defaults patch fill-color (SEABED case) + chart filter (category in)" {
    const a = std.testing.allocator;
    const m = MarinerSettings{};
    const out = try buildStyle(a, test_template, &m, test_colortables, null, 1700000000);
    defer a.free(out);

    var parsed = try std.json.parseFromSlice(Value, a, out, .{});
    defer parsed.deinit();
    const layers = parsed.value.object.get("layers").?.array.items;

    // fill-areas fill-color is a `case` whose SEABED arm is a `match` with DEPMD.
    var fill: ?Value = null;
    for (layers) |L| if (std.mem.eql(u8, L.object.get("id").?.string, "fill-areas")) {
        fill = L.object.get("paint").?.object.get("fill-color");
    };
    try std.testing.expect(fill != null);
    try std.testing.expectEqualStrings("case", fill.?.array.items[0].string);
    try std.testing.expect(std.mem.indexOf(u8, out, "DEPMD") != null);

    // A chart layer's filter contains the category `in` clause + ISODGR01 case.
    try std.testing.expect(std.mem.indexOf(u8, out, "ISODGR01") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "M_QUAL") != null);

    // Depth band edges emitted as floats (nlohmann-style ".0").
    try std.testing.expect(std.mem.indexOf(u8, out, "10.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "30.0") != null);
}

test "buildStyle: empty colortables keeps baked colours (no recolour)" {
    const a = std.testing.allocator;
    const m = MarinerSettings{};
    const out = try buildStyle(a, test_template, &m, "", null, 1700000000);
    defer a.free(out);
    // No palette -> background-color stays the template's baked value.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"#000\"") != null);
    // But chart filters are still applied (category clause is palette-independent).
    try std.testing.expect(std.mem.indexOf(u8, out, "ISODGR01") != null);
}

test "buildStyle: night scheme uses neutral text ink + dark halo" {
    const a = std.testing.allocator;
    const m = MarinerSettings{ .scheme = .night };
    const out = try buildStyle(a, test_template, &m, test_colortables, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#aab7bf") != null); // night text
    try std.testing.expect(std.mem.indexOf(u8, out, "rgba(0,0,0,0.85)") != null); // dark halo
}

test "buildStyle: bad template returned unchanged" {
    const a = std.testing.allocator;
    const m = MarinerSettings{};
    const bad = "{not json";
    const out = try buildStyle(a, bad, &m, test_colortables, null, 1700000000);
    defer a.free(out);
    try std.testing.expectEqualStrings(bad, out);
}

test "buildStyle: feet depth unit -> contour label uses M_TO_FT" {
    const a = std.testing.allocator;
    const m = MarinerSettings{ .depth_unit = .feet };
    const out = try buildStyle(a, test_template, &m, test_colortables, null, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "3.280839895") != null);
}

test "buildStyle: enabled bands add a band filter" {
    const a = std.testing.allocator;
    const m = MarinerSettings{};
    const bands = [_]i32{ 2, 3 };
    const out = try buildStyle(a, test_template, &m, test_colortables, &bands, 1700000000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"band\"") != null);
}

test "buildStyle: date resolution (pinned + today from now_unix)" {
    const a = std.testing.allocator;
    // Pinned date is used verbatim.
    const m1 = MarinerSettings{ .date_view = "20240115" };
    const o1 = try buildStyle(a, test_template, &m1, test_colortables, null, 1700000000);
    defer a.free(o1);
    try std.testing.expect(std.mem.indexOf(u8, o1, "20240115") != null);
    try std.testing.expect(std.mem.indexOf(u8, o1, "0115") != null); // recurring MMDD

    // Empty date -> today from now_unix (1700000000 = 2023-11-14 UTC).
    const m2 = MarinerSettings{};
    const o2 = try buildStyle(a, test_template, &m2, test_colortables, null, 1700000000);
    defer a.free(o2);
    try std.testing.expect(std.mem.indexOf(u8, o2, "20231114") != null);

    // date_dependent off -> no date_recurring clause at all.
    const m3 = MarinerSettings{ .date_dependent = false };
    const o3 = try buildStyle(a, test_template, &m3, test_colortables, null, 1700000000);
    defer a.free(o3);
    try std.testing.expect(std.mem.indexOf(u8, o3, "date_recurring") == null);
}
