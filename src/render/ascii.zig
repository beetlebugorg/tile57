//! AsciiSurface: the Surface implementation that renders a chart into a TEXT
//! grid — one Unicode character per terminal cell. The worked example of how
//! cheap a new backend is: one file, no engine edits (surface.zig's promise).
//!
//!   Surface calls ─► lowering (S-52 token/symbol-name -> a character)
//!                ─► op buffer ─► endScene: sort by display_priority ─► char grid
//!
//! Lowering happens HERE, like the pixel surfaces resolve through resolve.zig:
//! fills pick a shade character per color token (LANDA '#', DEPVS '▒' …),
//! lines walk Bresenham with a slope-picked '-' '|' '/' '\', point symbols
//! place a single glyph by symbol-name family (buoys 'B', lights '*'),
//! soundings print their rounded depth, labels their first word. Optional
//! ANSI-256 mode resolves tokens through the same colorProfile the pixel path
//! uses (resolve.Colors) and quantizes to the xterm cube.
//!
//! Buffering exists for the same reason as pixel.zig: the engine emits
//! features in CELL order, but a grid must be WRITTEN in S-52 priority order.
//!
//! Rule (surface.zig): no s57/s101/portray imports — everything a character
//! needs is already on the call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rs = @import("surface.zig");
const paint = @import("paint.zig");
const resolve = @import("resolve.zig");
const sndfrm = @import("sndfrm.zig");
const declut = @import("declutter.zig");

/// Canvas px per character ROW. A terminal cell is ~twice as tall as it is
/// wide, so the surface exposes a w_px x h_px canvas of cols x rows*2 px to
/// the view driver (ViewTiles) and halves y when writing the grid — a circle
/// on the chart stays a circle on screen.
pub const ROW_PX = 2;

/// Unmapped color tokens paint '?' — the text-grid cousin of the pixel path's
/// magenta fallback: visible, never silent. A chart full of '?' is the cue to
/// add a row to `fill_chars`.
const FALLBACK_FILL: u21 = '?';

/// Unmapped tokens in ANSI mode quantize to the same magenta (xterm 201).
const FALLBACK_ANSI: u8 = 201;

// Area-fill shade per S-52 color token, shallow -> deep: land is solid,
// drying/shallow water hatches densest, safe water opens up to blank.
const fill_chars = [_]struct { token: []const u8, ch: u21 }{
    .{ .token = "LANDA", .ch = '#' }, // land
    .{ .token = "CHBRN", .ch = '@' }, // built structures (buildings, docks)
    .{ .token = "DEPIT", .ch = '%' }, // intertidal (dries)
    .{ .token = "DEPVS", .ch = '▒' }, // very shallow (inside the safety contour)
    .{ .token = "DEPMS", .ch = '░' }, // medium-shallow
    .{ .token = "DEPMD", .ch = '~' }, // medium-deep
    .{ .token = "DEPDW", .ch = ' ' }, // deep, safe water — open
    .{ .token = "NODTA", .ch = ' ' }, // no data (also the grid's ground state)
    .{ .token = "CHGRD", .ch = '·' }, // grey overlay washes (traffic lanes …)
    .{ .token = "CHGRF", .ch = '·' },
    .{ .token = "TRFCF", .ch = '·' },
};

// Point-symbol glyph by symbol-name FAMILY (first matching prefix wins, so
// the specific BOYLAT rides above the generic BOY). Everything unlisted gets
// the generic mark 'o' — a text grid can't carry 800 S-52 glyphs, but it can
// say "something is charted here".
const symbol_chars = [_]struct { prefix: []const u8, ch: u21 }{
    .{ .prefix = "BOYLAT", .ch = 'b' }, // lateral buoys
    .{ .prefix = "BOY", .ch = 'B' }, // every other buoy family
    .{ .prefix = "BCN", .ch = '!' }, // beacons
    .{ .prefix = "LIGHTS", .ch = '*' },
    .{ .prefix = "LITFLT", .ch = '*' }, // light floats/vessels
    .{ .prefix = "WRECKS", .ch = 'W' },
    .{ .prefix = "UWTROC", .ch = '+' }, // underwater rocks
    .{ .prefix = "ISODGR", .ch = 'x' }, // isolated dangers
    .{ .prefix = "DANGER", .ch = 'x' },
    .{ .prefix = "OBSTRN", .ch = 'x' },
    .{ .prefix = "ACHARE", .ch = 'a' }, // anchorages
    .{ .prefix = "ACHBRT", .ch = 'a' },
    .{ .prefix = "QUESMRK", .ch = '?' },
};

/// Grid-space point (canvas px: 1 px per column, ROW_PX px per row).
const Pt = struct { x: f32, y: f32 };

const OpKind = union(enum) {
    fill: struct { rings: []const []const Pt, ch: u21, color: ?u8 },
    pattern: struct { rings: []const []const Pt },
    stroke: struct { lines: []const []const Pt, dash: rs.Dash, color: ?u8 },
    glyph: struct { ch: u21, col: i64, row: i64, color: ?u8 },
    label: struct { text: []const u8, col: i64, row: i64, w: i64, color: ?u8, group: i64, class: []const u8 },
};

/// Paint class, the same as the pixel surface (pixel.zig OpLayer). NOT the major
/// sort key — it is the S-52 §10.3.4.1 tiebreak used only at equal priority.
const OpLayer = paint.Layer;

const Op = struct {
    layer: OpLayer,
    prio: i64,
    display_plane: i64 = 0,
    seq: usize,
    kind: OpKind,
};

/// See pixel.zig orderLt — this must stay byte-identical in behaviour.
/// `radar` is whether a RADAR overlay is present — the condition §10.3.4.2 puts
/// on the DisplayPlane axis. Without it, DisplayPlane is not an ordering axis at
/// all and priority leads.
fn orderLt(radar: bool, l: Op, r: Op) bool {
    const lk = paint.key(l.layer, l.prio, l.display_plane, radar);
    const rk = paint.key(r.layer, r.prio, r.display_plane, radar);
    if (lk != rk) return lk < rk;
    return l.seq < r.seq; // equal key: emission order (SENC sequence)
}

/// One character cell: the glyph and optional ANSI-256 fore/background. Cells
/// carry no occupancy flag: text is drawn LAST, over the marks beneath it, and
/// a label competes only with other labels — through the shared collision pool,
/// exactly like the pixel and vector surfaces.
const Cell = struct { ch: u21 = ' ', fg: ?u8 = null, bg: ?u8 = null };

pub const AsciiSurface = struct {
    a: Allocator,
    colors: *const resolve.Colors,
    palette: resolve.PaletteId,
    settings: *const resolve.Settings,
    /// Fractional display zoom the gates evaluate at.
    zoom: f64,
    /// Output size in characters.
    cols: u32,
    rows: u32,
    /// The canvas the view driver sees (w_px = cols, h_px = rows * ROW_PX) —
    /// the same field shape as PixelSurface so scene.generateView drives both.
    w_px: u32,
    h_px: u32,
    px_per_tile: f32,
    scale: f32,
    origin: Pt = .{ .x = 0, .y = 0 },
    /// ANSI-256 color mode: fills set backgrounds, marks set foregrounds.
    ansi: bool = false,
    ops: std.ArrayList(Op) = .empty,
    cur: rs.FeatureMeta = .{},
    cur_visible: bool = true,

    const vtable = rs.Surface.VTable{
        .beginScene = beginScene,
        .beginFeature = beginFeature,
        .fillArea = fillArea,
        .fillPattern = fillPattern,
        .strokeLine = strokeLine,
        .drawSymbol = drawSymbol,
        .drawSounding = drawSounding,
        .drawText = drawText,
        .endFeature = endFeature,
        .endScene = endScene,
    };

    /// `a` should be a scratch arena, like PixelSurface: buffered ops live
    /// until endScene. `px_per_tile` is the view driver's usual
    /// 256 * 2^(zoom - round(zoom)) — one character column plays one CSS px.
    pub fn initView(a: Allocator, colors: *const resolve.Colors, palette: resolve.PaletteId, settings: *const resolve.Settings, zoom: f64, cols: u32, rows: u32, px_per_tile: f32, tile_extent: u32) AsciiSurface {
        return .{
            .a = a,
            .colors = colors,
            .palette = palette,
            .settings = settings,
            .zoom = zoom,
            .cols = cols,
            .rows = rows,
            .w_px = cols,
            .h_px = rows * ROW_PX,
            .px_per_tile = px_per_tile,
            .scale = px_per_tile / @as(f32, @floatFromInt(tile_extent)),
        };
    }

    /// Position the NEXT tile's geometry: its top-left corner in canvas px.
    pub fn setOrigin(self: *AsciiSurface, x: f32, y: f32) void {
        self.origin = .{ .x = x, .y = y };
    }

    pub fn asSurface(self: *AsciiSurface) rs.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn sp(ctx: *anyopaque) *AsciiSurface {
        return @ptrCast(@alignCast(ctx));
    }

    /// Token -> ANSI-256 index (null in plain mode: the terminal's defaults).
    fn resolveColor(self: *const AsciiSurface, token: []const u8) ?u8 {
        if (!self.ansi) return null;
        const rgb = self.colors.get(self.palette, token) orelse return FALLBACK_ANSI;
        return ansi256(rgb);
    }

    fn fillChar(token: []const u8) u21 {
        for (fill_chars) |fc| {
            if (std.mem.eql(u8, fc.token, token)) return fc.ch;
        }
        return FALLBACK_FILL;
    }

    fn symbolChar(name: []const u8) ?u21 {
        // Topmarks ride their structure's anchor; a second glyph there would
        // just overwrite the buoy/beacon it decorates.
        if (std.mem.startsWith(u8, name, "TOPMAR")) return null;
        for (symbol_chars) |sc| {
            if (std.mem.startsWith(u8, name, sc.prefix)) return sc.ch;
        }
        return 'o';
    }

    fn toGrid(self: *AsciiSurface, parts: []const []const rs.TilePoint) ![]const []const Pt {
        const out = try self.a.alloc([]const Pt, parts.len);
        for (parts, 0..) |part, i| {
            const pts = try self.a.alloc(Pt, part.len);
            for (part, 0..) |p, j| pts[j] = .{
                .x = self.origin.x + @as(f32, @floatFromInt(p.x)) * self.scale,
                .y = self.origin.y + @as(f32, @floatFromInt(p.y)) * self.scale,
            };
            out[i] = pts;
        }
        return out;
    }

    /// The character cell under a canvas-px anchor.
    fn toCell(self: *const AsciiSurface, at: rs.TilePoint) struct { col: i64, row: i64 } {
        const x = self.origin.x + @as(f32, @floatFromInt(at.x)) * self.scale;
        const y = self.origin.y + @as(f32, @floatFromInt(at.y)) * self.scale;
        return .{ .col = @intFromFloat(@floor(x)), .row = @intFromFloat(@floor(y / ROW_PX)) };
    }

    fn push(self: *AsciiSurface, layer: OpLayer, kind: OpKind) !void {
        try self.ops.append(self.a, .{ .layer = layer, .prio = self.cur.display_priority, .display_plane = self.cur.display_plane, .seq = self.ops.items.len, .kind = kind });
    }

    // ---- Surface impl ---------------------------------------------------------

    fn beginScene(_: *anyopaque, _: u8) anyerror!void {}

    fn beginFeature(ctx: *anyopaque, meta: *const rs.FeatureMeta) anyerror!void {
        const self = sp(ctx);
        self.cur = meta.*;
        // Category / viewing-group / SCAMIN gates apply per feature, exactly
        // like the pixel surface.
        self.cur_visible = resolve.visible(meta, null, self.zoom, self.settings) and
            !droppedClass(meta.class);
    }

    // Classes dropped wholesale at character resolution: long dashed linework
    // that reads as clutter in a text grid. Depth CONTOURS go because the
    // depth-area shade ramp already carries the bathymetry; cables/pipelines
    // and navigation (leading/clearing/transit) lines go because a screenful
    // of `- - -` swallows the marks that matter here (soundings, buoys,
    // coastline).
    fn droppedClass(class: []const u8) bool {
        const dropped = [_][]const u8{
            "DEPCNT", // depth contour
            "CBLSUB", "CBLOHD", "CBLARE", // cables (submarine / overhead / area)
            "PIPSOL", "PIPOHD", "PIPARE", // pipelines (submarine-on-land / overhead / area)
            "NAVLNE", // navigation line (leading / clearing / transit)
        };
        for (dropped) |d| if (std.mem.eql(u8, class, d)) return true;
        return false;
    }

    fn fillArea(ctx: *anyopaque, token: rs.ColorToken, rings: []const []const rs.TilePoint, depth: ?rs.DepthRange) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        // A depth area re-shades LIVE against the mariner's contours (SEABED01) — the
        // baked token carries the bake context's contours, not this mariner's. The
        // depth shade is most of what this backend draws, so it must swap here too.
        const tok = if (depth) |d| resolve.seabedToken(d, self.settings) else token;
        // In ANSI mode land reads as a solid background wash, not a wall of
        // '#'/'@' — the color alone carries it, and marks/labels on land stay
        // legible. Plain text keeps the glyphs (no color to carry the fill).
        const ch = if (self.ansi and (std.mem.eql(u8, tok, "LANDA") or std.mem.eql(u8, tok, "CHBRN")))
            ' '
        else
            fillChar(tok);
        try self.push(.area, .{ .fill = .{ .rings = try self.toGrid(rings), .ch = ch, .color = self.resolveColor(tok) } });
    }

    fn fillPattern(ctx: *anyopaque, name: rs.SymbolName, rings: []const []const rs.TilePoint) anyerror!void {
        _ = name; // every S-52 pattern lowers to the same sparse dot lattice
        const self = sp(ctx);
        if (!self.cur_visible) return;
        try self.push(.pattern, .{ .pattern = .{ .rings = try self.toGrid(rings) } });
    }

    fn strokeLine(ctx: *anyopaque, token: rs.ColorToken, width_px: f64, dash: rs.Dash, lines: []const []const rs.TilePoint, valdco: ?f64) anyerror!void {
        _ = width_px; // a text grid has exactly one line weight
        _ = valdco; // contour labels would fight the soundings for cells; the sounding digits already carry depths
        const self = sp(ctx);
        if (!self.cur_visible) return;
        try self.push(.line, .{ .stroke = .{ .lines = try self.toGrid(lines), .dash = dash, .color = self.resolveColor(token) } });
    }

    fn drawSymbol(ctx: *anyopaque, name: rs.SymbolName, at: rs.TilePoint, rot_deg: f64, scale: f64, rot_north: bool, placement: rs.SymbolPlacement, danger_depth: ?f64) anyerror!void {
        _ = rot_deg; // a single character doesn't rotate
        _ = scale;
        _ = rot_north;
        const self = sp(ctx);
        // Linestyle-tessellated symbols would shout over the stroke that
        // already draws their line; anchor-placed marks only.
        if (placement == .line) return;
        // Re-gate with the symbol name: ISODGR01 rides its own toggle.
        if (!resolve.visible(&self.cur, name, self.zoom, self.settings)) return;
        // Any danger with a depth is an 'x', DANGER01/02 alike — the live
        // shallow/deep swap is a colour nuance a character can't carry.
        const ch = if (danger_depth != null) 'x' else (symbolChar(name) orelse return);
        const cell = self.toCell(at);
        try self.push(.symbol, .{ .glyph = .{ .ch = ch, .col = cell.col, .row = cell.row, .color = self.resolveColor("CHBLK") } });
    }

    fn drawSounding(ctx: *anyopaque, depth_m: f64, swept: bool, low_acc: bool, at: rs.TilePoint) anyerror!void {
        _ = swept; // quality rings don't survive the trip to one character
        _ = low_acc;
        const self = sp(ctx);
        if (!resolve.visible(&self.cur, null, self.zoom, self.settings)) return;
        // Rounded depth in the mariner's unit. The pixel path's bold/faint
        // safety split (SOUNDS/SOUNDG) is a glyph nicety the grid drops.
        const shown = if (self.settings.depth_unit == .feet) depth_m * sndfrm.M_TO_FT else depth_m;
        var buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}", .{@round(shown)}) catch return;
        const cell = self.toCell(at);
        // A sounding is a SYMBOL: it always draws and never enters the collision
        // pool (see declutter.zig). Text simply draws on top of it.
        try self.push(.sounding, .{
            .label = .{
                .text = try self.a.dupe(u8, label),
                .col = cell.col - @as(i64, @intCast(label.len / 2)), // centred on the spot
                .row = cell.row,
                .w = @intCast(label.len),
                .color = self.resolveColor("CHGRD"),
                .group = 0,
                .class = self.cur.class,
            },
        });
    }

    fn drawText(ctx: *anyopaque, text: []const u8, style: *const rs.TextStyle, at: rs.TilePoint) anyerror!void {
        const self = sp(ctx);
        if (!self.cur_visible) return;
        if (!resolve.textGroupVisible(style.group, self.settings)) return;
        // First word only: a text grid earns its keep with placement, not prose.
        const word = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
        if (word.len == 0) return;
        const cell = self.toCell(at);
        var col = cell.col;
        if (std.mem.eql(u8, style.halign, "center")) col -= @intCast(word.len / 2);
        if (std.mem.eql(u8, style.halign, "right")) col -= @intCast(word.len);
        try self.push(.text, .{ .label = .{
            .text = try self.a.dupe(u8, word),
            .col = col,
            .row = cell.row,
            .w = @intCast(word.len),
            .color = self.resolveColor(style.color),
            .group = style.group,
            .class = self.cur.class,
        } });
    }

    fn endFeature(_: *anyopaque) anyerror!void {}

    // ---- painting ---------------------------------------------------------------

    fn cellAt(self: *AsciiSurface, grid: []Cell, col: i64, row: i64) ?*Cell {
        if (col < 0 or row < 0 or col >= self.cols or row >= self.rows) return null;
        return &grid[@as(usize, @intCast(row)) * self.cols + @as(usize, @intCast(col))];
    }

    /// Even-odd scanline fill through each character row's px midline. When
    /// `lattice` is set only a sparse dot pattern is written (fillPattern).
    fn paintFill(self: *AsciiSurface, grid: []Cell, rings: []const []const Pt, ch: u21, color: ?u8, lattice: bool) !void {
        var xs = std.ArrayList(f32).empty;
        defer xs.deinit(self.a);
        var r: u32 = 0;
        while (r < self.rows) : (r += 1) {
            const y = (@as(f32, @floatFromInt(r)) + 0.5) * ROW_PX;
            xs.clearRetainingCapacity();
            for (rings) |ring| {
                if (ring.len < 3) continue;
                for (ring, 0..) |p, i| {
                    const q = ring[(i + 1) % ring.len]; // implicit closing edge
                    if ((p.y > y) == (q.y > y)) continue;
                    try xs.append(self.a, p.x + (y - p.y) * (q.x - p.x) / (q.y - p.y));
                }
            }
            std.mem.sort(f32, xs.items, {}, std.sort.asc(f32));
            var i: usize = 0;
            while (i + 1 < xs.items.len) : (i += 2) {
                var c: i64 = @intFromFloat(@ceil(xs.items[i] - 0.5));
                const c_end: i64 = @intFromFloat(@floor(xs.items[i + 1] - 0.5));
                while (c <= c_end) : (c += 1) {
                    const cell = self.cellAt(grid, c, r) orelse continue;
                    if (lattice) {
                        // Sparse lattice, offset per row band, over whatever
                        // fill is already there.
                        if (r % 2 == 0 and @mod(c + r, 4) == 0) cell.ch = '·';
                    } else {
                        cell.* = .{ .ch = ch, .bg = color };
                    }
                }
            }
        }
    }

    // Slope-picked stroke character, in CELL units (y down): mostly-horizontal
    // runs read '-', mostly-vertical '|', diagonals '\' and '/'.
    fn segChar(dc: i64, dr: i64) u21 {
        if (@abs(dc) >= 2 * @abs(dr)) return '-';
        if (@abs(dr) >= 2 * @abs(dc)) return '|';
        return if ((dc > 0) == (dr > 0)) '\\' else '/';
    }

    /// Bresenham over character cells, one segment at a time. Dashed lines
    /// skip alternating pairs of cells — the [4,3] px pattern's grid cousin.
    fn paintStroke(self: *AsciiSurface, grid: []Cell, lines: []const []const Pt, dash: rs.Dash, color: ?u8) void {
        for (lines) |line| {
            for (0..line.len -| 1) |i| {
                const c0: i64 = @intFromFloat(@floor(line[i].x));
                const r0: i64 = @intFromFloat(@floor(line[i].y / ROW_PX));
                const c1: i64 = @intFromFloat(@floor(line[i + 1].x));
                const r1: i64 = @intFromFloat(@floor(line[i + 1].y / ROW_PX));
                const ch = segChar(c1 - c0, r1 - r0);
                const dc: i64 = @intCast(@abs(c1 - c0));
                const dr: i64 = @intCast(@abs(r1 - r0));
                const sc: i64 = if (c1 > c0) 1 else -1;
                const sr: i64 = if (r1 > r0) 1 else -1;
                var err = dc - dr;
                var c = c0;
                var r = r0;
                var step: u32 = 0;
                while (true) : (step += 1) {
                    if (dash == .solid or step % 4 < 2) {
                        if (self.cellAt(grid, c, r)) |cell| {
                            cell.ch = ch;
                            cell.fg = color;
                        }
                    }
                    if (c == c1 and r == r1) break;
                    const e2 = 2 * err;
                    if (e2 > -dr) {
                        err -= dr;
                        c += sc;
                    }
                    if (e2 < dc) {
                        err += dc;
                        r += sr;
                    }
                }
            }
        }
    }

    /// Write a run of characters into the grid, over whatever is under them —
    /// text is drawn last. A run that would fall off the grid is skipped whole
    /// (a half-written label is worse than none). WHICH labels get here is the
    /// pool's decision, not the grid's.
    fn paintLabel(self: *AsciiSurface, grid: []Cell, text: []const u8, col: i64, row: i64, color: ?u8) void {
        var view = std.unicode.Utf8View.init(text) catch return;
        var n: i64 = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |_| : (n += 1) {
            _ = self.cellAt(grid, col + n, row) orelse return; // clipped: skip whole label
        }
        it = view.iterator();
        n = 0;
        while (it.nextCodepoint()) |cp| : (n += 1) {
            const cell = self.cellAt(grid, col + n, row).?;
            cell.ch = cp;
            cell.fg = color;
        }
    }

    fn endScene(ctx: *anyopaque, out: Allocator) anyerror![]u8 {
        const self = sp(ctx);
        // Label declutter, through the shared pool (render/declutter.zig owns the
        // policy — see there for why only text competes). Candidates go in by
        // EMISSION order, which is why this runs before the paint sort. Boxes are
        // character cells: the medium differs from the raster's pixels, the
        // ranking does not.
        var pool = declut.Pool{};
        defer pool.deinit(self.a);
        for (self.ops.items) |op| {
            if (op.layer != .text) continue;
            const l = switch (op.kind) {
                .label => |lb| lb,
                else => continue,
            };
            try pool.add(self.a, op.seq, l.group, l.class, l.text, .{
                .x0 = @floatFromInt(l.col),
                .y0 = @floatFromInt(l.row),
                .x1 = @floatFromInt(l.col + l.w - 1),
                .y1 = @floatFromInt(l.row),
            });
        }
        // The grid's unit is a CHARACTER, not a pixel: one column plays one CSS px,
        // so the reference spacing converts at the surface's px-per-column.
        var kept = try pool.resolve(self.a, declut.REPEAT_PX / @as(f64, @floatFromInt(ROW_PX)));
        defer kept.deinit(self.a);

        // Paint order = the pixel surface's exact sort: (DrawingPriority,
        // emission order), text last. See pixel.zig OpLayer for why geometry
        // class is not a key.
        std.mem.sort(Op, self.ops.items, self.settings.radar_overlay, orderLt);

        const grid = try self.a.alloc(Cell, @as(usize, self.cols) * self.rows);
        @memset(grid, .{});

        // Fills, patterns, lines, symbols and SOUNDINGS paint LOW to HIGH priority
        // — later (higher) writes overwrite, exactly like painting pixels. A
        // sounding is a symbol: it always draws, and blocks no label.
        for (self.ops.items) |op| switch (op.kind) {
            .fill => |f| try self.paintFill(grid, f.rings, f.ch, f.color, false),
            .pattern => |p| try self.paintFill(grid, p.rings, ' ', null, true),
            .stroke => |s| self.paintStroke(grid, s.lines, s.dash, s.color),
            .glyph => |g| if (self.cellAt(grid, g.col, g.row)) |cell| {
                cell.ch = g.ch;
                cell.fg = g.color;
            },
            .label => |l| if (op.layer == .sounding) self.paintLabel(grid, l.text, l.col, l.row, l.color),
        };
        // Text paints LAST, over the marks beneath it, and only where the pool
        // kept it — the grid's version of the pixel collision pass, resolving
        // through the very same policy.
        for (self.ops.items) |op| switch (op.kind) {
            .label => |l| if (op.layer == .text and kept.has(op.seq))
                self.paintLabel(grid, l.text, l.col, l.row, l.color),
            else => {},
        };

        // Encode: UTF-8 rows; in ANSI mode fore/background escapes are emitted
        // only on change, and every row ends reset so a pager can't bleed.
        // ANSI output is bracketed in DECAWM autowrap-off/-on (ESC[?7l/?7h) so
        // a grid wider than the terminal CLIPS at the right edge instead of
        // wrapping and shearing the picture.
        var buf = std.ArrayList(u8).empty;
        if (self.ansi) try buf.appendSlice(out, "\x1b[?7l");
        var r: u32 = 0;
        while (r < self.rows) : (r += 1) {
            var fg: ?u8 = null; // rows start at the terminal defaults
            var bg: ?u8 = null;
            var c: u32 = 0;
            while (c < self.cols) : (c += 1) {
                const cell = grid[@as(usize, r) * self.cols + c];
                if (self.ansi) {
                    if (!std.meta.eql(cell.bg, bg)) {
                        bg = cell.bg;
                        if (bg) |n| try buf.print(out, "\x1b[48;5;{d}m", .{n}) else try buf.appendSlice(out, "\x1b[49m");
                    }
                    if (!std.meta.eql(cell.fg, fg)) {
                        fg = cell.fg;
                        if (fg) |n| try buf.print(out, "\x1b[38;5;{d}m", .{n}) else try buf.appendSlice(out, "\x1b[39m");
                    }
                }
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.ch, &utf8) catch continue;
                try buf.appendSlice(out, utf8[0..n]);
            }
            if (self.ansi and (fg != null or bg != null)) try buf.appendSlice(out, "\x1b[0m");
            try buf.append(out, '\n');
        }
        if (self.ansi) try buf.appendSlice(out, "\x1b[?7h");
        return buf.toOwnedSlice(out);
    }
};

/// RGB -> the nearest xterm-256 index: the 6x6x6 color cube (16..231), or the
/// grayscale ramp (232..255) for pure grays. The standard quantization every
/// terminal palette tool uses.
fn ansi256(c: resolve.Rgb) u8 {
    if (c.r == c.g and c.g == c.b) {
        if (c.r < 8) return 16; // cube black
        if (c.r > 248) return 231; // cube white
        return @intCast(232 + (@as(u32, c.r) - 8) * 24 / 247);
    }
    const q = struct {
        fn f(v: u8) u8 {
            if (v < 48) return 0;
            if (v < 114) return 1;
            return @intCast(@min(5, (@as(u32, v) - 35) / 40));
        }
    }.f;
    return 16 + 36 * q(c.r) + 6 * q(c.g) + q(c.b);
}

// ---- tests -------------------------------------------------------------------

const test_profile =
    \\<palette name="Day">
    \\ <item token="LANDA"><srgb><red>226</red><green>193</green><blue>129</blue></srgb></item>
    \\ <item token="DEPVS"><srgb><red>180</red><green>210</green><blue>230</blue></srgb></item>
    \\ <item token="CHBLK"><srgb><red>0</red><green>0</green><blue>0</blue></srgb></item>
    \\ <item token="CHGRD"><srgb><red>90</red><green>105</green><blue>119</blue></srgb></item>
    \\</palette>
;

// Grid helper: the codepoint at (col, row) of rendered rows (plain mode).
fn charAt(text: []const u8, cols: u32, col: u32, row: u32) !u21 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var r: u32 = 0;
    while (lines.next()) |line| : (r += 1) {
        if (r != row) continue;
        var it = (try std.unicode.Utf8View.init(line)).iterator();
        var c: u32 = 0;
        while (it.nextCodepoint()) |cp| : (c += 1) {
            if (c == col) return cp;
        }
        _ = cols;
    }
    return error.OutOfGrid;
}

test "AsciiSurface: fills shade by token, strokes pick slope chars, glyphs and labels place" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.Settings{};
    // 32x16 chars = a 32x32 px canvas; tile extent 32 makes tile units = px.
    var as = AsciiSurface.initView(a, &colors, .day, &settings, 14.0, 32, 16, 32, 32);
    const surf = as.asSurface();
    try surf.beginScene(14);

    const full = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 32 }, .{ .x = 0, .y = 32 } };
    const rings = [_][]const rs.TilePoint{&full};
    const water = rs.FeatureMeta{ .display_priority = 1 };
    try surf.beginFeature(&water);
    try surf.fillArea("DEPVS", &rings, .{ .d1 = 0, .d2 = 5 });
    try surf.endFeature();

    // A horizontal line across the middle, a mark, a sounding, and a name.
    const line = [_]rs.TilePoint{ .{ .x = 0, .y = 16 }, .{ .x = 32, .y = 16 } };
    const lines = [_][]const rs.TilePoint{&line};
    const feat = rs.FeatureMeta{ .display_priority = 6 };
    try surf.beginFeature(&feat);
    try surf.strokeLine("CHBLK", 1, .solid, &lines, null);
    try surf.drawSymbol("BOYLAT24", .{ .x = 4, .y = 4 }, 0, 1, false, .point, null);
    try surf.drawSymbol("MARKER99", .{ .x = 8, .y = 4 }, 0, 1, false, .line, null); // line-placed: dropped
    try surf.drawSounding(4.4, false, false, .{ .x = 16, .y = 8 });
    const style = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 26 };
    try surf.drawText("Annapolis Harbor", &style, .{ .x = 8, .y = 24 });
    try surf.endFeature();

    // A SCAMIN 1:30000 feature at zoom 10 (gate ~13.19): dropped entirely.
    var as_low = AsciiSurface.initView(a, &colors, .day, &settings, 10.0, 32, 16, 32, 32);
    const gated = rs.FeatureMeta{ .display_priority = 9, .scamin = 30000 };
    try as_low.asSurface().beginFeature(&gated);
    try as_low.asSurface().fillArea("LANDA", &rings, null);
    try std.testing.expectEqual(@as(usize, 0), as_low.ops.items.len);

    const text = try surf.endScene(a);
    // Exact dimensions: 16 rows of 32 codepoints.
    var it = std.mem.splitScalar(u8, text, '\n');
    var nrows: u32 = 0;
    while (it.next()) |row| {
        if (row.len == 0) continue; // trailing split after the last '\n'
        try std.testing.expectEqual(@as(usize, 32), try std.unicode.utf8CountCodepoints(row));
        nrows += 1;
    }
    try std.testing.expectEqual(@as(u32, 16), nrows);
    try std.testing.expectEqual(@as(u21, '▒'), try charAt(text, 32, 0, 0)); // DEPVS shade
    try std.testing.expectEqual(@as(u21, '-'), try charAt(text, 32, 0, 8)); // horizontal stroke
    try std.testing.expectEqual(@as(u21, 'b'), try charAt(text, 32, 4, 2)); // lateral buoy
    try std.testing.expectEqual(@as(u21, '4'), try charAt(text, 32, 16, 4)); // 4.4 m rounds to "4"
    try std.testing.expect(std.mem.indexOf(u8, text, "Annapolis") != null); // first word only
    try std.testing.expect(std.mem.indexOf(u8, text, "Harbor") == null);
}

test "labels declutter: highest priority claims the cells, overlap is dropped" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.Settings{};
    var as = AsciiSurface.initView(a, &colors, .day, &settings, 14.0, 32, 16, 32, 32);
    const surf = as.asSurface();

    // IMPORTANT text (a bridge's vertical clearance, group 11) against Other
    // text (a geographic name, group 26) on the same spot. The name is emitted
    // FIRST and carries the HIGHER feature draw priority — neither buys it the
    // space: the text group is the whole ladder, and a label's feature priority
    // says nothing about the label (all text is drawn last, at priority 8).
    const name = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 26 };
    const clearance = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 11 };
    const hi = rs.FeatureMeta{ .display_priority = 9 };
    try surf.beginFeature(&hi);
    try surf.drawText("loser", &name, .{ .x = 8, .y = 8 });
    try surf.endFeature();
    const lo = rs.FeatureMeta{ .display_priority = 3 };
    try surf.beginFeature(&lo);
    try surf.drawText("winner", &clearance, .{ .x = 8, .y = 8 });
    try surf.endFeature();

    const text = try surf.endScene(a);
    try std.testing.expect(std.mem.indexOf(u8, text, "winner") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loser") == null);
}

test "labels declutter: a sounding neither drops a label nor is dropped by one" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.Settings{};
    var as = AsciiSurface.initView(a, &colors, .day, &settings, 14.0, 32, 16, 32, 32);
    const surf = as.asSurface();

    // The sounding is drawn FIRST, right where the light description lands. It
    // is a symbol: it claims nothing, so the label survives — and the sounding
    // still draws. Toggling soundings therefore cannot cost a chart its labels.
    const meta = rs.FeatureMeta{ .display_priority = 5 };
    try surf.beginFeature(&meta);
    try surf.drawSounding(4.0, false, false, .{ .x = 8, .y = 8 });
    try surf.endFeature();
    const light = rs.TextStyle{ .color = "CHBLK", .font_size = 12, .group = 23 };
    try surf.beginFeature(&meta);
    try surf.drawText("FlR", &light, .{ .x = 8, .y = 8 });
    try surf.endFeature();

    const text = try surf.endScene(a);
    try std.testing.expect(std.mem.indexOf(u8, text, "FlR") != null);
}

test "ANSI mode: tokens quantize to xterm-256, rows reset, plain mode stays escape-free" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The quantizer: cube corners, cube interior, gray ramp.
    try std.testing.expectEqual(@as(u8, 196), ansi256(.{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 16), ansi256(.{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 231), ansi256(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(@as(u8, 243), ansi256(.{ .r = 128, .g = 128, .b = 128 }));

    var colors = try resolve.Colors.init(a, test_profile);
    const settings = resolve.Settings{};
    var as = AsciiSurface.initView(a, &colors, .day, &settings, 14.0, 8, 4, 8, 8);
    as.ansi = true;
    const surf = as.asSurface();
    const full = [_]rs.TilePoint{ .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 8, .y = 8 }, .{ .x = 0, .y = 8 } };
    const rings = [_][]const rs.TilePoint{&full};
    const meta = rs.FeatureMeta{ .display_priority = 1 };
    try surf.beginFeature(&meta);
    try surf.fillArea("DEPVS", &rings, null);
    try surf.endFeature();
    const text = try surf.endScene(a);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[48;5;") != null); // fill = background
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[0m\n") != null); // rows end reset

    var plain = AsciiSurface.initView(a, &colors, .day, &settings, 14.0, 8, 4, 8, 8);
    const psurf = plain.asSurface();
    try psurf.beginFeature(&meta);
    try psurf.fillArea("DEPVS", &rings, null);
    try psurf.endFeature();
    const ptext = try psurf.endScene(a);
    try std.testing.expect(std.mem.indexOfScalar(u8, ptext, 0x1b) == null);
}
