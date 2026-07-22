//! S-101 drawing-instruction stream -> structured portrayal, for translation to
//! MVT. The S-101 rules emit a ';'-separated stream of `Key:Value` instructions
//! (e.g. `ColorFill:DEPMS;AreaFillReference:DIAMOND1;LineStyle:_simple_,,0.96,
//! CHGRD;LineInstruction:_simple_;PointInstruction:BCNCAR01`). This parses one
//! feature's stream into fills / patterns / lines / points / texts that
//! scene maps onto the chart's MVT layers (color_token, etc.).
//!
//! Mirrors internal/engine/portrayal/s101emit.go (the instruction interpreter).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// S-52 CHARS text weight/slant, mirrored (render/font.zig owns the face-picking
/// twins). s101 is below render in the module DAG, so it carries its own copy;
/// scene maps these onto render's `font.Weight`/`font.Slant` when building the
/// TextStyle. "Light" collapses to regular — no label sits below the readable floor.
pub const Weight = enum { regular, bold };
pub const Slant = enum { upright, italic };

pub const Line = struct { style: []const u8, width: f64, color: []const u8 };
pub const Point = struct { symbol: []const u8, rotation: f64, offset_x: f64, offset_y: f64, rot_north: bool = false };
pub const Text = struct {
    text: []const u8,
    color: []const u8,
    group: i64 = 0,
    // S-52 text-style modifiers (OpText), applied at the TextInstruction. font_size
    // is the FontSize px (0 => the emit default, 12, matching the oracle). halign /
    // valign are the resolved lowercase tile values the style's TEXT_ANCHOR keys on:
    // halign "left"|"center"|"right" (default "left"), valign "top"|"middle"|"bottom"
    // (default "bottom") — matching the oracle's hAlign/vAlign + halignName/valignName.
    font_size: f64 = 0,
    // S-101 FontWeight / FontSlant (OpText). The catalogue emits these on only a
    // handful of non-name labels (dredged-area depth in italics, magnetic-variation
    // in light); the geographic-name hierarchy comes from the tier resolver in
    // scene, which overrides these for name classes. Default regular/upright.
    weight: Weight = .regular,
    slant: Slant = .upright,
    halign: []const u8 = "left",
    valign: []const u8 = "bottom",
    // S-101 LocalOffset (mm, +x right / +y down): shifts the label off the feature's
    // pivot so a name doesn't overprint its symbol (e.g. PortrayFeatureName's
    // 0,-3.51 = one text-body up). Applied via the style's text-offset; combines
    // with the TextAlign anchor, as the S-52 model intends.
    offset_x: f64 = 0,
    offset_y: f64 = 0,
};

/// Map an S-100 Part 9 TextAlignHorizontal to the tile `halign`. The catalogue uses
/// Start / Center / End (LTR: left / center / right) — it never emits the literal
/// "Left"/"Right". "End" (right-aligned; 43 rules incl. every buoy/beacon name) must
/// map to "right": otherwise it falls through to "left" and the label anchors on the
/// wrong side of its symbol, landing over it. NOTE the oracle's hAlign shares this
/// bug (handles "Center"/"Right" only, so End->left) — this deliberately diverges to
/// the S-100-correct anchor so labels sit clear of their symbol (Right/Left kept for
/// robustness).
fn mapHAlign(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    if (std.mem.eql(u8, t, "Center")) return "center";
    if (std.mem.eql(u8, t, "End") or std.mem.eql(u8, t, "Right")) return "right";
    return "left"; // Start / Left / unset
}

/// Map an S-101 TextAlignVertical to the tile `valign` value (oracle vAlign +
/// valignName): "Top"->"top", "Center"->"middle", anything else (incl. unset)
/// ->"bottom".
fn mapVAlign(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    if (std.mem.eql(u8, t, "Top")) return "top";
    if (std.mem.eql(u8, t, "Center")) return "middle";
    return "bottom";
}

/// One stroked element of a screen-space figure a rule CONSTRUCTED via
/// AugmentedRay / ArcByRadius — a light-sector leg (ray) or sector arc/ring. Sizes
/// stay in their source units (display mm, or a ground-distance leg in metres); the
/// baker tessellates them around the feature anchor per zoom (mm are fixed display
/// millimetres, hence per-zoom). Mirrors Go's portrayal.AugmentedFigure.
pub const AugFigure = struct {
    is_ray: bool, // true: a straight leg (bearing/length); false: an arc/ring
    // Ray params: true-north bearing (already from-seaward reversed by the rule) and
    // its length as display mm, OR as a ground distance (metres) when length_ground_m>0.
    bearing_deg: f64 = 0,
    length_mm: f64 = 0,
    length_ground_m: f64 = 0,
    // Arc params, centred on the anchor; a 0 sweep is a full all-round ring.
    radius_mm: f64 = 0,
    start_deg: f64 = 0,
    sweep_deg: f64 = 0,
    // Stroke from the rule's LineStyle (width in mm; dashed from its dash length).
    color: []const u8 = "CHBLK",
    width_mm: f64 = 0,
    dashed: bool = false,
    // Explicit anchor from an AugmentedPoint instruction (else the feature geometry).
    anchor_lon: f64 = 0,
    anchor_lat: f64 = 0,
    has_anchor: bool = false,
    vg: i64 = 0, // the figure's draw viewing group, so sector arcs filter independently
};

pub const Portrayal = struct {
    fill_token: ?[]const u8 = null, // ColorFill (last wins)
    patterns: []const []const u8 = &.{}, // AreaFillReference
    lines: []const Line = &.{},
    points: []const Point = &.{},
    texts: []const Text = &.{},
    // S-52 DrawingPriority for the feature = the MAX priority over its draw
    // instructions (mirrors the Go s101build feature DisplayPriority). 0 when the
    // stream carries no DrawingPriority. Surfaced as the MVT `display_priority` property
    // so the style can paint area fills in S-52 display order (DEPARE 3 < LNDARE 12).
    display_priority: i64 = 0,
    // S-101 DisplayPlane: 0 = UnderRadar (the near-universal default), 1 = OverRadar.
    // Surfaced as the MVT `plane` property (emitted only when 1); the style's
    // symbol-sort-key uses plane*64 + display_priority, so an OverRadar symbol sorts above an
    // UnderRadar one of equal priority.
    plane: i64 = 0,
    // S-52 display-category rank (§10.3.4): 0=base, 1=standard, 2=other. The feature
    // takes the MOST-VISIBLE (lowest) band over its instructions' viewing groups;
    // standard (1) when none carries a category band. Surfaced as the MVT `cat`
    // property so the mariner's Base/Standard/Other selection filters client-side.
    cat: i64 = 1,
    // Raw S-101 viewing-group number of the feature's PRIMARY draw (the first
    // instruction whose draw viewing group is a real 1xxxx/2xxxx/3xxxx/9xxxx display
    // group). For a non-text section the modifier is `ViewingGroup:<drawVG>` (arg0);
    // for a text section it is `ViewingGroup:<textGroup>,<drawVG>` (arg1 is the draw
    // group). Surfaced as the MVT `vg` property so the client can filter on the exact
    // viewing group (§14.5), not just the coarse Base/Standard/Other category band. 0
    // when the feature carries no banded viewing group.
    vg: i64 = 0,
    // Date-dependent validity (S-52 §10.4.1.1), from the feature-level `Date:start,
    // end` instruction. S-100 truncated dates: a "--" prefix marks a recurring
    // month-day bound. Empty when the feature is undated. Surfaced as the MVT
    // date_start/date_end/date_recurring properties.
    date_start: []const u8 = "",
    date_end: []const u8 = "",
    // Constructed screen-space sector figures (LightSectored legs/arcs), tessellated
    // around the feature anchor by the baker. Empty for non-sectored features.
    aug_figures: []const AugFigure = &.{},
};

/// Display-category rank for a viewing group, from its leading digit (S-52 §10.3.4):
/// 1xxxx Base, 2xxxx Standard, 3xxxx/9xxxx Other. Anything else (text-group
/// selectors, <10000) carries no category band -> -1. Mirrors the Go
/// displayCategoryForViewingGroup (internal/engine/portrayal/s101build.go).
fn categoryRank(vg: i64) i64 {
    return switch (@divTrunc(vg, 10000)) {
        1 => 0, // Display Base
        2 => 1, // Display Standard
        3, 9 => 2, // Display Other (incl. 9xxxx quality/CATZOC overlays)
        else => -1, // no display-category band
    };
}

fn nthCsv(s: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) if (i == n) return part;
    return "";
}

fn toFloat(s: []const u8) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch 0;
}

/// Reverse the framework's EncodeDEFString escaping (`& ; : ,` -> `&a &s &c &m`),
/// so text escaped to survive the ;/:/, tokenizing decodes back to the display
/// string. The escape char (`&a` -> `&`) MUST be decoded LAST or an encoded
/// separator like `&as` (== literal `&s`) would wrongly become `;`. Mirrors Go
/// decodeDEF (pkg/s100/instructions/instructions.go:337). Allocates into `a`.
fn decodeDEF(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var r = try std.mem.replaceOwned(u8, a, s, "&s", ";");
    r = try std.mem.replaceOwned(u8, a, r, "&c", ":");
    r = try std.mem.replaceOwned(u8, a, r, "&m", ",");
    r = try std.mem.replaceOwned(u8, a, r, "&a", "&");
    return r;
}

// S-101 simple-line widths are millimetres; the engine renders in pixels. Mirrors
// Go's pxPerMM = float64(DefaultPxPerSymbolUnit)*100, DefaultPxPerSymbolUnit being
// float32(0.01/0.26458) (~3.7796 px/mm). Kept in the float32->float64 form so the
// scaled width matches the oracle.
pub const PX_PER_MM: f64 = @as(f64, @as(f32, 0.01 / 0.26458)) * 100.0;

/// Parse one feature's instruction stream. Allocates into `a` (use an arena).
pub fn parse(a: Allocator, stream: []const u8) !Portrayal {
    var patterns = std.ArrayList([]const u8).empty;
    var lines = std.ArrayList(Line).empty;
    var points = std.ArrayList(Point).empty;
    var texts = std.ArrayList(Text).empty;
    var aug_figures = std.ArrayList(AugFigure).empty;

    var fill_token: ?[]const u8 = null;
    var display_priority: i64 = 0; // feature DrawingPriority = max seen in the stream
    var plane: i64 = 0; // S-101 DisplayPlane: 0 UnderRadar (default), 1 OverRadar
    var cat: i64 = -1; // most-visible display-category rank; -1 until a banded VG is seen
    var vg: i64 = 0; // controlling viewing group = most-visible draw's banded VG (band(vg)==cat)
    var date_start: []const u8 = "";
    var date_end: []const u8 = "";
    // running state set by modifier instructions, applied at the next verb
    var cur_width: f64 = 1;
    var cur_color: []const u8 = "CHBLK";
    var cur_style: []const u8 = "_simple_";
    var cur_rot: f64 = 0;
    var cur_rot_north: bool = false; // Rotation CRS == GeographicCRS (rotates with true north)
    var cur_ox: f64 = 0;
    var cur_oy: f64 = 0;
    var cur_font: []const u8 = "CHBLK";
    var cur_font_size: f64 = 0; // FontSize px (0 => emit default 12)
    var cur_weight: Weight = .regular;
    var cur_slant: Slant = .upright;
    var cur_align_h: []const u8 = ""; // TextAlignHorizontal (raw; mapped at TextInstruction)
    var cur_align_v: []const u8 = ""; // TextAlignVertical (raw; mapped at TextInstruction)
    var cur_tgrp: i64 = 0; // text group (S-52 §14.5) of the most recent ViewingGroup
    var cur_dash_len: f64 = 0; // dash length (LineStyle arg1) of the current _simple_ stroke
    var cur_draw_vg: i64 = 0; // draw viewing group of the most recent ViewingGroup section
    // The screen-space figure currently under construction (AugmentedRay/ArcByRadius);
    // a LineInstruction strokes it (rather than the feature geometry) until ClearGeometry.
    const AugKind = enum { ray, arc };
    var cur_aug: ?AugKind = null;
    var aug_bearing: f64 = 0;
    var aug_len_mm: f64 = 0;
    var aug_len_ground: f64 = 0;
    var aug_radius_mm: f64 = 0;
    var aug_start: f64 = 0;
    var aug_sweep: f64 = 0;
    var cur_anchor_lon: f64 = 0;
    var cur_anchor_lat: f64 = 0;
    var cur_has_anchor: bool = false;

    var it = std.mem.splitScalar(u8, stream, ';');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        // ClearGeometry / other colon-less verbs: end of an augmented-geometry run —
        // drop the explicit anchor and constructed figure so later draws re-attach to
        // the feature geometry (mirrors Go's ClearGeometry).
        if (std.mem.eql(u8, item, "ClearGeometry")) {
            cur_aug = null;
            cur_has_anchor = false;
            cur_anchor_lon = 0;
            cur_anchor_lat = 0;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const key = item[0..colon];
        const val = item[colon + 1 ..];

        if (std.mem.eql(u8, key, "ColorFill")) {
            fill_token = val;
        } else if (std.mem.eql(u8, key, "AreaFillReference")) {
            // DIAMOND1 (SEABED01 shallow-water pattern) is owned by the client's
            // toggle-aware, live-safety-contour layer; baking it would double the
            // shading and ignore the toggle (mirrors Go s101build.go:371).
            if (!std.mem.eql(u8, val, "DIAMOND1")) try patterns.append(a, val);
        } else if (std.mem.eql(u8, key, "LineStyle")) {
            // _simple_,<dashLength>,<width>,<color>
            cur_style = nthCsv(val, 0);
            cur_dash_len = toFloat(nthCsv(val, 1));
            cur_width = toFloat(nthCsv(val, 2));
            cur_color = nthCsv(val, 3);
        } else if (std.mem.eql(u8, key, "LineInstruction") or std.mem.eql(u8, key, "LineInstructionUnsuppressed")) {
            // LineInstructionUnsuppressed (UpdateInformation chart-revision overlay,
            // CHRVID02/CHRVDEL2) emits the same stroke as LineInstruction — the
            // "Unsuppressed" suffix is a PresLib suppression flag, not a different draw.
            // Go Reduce folds both into one case (instructions.go:301); was dropped here.
            if (cur_aug) |kind| {
                // A figure (sector leg/arc) is current: this strokes THAT screen-space
                // geometry with the current LineStyle, not the feature's own geometry.
                try aug_figures.append(a, .{
                    .is_ray = kind == .ray,
                    .bearing_deg = aug_bearing,
                    .length_mm = aug_len_mm,
                    .length_ground_m = aug_len_ground,
                    .radius_mm = aug_radius_mm,
                    .start_deg = aug_start,
                    .sweep_deg = aug_sweep,
                    .color = cur_color,
                    .width_mm = cur_width,
                    .dashed = cur_dash_len > 0,
                    .anchor_lon = cur_anchor_lon,
                    .anchor_lat = cur_anchor_lat,
                    .has_anchor = cur_has_anchor,
                    .vg = cur_draw_vg,
                });
            } else if (std.mem.eql(u8, val, "_simple_")) {
                // mm -> px (Go SimpleLine.Width * pxPerMM); raw mm rendered ~3.78x too thin.
                // dashFor (oracle s101emit.go:278): LineStyle DashLength>0 strokes dashed,
                // else solid. The emit side maps an unregistered "dashed" style to a generic
                // dashed stroke (scene.zig:923), matching StrokeLine{Dash: DashDashed}.
                const simple_style: []const u8 = if (cur_dash_len > 0) "dashed" else "solid";
                try lines.append(a, .{ .style = simple_style, .width = cur_width * PX_PER_MM, .color = cur_color });
            } else {
                // named complex line pattern
                try lines.append(a, .{ .style = val, .width = cur_width, .color = cur_color });
            }
        } else if (std.mem.eql(u8, key, "AugmentedRay")) {
            // "AugmentedRay:<bearingCRS>,<bearing>,<lenCRS>,<len>" — a leg from the
            // anchor. The bearing (arg1) is already from-seaward reversed. The LENGTH's
            // CRS (arg2) sets its unit: GeographicCRS => ground metres (a fixed ground
            // distance), else display mm (the short sector leg).
            aug_bearing = toFloat(nthCsv(val, 1));
            const len_crs = std.mem.trim(u8, nthCsv(val, 2), " ");
            const len_val = toFloat(nthCsv(val, 3));
            aug_len_mm = 0;
            aug_len_ground = 0;
            if (std.mem.eql(u8, len_crs, "GeographicCRS")) aug_len_ground = len_val else aug_len_mm = len_val;
            cur_aug = .ray;
        } else if (std.mem.eql(u8, key, "ArcByRadius")) {
            // "ArcByRadius:<cx>,<cy>,<radiusMM>,<startDeg>,<sweepDeg>" — an arc/ring
            // centred on the anchor (cx,cy is 0 for sector figures).
            aug_radius_mm = toFloat(nthCsv(val, 2));
            aug_start = toFloat(nthCsv(val, 3));
            aug_sweep = toFloat(nthCsv(val, 4));
            cur_aug = .arc;
        } else if (std.mem.eql(u8, key, "AugmentedPoint")) {
            // "AugmentedPoint:<CRS>,<x>,<y>" places subsequent figures at the geographic
            // point (x=lon, y=lat) rather than the feature geometry.
            cur_anchor_lon = toFloat(nthCsv(val, 1));
            cur_anchor_lat = toFloat(nthCsv(val, 2));
            cur_has_anchor = true;
        } else if (std.mem.eql(u8, key, "Rotation")) {
            // S-101 form "Rotation:<CRS>,<angle>" (GeographicCRS=true-north, else
            // screen); a bare "Rotation:<angle>" with no CRS is screen-referenced.
            const crs = nthCsv(val, 0);
            const ang = nthCsv(val, 1);
            if (ang.len == 0) {
                cur_rot = toFloat(crs); // bare angle
                cur_rot_north = false;
            } else {
                cur_rot = toFloat(ang);
                cur_rot_north = std.mem.eql(u8, std.mem.trim(u8, crs, " "), "GeographicCRS");
            }
        } else if (std.mem.eql(u8, key, "LocalOffset")) {
            cur_ox = toFloat(nthCsv(val, 0));
            cur_oy = toFloat(nthCsv(val, 1));
        } else if (std.mem.eql(u8, key, "PointInstruction")) {
            try points.append(a, .{ .symbol = val, .rotation = cur_rot, .offset_x = cur_ox, .offset_y = cur_oy, .rot_north = cur_rot_north });
        } else if (std.mem.eql(u8, key, "FontColor")) {
            cur_font = val;
        } else if (std.mem.eql(u8, key, "FontSize")) {
            cur_font_size = toFloat(val);
        } else if (std.mem.eql(u8, key, "FontWeight")) {
            // CHARS weight: Bold emboldens; Medium/Light both hold at regular so no
            // label drops below the S-52 readable-from-1m floor.
            cur_weight = if (std.mem.eql(u8, std.mem.trim(u8, val, " "), "Bold")) .bold else .regular;
        } else if (std.mem.eql(u8, key, "FontSlant")) {
            // CHARS slant: "Italics" -> italic (hydrography), else upright.
            cur_slant = if (std.mem.eql(u8, std.mem.trim(u8, val, " "), "Italics")) .italic else .upright;
        } else if (std.mem.eql(u8, key, "TextAlignHorizontal")) {
            cur_align_h = val;
        } else if (std.mem.eql(u8, key, "TextAlignVertical")) {
            cur_align_v = val;
        } else if (std.mem.eql(u8, key, "TextInstruction")) {
            // The reference is DEF-encoded (separators escaped); decode it. The
            // oracle drops an OpText whose decoded reference is empty (s101emit.go:123,
            // `if cmd.Reference == "" return nil`) — skip it here, equivalently.
            const txt = try decodeDEF(a, val);
            if (txt.len == 0) continue;
            try texts.append(a, .{ .text = txt, .color = cur_font, .group = cur_tgrp, .font_size = cur_font_size, .weight = cur_weight, .slant = cur_slant, .halign = mapHAlign(cur_align_h), .valign = mapVAlign(cur_align_v), .offset_x = cur_ox, .offset_y = cur_oy });
        } else if (std.mem.eql(u8, key, "DrawingPriority")) {
            // S-52 display priority. A feature draws across several viewing groups,
            // each with its own DrawingPriority; the feature's priority is the MAX
            // (matches Go s101build's `priority = max(c.Priority)`).
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, val, " "), 10) catch continue;
            if (v > display_priority) display_priority = v;
        } else if (std.mem.eql(u8, key, "ViewingGroup")) {
            // The feature's display category is the most-visible (lowest-rank) band
            // over its instructions. Text instructions carry ViewingGroup:<textGroup>,
            // <drawVG>; arg 0 there is the small text-group number, which categoryRank
            // maps to -1 (no band), so it correctly never lowers the category.
            const arg0 = std.mem.trim(u8, nthCsv(val, 0), " ");
            const arg1 = std.mem.trim(u8, nthCsv(val, 1), " ");
            const vg0 = std.fmt.parseInt(i64, arg0, 10) catch continue;
            cur_tgrp = vg0; // for a text instruction, arg 0 is its S-52 text group
            // The feature's display category AND its controlling viewing group come from
            // the SAME most-visible (lowest-rank) draw, so band(vg) == cat always holds
            // and the cat / viewing-group filters can never contradict (matches the Go
            // baker's cat selection, s101build.go:400). arg0 is the banded draw VG for a
            // non-text section; a text section puts its text group in arg0 (rank -1) so
            // text never controls cat/vg — the banded text draw VG (arg1) is the separate
            // tgrp axis. Replaces the old first-wins vg (controlling-VG model).
            const rank = categoryRank(vg0);
            if (rank >= 0 and (cat < 0 or rank < cat)) {
                cat = rank;
                vg = vg0;
            }
            // Current section's draw VG (arg1 for a text section, else arg0), carried by
            // this section's aug figures — sector arcs filter on their OWN vg independent
            // of the feature-level rule above.
            const draw_vg = if (arg1.len > 0) (std.fmt.parseInt(i64, arg1, 10) catch vg0) else vg0;
            cur_draw_vg = draw_vg;
        } else if (std.mem.eql(u8, key, "Date")) {
            // Feature-level validity period "start,end" (either bound may be empty).
            date_start = std.mem.trim(u8, nthCsv(val, 0), " ");
            date_end = std.mem.trim(u8, nthCsv(val, 1), " ");
        } else if (std.mem.eql(u8, key, "DisplayPlane")) {
            // S-101 draw plane vs the radar overlay. UnderRadar (the near-universal
            // default) stays 0; OverRadar -> 1 so the style's symbol-sort-key
            // (plane*64 + display_priority) sorts it above an equal-priority UnderRadar symbol.
            // Any other/unknown value stays 0.
            if (std.mem.eql(u8, std.mem.trim(u8, val, " "), "OverRadar")) plane = 1;
        }
        // AlertReference / Hover / etc. are display metadata we don't map yet.
    }

    return .{
        .fill_token = fill_token,
        .patterns = patterns.items,
        .lines = lines.items,
        .points = points.items,
        .texts = texts.items,
        .display_priority = display_priority,
        .plane = plane,
        .cat = if (cat < 0) 1 else cat, // no banded VG -> Standard
        .vg = vg,
        .date_start = date_start,
        .date_end = date_end,
        .aug_figures = aug_figures.items,
    };
}

test "decodeDEF reverses the framework escaping (escape char decoded last)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No '&' -> returned verbatim.
    try std.testing.expectEqualStrings("Fishing Creek", try decodeDEF(a, "Fishing Creek"));
    // Each escaped separator decodes back.
    try std.testing.expectEqualStrings("a;b:c,d", try decodeDEF(a, "a&sb&cc&md"));
    // A literal ampersand (encoded &a) decodes; and the order matters: the encoded
    // form of a literal "&s" is "&as", which must decode to "&s", not ";".
    try std.testing.expectEqualStrings("R&D", try decodeDEF(a, "R&aD"));
    try std.testing.expectEqualStrings("&s", try decodeDEF(a, "&as"));
}

test "TextInstruction decodes DEF and drops empty text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An escaped label decodes; an empty TextInstruction is dropped.
    const p = try parse(a, "FontColor:CHBLK;TextInstruction:Smith&cs Cove;TextInstruction:");
    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
    try std.testing.expectEqualStrings("Smith:s Cove", p.texts[0].text);
}

test "parse the real DEPARE03 instruction stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The actual output from chartplotter-render --s101portray (DepthArea, 5-10 m).
    const stream =
        "ViewingGroup:13030;DrawingPriority:3;DisplayPlane:UnderRadar;" ++
        "AlertReference:SafetyContour;ColorFill:DEPMS;" ++
        "ViewingGroup:90000;DrawingPriority:9;DisplayPlane:UnderRadar;AreaFillReference:DIAMOND1";
    const p = try parse(a, stream);
    try std.testing.expectEqualStrings("DEPMS", p.fill_token.?);
    // DIAMOND1 is dropped (client-owned shallow-water pattern), so no patterns remain.
    try std.testing.expectEqual(@as(usize, 0), p.patterns.len);
    // display_priority = max(3, 9) over the two viewing-group sections.
    try std.testing.expectEqual(@as(i64, 9), p.display_priority);
    // DisplayPlane:UnderRadar -> plane 0 (the default; emitted-untagged in the tile).
    try std.testing.expectEqual(@as(i64, 0), p.plane);
    // Display category = most visible over {13030 -> Base, 90000 -> Other} = Base.
    try std.testing.expectEqual(@as(i64, 0), p.cat);
}

test "DisplayPlane:OverRadar parses to plane=1 (UnderRadar/absent stay 0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const over = try parse(a, "ViewingGroup:27070;DrawingPriority:24;DisplayPlane:OverRadar;PointInstruction:LIGHTS13");
    try std.testing.expectEqual(@as(i64, 1), over.plane);
    const under = try parse(a, "ViewingGroup:27070;DrawingPriority:24;DisplayPlane:UnderRadar;PointInstruction:LIGHTS13");
    try std.testing.expectEqual(@as(i64, 0), under.plane);
    const none = try parse(a, "ViewingGroup:27070;DrawingPriority:24;PointInstruction:LIGHTS13");
    try std.testing.expectEqual(@as(i64, 0), none.plane);
}

test "display category defaults to Standard when no banded viewing group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A text-only stream: ViewingGroup carries a text-group number (no category band).
    const p = try parse(a, "ViewingGroup:21,26070;DrawingPriority:24;FontColor:CHBLK;TextInstruction:Foo");
    try std.testing.expectEqual(@as(i64, 1), p.cat); // Standard
    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
}

test "viewing group: controlling VG = most-visible draw, band(vg)==cat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Single non-text draw: ViewingGroup:<drawVG> — arg0 is the banded draw group
    // (32050 = Other). vg = 32050 and categoryRank(32050) == cat.
    const ln = try parse(a, "ViewingGroup:32050;DrawingPriority:9;LineStyle:_simple_,,0.96,CHGRD;LineInstruction:_simple_");
    try std.testing.expectEqual(@as(i64, 32050), ln.vg);
    try std.testing.expectEqual(categoryRank(32050), ln.cat);

    // Text-only draw: arg0 (21) is the text group (rank -1, never controls cat/vg) and
    // arg1 (26070) is the tgrp axis, NOT the feature VG. So vg stays 0 (unbanded ->
    // always shown by the deny-list filter), cat defaults to Standard.
    const tx = try parse(a, "ViewingGroup:21,26070;DrawingPriority:24;FontColor:CHBLK;TextInstruction:Foo");
    try std.testing.expectEqual(@as(i64, 0), tx.vg);
    try std.testing.expectEqual(@as(i64, 1), tx.cat);

    // Most-visible across sections: a text group (21), then a Base draw (13030), then an
    // Other draw (90000). vg is the Base draw 13030 (most visible), NOT the first banded
    // draw — and band(vg) == cat == 0 (Base).
    const both = try parse(a, "ViewingGroup:21,29070;FontColor:CHBLK;TextInstruction:Bar;" ++
        "ViewingGroup:13030;ColorFill:DEPMS;ViewingGroup:90000;AreaFillReference:FOO");
    try std.testing.expectEqual(@as(i64, 13030), both.vg);
    try std.testing.expectEqual(categoryRank(13030), both.cat);
    try std.testing.expectEqual(@as(i64, 0), both.cat); // Base

    // No banded VG at all -> vg stays 0.
    const none = try parse(a, "FontColor:CHBLK;TextInstruction:foo");
    try std.testing.expectEqual(@as(i64, 0), none.vg);
}

test "parse LightSectored augmented legs + arcs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A real LightSectored stream (US4MD82M): two dashed sector-limit legs (display mm)
    // and one arc stroked twice (black backing + yellow), then ClearGeometry + text.
    const stream =
        "ViewingGroup:27070;DrawingPriority:24;DisplayPlane:UnderRadar;Hover:true;" ++
        "AugmentedRay:GeographicCRS,221.0,LocalCRS,25.0;Dash:0,3.6;LineStyle:_simple_,5.4,0.32,CHBLK;LineInstruction:_simple_;" ++
        "AugmentedRay:GeographicCRS,224.0,LocalCRS,25.0;LineInstruction:_simple_;" ++
        "ArcByRadius:0,0,20,221.0,3.0;AugmentedPath:LocalCRS,GeographicCRS,LocalCRS;" ++
        "LineStyle:_simple_,,1.28,CHBLK;LineInstruction:_simple_;" ++
        "LineStyle:_simple_,,0.64,LITYW;LineInstruction:_simple_;ClearGeometry;ClearGeometry;" ++
        "FontColor:CHBLK;ViewingGroup:23,27070;TextInstruction:Fl W 2.5s11.6m";
    const p = try parse(a, stream);

    // 2 dashed legs + 2 arc strokes (black + yellow), and NO feature-geometry lines.
    try std.testing.expectEqual(@as(usize, 0), p.lines.len);
    try std.testing.expectEqual(@as(usize, 4), p.aug_figures.len);

    const leg0 = p.aug_figures[0];
    try std.testing.expect(leg0.is_ray);
    try std.testing.expectApproxEqAbs(@as(f64, 221.0), leg0.bearing_deg, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), leg0.length_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.32), leg0.width_mm, 1e-9);
    try std.testing.expect(leg0.dashed); // dash length 5.4 > 0
    try std.testing.expectEqualStrings("CHBLK", leg0.color);
    try std.testing.expectEqual(@as(i64, 27070), leg0.vg);

    const leg1 = p.aug_figures[1];
    try std.testing.expect(leg1.is_ray and leg1.dashed); // reuses the prior dashed LineStyle
    try std.testing.expectApproxEqAbs(@as(f64, 224.0), leg1.bearing_deg, 1e-9);

    const arc_back = p.aug_figures[2];
    try std.testing.expect(!arc_back.is_ray);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), arc_back.radius_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 221.0), arc_back.start_deg, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), arc_back.sweep_deg, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.28), arc_back.width_mm, 1e-9);
    try std.testing.expect(!arc_back.dashed);
    try std.testing.expectEqualStrings("CHBLK", arc_back.color);

    const arc_col = p.aug_figures[3];
    try std.testing.expect(!arc_col.is_ray);
    try std.testing.expectEqualStrings("LITYW", arc_col.color);
    try std.testing.expectApproxEqAbs(@as(f64, 0.64), arc_col.width_mm, 1e-9);

    // The characteristic text still parses (rhythmOfLight path).
    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
    try std.testing.expectEqualStrings("Fl W 2.5s11.6m", p.texts[0].text);
}

test "parse line + point + text instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try parse(a, "ViewingGroup:32050;DrawingPriority:9;LineStyle:_simple_,,0.96,CHGRD;LineInstruction:_simple_");
    try std.testing.expectEqual(@as(usize, 1), line.lines.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96) * PX_PER_MM, line.lines[0].width, 1e-6); // mm -> px (~3.63)
    try std.testing.expectEqualStrings("CHGRD", line.lines[0].color);
    try std.testing.expectEqual(@as(i64, 9), line.display_priority);

    // LineInstructionUnsuppressed (UpdateInformation overlay) strokes like LineInstruction.
    const uns = try parse(a, "LineStyle:_simple_,,0.64,CHRVID02;LineInstructionUnsuppressed:_simple_");
    try std.testing.expectEqual(@as(usize, 1), uns.lines.len);
    try std.testing.expectEqualStrings("CHRVID02", uns.lines[0].color);

    // No DrawingPriority in the stream -> default 0.
    const nopri = try parse(a, "FontColor:CHBLK;TextInstruction:foo");
    try std.testing.expectEqual(@as(i64, 0), nopri.display_priority);

    const pt = try parse(a, "LocalOffset:1,-2;Rotation:45;PointInstruction:BCNCAR01");
    try std.testing.expectEqual(@as(usize, 1), pt.points.len);
    try std.testing.expectEqualStrings("BCNCAR01", pt.points[0].symbol);
    try std.testing.expectApproxEqAbs(@as(f64, 45), pt.points[0].rotation, 1e-9);
    try std.testing.expect(!pt.points[0].rot_north); // bare form is screen-referenced

    // CRS-qualified rotation (the production form): angle is arg 1, GeographicCRS=true-north.
    const rg = try parse(a, "Rotation:GeographicCRS,135;PointInstruction:LIGHTS11");
    try std.testing.expectApproxEqAbs(@as(f64, 135), rg.points[0].rotation, 1e-9);
    try std.testing.expect(rg.points[0].rot_north);
    const rp = try parse(a, "Rotation:PortrayalCRS,200;PointInstruction:LIGHTS11");
    try std.testing.expectApproxEqAbs(@as(f64, 200), rp.points[0].rotation, 1e-9);
    try std.testing.expect(!rp.points[0].rot_north);

    const tx = try parse(a, "FontColor:CHBLK;TextInstruction:Fl.R.4s");
    try std.testing.expectEqual(@as(usize, 1), tx.texts.len);
    try std.testing.expectEqualStrings("Fl.R.4s", tx.texts[0].text);
}

test "parse OpText FontSize / TextAlign modifiers (and oracle left/bottom defaults)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Explicit modifiers snapshot onto the TextInstruction (resolved to tile values).
    const p = try parse(a, "FontColor:CHBLK;FontSize:8;TextAlignHorizontal:Center;TextAlignVertical:Top;TextInstruction:Foo");
    try std.testing.expectEqual(@as(usize, 1), p.texts.len);
    try std.testing.expectEqual(@as(f64, 8), p.texts[0].font_size);
    try std.testing.expectEqualStrings("center", p.texts[0].halign);
    try std.testing.expectEqualStrings("top", p.texts[0].valign);

    // No align modifiers -> the oracle defaults (halign "left", valign "bottom") and
    // font_size 0 (the emit substitutes the default 12).
    const d = try parse(a, "FontColor:CHBLK;TextInstruction:Bar");
    try std.testing.expectEqual(@as(f64, 0), d.texts[0].font_size);
    try std.testing.expectEqualStrings("left", d.texts[0].halign);
    try std.testing.expectEqualStrings("bottom", d.texts[0].valign);

    // TextAlignVertical:Center maps to "middle" (not "center"), per valignName.
    const m = try parse(a, "TextAlignVertical:Center;TextInstruction:Baz");
    try std.testing.expectEqualStrings("middle", m.texts[0].valign);

    // S-100 Part 9 Start/End (the catalogue's actual horizontal values, e.g. every
    // buoy name uses End). End -> "right" (was falling through to "left"), Start ->
    // "left". A buoy name (LocalOffset:-3.51,3.51;TextAlignHorizontal:End) resolves
    // to halign "right" + loff "-1,1".
    const e = try parse(a, "LocalOffset:-3.51,3.51;TextAlignHorizontal:End;TextInstruction:CR");
    try std.testing.expectEqualStrings("right", e.texts[0].halign);
    try std.testing.expectEqual(@as(f64, -3.51), e.texts[0].offset_x);
    const st = try parse(a, "TextAlignHorizontal:Start;TextInstruction:Baz");
    try std.testing.expectEqualStrings("left", st.texts[0].halign);
}
