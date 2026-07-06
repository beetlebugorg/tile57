const std = @import("std");
const engine = @import("engine");
const render = @import("render");
const chart = @import("chart");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;
const worldPxOf = common.worldPxOf;
const terminalSize = common.terminalSize;
const cellPx = common.cellPx;

const ExAttr = struct { acr: []const u8, code: u16, value: []const u8 };

const ExLevel3 = struct {
    calls: []const render.inspect.Call,
    z: u8,
    x: u32,
    y: u32,
    matched: bool, // this feature was found in the sampled tile (else out of view)
};

// Where to point renderView for a feature's `--kitty` thumbnail: the anchor
// lon/lat + a per-feature zoom (a point sits at its node and renders at the
// cell's native band zoom; a line/area is centred on its bbox at a zoom that
// frames it). `framed` distinguishes the two for the caption. `frac`/`band_max`
// let the TUI RE-FRAME for its much larger dynamic canvas (the console keeps the
// THUMB_PX-square `zoom`): `frac` is the bbox's larger normalized-globe span
// (world=1.0), `band_max` the cell's native band-max zoom. `frac <= 0` = point /
// degenerate bbox — render at `band_max`. `has_bbox` + min/max lon/lat carry a
// line/area's real extent so the TUI live map can BOX the selected feature (a
// point leaves has_bbox false).
const ExThumb = struct {
    lon: f64,
    lat: f64,
    zoom: f64,
    framed: bool,
    frac: f64 = 0,
    band_max: f64 = 0,
    has_bbox: bool = false,
    min_lon: f64 = 0,
    min_lat: f64 = 0,
    max_lon: f64 = 0,
    max_lat: f64 = 0,
};

// The TUI live-cell-map's cross-frame state. `seq` is the cached a=T
// (transmit-AND-display) kitty sequence for the currently-framed view,
// re-emitted every frame (after the text) so the text redraw can't leave it
// stale. The cache is keyed on the VIEW (lon/lat/zoom) + pixel size (w/h): a new
// selection reframes to a new view, a terminal resize changes the size, and
// either invalidates the cache. `arena` owns `seq` and is reset when the view
// changes — the render (the slow step) runs once per view, matching the old
// transmit-once-per-selection model. `zoom < 0` means "no cached view yet".
// `hl_*` mirror the current view's highlight so a change in the highlighted
// feature (even at an identical view) re-renders too.
const ThumbState = struct {
    lon: f64 = 0,
    lat: f64 = 0,
    zoom: f64 = -1,
    seq: ?[]const u8 = null,
    w: u32 = 0,
    h: u32 = 0,
    hl_on: bool = false,
    hl_lon: f64 = 0,
    hl_lat: f64 = 0,
    arena: *std.heap.ArenaAllocator,
};

// The map view the live cell map renders: a centre + web-mercator zoom. A class
// header frames the WHOLE cell (exFitCellView); a feature frames the cell zoomed
// IN around it with surrounding context (exFeatureView).
const MapView = struct { lon: f64, lat: f64, zoom: f64 };

// Console thumbnail crop size (device px). Small on purpose — a glanceable proof
// of what the portrayal actually draws, inline beside the text dump. The TUI sizes
// its own thumbnail dynamically (fills the detail pane); THUMB_PX is the baseline
// the TUI scales symbols against so a fixed-device-px point mark still reads big.
const THUMB_PX: u32 = 200;

// Background colour token the isolated feature thumbnail clears to: DEPMS, the
// S-52 light shallow-water shade — a solid "mini scene" sea the single feature's
// black/coloured marks read clearly against.
const THUMB_BG: []const u8 = "DEPMS";

const ExRow = struct {
    cell_name: []const u8,
    cell_id: usize = 0, // index into the source cell list (TUI lazy re-load); 0 for streaming
    index: usize, // feature index within its cell
    rcid: u32,
    foid: u64,
    prim: u8,
    objl: u16,
    class: []const u8, // S-57 acronym ("LIGHTS") or "?<objl>"
    s101: []const u8, // S-101 feature-class name ("Light") or ""
    attrs: []const ExAttr,
    raw: ?[]const u8, // level 2: raw instruction stream
    parsed: ?engine.s101_instr.Portrayal, // level 2: parsed
    resolved: ?ExLevel3, // level 3
    thumb: ?ExThumb, // --kitty: where to render this feature's thumbnail (null = no geometry)
};

// One source cell in an explore run: the path (relative to the run's `dir`) to
// re-read + re-parse on demand. The TUI holds one of these per cell so it can
// lazily rebuild a selected feature's level-3 + thumbnail without keeping every
// cell's heavy recorded-render pass resident.
const ExCellSrc = struct { base_rel: []const u8 };

// The TUI's per-feature INDEX entry: just enough to navigate + show levels 1+2.
// It deliberately does NOT keep the structured attrs/raw/parsed portrayal or the
// full portrayal stream (those are formatted into `det12` once and dropped), nor
// any level-3 calls — level 3 + the kitty thumbnail are rebuilt lazily from the
// re-parsed cell on selection. `index` is the feature's position within its cell,
// `cell_id` indexes the cell source list.
const ExIndexRow = struct {
    class: []const u8, // filter key (S-57 acronym or "?<objl>")
    label: []const u8, // left-pane list label
    det12: []const []const u8, // pre-formatted levels 1+2 detail lines
    cell_id: usize,
    index: usize,
    prim: u8, // S-57 primitive (1 point / 2 line / 3 area) — geometry glyph in the tree
    objl: u16, // object-class code — the group header's S-101 human name
};

const ExFilters = struct {
    classes: ?[]const u8 = null, // comma-separated acronym allow-list
    obj: ?u64 = null, // match feature index OR rcid OR foid
    zoom: ?f64 = null, // override the auto fit-zoom for the resolving pass
    do_resolve: bool = true,
    kitty: bool = false, // compute each row's per-feature thumbnail view (--kitty)
};

fn exPrimName(p: u8) []const u8 {
    return switch (p) {
        1 => "point",
        2 => "line",
        3 => "area",
        255 => "none",
        else => "?",
    };
}

fn exCatName(c: i64) []const u8 {
    return switch (c) {
        0 => "base",
        1 => "standard",
        2 => "other",
        else => "?",
    };
}

// The largest zoom (<= `cap`) at which the whole cell bbox falls inside a SINGLE
// web-mercator tile — so one appendTile pass records every feature, and at the
// finest such zoom the cell nearly fills the 4096-unit tile (geometry stays crisp
// rather than collapsing). bounds = [west, south, east, north].
fn exFitTile(bounds: [4]f64, cap: u8) ExLevel3 {
    const nw = engine.tile.lonLatToWorld(bounds[0], bounds[3]); // (min x, min y: y grows south)
    const se = engine.tile.lonLatToWorld(bounds[2], bounds[1]); // (max x, max y)
    var z: u8 = cap;
    while (true) : (z -= 1) {
        const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
        const x0: i64 = @intFromFloat(@floor(nw[0] * n));
        const x1: i64 = @intFromFloat(@floor(se[0] * n));
        const y0: i64 = @intFromFloat(@floor(nw[1] * n));
        const y1: i64 = @intFromFloat(@floor(se[1] * n));
        if ((x0 == x1 and y0 == y1) or z == 0)
            return .{ .calls = &.{}, .z = z, .x = @intCast(@max(0, x0)), .y = @intCast(@max(0, y0)), .matched = false };
    }
}

// The tile containing the cell centre at an explicit zoom (--zoom override).
fn exTileAt(bounds: [4]f64, zoom: f64) ExLevel3 {
    const z: u8 = @intFromFloat(std.math.clamp(@round(zoom), 0, 22));
    const c = engine.tile.lonLatToWorld((bounds[0] + bounds[2]) / 2.0, (bounds[1] + bounds[3]) / 2.0);
    const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    return .{ .calls = &.{}, .z = z, .x = @intFromFloat(@floor(c[0] * n)), .y = @intFromFloat(@floor(c[1] * n)), .matched = false };
}

// Pick the renderView point + zoom for a feature's `--kitty` thumbnail. A POINT
// feature sits at its node, rendered at the cell's native band zoom (the finest
// zoom the cell is compiled for, so SCAMIN never gates the symbol out). A LINE or
// AREA is centred on its geometry bbox at the zoom that frames the larger span to
// ~80% of the crop. Returns null when the feature has no resolvable geometry.
fn exThumbView(a: std.mem.Allocator, cell: *engine.s57.Cell, f: engine.s57.Feature) ?ExThumb {
    const band = engine.bake_enc.bandOf(cell.params.cscl);
    const zr = engine.bake_enc.bandZooms(band);
    const band_max: f64 = @floatFromInt(zr.max);
    if (f.prim == 1) {
        const p = cell.pointGeometry(f) orelse return null;
        return .{ .lon = p.lon(), .lat = p.lat(), .zoom = band_max, .framed = false, .frac = 0, .band_max = band_max };
    }
    // Line/area: bbox of the assembled geometry parts.
    const parts = cell.geometryParts(a, f) catch return null;
    var min_lon: f64 = 1e9;
    var min_lat: f64 = 1e9;
    var max_lon: f64 = -1e9;
    var max_lat: f64 = -1e9;
    var any = false;
    for (parts) |part| for (part) |pt| {
        any = true;
        min_lon = @min(min_lon, pt.lon());
        min_lat = @min(min_lat, pt.lat());
        max_lon = @max(max_lon, pt.lon());
        max_lat = @max(max_lat, pt.lat());
    };
    if (!any) return null;
    const clon = (min_lon + max_lon) / 2.0;
    const clat = (min_lat + max_lat) / 2.0;
    // Frame the bbox: the larger normalized-globe span * 256*2^z should fill ~80%
    // of the crop. Fall back to the band zoom for a degenerate (zero-span) bbox.
    const nw = worldPxOf(min_lon, max_lat, 1.0);
    const se = worldPxOf(max_lon, min_lat, 1.0);
    const frac = @max(@abs(se[0] - nw[0]), @abs(se[1] - nw[1]));
    var zoom: f64 = band_max;
    if (frac > 1e-12) {
        const target = @as(f64, @floatFromInt(THUMB_PX)) * 0.8;
        zoom = std.math.clamp(std.math.log2(target / (256.0 * frac)), 2.0, 19.0);
    }
    return .{
        .lon = clon,
        .lat = clat,
        .zoom = zoom,
        .framed = true,
        .frac = frac,
        .band_max = band_max,
        .has_bbox = true,
        .min_lon = min_lon,
        .min_lat = min_lat,
        .max_lon = max_lon,
        .max_lat = max_lat,
    };
}

// The framing zoom that fills ~`fill` of a `target_px`-min-dimension canvas with
// this feature's geometry. A POINT (or a degenerate bbox) renders at the cell's
// native band-max zoom. Used by the TUI to reframe for its larger dynamic canvas
// (the console keeps the fixed THUMB_PX-square `ExThumb.zoom`). The upper zoom
// clamp is deliberately high (24, past any real band) so a tiny line/area still
// scales up to fill the big canvas instead of sitting as a speck on empty sea.
fn exThumbZoom(t: ExThumb, target_px: f64, fill: f64) f64 {
    if (!t.framed or t.frac <= 1e-12) return t.band_max;
    const target = target_px * fill;
    return std.math.clamp(std.math.log2(target / (256.0 * t.frac)), 2.0, MAP_FEATURE_ZOOM_MAX);
}

// How much of the live-cell-map canvas the framed geometry fills. The whole-cell
// overview packs the cell bbox into ~92% of the canvas (a thin margin so the
// coastline isn't flush to the edge); a feature frame packs the SELECTED feature
// into ~82% so it clearly dominates the render (with a thin context margin — the
// highlight reticle then pins exactly which one it is).
const MAP_CELL_FILL: f64 = 0.92;
const MAP_FEATURE_FILL: f64 = 0.82;

// A point has no extent to fit, so its feature frame zooms this many levels PAST
// the cell's native band-max (each level halves the framed ground span) — tight
// enough that the symbol + its immediate surroundings fill the pane. Capped at
// MAP_FEATURE_ZOOM_MAX so a berthing-band point (or a near-degenerate line/area)
// can't blow up past a sane scale.
const MAP_POINT_ZOOM_IN: f64 = 3.0;
const MAP_FEATURE_ZOOM_MAX: f64 = 21.0;

// The whole-cell overview view: centre on the cell bbox, zoom so its larger span
// reaches `fill` of the canvas. `bounds` = [west, south, east, north]. A
// degenerate (zero-span) bbox falls back to a mid zoom. Used when a class HEADER
// is selected — the "you are here" over the real quilted chart.
fn exFitCellView(bounds: [4]f64, w: u32, h: u32, fill: f64) MapView {
    const clon = (bounds[0] + bounds[2]) / 2.0;
    const clat = (bounds[1] + bounds[3]) / 2.0;
    const nw = worldPxOf(bounds[0], bounds[3], 1.0); // west,north  -> (x_min, y_min)
    const se = worldPxOf(bounds[2], bounds[1], 1.0); // east,south  -> (x_max, y_max)
    const span_x = @abs(se[0] - nw[0]);
    const span_y = @abs(se[1] - nw[1]);
    const wf = @as(f64, @floatFromInt(w)) * fill;
    const hf = @as(f64, @floatFromInt(h)) * fill;
    var zoom: f64 = 12;
    var got = false;
    if (span_x > 1e-12) {
        zoom = std.math.log2(wf / (256.0 * span_x));
        got = true;
    }
    if (span_y > 1e-12) {
        const zy = std.math.log2(hf / (256.0 * span_y));
        zoom = if (got) @min(zoom, zy) else zy;
        got = true;
    }
    return .{ .lon = clon, .lat = clat, .zoom = std.math.clamp(if (got) zoom else 12, 1.0, 19.0) };
}

// The zoomed-in feature view: centre on the feature, framed TIGHT so it dominates
// the render. A line/area fits its bbox to ~MAP_FEATURE_FILL of the canvas (a tiny
// feature still scales up close rather than sitting as a speck); a point (or a
// degenerate bbox) zooms MAP_POINT_ZOOM_IN levels past the cell's band-max so the
// symbol + its immediate surroundings fill the pane. This is a real map crop of
// the cell — the same scene as the header overview, just framed much tighter — so
// the selected feature appears in its true neighbourhood.
fn exFeatureView(tv: ExThumb, w: u32, h: u32) MapView {
    const min_dim: f64 = @floatFromInt(@min(w, h));
    const zoom = if (tv.framed and tv.frac > 1e-12)
        exThumbZoom(tv, min_dim, MAP_FEATURE_FILL)
    else
        std.math.clamp(tv.band_max + MAP_POINT_ZOOM_IN, tv.band_max, MAP_FEATURE_ZOOM_MAX);
    return .{ .lon = tv.lon, .lat = tv.lat, .zoom = zoom };
}

// The highlight marker for a framed feature: its anchor node (the ExThumb centre
// — a point's node, or a line/area's bbox centre) plus, for a line/area, its
// real bbox so the render can box the extent. A point carries no bbox.
fn exFeatureHighlight(tv: ExThumb) chart.Highlight {
    return .{
        .lon = tv.lon,
        .lat = tv.lat,
        .bbox = if (tv.has_bbox) .{ tv.min_lon, tv.min_lat, tv.max_lon, tv.max_lat } else null,
    };
}

fn exClassMatches(list: []const u8, acr: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |w| {
        const t = std.mem.trim(u8, w, " ");
        if (t.len > 0 and std.ascii.eqlIgnoreCase(t, acr)) return true;
    }
    return false;
}

// Feature fingerprint = class + NUL + acronym→value blob. The SAME key the
// recording surface sees (FeatureMeta.class / .s57_json), so a recorded draw pass
// matches its source feature. Allocated into `a`.
fn exKey(a: std.mem.Allocator, class: []const u8, s57_json: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ class, s57_json }) catch class;
}

const ExQueue = struct { idxs: std.ArrayList(usize) = .empty, head: usize = 0 };

// The whole-cell recording pass, indexed for per-feature level-3 lookup. Built
// once per cell by exSetupResolve; the queue heads advance as kept features are
// folded IN FEATURE ORDER (exFoldResolved), so the same cell must be folded in a
// single ascending sweep (exProcessCell / exStreamCell / the TUI cell cache all do).
const ExResolveCtx = struct {
    recorded: []const render.inspect.RecordedFeature,
    qmap: std.StringHashMap(ExQueue),
    view: ExLevel3, // z/x/y of the sampled tile (calls empty; per-feature calls fold in)
};

// Drive the recording surface once over the whole cell and index the recorded
// passes by feature fingerprint. Returns null when resolving is disabled or the
// cell has no bounds (level 3 unavailable). Everything is allocated into `a`
// (the recorded `Call` lists carry the geometry — the memory-heavy part — so `a`
// should be a per-cell arena that is reset before the next cell).
fn exSetupResolve(a: std.mem.Allocator, cell: *engine.s57.Cell, portrayal: ?[]const ?[]const u8, F: ExFilters) ?ExResolveCtx {
    if (!F.do_resolve) return null;
    const b = cell.bounds() orelse return null;
    const v = if (F.zoom) |zz| exTileAt(b, zz) else exFitTile(b, 19);
    var is = render.inspect.InspectSurface.init(a);
    const surf = is.asSurface();
    surf.beginScene(v.z) catch {};
    const one = [_]engine.scene.CellRef{.{ .cell = cell, .portrayal = portrayal }};
    engine.scene.appendTile(surf, a, &one, v.z, v.x, v.y, true) catch {};
    _ = surf.endScene(a) catch {};
    var qmap = std.StringHashMap(ExQueue).init(a);
    const recorded = is.features.items;
    for (recorded, 0..) |rf, ri| {
        const key = exKey(a, rf.meta.class, rf.meta.s57_json);
        const gop = qmap.getOrPut(key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.idxs.append(a, ri) catch {};
    }
    return .{ .recorded = recorded, .qmap = qmap, .view = v };
}

// Level 3 for one feature: fold its consecutive recorded passes (boundary/point
// variant passes + constructed sector figures are emitted adjacently) into one
// call list, CONSUMING the fingerprint queue. Must be called in feature order for
// the cell's kept features. Caveat: two neighbouring features that share a class
// AND identical attributes (mostly attribute-less areas like LNDARE) can merge —
// attributed features (the tool's focus) are distinct, so this is exact for them.
fn exFoldResolved(a: std.mem.Allocator, f: engine.s57.Feature, class: ?[]const u8, ctx: *ExResolveCtx) !ExLevel3 {
    var matched = false;
    var call_items: []const render.inspect.Call = &.{};
    if (class) |cls| {
        const s57_json = engine.scene.encodeS57Attrs(a, f) catch "";
        const key = exKey(a, cls, s57_json);
        if (ctx.qmap.getPtr(key)) |q| if (q.head < q.idxs.items.len) {
            var calls = std.ArrayList(render.inspect.Call).empty;
            var idx = q.idxs.items[q.head];
            q.head += 1;
            try calls.appendSlice(a, ctx.recorded[idx].calls.items);
            while (q.head < q.idxs.items.len and q.idxs.items[q.head] == idx + 1) {
                idx = q.idxs.items[q.head];
                q.head += 1;
                try calls.appendSlice(a, ctx.recorded[idx].calls.items);
            }
            matched = true;
            call_items = calls.items;
        };
    }
    return .{ .calls = call_items, .z = ctx.view.z, .x = ctx.view.x, .y = ctx.view.y, .matched = matched };
}

// Whether a feature passes the class/object filters (the shared gate used by the
// count pre-pass, the streaming emit and the TUI index/cache — kept identical so
// output byte-for-byte matches across paths).
fn exPasses(F: ExFilters, class: ?[]const u8, f: engine.s57.Feature, fi: usize) bool {
    if (F.classes) |cl| {
        if (class == null or !exClassMatches(cl, class.?)) return false;
    }
    if (F.obj) |want| {
        if (fi != want and f.rcid != want and f.foid != want) return false;
    }
    return true;
}

// Build one feature's ExRow (all three levels) into `a`. Strings are duped into
// `a`, so the cell may be freed afterwards. `ctx` (when non-null) is consumed in
// feature order — the caller must invoke this for kept features in ascending index
// order. Assumes the feature already passed the filters (exPasses).
fn exBuildRow(a: std.mem.Allocator, cell: *engine.s57.Cell, cell_name: []const u8, cell_id: usize, fi: usize, f: engine.s57.Feature, class: ?[]const u8, portrayal: ?[]const ?[]const u8, ctx: ?*ExResolveCtx, F: ExFilters) !ExRow {
    var attrs = std.ArrayList(ExAttr).empty;
    for (f.attrs) |at| {
        const acr = engine.catalogue.attrAcronym(at.code) orelse
            std.fmt.allocPrint(a, "?{d}", .{at.code}) catch "?";
        try attrs.append(a, .{ .acr = acr, .code = at.code, .value = try a.dupe(u8, std.mem.trim(u8, at.value, " ")) });
    }

    const raw: ?[]const u8 = if (portrayal) |p| (if (fi < p.len) p[fi] else null) else null;
    const parsed: ?engine.s101_instr.Portrayal = if (raw) |s| (engine.s101_instr.parse(a, s) catch null) else null;

    const resolved: ?ExLevel3 = if (ctx) |c| try exFoldResolved(a, f, class, c) else null;
    const thumb: ?ExThumb = if (F.kitty) exThumbView(a, cell, f) else null;

    return .{
        .cell_name = cell_name,
        .cell_id = cell_id,
        .index = fi,
        .rcid = f.rcid,
        .foid = f.foid,
        .prim = f.prim,
        .objl = f.objl,
        .class = class orelse (std.fmt.allocPrint(a, "?{d}", .{f.objl}) catch "?"),
        .s101 = engine.catalogue.resolveFeatureByObjl(f.objl) orelse "",
        .attrs = attrs.items,
        .raw = raw,
        .parsed = parsed,
        .resolved = resolved,
        .thumb = thumb,
    };
}

// Collect one parsed cell's features into `rows` (levels 1+2 always; level 3 when
// do_resolve and the cell has bounds). Strings a Row keeps are duped into `a`, so
// the caller may deinit the cell afterwards. Used to build the TUI's lightweight
// feature index (with F.do_resolve = false, F.kitty = false — level 3 + thumbs are
// computed lazily on selection); console/JSON stream per feature via exStreamCell.
fn exProcessCell(a: std.mem.Allocator, cell: *engine.s57.Cell, name: []const u8, rules: []const u8, F: ExFilters, cell_id: usize, rows: *std.ArrayList(ExRow)) !void {
    const portrayal: ?[]const ?[]const u8 = engine.portray.portrayCell(a, cell, rules) catch null;
    var ctx_storage = exSetupResolve(a, cell, portrayal, F);
    const ctx: ?*ExResolveCtx = if (ctx_storage) |*c| c else null;
    const cell_name = try a.dupe(u8, if (name.len > 0) name else cell.name);

    for (cell.features, 0..) |f, fi| {
        const class = engine.catalogue.acronymByObjl(f.objl);
        if (!exPasses(F, class, f, fi)) continue;
        const row = try exBuildRow(a, cell, cell_name, cell_id, fi, f, class, portrayal, ctx, F);
        try rows.append(a, row);
    }
}

// A short list label for a feature: its name (OBJNAM) if any, else a FOID/index.
fn exLabel(a: std.mem.Allocator, row: ExRow) []const u8 {
    for (row.attrs) |at| {
        if (std.mem.eql(u8, at.acr, "OBJNAM") and at.value.len > 0)
            return std.fmt.allocPrint(a, "{s} {s}", .{ row.class, at.value }) catch row.class;
    }
    if (row.foid != 0)
        return std.fmt.allocPrint(a, "{s} foid:{x}", .{ row.class, row.foid }) catch row.class;
    return std.fmt.allocPrint(a, "{s} #{d}", .{ row.class, row.index }) catch row.class;
}

// Format one recorded Surface call in S-52 shorthand (SY/LS/AC/AP/TX + args).
fn exAppendCall(a: std.mem.Allocator, out: *std.ArrayList(u8), call: render.inspect.Call) !void {
    switch (call) {
        .fill_area => |c| {
            try out.print(a, "    fillArea AC({s})  rings={d} verts={d}", .{ c.token, c.rings, c.verts });
            if (c.depth) |d| try out.print(a, "  depth={d}..{d}m", .{ d.d1, d.d2 });
            try out.append(a, '\n');
        },
        .fill_pattern => |c| try out.print(a, "    fillPattern AP({s})  rings={d} verts={d}\n", .{ c.name, c.rings, c.verts }),
        .stroke_line => |c| {
            try out.print(a, "    strokeLine LS({s},{d:.2},{s})  segs={d} verts={d}", .{ c.token, c.width_px, @tagName(c.dash), c.lines, c.verts });
            if (c.valdco) |v| try out.print(a, "  valdco={d}", .{v});
            try out.append(a, '\n');
        },
        .draw_symbol => |c| {
            try out.print(a, "    drawSymbol SY({s}) @({d},{d}) rot={d:.0}{s} scale={d:.2} {s}", .{ c.name, c.at.x, c.at.y, c.rot_deg, if (c.rot_north) "N" else "", c.scale, @tagName(c.placement) });
            if (c.danger_depth) |d| try out.print(a, " danger={d}m", .{d});
            try out.append(a, '\n');
        },
        .draw_sounding => |c| {
            try out.print(a, "    drawSounding {d}m", .{c.depth_m});
            if (c.swept) try out.appendSlice(a, " swept");
            if (c.low_acc) try out.appendSlice(a, " lowAcc");
            try out.print(a, " @({d},{d})\n", .{ c.at.x, c.at.y });
        },
        .draw_text => |c| try out.print(a, "    drawText TX(\"{s}\") {s} size={d:.0} {s}/{s} @({d},{d})\n", .{ c.text, c.color, c.font_size, c.halign, c.valign, c.at.x, c.at.y }),
    }
}

// The per-feature detail is emitted in two parts so the TUI can keep only levels
// 1+2 resident and format level 3 lazily on selection; the console streamer calls
// both back-to-back for the classic full dump.

// Levels 1+2 (header + S-57 attributes + S-101 portrayal) — cheap, and the only
// part the TUI keeps resident per feature. Level 3 (exFormatLevel3) is appended
// lazily on selection.
fn exFormatDetail12(a: std.mem.Allocator, out: *std.ArrayList(u8), row: ExRow) !void {
    try out.print(a, "[{s} #{d}] {s}", .{ row.cell_name, row.index, row.class });
    if (row.s101.len > 0) try out.print(a, " ({s})", .{row.s101});
    try out.print(a, "  prim={s} objl={d} rcid={d}", .{ exPrimName(row.prim), row.objl, row.rcid });
    if (row.foid != 0) try out.print(a, " foid={x}", .{row.foid});
    try out.append(a, '\n');

    // Level 1 — raw S-57 attributes.
    try out.appendSlice(a, "  1. S-57 attributes:\n");
    if (row.attrs.len == 0) {
        try out.appendSlice(a, "     (none)\n");
    } else for (row.attrs) |at| {
        try out.print(a, "     {s} = {s}\n", .{ at.acr, at.value });
    }

    // Level 2 — S-101 portrayal instruction stream (raw + parsed).
    try out.appendSlice(a, "  2. S-101 portrayal instructions:\n");
    if (row.raw) |raw| {
        try out.print(a, "     raw: {s}\n", .{raw});
    } else {
        try out.appendSlice(a, "     raw: (class unmapped, or emitted nothing)\n");
    }
    if (row.parsed) |p| {
        try out.print(a, "     parsed: prio={d} cat={s} vg={d}", .{ p.draw_prio, exCatName(p.cat), p.vg });
        if (p.date_start.len > 0 or p.date_end.len > 0) try out.print(a, " date=[{s}..{s}]", .{ p.date_start, p.date_end });
        try out.append(a, '\n');
        if (p.fill_token) |t| try out.print(a, "       fill:   AC({s})\n", .{t});
        for (p.patterns) |pat| try out.print(a, "       pattern: AP({s})\n", .{pat});
        for (p.lines) |ln| try out.print(a, "       line:   LS({s}, w={d:.2}, {s})\n", .{ ln.style, ln.width, ln.color });
        for (p.points) |pt| try out.print(a, "       symbol: SY({s}) rot={d:.0}{s} off={d:.2},{d:.2}\n", .{ pt.symbol, pt.rotation, if (pt.rot_north) "N" else "", pt.offset_x, pt.offset_y });
        for (p.texts) |tx| try out.print(a, "       text:   TX(\"{s}\") {s} size={d:.0} {s}/{s} grp={d}\n", .{ tx.text, tx.color, tx.font_size, tx.halign, tx.valign, tx.group });
        if (p.aug_figures.len > 0) {
            var rays: usize = 0;
            var arcs: usize = 0;
            for (p.aug_figures) |fig| if (fig.is_ray) {
                rays += 1;
            } else {
                arcs += 1;
            };
            try out.print(a, "       augmented: {d} ray(s), {d} arc(s) (light sector figure)\n", .{ rays, arcs });
        }
    }
}

// Level 3 — resolved Surface calls (from an already-folded ExLevel3, or null when
// resolving is disabled / the cell has no bounds).
fn exFormatLevel3(a: std.mem.Allocator, out: *std.ArrayList(u8), resolved: ?ExLevel3) !void {
    try out.appendSlice(a, "  3. Resolved Surface calls:\n");
    if (resolved) |lo| {
        if (!lo.matched) {
            try out.print(a, "     (not in the sampled tile z{d} {d}/{d}/{d}; use --zoom to sample a tile it covers)\n", .{ lo.z, lo.z, lo.x, lo.y });
        } else if (lo.calls.len == 0) {
            try out.print(a, "     (no draw calls at z{d} tile {d}/{d}/{d} — gated or geometry clipped)\n", .{ lo.z, lo.z, lo.x, lo.y });
        } else {
            try out.print(a, "     (z{d} tile {d}/{d}/{d})\n", .{ lo.z, lo.z, lo.x, lo.y });
            for (lo.calls) |c| try exAppendCall(a, out, c);
        }
    } else {
        try out.appendSlice(a, "     (resolving disabled / cell has no bounds)\n");
    }
}

fn exJsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => if (ch < 0x20) try out.print(a, "\\u{x:0>4}", .{ch}) else try out.append(a, ch),
    };
    try out.append(a, '"');
}

// One feature as a JSON object (no surrounding array / comma — the streaming
// caller writes `[`, the `,\n` separators and the closing `]\n`).
fn exWriteJsonRow(a: std.mem.Allocator, out: *std.ArrayList(u8), row: ExRow) !void {
    try out.print(a, "{{\"cell\":\"{s}\",\"index\":{d},\"rcid\":{d},\"foid\":\"{x}\",\"prim\":\"{s}\",\"objl\":{d},\"class\":", .{ row.cell_name, row.index, row.rcid, row.foid, exPrimName(row.prim), row.objl });
    try exJsonStr(a, out, row.class);
    try out.appendSlice(a, ",\"s101\":");
    try exJsonStr(a, out, row.s101);
    // Level 1.
    try out.appendSlice(a, ",\"attrs\":{");
    for (row.attrs, 0..) |at, j| {
        if (j > 0) try out.append(a, ',');
        try exJsonStr(a, out, at.acr);
        try out.append(a, ':');
        try exJsonStr(a, out, at.value);
    }
    try out.appendSlice(a, "}");
    // Level 2.
    try out.appendSlice(a, ",\"portrayal_raw\":");
    if (row.raw) |raw| try exJsonStr(a, out, raw) else try out.appendSlice(a, "null");
    if (row.parsed) |p| {
        try out.print(a, ",\"portrayal\":{{\"prio\":{d},\"cat\":\"{s}\",\"vg\":{d},\"fill\":", .{ p.draw_prio, exCatName(p.cat), p.vg });
        if (p.fill_token) |t| try exJsonStr(a, out, t) else try out.appendSlice(a, "null");
        try out.appendSlice(a, ",\"symbols\":[");
        for (p.points, 0..) |pt, j| {
            if (j > 0) try out.append(a, ',');
            try exJsonStr(a, out, pt.symbol);
        }
        try out.appendSlice(a, "],\"texts\":[");
        for (p.texts, 0..) |tx, j| {
            if (j > 0) try out.append(a, ',');
            try exJsonStr(a, out, tx.text);
        }
        try out.print(a, "],\"lines\":{d},\"patterns\":{d},\"aug_figures\":{d}}}", .{ p.lines.len, p.patterns.len, p.aug_figures.len });
    } else try out.appendSlice(a, ",\"portrayal\":null");
    // Level 3.
    if (row.resolved) |lo| {
        try out.print(a, ",\"resolved\":{{\"z\":{d},\"x\":{d},\"y\":{d},\"matched\":{},\"calls\":[", .{ lo.z, lo.x, lo.y, lo.matched });
        for (lo.calls, 0..) |c, j| {
            if (j > 0) try out.append(a, ',');
            try exJsonStr(a, out, @tagName(std.meta.activeTag(c)));
        }
        try out.appendSlice(a, "]}");
    } else try out.appendSlice(a, ",\"resolved\":null");
    try out.appendSlice(a, "}");
}

// Read a base cell's sequential .001.. update files from `dir` (auto-discovery,
// like the streaming chart loader). Missing = end of chain.
fn exReadUpdates(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, base_rel: []const u8) []const []const u8 {
    if (!std.mem.endsWith(u8, base_rel, ".000")) return &.{};
    const stem = base_rel[0 .. base_rel.len - 4];
    var list = std.ArrayList([]const u8).empty;
    var u: u32 = 1;
    while (u <= 999) : (u += 1) {
        const upn = std.fmt.allocPrint(a, "{s}.{d:0>3}", .{ stem, u }) catch break;
        const ub = dir.readFileAlloc(io, upn, a, .unlimited) catch break;
        list.append(a, ub) catch break;
    }
    return list.items;
}

// Parse `base_rel` from `dir` (with its updates) into `a`. All cell allocations
// (bytes, updates, the parsed Cell + its child arena/maps) live in `a`, so the
// caller reclaims them by resetting `a` — no cell.deinit() needed. `quiet`
// suppresses the read/parse diagnostics for the throwaway count pre-pass.
fn exParseCellFrom(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, base_rel: []const u8, quiet: bool) ?engine.s57.Cell {
    const base = dir.readFileAlloc(io, base_rel, a, .unlimited) catch {
        if (!quiet) std.debug.print("cannot read {s}\n", .{base_rel});
        return null;
    };
    const updates = exReadUpdates(io, a, dir, base_rel);
    return engine.s57.parseCellWithUpdates(a, base, updates) catch {
        if (!quiet) std.debug.print("cannot parse {s}\n", .{base_rel});
        return null;
    };
}

// A small buffered sink over stdout: append into a reusable buffer and flush in
// ~64 KiB chunks (and at teardown), so the explore dump streams out instead of
// materialising the whole thing in one giant ArrayList. The buffer backing lives
// in a long-lived allocator (the process arena); clearRetainingCapacity reuses it.
const OutBuf = struct {
    io: std.Io,
    f: std.Io.File,
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    const FLUSH_AT: usize = 1 << 16;

    fn write(self: *OutBuf, bytes: []const u8) void {
        self.buf.appendSlice(self.a, bytes) catch {
            // On OOM growing the buffer, flush what we have and write directly.
            self.flush();
            self.f.writeStreamingAll(self.io, bytes) catch {};
            return;
        };
        if (self.buf.items.len >= FLUSH_AT) self.flush();
    }
    fn flush(self: *OutBuf) void {
        if (self.buf.items.len == 0) return;
        self.f.writeStreamingAll(self.io, self.buf.items) catch {};
        self.buf.clearRetainingCapacity();
    }
};

const ExOut = enum { console, json };

const EX_SEP = "\n────────────────────────────────────────────────────────────────\n";

// Stream one cell's matching features to `out` (console detail or JSON objects),
// building each feature's ExRow in `fa_arena` (reset per feature) and the whole-
// cell portrayal + recording pass in `ca_arena` (the caller resets it before the
// next cell). Peak memory = ONE cell, never the whole source. The JSON `first`
// flag carries comma state across cells.
fn exStreamCell(
    ca_arena: *std.heap.ArenaAllocator,
    fa_arena: *std.heap.ArenaAllocator,
    cell: *engine.s57.Cell,
    name: []const u8,
    rules: []const u8,
    F: ExFilters,
    mode: ExOut,
    out: *OutBuf,
    first: *bool,
    palette: render.resolve.PaletteId,
    m: *const render.resolve.MarinerSettings,
) !void {
    const ca = ca_arena.allocator();
    const portrayal: ?[]const ?[]const u8 = engine.portray.portrayCell(ca, cell, rules) catch null;
    var ctx_storage = exSetupResolve(ca, cell, portrayal, F);
    const ctx: ?*ExResolveCtx = if (ctx_storage) |*c| c else null;
    const cell_name = try ca.dupe(u8, if (name.len > 0) name else cell.name);

    for (cell.features, 0..) |f, fi| {
        const class = engine.catalogue.acronymByObjl(f.objl);
        if (!exPasses(F, class, f, fi)) continue;

        _ = fa_arena.reset(.retain_capacity);
        const fa = fa_arena.allocator();
        const row = try exBuildRow(fa, cell, cell_name, 0, fi, f, class, portrayal, ctx, F);

        var chunk = std.ArrayList(u8).empty;
        switch (mode) {
            .console => {
                try chunk.appendSlice(fa, EX_SEP);
                try exFormatDetail12(fa, &chunk, row);
                try exFormatLevel3(fa, &chunk, row.resolved);
                if (F.kitty) try exAppendThumb(fa, &chunk, cell, portrayal, fi, row, palette, m);
            },
            .json => {
                if (!first.*) try chunk.appendSlice(fa, ",\n");
                try exWriteJsonRow(fa, &chunk, row);
                first.* = false;
            },
        }
        out.write(chunk.items);
    }
}

// A parsed camera for --view: the "lon,lat,zoom" the explorer bounds its cell set
// to. Accepts the bare triple ("-75.39724,37.876816,12.34") or a share URL whose
// hash carries it ("http://host:8080/#v=-75.39724,37.876816,12.34" — the web app's
// parseViewHash format). Extra hash fields (bearing,pitch) are ignored.
const View = struct { lon: f64, lat: f64, zoom: f64 };
fn parseViewArg(s: []const u8) ?View {
    var v = s;
    if (std.mem.indexOf(u8, v, "#v=")) |i| {
        v = v[i + 3 ..];
        if (std.mem.indexOfScalar(u8, v, '&')) |j| v = v[0..j];
    }
    var it = std.mem.splitScalar(u8, v, ',');
    const lon = std.fmt.parseFloat(f64, std.mem.trim(u8, it.next() orelse return null, " \t")) catch return null;
    const lat = std.fmt.parseFloat(f64, std.mem.trim(u8, it.next() orelse return null, " \t")) catch return null;
    const zoom = std.fmt.parseFloat(f64, std.mem.trim(u8, it.next() orelse return null, " \t")) catch return null;
    return .{ .lon = lon, .lat = lat, .zoom = zoom };
}

// Web-Mercator latitude at world-pixel y (inverse of the projection below).
fn latOfY(y_px: f64, world: f64) f64 {
    const n = std.math.pi * (1.0 - 2.0 * y_px / world);
    return std.math.atan(std.math.sinh(n)) * 180.0 / std.math.pi;
}

// The [west, south, east, north] geographic bounds of a `w_px`×`h_px` screen
// centred on (lon,lat) at web-Mercator `zoom` — the same projection the client
// uses, so "cells in this viewport" matches what the app would load at that view.
fn viewportBbox(lon: f64, lat: f64, zoom: f64, w_px: f64, h_px: f64) [4]f64 {
    const world = 256.0 * std.math.pow(f64, 2.0, zoom);
    const cx = (lon + 180.0) / 360.0 * world;
    const sphi = @sin(lat * std.math.pi / 180.0);
    const cy = (0.5 - @log((1.0 + sphi) / (1.0 - sphi)) / (4.0 * std.math.pi)) * world;
    const west = (cx - w_px / 2.0) / world * 360.0 - 180.0;
    const east = (cx + w_px / 2.0) / world * 360.0 - 180.0;
    const north = latOfY(cy - h_px / 2.0, world); // smaller y = higher lat
    const south = latOfY(cy + h_px / 2.0, world);
    return .{ west, south, east, north };
}

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 explore <cell.000 | ENC_ROOT --view LON,LAT,ZOOM> [--class ACR[,ACR..]] [--object FOID|RCID|INDEX] [--zoom N] [--view LON,LAT,ZOOM|URL] [--viewport WxH] [--json] [--tui] [--kitty] [--no-resolve] [--rules DIR]\n", .{});
        return;
    }
    const path = args[2];
    var F = ExFilters{};
    var json = false;
    var tui = false;
    var kitty = false;
    var rules_flag: ?[]const u8 = null;
    var view: ?View = null;
    var viewport_w: f64 = 1280; // the screen the viewport filter assumes (CSS px)
    var viewport_h: f64 = 800;
    var f = Flags{ .args = args, .i = 2 };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "--view")) {
            const v = f.val("--view") orelse return;
            view = parseViewArg(v) orelse return usageErr("--view must be LON,LAT,ZOOM or a URL with #v=LON,LAT,ZOOM");
        } else if (std.mem.eql(u8, arg, "--viewport")) {
            const v = f.val("--viewport") orelse return;
            const xi = std.mem.indexOfScalar(u8, v, 'x') orelse return usageErr("--viewport must be WxH");
            viewport_w = std.fmt.parseFloat(f64, v[0..xi]) catch return usageErr("bad --viewport W");
            viewport_h = std.fmt.parseFloat(f64, v[xi + 1 ..]) catch return usageErr("bad --viewport H");
        } else if (std.mem.eql(u8, arg, "--class")) {
            F.classes = f.val("--class") orelse return;
        } else if (std.mem.eql(u8, arg, "--object")) {
            const v = f.val("--object") orelse return;
            F.obj = std.fmt.parseInt(u64, v, 0) catch return usageErr("--object must be an integer (FOID/RCID/index; 0x.. for hex FOID)");
        } else if (std.mem.eql(u8, arg, "--zoom")) {
            const v = f.val("--zoom") orelse return;
            F.zoom = std.fmt.parseFloat(f64, v) catch return usageErr("--zoom must be a number");
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            tui = true;
        } else if (std.mem.eql(u8, arg, "--kitty")) {
            kitty = true;
            F.kitty = true;
        } else if (std.mem.eql(u8, arg, "--no-resolve")) {
            F.do_resolve = false;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules_flag = f.val("--rules") orelse return;
        } else return usageErr("unknown flag");
    }

    engine.portray.setQuiet(true);
    engine.catalogue.warmUp();
    const rules = resolveRulesDir(rules_flag);

    // --kitty renders from the same re-parsed cell + portrayal streams the text
    // dump uses, so no separate Chart handle is opened. In the CONSOLE dump each
    // feature gets an ISOLATED render of just its portrayal on a solid background
    // (chart.renderFeature); the --tui LIVE CELL MAP instead frames the selection
    // over the real chart (chart.renderCellView — see exTuiMap).
    const palette: render.resolve.PaletteId = .day;
    var m = render.resolve.MarinerSettings{ .display_other = true };
    m.scheme = .day;

    // explore inspects one or more source cells. `dir` stays open for the whole run
    // (the TUI re-reads cells lazily to rebuild level 3 + the map render).
    //   • a single .000 auto-discovers its .001+ updates (exParseCellFrom); OR
    //   • an ENC_ROOT (directory) with --view: the viewport BOUNDS the cell set to
    //     the handful under that screen, so the tree + map stay tractable (an
    //     unfiltered ENC_ROOT with hundreds of cells would not).
    var dir: std.Io.Dir = undefined;
    var cell_paths = std.ArrayList([]const u8).empty;
    if (std.mem.endsWith(u8, path, ".000")) {
        const dirp = std.fs.path.dirname(path) orelse ".";
        dir = std.Io.Dir.cwd().openDir(io, dirp, .{}) catch return usageErr("cannot open cell directory");
        try cell_paths.append(a, try a.dupe(u8, std.fs.path.basename(path)));
    } else {
        const v = view orelse {
            std.debug.print("error: explore takes a single .000 cell, or an ENC_ROOT with --view LON,LAT,ZOOM (or a #v= URL) to pull the cells under that viewport\n", .{});
            std.process.exit(2);
        };
        dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return usageErr("cannot open ENC_ROOT directory");
        const vb = viewportBbox(v.lon, v.lat, v.zoom, viewport_w, viewport_h);
        // Cheap bbox scan: peekMeta (M_COVR/header only, no full parse) per .000,
        // keep those whose coverage intersects the viewport. One cell's bytes resident
        // at a time (scan arena reset per file).
        const Match = struct { path: []const u8, cscl: i32 };
        var matches = std.ArrayList(Match).empty;
        var scan_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scan_arena.deinit();
        var scanned: usize = 0;
        var walker = dir.walk(a) catch return usageErr("cannot walk ENC_ROOT");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".000")) continue;
            _ = scan_arena.reset(.retain_capacity);
            const sa = scan_arena.allocator();
            const bytes = dir.readFileAlloc(io, entry.path, sa, .unlimited) catch continue;
            scanned += 1;
            const meta = engine.s57.peekMeta(sa, bytes) orelse continue;
            const bb = meta.bounds orelse continue; // [west, south, east, north]
            if (bb[0] <= vb[2] and bb[2] >= vb[0] and bb[1] <= vb[3] and bb[3] >= vb[1])
                try matches.append(a, .{ .path = try a.dupe(u8, entry.path), .cscl = meta.cscl });
        }
        if (matches.items.len == 0) {
            std.debug.print("no cells intersect the viewport ({d} .000 scanned; view {d:.5},{d:.5} z{d:.2}, {d:.0}x{d:.0}px)\n", .{ scanned, v.lon, v.lat, v.zoom, viewport_w, viewport_h });
            return;
        }
        // Coarsest-first (largest compilation scale = overview) so the tree reads
        // overview -> harbour, like the chart stack.
        std.mem.sort(Match, matches.items, {}, struct {
            fn lt(_: void, x: Match, y: Match) bool {
                return x.cscl > y.cscl;
            }
        }.lt);
        for (matches.items) |mt| try cell_paths.append(a, mt.path);
        std.debug.print("viewport {d:.5},{d:.5} z{d:.2}: {d} of {d} cell(s)\n", .{ v.lon, v.lat, v.zoom, cell_paths.items.len, scanned });
    }
    defer dir.close(io);

    // Per-cell scratch (heavy: parse + portrayal + recording surface) reset before
    // every cell, and a per-feature scratch reset before every feature — both backed
    // by the page allocator so freed pages return to the OS. Peak stays at ONE cell
    // regardless of how big the ENC_ROOT is.
    var cell_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cell_arena.deinit();
    var feat_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer feat_arena.deinit();

    // --- TUI: build only the lightweight feature INDEX (levels 1+2) resident; the
    //     level-3 resolve + kitty thumbnail are computed lazily per selection. ---
    if (tui) {
        var index_F = F;
        index_F.do_resolve = false; // level 3 is lazy (per selection)
        index_F.kitty = false; // thumbnails are lazy (per selection)
        // Build the lightweight index: parse + portray each cell in the per-cell
        // scratch (freed after), keeping only the formatted levels-1+2 lines + label
        // on the process arena. Peak during the build stays at one cell; the resident
        // index scales with feature COUNT (text), not with geometry.
        var index = std.ArrayList(ExIndexRow).empty;
        for (cell_paths.items, 0..) |base_rel, cid| {
            _ = cell_arena.reset(.free_all);
            const ca = cell_arena.allocator();
            var cell = exParseCellFrom(io, ca, dir, base_rel, false) orelse continue;
            var rows = std.ArrayList(ExRow).empty; // transient (scratch)
            exProcessCell(ca, &cell, std.fs.path.basename(base_rel), rules, index_F, cid, &rows) catch {};
            for (rows.items) |row| {
                var d = std.ArrayList(u8).empty;
                exFormatDetail12(a, &d, row) catch continue;
                index.append(a, .{
                    .class = a.dupe(u8, row.class) catch continue,
                    .label = a.dupe(u8, exLabel(ca, row)) catch continue,
                    .det12 = splitLines(a, d.items) catch continue,
                    .cell_id = cid,
                    .index = row.index,
                    .prim = row.prim,
                    .objl = row.objl,
                }) catch {};
            }
        }
        _ = cell_arena.reset(.free_all);
        if (index.items.len == 0) {
            std.debug.print("no matching features (source opened, but nothing passed the filters)\n", .{});
            return;
        }
        var cells = std.ArrayList(ExCellSrc).empty;
        for (cell_paths.items) |bp| try cells.append(a, .{ .base_rel = bp });
        return exploreTui(io, a, index.items, cells.items, dir, rules, F, kitty, palette, &m, path);
    }

    // --- Non-TUI: stream each cell's features straight to a buffered stdout, one
    //     cell resident at a time. ---
    var outbuf = OutBuf{ .io = io, .f = std.Io.File.stdout(), .a = a };
    defer outbuf.flush();
    outbuf.buf.ensureTotalCapacity(a, OutBuf.FLUSH_AT) catch {};

    if (json) {
        outbuf.write("[");
        var first = true;
        for (cell_paths.items) |base_rel| {
            _ = cell_arena.reset(.free_all);
            var cell = exParseCellFrom(io, cell_arena.allocator(), dir, base_rel, false) orelse continue;
            exStreamCell(&cell_arena, &feat_arena, &cell, std.fs.path.basename(base_rel), rules, F, .json, &outbuf, &first, palette, &m) catch {};
        }
        outbuf.write("]\n");
        return;
    }

    // Console. The header ("N feature(s)") needs the grand total up front, so scan
    // every cell for its count first, then a second pass streams each cell's dump
    // (one cell resident at a time; `first` carries separator state across cells).
    var first = true;
    var total: usize = 0;
    for (cell_paths.items) |base_rel| {
        _ = cell_arena.reset(.free_all);
        const cell = exParseCellFrom(io, cell_arena.allocator(), dir, base_rel, true) orelse continue;
        for (cell.features, 0..) |fe, fi| {
            if (exPasses(F, engine.catalogue.acronymByObjl(fe.objl), fe, fi)) total += 1;
        }
    }
    if (total == 0) {
        std.debug.print("no matching features (source opened, but nothing passed the filters)\n", .{});
        return;
    }
    outbuf.write(std.fmt.allocPrint(a, "{d} feature(s)\n", .{total}) catch "");
    for (cell_paths.items) |base_rel| {
        _ = cell_arena.reset(.free_all);
        var cell = exParseCellFrom(io, cell_arena.allocator(), dir, base_rel, false) orelse continue;
        exStreamCell(&cell_arena, &feat_arena, &cell, std.fs.path.basename(base_rel), rules, F, .console, &outbuf, &first, palette, &m) catch {};
    }
}

// Console `--kitty`: after a row's text dump, append a one-line caption + the
// feature's RESOLVED render as an inline kitty-graphics PNG. The render is
// ISOLATED — only this feature's portrayal (chart.renderFeature, only_fi = fi)
// on a solid background, NOT a map crop of the surrounding scene. Any failure
// prints a short note instead of an image (graceful degradation), never an error.
fn exAppendThumb(a: std.mem.Allocator, out: *std.ArrayList(u8), cell: *engine.s57.Cell, portrayal: ?[]const ?[]const u8, fi: usize, row: ExRow, palette: render.resolve.PaletteId, m: *const render.resolve.MarinerSettings) !void {
    const tv = row.thumb orelse {
        try out.appendSlice(a, "  resolved render: (no renderable geometry)\n");
        return;
    };
    const png = chart.renderFeature(cell, portrayal, fi, tv.lon, tv.lat, tv.zoom, THUMB_PX, THUMB_PX, palette, m, THUMB_BG, .png) catch {
        try out.appendSlice(a, "  resolved render: (renderFeature failed for this feature)\n");
        return;
    };
    defer chart.freeBytes(png);
    const seq = render.kitty.encodePng(a, png) catch {
        try out.appendSlice(a, "  resolved render: (kitty encode failed)\n");
        return;
    };
    try out.print(a, "  resolved render (isolated) — {d}x{d}px {s} @ z{d:.1} ({d:.4},{d:.4}):\n", .{ THUMB_PX, THUMB_PX, if (tv.framed) "bbox" else "anchor", tv.zoom, tv.lon, tv.lat });
    try out.appendSlice(a, seq);
    try out.append(a, '\n');
}

// ---- explore --tui: colour + layout vocabulary -----------------------------
// Standard 8/16-colour ANSI only (+ bold/dim/reverse) so it degrades on plain
// terminals; no 256-colour assumptions. Colours are zero display-width, applied
// AFTER any width clipping, so column maths stays exact.
const EXC_RESET = "\x1b[0m";
const EXC_BOLD = "\x1b[1m";
const EXC_DIM = "\x1b[2m";
const EXC_REV = "\x1b[7m";
const EXC_RED = "\x1b[31m";
const EXC_GREEN = "\x1b[32m";
const EXC_YELLOW = "\x1b[33m";
const EXC_BLUE = "\x1b[34m";
const EXC_MAGENTA = "\x1b[35m";
const EXC_CYAN = "\x1b[36m";
const EXC_BCYAN = "\x1b[1;36m"; // class acronym (group header + feature title)
const EXC_H1 = "\x1b[1;33m"; // detail section "1. S-57 attributes"
const EXC_H2 = "\x1b[1;35m"; // detail section "2. S-101 portrayal instructions"
const EXC_H3 = "\x1b[1;32m"; // detail section "3. Resolved Surface calls"
const EXC_SPACES = " " ** 80;

// Per-primitive geometry glyph + colour for the class tree (point ● / line ─ /
// area ▬). All are single display columns but multi-byte UTF-8 — see dispWidth.
fn exGeomGlyph(prim: u8) []const u8 {
    return switch (prim) {
        1 => "\u{25CF}", // ● point
        2 => "\u{2500}", // ─ line
        3 => "\u{25AC}", // ▬ area
        else => "\u{00B7}", // · unknown
    };
}
fn exGeomColor(prim: u8) []const u8 {
    return switch (prim) {
        1 => EXC_CYAN,
        2 => EXC_GREEN,
        3 => EXC_BLUE,
        else => EXC_DIM,
    };
}
fn exGeomName(prim: u8) []const u8 {
    return switch (prim) {
        1 => "point",
        2 => "line",
        3 => "area",
        else => "other",
    };
}
fn exPrimSlot(prim: u8) usize {
    return switch (prim) {
        1 => 0,
        2 => 1,
        3 => 2,
        else => 3,
    };
}

// A class group in the tree: the member feature rows (indices into the resident
// index), a per-primitive tally for the header glyph + summary, the S-101 human
// name, and a collapse flag. Built once (the index is fixed for the session).
const ExGroup = struct {
    class: []const u8,
    members: []const usize, // indices into the resident `rows` (ExIndexRow) list
    counts: [4]usize, // [point, line, area, other]
    dominant: u8, // S-57 primitive of the header glyph (most common in the class)
    s101: []const u8, // S-101 feature-class name for the header, or ""
    expanded: bool,
};

// One flattened, on-screen row: a group HEADER, or a FEATURE under an expanded
// group. `row` indexes the resident index (only meaningful when !is_header).
const ExVisRow = struct { is_header: bool, group: usize, row: usize };

fn exLtClass(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// Group the resident index by S-57 class, sorted alphabetically by acronym. All
// allocations land in `a` (tiny — just index lists + group headers), so this is
// memory-negligible next to the level-3/thumbnail arenas.
fn exBuildGroups(a: std.mem.Allocator, rows: []const ExIndexRow) ![]ExGroup {
    var map = std.StringHashMap(std.ArrayList(usize)).init(a);
    for (rows, 0..) |row, i| {
        const gop = try map.getOrPut(row.class);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).empty;
        try gop.value_ptr.append(a, i);
    }
    var classes = std.ArrayList([]const u8).empty;
    var kit = map.keyIterator();
    while (kit.next()) |k| try classes.append(a, k.*);
    std.mem.sort([]const u8, classes.items, {}, exLtClass);

    var groups = std.ArrayList(ExGroup).empty;
    for (classes.items) |cls| {
        const members = map.get(cls).?.items;
        var counts = [_]usize{ 0, 0, 0, 0 };
        for (members) |ri| counts[exPrimSlot(rows[ri].prim)] += 1;
        var dom: u8 = 1;
        var best: usize = 0;
        for ([_]u8{ 1, 2, 3, 255 }) |p| {
            const c = counts[exPrimSlot(p)];
            if (c > best) {
                best = c;
                dom = p;
            }
        }
        try groups.append(a, .{
            .class = cls,
            .members = members,
            .counts = counts,
            .dominant = dom,
            .s101 = engine.catalogue.resolveFeatureByObjl(rows[members[0]].objl) orelse "",
            .expanded = false,
        });
    }
    // A single-group source opens expanded — no point hiding the only class.
    if (groups.items.len == 1) groups.items[0].expanded = true;
    return groups.items;
}

// The feature-row label with its redundant leading class stripped (the class is
// already the group header): "LIGHTS Thomas Point" -> "Thomas Point".
fn exSubLabel(row: ExIndexRow) []const u8 {
    if (std.mem.startsWith(u8, row.label, row.class) and
        row.label.len > row.class.len and row.label[row.class.len] == ' ')
        return row.label[row.class.len + 1 ..];
    return row.label;
}

// The header-summary detail shown when a GROUP header is selected (cheap — no
// cell re-parse). Lines land in `a` (a per-detail arena, reset per selection).
fn exGroupDetail(a: std.mem.Allocator, g: ExGroup, rows: []const ExIndexRow) ![]const []const u8 {
    _ = rows;
    var lines = std.ArrayList([]const u8).empty;
    if (g.s101.len > 0)
        try lines.append(a, try std.fmt.allocPrint(a, "{s}  ({s})", .{ g.class, g.s101 }))
    else
        try lines.append(a, try a.dupe(u8, g.class));
    try lines.append(a, "");
    try lines.append(a, try std.fmt.allocPrint(a, "  {d} feature(s) in this class", .{g.members.len}));
    var gb = std.ArrayList(u8).empty;
    try gb.appendSlice(a, "  geometry: ");
    var first = true;
    for ([_]u8{ 1, 2, 3, 255 }) |p| {
        const c = g.counts[exPrimSlot(p)];
        if (c == 0) continue;
        if (!first) try gb.appendSlice(a, "  ");
        first = false;
        try gb.print(a, "{d} {s}", .{ c, exGeomName(p) });
    }
    try lines.append(a, gb.items);
    try lines.append(a, try std.fmt.allocPrint(a, "  status: {s}", .{if (g.expanded) "expanded" else "collapsed"}));
    try lines.append(a, "");
    if (g.expanded)
        try lines.append(a, "  <-/Enter/Space  collapse this class")
    else
        try lines.append(a, "  ->/Enter/Space  expand this class");
    try lines.append(a, "  then select a feature to inspect its");
    try lines.append(a, "  S-57 attributes + portrayal + resolved render");
    return lines.items;
}

// Display width in terminal columns: count UTF-8 scalars (lead bytes), each as a
// single column. Correct for the ASCII + box-drawing glyphs the tree uses; the
// honest caveat is East-Asian "ambiguous width" glyphs (● ▬ ·) render as 2 cols
// in CJK-wide terminals, which this counts as 1 (assumes a Western-width font).
fn dispWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) w += 1;
    }
    return w;
}

// Clip `s` to at most `cols` display columns on a UTF-8 scalar boundary.
fn clipCols(s: []const u8, cols: usize) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const lead = (s[i] & 0xC0) != 0x80;
        if (lead and w >= cols) break;
        if (lead) w += 1;
        i += 1;
    }
    return s[0..i];
}

// A full-width reverse-video status bar (title / footer). `text` must be plain
// (no escapes) so the width maths is exact; the whole bar is reverse (+ optional
// bold), then padded with spaces to `cols`.
fn exEmitBar(fa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8, cols: usize, bold: bool) !void {
    try buf.appendSlice(fa, EXC_REV);
    if (bold) try buf.appendSlice(fa, EXC_BOLD);
    const c = clipCols(text, cols);
    try buf.appendSlice(fa, c);
    var w = dispWidth(c);
    while (w < cols) : (w += 1) try buf.append(fa, ' ');
    try buf.appendSlice(fa, EXC_RESET);
}

// One coloured segment of a left-pane row (text + its known display width +
// optional SGR colour). Assembling from known-width parts lets exEmitLeft clip
// and pad by columns without measuring around the embedded escapes.
const ExSeg = struct { t: []const u8, w: usize, c: []const u8 };

// Emit one left-pane cell of exactly `width` columns from coloured segments,
// clipping the overflowing segment on a scalar boundary and padding the rest. A
// selected row is drawn as a plain reverse-video bar (segment colours dropped so
// fg-on-reverse never muddies the highlight).
fn exEmitLeft(fa: std.mem.Allocator, buf: *std.ArrayList(u8), segs: []const ExSeg, width: usize, selected: bool) !void {
    if (selected) try buf.appendSlice(fa, EXC_REV);
    var used: usize = 0;
    for (segs) |sg| {
        if (used >= width) break;
        const avail = width - used;
        const colour = !selected and sg.c.len > 0;
        if (sg.w <= avail) {
            if (colour) try buf.appendSlice(fa, sg.c);
            try buf.appendSlice(fa, sg.t);
            if (colour) try buf.appendSlice(fa, EXC_RESET);
            used += sg.w;
        } else {
            const clipped = clipCols(sg.t, avail);
            if (colour) try buf.appendSlice(fa, sg.c);
            try buf.appendSlice(fa, clipped);
            if (colour) try buf.appendSlice(fa, EXC_RESET);
            used += dispWidth(clipped);
            break;
        }
    }
    while (used < width) : (used += 1) try buf.append(fa, ' ');
    if (selected) try buf.appendSlice(fa, EXC_RESET);
}

fn exTokenColor(op: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, op, "SY")) return EXC_MAGENTA; // symbol name
    if (std.mem.eql(u8, op, "AC")) return EXC_CYAN; // area colour token
    if (std.mem.eql(u8, op, "AP")) return EXC_CYAN; // area pattern
    if (std.mem.eql(u8, op, "LS")) return EXC_CYAN; // line style
    if (std.mem.eql(u8, op, "TX")) return EXC_GREEN; // text
    return null;
}

// Colourise S-52 shorthand opcodes (SY/AC/AP/LS/TX) in a detail line: dim the
// "XX(" opener, colour the parenthesised token by opcode. Leaves everything else
// untouched (best-effort — a ')' inside a TX string ends the run early).
fn exColorTokens(fa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 3 <= s.len and s[i + 2] == '(' and
            s[i] >= 'A' and s[i] <= 'Z' and s[i + 1] >= 'A' and s[i + 1] <= 'Z')
        {
            if (exTokenColor(s[i .. i + 2])) |col| {
                var j = i + 3;
                while (j < s.len and s[j] != ')') j += 1;
                try buf.appendSlice(fa, EXC_DIM);
                try buf.appendSlice(fa, s[i .. i + 3]);
                try buf.appendSlice(fa, EXC_RESET);
                try buf.appendSlice(fa, col);
                try buf.appendSlice(fa, s[i + 3 .. j]);
                try buf.appendSlice(fa, EXC_RESET);
                if (j < s.len) {
                    try buf.append(fa, ')');
                    j += 1;
                }
                i = j;
                continue;
            }
        }
        try buf.append(fa, s[i]);
        i += 1;
    }
}

// Emit one detail-pane line, clipped to `budget` columns, with colour applied by
// line type: the group-summary title, the numbered S-57/S-101/resolved section
// headers, the feature title, attribute acronyms, and S-52 opcode tokens. The
// underlying text is the SAME bytes the console path prints — colour lives only
// here, so `--json`/console stay byte-identical.
fn exEmitDetail(fa: std.mem.Allocator, buf: *std.ArrayList(u8), line: []const u8, budget: usize, first_header: bool) !void {
    const s = clipCols(line, budget);
    if (first_header) {
        try buf.appendSlice(fa, EXC_BCYAN);
        try buf.appendSlice(fa, s);
        try buf.appendSlice(fa, EXC_RESET);
        return;
    }
    if (std.mem.startsWith(u8, s, "  1. ")) return exSection(fa, buf, s, EXC_H1);
    if (std.mem.startsWith(u8, s, "  2. ")) return exSection(fa, buf, s, EXC_H2);
    if (std.mem.startsWith(u8, s, "  3. ")) return exSection(fa, buf, s, EXC_H3);
    if (s.len > 0 and s[0] == '[') {
        try buf.appendSlice(fa, EXC_BOLD);
        try buf.appendSlice(fa, s);
        try buf.appendSlice(fa, EXC_RESET);
        return;
    }
    // Attribute line: five leading spaces, an uppercase acronym, then " = ".
    if (std.mem.startsWith(u8, s, "     ") and s.len > 6 and s[5] >= 'A' and s[5] <= 'Z') {
        if (std.mem.indexOf(u8, s, " = ")) |eq| {
            try buf.appendSlice(fa, s[0..5]);
            try buf.appendSlice(fa, EXC_YELLOW);
            try buf.appendSlice(fa, s[5..eq]);
            try buf.appendSlice(fa, EXC_RESET);
            try buf.appendSlice(fa, s[eq..]);
            return;
        }
    }
    try exColorTokens(fa, buf, s);
}

fn exSection(fa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, color: []const u8) !void {
    try buf.appendSlice(fa, color);
    try buf.appendSlice(fa, s);
    try buf.appendSlice(fa, EXC_RESET);
}

// Parse + portray the single explored cell into `sa` and fold every kept
// feature's level 3 (resolved calls) + `--kitty` map framing, IN feature order
// (the resolve queue consumes in that order — the same single ascending sweep the
// console dump uses), so a random-access lookup by feature index matches the dump.
// Everything is `sa`-owned and resident for the run (explore is single-cell). On
// any failure the out-params keep their empty defaults (the TUI degrades to the
// text-only levels 1+2). Mirrors the console path's per-cell processing.
fn exLoadCell(
    io: std.Io,
    sa: std.mem.Allocator,
    dir: std.Io.Dir,
    base_rel: []const u8,
    rules: []const u8,
    F: ExFilters,
    do_kitty: bool,
    out_cell: *?*engine.s57.Cell,
    out_portrayal: *?[]const ?[]const u8,
    out_resolved: *[]?ExLevel3,
    out_thumb: *[]?ExThumb,
) void {
    const cell_val = exParseCellFrom(io, sa, dir, base_rel, true) orelse return;
    // Persist the parsed Cell in `sa` so the map render + level 3 can reach it
    // across frames (a stack local would dangle once this function returns).
    const cell = sa.create(engine.s57.Cell) catch return;
    cell.* = cell_val;
    const portrayal = engine.portray.portrayCell(sa, cell, rules) catch null;
    var ctx_storage = exSetupResolve(sa, cell, portrayal, F);
    const ctx: ?*ExResolveCtx = if (ctx_storage) |*cc| cc else null;
    var rbf: []?ExLevel3 = &.{};
    if (sa.alloc(?ExLevel3, cell.features.len)) |buf| {
        rbf = buf;
        @memset(rbf, null);
    } else |_| {}
    var tbf: []?ExThumb = &.{};
    if (do_kitty) {
        if (sa.alloc(?ExThumb, cell.features.len)) |buf| {
            tbf = buf;
            @memset(tbf, null);
        } else |_| {}
    }
    for (cell.features, 0..) |fe, cfi| {
        const class = engine.catalogue.acronymByObjl(fe.objl);
        if (!exPasses(F, class, fe, cfi)) continue;
        if (ctx) |c2| {
            if (cfi < rbf.len) rbf[cfi] = exFoldResolved(sa, fe, class, c2) catch null;
        }
        if (do_kitty and cfi < tbf.len) tbf[cfi] = exThumbView(sa, cell, fe);
    }
    out_resolved.* = rbf;
    out_thumb.* = tbf;
    out_cell.* = cell;
    out_portrayal.* = portrayal;
}

// `tile57 explore --tui`: a two-pane feature explorer that doubles as a LIVE
// CELL MAP. Left = a COLLAPSIBLE class tree (group headers + indented features);
// right = the selected item's text detail with, under `--kitty`, a live map
// render that FRAMES the selection: a class HEADER shows the whole cell (the
// real quilted chart — "you are here"); a FEATURE zooms the map IN around it
// with its neighbours / depths still visible. Scrolling the list down visually
// zooms the map into the thing. j/k or arrows move; ->/Enter/Space expand, <-
// collapse, E/C expand/collapse all; PgUp/PgDn page; g/G home/end; [/] scroll
// detail; m toggles map-only; / filters by class; q quits. Same termios raw-mode
// + alt-screen scaffolding as `tile57 ascii --tui`; dependency-free. The map is
// transmit-once-per-view + place, deleted each frame — the same cached-region
// pattern as the ascii kitty TUI, so it never scrolls the layout.
fn exploreTui(io: std.Io, a: std.mem.Allocator, rows: []const ExIndexRow, cells: []const ExCellSrc, dir: std.Io.Dir, rules: []const u8, F: ExFilters, kitty: bool, palette: render.resolve.PaletteId, m: *const render.resolve.MarinerSettings, source: []const u8) !void {
    // The interactive TUI is POSIX-only: std.posix.termios is `void` on Windows,
    // so gate the whole raw-mode body out at comptime (same idiom as common.zig's
    // terminalSize). The non-interactive `explore` paths stay cross-platform.
    if (@import("builtin").os.tag == .windows) return usageErr("--tui is not supported on Windows");
    const stdout = std.Io.File.stdout();
    const stdin_fd = std.Io.File.stdin().handle;
    const old = std.posix.tcgetattr(stdin_fd) catch return usageErr("--tui needs a terminal");
    var raw = old;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false; // ctrl-c arrives as 0x03 → clean quit through the defers
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(stdin_fd, .NOW, raw) catch return usageErr("--tui needs a terminal");
    defer std.posix.tcsetattr(stdin_fd, .NOW, old) catch {};
    stdout.writeStreamingAll(io, "\x1b[?1049h\x1b[?25l") catch {}; // alt screen, hide cursor
    defer stdout.writeStreamingAll(io, "\x1b[?25h\x1b[?1049l") catch {};
    const do_kitty = kitty;
    defer if (do_kitty) stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
    // The live map's cross-frame state + its dedicated arena (owns the cached a=T
    // sequence; reset per view). `sel_cell`/`sel_portrayal` are the parsed cell +
    // portrayal the map + level-3 draw from (sel_arena-owned, resident for the run
    // — explore is single-cell, so one cell is the whole working set).
    var thumb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer thumb_arena.deinit();
    var thumb = ThumbState{ .arena = &thumb_arena };
    var sel_cell: ?*engine.s57.Cell = null;
    var sel_portrayal: ?[]const ?[]const u8 = null;
    var map_full = false; // 'm': map fills the whole detail pane (hide the text)

    // The resident index (rows) already carries each feature's label + LEVELS 1+2
    // detail lines. Level 3 (resolved calls) is read from `resolved_by_fi` below.

    // The class tree: group the index by S-57 class once (it is fixed for the
    // session); `expanded` toggles per header. Memory-negligible next to the arenas.
    const groups = try exBuildGroups(a, rows);
    const src_base = std.fs.path.basename(source);

    // Level-3 / map state. `sel_arena` holds the single cell's parse + recording +
    // folded resolved calls + per-feature map framings, resident for the run.
    // `det_arena` holds just the currently-shown feature's level-3 (or a group
    // header summary). Both page-backed so their resets return memory to the OS.
    var sel_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer sel_arena.deinit();
    var det_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer det_arena.deinit();
    // Per-FRAME scratch (bounded to one redraw) for the output buffer + tiny format
    // temporaries, reset each frame so the process arena never grows with redraws.
    var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer frame_arena.deinit();
    const need_cell = F.do_resolve or do_kitty; // no parse needed if neither
    var resolved_by_fi: []?ExLevel3 = &.{}; // the cell, indexed by feature index
    var thumb_by_fi: []?ExThumb = &.{};
    // Load the single cell up front (parse + portray + fold level 3 + per-feature
    // map framings) — resident for the whole session. explore is single-cell now,
    // so there is no lazy per-selection cell crossing to manage.
    if (need_cell and cells.len > 0)
        exLoadCell(io, sel_arena.allocator(), dir, cells[0].base_rel, rules, F, do_kitty, &sel_cell, &sel_portrayal, &resolved_by_fi, &thumb_by_fi);
    var cur_det: []const []const u8 = &.{}; // detail lines for the current selection
    var det_is_header = false; // cur_det is a group summary (colour its title line)
    // What cur_det was built for: kind 0=none 1=feature 2=header, id = rows[] index
    // (feature) or group index (header). det_kind = 3 forces a rebuild after a tree
    // mutation (expand/collapse changes the header summary or the feature set).
    var det_kind: u8 = 3;
    var det_id: usize = 0;

    var filt_buf: [64]u8 = undefined;
    var filt_len: usize = 0;
    var filtering = false; // typing into the class filter
    var sel: usize = 0; // index into the flattened visible-row list
    // With --kitty the point of the tool is the render, so don't open on a class
    // HEADER (which has no thumbnail) — expand the first group and land on its
    // first feature so a render is visible immediately. Without --kitty, groups
    // open collapsed (a tidy class list to navigate).
    if (do_kitty and groups.len > 0) {
        groups[0].expanded = true;
        sel = 1; // vis row 0 is the first header; row 1 is its first feature
    }
    var top: usize = 0; // first visible list row
    var det_top: usize = 0; // detail scroll offset
    // After a tree mutation the flattened list shifts; relocate the selection onto
    // this stable (group, header?/row) identity rather than onto a stale index.
    var sel_target: ?ExVisRow = null;

    // The flattened visible rows: a header per matching group, plus its features
    // when expanded. Rebuilt each frame into a reused buffer (no per-frame growth).
    var vis = std.ArrayList(ExVisRow).empty;
    while (true) {
        const filt = filt_buf[0..filt_len];
        vis.clearRetainingCapacity();
        var nvis_groups: usize = 0;
        for (groups, 0..) |g, gidx| {
            if (filt.len > 0 and indexOfIgnoreCase(g.class, filt) == null) continue;
            nvis_groups += 1;
            try vis.append(a, .{ .is_header = true, .group = gidx, .row = 0 });
            if (g.expanded) for (g.members) |ri|
                try vis.append(a, .{ .is_header = false, .group = gidx, .row = ri });
        }
        // Relocate the selection after a tree mutation, then clamp it in range.
        if (sel_target) |t| {
            sel_target = null;
            for (vis.items, 0..) |v, k| {
                if (v.group == t.group and v.is_header == t.is_header and (v.is_header or v.row == t.row)) {
                    sel = k;
                    break;
                }
            }
        }
        if (vis.items.len == 0) sel = 0 else if (sel >= vis.items.len) sel = vis.items.len - 1;

        const cur: ?ExVisRow = if (vis.items.len > 0) vis.items[sel] else null;
        // `gi`: the resident-index row of the selected FEATURE (null on a header /
        // empty view) — the key for the level-3 detail + feature map framing.
        const gi: ?usize = if (cur) |c| (if (c.is_header) null else c.row) else null;

        // Rebuild the detail only when the selected item's identity changes (or a
        // tree mutation forced det_kind = 3). Level 3 + the map framings were folded
        // once up front (exLoadCell); a FEATURE reads its resolved calls, a HEADER
        // shows a cheap summary.
        var want_kind: u8 = 0;
        var want_id: usize = 0;
        if (cur) |c| {
            if (c.is_header) {
                want_kind = 2;
                want_id = c.group;
            } else {
                want_kind = 1;
                want_id = c.row;
            }
        }
        if (want_kind != det_kind or want_id != det_id) {
            det_kind = want_kind;
            det_id = want_id;
            det_top = 0;
            det_is_header = want_kind == 2;
            if (want_kind == 0) {
                cur_det = &[_][]const u8{"(no classes match the filter)"};
            } else if (want_kind == 2) {
                _ = det_arena.reset(.retain_capacity);
                cur_det = exGroupDetail(det_arena.allocator(), groups[want_id], rows) catch
                    &[_][]const u8{groups[want_id].class};
            } else {
                const g = want_id;
                _ = det_arena.reset(.retain_capacity);
                const da = det_arena.allocator();
                const resolved: ?ExLevel3 = if (rows[g].index < resolved_by_fi.len) resolved_by_fi[rows[g].index] else null;
                var l3 = std.ArrayList(u8).empty;
                exFormatLevel3(da, &l3, resolved) catch {};
                const l3_lines = splitLines(da, l3.items) catch &[_][]const u8{};
                var lines = std.ArrayList([]const u8).empty;
                for (rows[g].det12) |ln| lines.append(da, ln) catch {};
                for (l3_lines) |ln| lines.append(da, ln) catch {};
                cur_det = lines.items;
            }
        }

        const ts_raw = terminalSize(io);
        const ts = ts_raw orelse .{ 100, 37, 0, 0 };
        const cols: usize = @max(40, ts[0]);
        const term_rows: usize = @max(8, ts[1]);
        const body_h = term_rows - 2; // one title row, one footer row
        const left_w = @min(@as(usize, 40), cols / 2);
        const right_w = cols - left_w - 3; // " │ " separator

        // Keep the selection on screen.
        if (sel < top) top = sel;
        if (sel >= top + body_h) top = sel + 1 - body_h;

        _ = frame_arena.reset(.retain_capacity);
        const fa = frame_arena.allocator();
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(fa, "\x1b[H");

        // Title bar: source + totals (+ the matching-class count while filtering).
        var hdr = std.ArrayList(u8).empty;
        try hdr.print(fa, " tile57 explore   {s}   {d} features \u{00B7} {d} classes", .{ src_base, rows.len, groups.len });
        if (filt.len > 0) try hdr.print(fa, "   filter \"{s}\" \u{2192} {d}", .{ filt, nvis_groups });
        try exEmitBar(fa, &buf, hdr.items, cols, true);
        try buf.appendSlice(fa, "\x1b[K\n");

        var r: usize = 0;
        while (r < body_h) : (r += 1) {
            // Left: the collapsible class tree, windowed around `top`.
            const li = top + r;
            if (li < vis.items.len) {
                const v = vis.items[li];
                const selected = li == sel;
                var segs: [8]ExSeg = undefined;
                var ns: usize = 0;
                if (v.is_header) {
                    const g = groups[v.group];
                    segs[ns] = .{ .t = if (g.expanded) "\u{25BE} " else "\u{25B8} ", .w = 2, .c = EXC_DIM };
                    ns += 1;
                    segs[ns] = .{ .t = g.class, .w = g.class.len, .c = EXC_BCYAN };
                    ns += 1;
                    const cnt: []const u8 = std.fmt.allocPrint(fa, "{d}", .{g.members.len}) catch "?";
                    const leftw = 2 + g.class.len;
                    const rightw = cnt.len + 2; // count + space + glyph
                    const spw = if (left_w > leftw + rightw) left_w - leftw - rightw else 1;
                    const spwc = @min(spw, EXC_SPACES.len);
                    segs[ns] = .{ .t = EXC_SPACES[0..spwc], .w = spwc, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = cnt, .w = cnt.len, .c = EXC_DIM };
                    ns += 1;
                    segs[ns] = .{ .t = " ", .w = 1, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = exGeomGlyph(g.dominant), .w = 1, .c = exGeomColor(g.dominant) };
                    ns += 1;
                } else {
                    const row = rows[v.row];
                    const sub = exSubLabel(row);
                    const dim = std.mem.startsWith(u8, sub, "foid:") or (sub.len > 0 and sub[0] == '#');
                    segs[ns] = .{ .t = "  ", .w = 2, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = exGeomGlyph(row.prim), .w = 1, .c = exGeomColor(row.prim) };
                    ns += 1;
                    segs[ns] = .{ .t = " ", .w = 1, .c = "" };
                    ns += 1;
                    segs[ns] = .{ .t = sub, .w = dispWidth(sub), .c = if (dim) EXC_DIM else "" };
                    ns += 1;
                }
                try exEmitLeft(fa, &buf, segs[0..ns], left_w, selected);
            } else {
                var k: usize = 0;
                while (k < left_w) : (k += 1) try buf.append(fa, ' ');
            }
            // Separator.
            try buf.appendSlice(fa, " ");
            try buf.appendSlice(fa, EXC_DIM);
            try buf.appendSlice(fa, "\u{2502}"); // │
            try buf.appendSlice(fa, EXC_RESET);
            try buf.appendSlice(fa, " ");
            // Right: the detail pane, windowed around `det_top`, colourised per line.
            const di = det_top + r;
            if (di < cur_det.len) try exEmitDetail(fa, &buf, cur_det[di], right_w, det_is_header and di == 0);
            try buf.appendSlice(fa, "\x1b[K\n");
        }

        // Footer keybar.
        if (filtering) {
            const t: []const u8 = std.fmt.allocPrint(fa, " filter class: {s}_    enter=apply   esc=clear", .{filt}) catch " filter";
            try exEmitBar(fa, &buf, t, cols, false);
        } else if (do_kitty) {
            try exEmitBar(fa, &buf, " j/k move  \u{2192}/enter expand  \u{2190} collapse  E/C all  / filter  [ ] scroll  m map  q quit", cols, false);
        } else {
            try exEmitBar(fa, &buf, " j/k move  \u{2192}/enter expand  \u{2190} collapse  E/C all  / filter  [ ] scroll  q quit", cols, false);
        }
        try buf.appendSlice(fa, "\x1b[J"); // clear anything below
        stdout.writeStreamingAll(io, buf.items) catch {};

        // --kitty: the LIVE CELL MAP, framed to the selection — a HEADER frames the
        // whole cell (the real quilted chart), a FEATURE frames the cell zoomed IN
        // around it. Transmit-and-displayed in the LOWER part of the detail pane
        // (BELOW the text, unless map-only), AFTER the text so it never scrolls the
        // layout. No cell / no framing clears any prior image.
        if (do_kitty) {
            // The image's pixel geometry (also the framing target — the feature
            // zoom depends on the canvas min dimension). Null = pane too small.
            const text_rows: usize = if (map_full) 0 else if (cur_det.len > det_top) @min(cur_det.len - det_top, body_h) else 0;
            var rendered = false;
            if (exMapGeom(right_w, left_w, term_rows, text_rows, map_full, ts_raw)) |gm| {
                if (sel_cell) |cp| {
                    // A FEATURE frames the cell zoomed IN around it AND highlights
                    // it; a HEADER frames the whole cell bbox (no single feature →
                    // no highlight). Either yields a real chart crop (context).
                    var view: ?MapView = null;
                    var hl: ?chart.Highlight = null;
                    if (gi) |g| {
                        const tv: ?ExThumb = if (rows[g].index < thumb_by_fi.len) thumb_by_fi[rows[g].index] else null;
                        if (tv) |t| {
                            view = exFeatureView(t, gm.w, gm.h);
                            hl = exFeatureHighlight(t);
                        }
                    } else if (cur != null and cur.?.is_header) {
                        if (cp.bounds()) |bnd| view = exFitCellView(bnd, gm.w, gm.h, MAP_CELL_FILL);
                    }
                    if (view) |v| {
                        exTuiMap(io, stdout, &thumb, cp, sel_portrayal, v, hl, palette, m, gm);
                        rendered = true;
                    }
                }
            }
            if (!rendered) {
                stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
                thumb.zoom = -1; // invalidate the cached view
            }
        }

        // Input.
        var b: [64]u8 = undefined;
        const n = std.posix.read(stdin_fd, &b) catch break;
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) {
            const c = b[i];
            if (filtering) {
                switch (c) {
                    0x0d, 0x0a => filtering = false, // enter (CR or LF): apply
                    0x1b => {
                        filt_len = 0;
                        filtering = false;
                    }, // esc: clear
                    0x7f, 0x08 => filt_len -|= 1, // backspace
                    else => if (c >= 0x20 and c < 0x7f and filt_len < filt_buf.len) {
                        filt_buf[filt_len] = c;
                        filt_len += 1;
                    },
                }
                i += 1;
                continue;
            }
            // Nav mode. Cursor escape sequences first (arrows + PgUp/PgDn).
            if (c == 0x1b and i + 2 < n and b[i + 1] == '[') {
                switch (b[i + 2]) {
                    'A' => sel -|= 1, // up
                    'B' => sel += 1, // down
                    'C' => { // right: expand the selected header
                        if (cur) |cc| if (cc.is_header) {
                            groups[cc.group].expanded = true;
                            det_kind = 3;
                            sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                        };
                    },
                    'D' => { // left: collapse the selected header (or a feature's parent)
                        if (cur) |cc| {
                            groups[cc.group].expanded = false;
                            det_kind = 3;
                            sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                        }
                    },
                    '5' => sel -|= body_h, // PgUp (ESC[5~)
                    '6' => sel += body_h, // PgDn (ESC[6~)
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (c) {
                'k' => sel -|= 1,
                'j' => sel += 1,
                'g' => sel = 0,
                'G' => sel = if (vis.items.len > 0) vis.items.len - 1 else 0,
                '[' => det_top -|= 1, // scroll detail up
                ']' => det_top += 1, // scroll detail down
                'm', 'M' => if (do_kitty) {
                    map_full = !map_full; // toggle map-only (hide the text under the map)
                    thumb.zoom = -1; // the canvas size changed → re-render the view
                },
                ' ', 0x0d, 0x0a => { // space / enter: toggle the selected header
                    if (cur) |cc| if (cc.is_header) {
                        groups[cc.group].expanded = !groups[cc.group].expanded;
                        det_kind = 3;
                        sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                    };
                },
                'E' => { // expand all classes
                    for (groups) |*g| g.expanded = true;
                    det_kind = 3;
                    if (cur) |cc| sel_target = cc;
                },
                'C' => { // collapse all classes
                    for (groups) |*g| g.expanded = false;
                    det_kind = 3;
                    if (cur) |cc| sel_target = .{ .is_header = true, .group = cc.group, .row = 0 };
                },
                '/' => {
                    filtering = true;
                    filt_len = 0;
                },
                'q', 'Q', 0x03 => return,
                else => {},
            }
            i += 1;
        }
        if (vis.items.len > 0 and sel >= vis.items.len) sel = vis.items.len - 1;
        if (cur_det.len > 0) det_top = @min(det_top, cur_det.len - 1) else det_top = 0;
    }
}

// The live cell map's on-screen geometry: its pixel size (`w`x`h`) and its 1-based
// top-left cell (`row`,`col`) in the detail pane. `w`/`h` are also the framing
// target (the feature zoom depends on the canvas min dimension), so the caller
// computes the geometry BEFORE the view.
const MapGeom = struct { w: u32, h: u32, row: usize, col: usize };

// Size + place the live cell map inside the detail pane. The body owns rows
// 2..term_rows-1 (title row 1, footer last). Normally the map fills the pane
// width and ~72% of the body height, pinned to the bottom with a few text rows
// kept above; map-only (`map_full`) gives it the whole body. Each axis is clamped
// to a sane pixel max so a huge terminal doesn't transmit an enormous PNG.
// Returns null when the pane is too small to hold a useful image.
fn exMapGeom(right_w: usize, left_w: usize, term_rows: usize, text_rows: usize, map_full: bool, ts_raw: ?[4]u32) ?MapGeom {
    const cp = cellPx(ts_raw);
    const cpw: usize = cp[0];
    const cph: usize = cp[1];
    const body_h: usize = term_rows - 2;
    const min_img_rows: usize = 6;
    const min_text_rows: usize = 3;
    const min_img_cols: usize = 16;
    const need_rows = if (map_full) min_img_rows else min_img_rows + min_text_rows;
    if (body_h < need_rows or right_w < min_img_cols) return null;

    const max_px: usize = 1600;
    var img_cols: usize = right_w;
    if (img_cols * cpw > max_px) img_cols = @max(min_img_cols, max_px / cpw);
    var img_rows: usize = if (map_full) body_h else std.math.clamp((body_h * 18) / 25, min_img_rows, body_h - min_text_rows);
    if (img_rows * cph > max_px) img_rows = @max(min_img_rows, max_px / cph);
    const top_offset: usize = if (map_full) 0 else @min(text_rows, body_h - img_rows);
    return .{
        .w = @intCast(img_cols * cpw),
        .h = @intCast(img_rows * cph),
        .row = 2 + top_offset, // 1-based; + img_rows-1 <= term_rows-1
        .col = left_w + 4, // 1-based left edge of the detail pane's content
    };
}

// Draw the LIVE CELL MAP for the current view (a full-context chart crop —
// chart.renderCellView, ALL features) into the detail pane at `geom`, positioned
// BELOW the visible text (or over the whole pane in map-only mode). The render +
// kitty encode run ONCE per VIEW (cached in `st` keyed on lon/lat/zoom + pixel
// size, re-run on a reframe or resize — the render is the slow step, the cached
// bytes are cheap to re-emit); every frame re-emits the cached a=T sequence AFTER
// the text so the redraw can't leave it stale. a=T (transmit-AND-display at the
// cursor) is the SAME escape shape as the console `--kitty` path. The image stays
// strictly within the body rows (footer clear) so its cursor-advance can't scroll
// the text away. Any failure clears the image and leaves the text intact.
fn exTuiMap(io: std.Io, stdout: std.Io.File, st: *ThumbState, cell: *engine.s57.Cell, portrayal: ?[]const ?[]const u8, view: MapView, highlight: ?chart.Highlight, palette: render.resolve.PaletteId, m: *const render.resolve.MarinerSettings, geom: MapGeom) void {
    const clear = struct {
        fn f(io_: std.Io, out: std.Io.File, s: *ThumbState) void {
            out.writeStreamingAll(io_, render.kitty.delete_all) catch {};
            s.zoom = -1;
            s.seq = null;
        }
    }.f;
    const w = geom.w;
    const h = geom.h;
    const hl_on = highlight != null;
    const hl_lon = if (highlight) |hh| hh.lon else 0;
    const hl_lat = if (highlight) |hh| hh.lat else 0;

    // (Re)render + rebuild the a=T sequence only when the VIEW, pixel size, or
    // HIGHLIGHTED feature changed. Keyed on the exact view + highlight so a new
    // selection (reframe) or a terminal resize invalidates, but re-selecting the
    // same item re-emits the cache.
    if (st.seq == null or st.lon != view.lon or st.lat != view.lat or st.zoom != view.zoom or st.w != w or st.h != h or st.hl_on != hl_on or st.hl_lon != hl_lon or st.hl_lat != hl_lat) {
        _ = st.arena.reset(.retain_capacity);
        const ta = st.arena.allocator();
        const png = chart.renderCellView(cell, portrayal, view.lon, view.lat, view.zoom, w, h, palette, m, .png, highlight) catch {
            clear(io, stdout, st);
            return;
        };
        defer chart.freeBytes(png);
        const seq = render.kitty.encodePng(ta, png) catch {
            clear(io, stdout, st);
            return;
        };
        st.seq = seq;
        st.lon = view.lon;
        st.lat = view.lat;
        st.zoom = view.zoom;
        st.w = w;
        st.h = h;
        st.hl_on = hl_on;
        st.hl_lon = hl_lon;
        st.hl_lat = hl_lat;
    }
    // Each frame: clear the previous frame's image, move the (hidden) cursor to the
    // map's top-left cell, then transmit+display the cached image.
    var mv: [40]u8 = undefined;
    const move = std.fmt.bufPrint(&mv, "\x1b[{d};{d}H", .{ geom.row, geom.col }) catch return;
    stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
    stdout.writeStreamingAll(io, move) catch {};
    stdout.writeStreamingAll(io, st.seq.?) catch {};
}

// Split text into lines (no trailing empty line for a final '\n'). Arena-owned.
fn splitLines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(a, line);
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

// Byte-clip a string to at most `w` bytes (a debug TUI; wide/UTF-8 clipping is
// best-effort, the terminal tolerates it).
fn clip(s: []const u8, w: usize) []const u8 {
    return if (s.len <= w) s else s[0..w];
}

fn padTo(a: std.mem.Allocator, buf: *std.ArrayList(u8), from: usize, to: usize) !void {
    var i = from;
    while (i < to) : (i += 1) try buf.append(a, ' ');
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}
