const std = @import("std");
const engine = @import("engine");
const assets = @import("assets");
const sprite = @import("sprite");
const render = @import("render");
const chart = @import("chart");
const catalog_embed = @import("catalog"); // embedded portrayal assets (colour profile)
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;

// tile57 png|pdf <cell.000 | bundle.pmtiles> <z> <x> <y> -o <out> [flags]  (one tile)
// tile57 png|pdf <source> --view <lon,lat,zoom> --size WxH -o <out> [flags] (a view)
// The render-engine pixel path: parse + portray a cell (or replay a baked
// PMTiles bundle), drive the engine through PixelSurface -> RasterCanvas ->
// PNG, or the same op stream -> PdfCanvas -> a deterministic vector PDF with
// real text objects. A view renders ONE whole scene across every covering
// tile (labels + declutter over the full canvas, no seams).
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8, output: render.pixel.Output) !void {
    if (args.len < 4) {
        std.debug.print("usage: tile57 {s} <cell.000|bundle.pmtiles> <z> <x> <y> -o <out> [--size N] [--palette day|dusk|night] [--rules DIR] [--dq] [--scale F]\n" ++
            "       tile57 {s} <source> --view <lon,lat,zoom> --size WxH -o <out> [flags]\n", .{ @tagName(output), @tagName(output) });
        return;
    }
    const path = args[2];
    const tile_mode = args[3].len > 0 and args[3][0] != '-';
    var z: u8 = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    if (tile_mode) {
        if (args.len < 6) return usageErr("tile mode needs z x y");
        z = std.fmt.parseInt(u8, args[3], 10) catch return usageErr("bad z");
        x = std.fmt.parseInt(u32, args[4], 10) catch return usageErr("bad x");
        y = std.fmt.parseInt(u32, args[5], 10) catch return usageErr("bad y");
    }

    var out_path: ?[]const u8 = null;
    var size_w: u32 = 256;
    var size_h: u32 = 256;
    var palette: render.resolve.PaletteId = .day;
    var rules: ?[]const u8 = null;
    var dq = false;
    var size_scale: f64 = 1.0; // physical-size multiplier (S-52 mm -> true mm)
    var view: ?struct { lon: f64, lat: f64, zoom: f64 } = null;
    // Mariner settings (defaults match the app: other ON for spot soundings).
    var m = render.resolve.MarinerSettings{ .display_other = true };
    var f = Flags{ .args = args, .i = if (tile_mode) 5 else 2 };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = f.next() orelse return usageErr("-o needs a path");
        } else if (std.mem.eql(u8, arg, "--size")) {
            const v = f.next() orelse return usageErr("--size needs a value");
            if (std.mem.indexOfScalar(u8, v, 'x')) |xi| {
                size_w = std.fmt.parseInt(u32, v[0..xi], 10) catch return usageErr("bad --size");
                size_h = std.fmt.parseInt(u32, v[xi + 1 ..], 10) catch return usageErr("bad --size");
            } else {
                size_w = std.fmt.parseInt(u32, v, 10) catch return usageErr("bad --size");
                size_h = size_w;
            }
        } else if (std.mem.eql(u8, arg, "--view")) {
            const v = f.next() orelse return usageErr("--view needs lon,lat,zoom");
            var it = std.mem.splitScalar(u8, v, ',');
            const lon = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lon");
            const lat = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lat");
            const zm = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view zoom");
            view = .{ .lon = lon, .lat = lat, .zoom = zm };
        } else if (std.mem.eql(u8, arg, "--palette")) {
            const v = f.next() orelse return usageErr("--palette needs a value");
            palette = std.meta.stringToEnum(render.resolve.PaletteId, v) orelse return usageErr("palette must be day|dusk|night");
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.next() orelse return usageErr("--rules needs a dir");
        } else if (std.mem.eql(u8, arg, "--dq")) {
            dq = true; // S-52 data-quality overlay (M_QUAL DQUAL* patterns)
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const v = f.next() orelse return usageErr("--scale needs a value");
            size_scale = std.fmt.parseFloat(f64, v) catch return usageErr("bad --scale");
        } else if (std.mem.eql(u8, arg, "--safety")) {
            const v = f.next() orelse return usageErr("--safety needs metres");
            m.safety_contour = std.fmt.parseFloat(f64, v) catch return usageErr("bad --safety");
        } else if (std.mem.eql(u8, arg, "--safety-depth")) {
            const v = f.next() orelse return usageErr("--safety-depth needs metres");
            m.safety_depth = std.fmt.parseFloat(f64, v) catch return usageErr("bad --safety-depth");
        } else if (std.mem.eql(u8, arg, "--shallow")) {
            const v = f.next() orelse return usageErr("--shallow needs metres");
            m.shallow_contour = std.fmt.parseFloat(f64, v) catch return usageErr("bad --shallow");
        } else if (std.mem.eql(u8, arg, "--deep")) {
            const v = f.next() orelse return usageErr("--deep needs metres");
            m.deep_contour = std.fmt.parseFloat(f64, v) catch return usageErr("bad --deep");
        } else if (std.mem.eql(u8, arg, "--feet")) {
            m.depth_unit = .feet;
        } else if (std.mem.eql(u8, arg, "--no-names")) {
            m.text_names = false;
        } else if (std.mem.eql(u8, arg, "--no-light-text")) {
            m.show_light_descriptions = false;
        } else if (std.mem.eql(u8, arg, "--no-other-text")) {
            m.text_other = false;
        } else if (std.mem.eql(u8, arg, "--no-other")) {
            m.display_other = false;
        } else if (std.mem.eql(u8, arg, "--plain")) {
            m.boundary_style = .plain;
        } else if (std.mem.eql(u8, arg, "--simplified")) {
            m.simplified_points = true;
        } else if (std.mem.eql(u8, arg, "--full-sectors")) {
            m.show_full_sector_lines = true;
        } else return usageErr("unknown flag");
    }
    const out = out_path orelse return usageErr("-o <out.png> is required");
    if (!tile_mode and view == null) return usageErr("--view lon,lat,zoom is required without z x y");

    // A DIRECTORY source is an ENC_ROOT: open it streaming through the chart
    // layer (band-quilted cell selection per covering view tile) and render.
    const is_dir = blk: {
        var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch break :blk false;
        d.close(io);
        break :blk true;
    };
    if (is_dir) {
        const v = view orelse return usageErr("an ENC_ROOT source needs --view");
        engine.portray.setQuiet(true);
        const c = chart.Chart.openPath(path, rules, false) catch return usageErr("cannot open ENC_ROOT");
        defer c.deinit();
        m.scheme = switch (palette) {
            .day => .day,
            .dusk => .dusk,
            .night => .night,
        };
        m.data_quality = dq;
        m.size_scale = size_scale;
        const bytes = c.renderView(v.lon, v.lat, v.zoom, size_w, size_h, palette, &m, output) catch return usageErr("render failed");
        defer chart.freeBytes(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes });
        std.debug.print("wrote {s}: view {d:.4},{d:.4} z{d:.2}, {d}x{d}px (ENC_ROOT quilt), {d} bytes\n", .{ out, v.lon, v.lat, v.zoom, size_w, size_h, bytes.len });
        return;
    }

    const from_bundle = std.mem.endsWith(u8, path, ".pmtiles");
    if (from_bundle and view == null) return usageErr("a .pmtiles source needs --view");

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var cell: engine.s57.Cell = undefined;
    var streams: []const ?[]const u8 = &.{};
    if (!from_bundle) {
        cell = try engine.s57.parseCell(a, data);
        engine.portray.setQuiet(true);
        // LIVE portrayal context: the mariner's real safety contour / depth /
        // contours / styles evaluate INSIDE the rules — the native win over
        // the tile path's fixed bake context.
        streams = try engine.portray.portrayCellWith(a, &cell, resolveRulesDir(rules), .{
            .safety_contour = m.safety_contour,
            .safety_depth = m.safety_depth,
            .shallow_contour = m.shallow_contour,
            .deep_contour = m.deep_contour,
            .plain_boundaries = m.boundary_style == .plain,
            .simplified_symbols = m.simplified_points,
            .full_light_lines = m.show_full_sector_lines,
        });
    }
    defer if (!from_bundle) cell.deinit();

    var colors = try render.resolve.Colors.init(a, catalog_embed.colorprofile[0].bytes);
    m.data_quality = dq;
    m.size_scale = size_scale;
    const settings = m;

    const zoom: f64 = if (view) |v| v.zoom else @floatFromInt(z);
    var ps = if (view != null) blk: {
        // 512-and-up outputs read as @2x (the CSS baseline is 256/tile).
        const dpr: f32 = if (@min(size_w, size_h) >= 512) 2 else 1;
        const zi = @round(zoom);
        const pt = 256.0 * std.math.pow(f64, 2.0, zoom - zi) * dpr;
        break :blk render.pixel.PixelSurface.initView(a, &colors, palette, &settings, zoom, size_w, size_h, @floatCast(pt), engine.tile.EXTENT);
    } else render.pixel.PixelSurface.init(a, &colors, palette, &settings, zoom, size_w, engine.tile.EXTENT);

    // Vector symbol store over the embedded catalogue, palette-matched CSS.
    const css_name = switch (palette) {
        .day => "daySvgStyle",
        .dusk => "duskSvgStyle",
        .night => "nightSvgStyle",
    };
    var css_data: []const u8 = "";
    for (catalog_embed.css) |e| {
        if (std.mem.eql(u8, e.name, css_name)) css_data = e.bytes;
    }
    const sym_srcs = try a.alloc(sprite.SvgSrc, catalog_embed.symbols.len);
    for (catalog_embed.symbols, 0..) |e, si| sym_srcs[si] = .{ .id = e.name, .svg = e.bytes };
    const fill_srcs = try a.alloc(sprite.AreaFillSrc, catalog_embed.areafills.len);
    for (catalog_embed.areafills, 0..) |e, fi| fill_srcs[fi] = .{ .id = e.name, .xml = e.bytes };
    const store = try sprite.CatalogStore.init(a, sym_srcs, fill_srcs, css_data);
    defer store.deinit();
    ps.store = store.asStore();
    ps.output = output;

    // Complex-linestyle table (idempotent; arena-backed — this run only).
    const ls_srcs = try a.alloc(assets.LineStyleSrc, catalog_embed.linestyles.len);
    for (catalog_embed.linestyles, 0..) |e, li| ls_srcs[li] = .{ .id = e.name, .xml = e.bytes };
    engine.scene.registerLinestylesXml(a, ls_srcs);

    const bytes = if (from_bundle) blk: {
        // Bundle-sourced replay: decode each covering baked tile and re-emit
        // it as Surface calls (bake context frozen; live-swappable props —
        // danger depth, sounding composition/unit — re-evaluate here).
        const v = view.?;
        var rd = try engine.pmtiles.Reader.init(a, data);
        defer rd.deinit();
        var vt = engine.scene.ViewTiles.init(v.lon, v.lat, v.zoom, size_w, size_h, ps.px_per_tile);
        const surf = ps.asSurface();
        try surf.beginScene(vt.z);
        const is_mlt = rd.header.tile_type == .mlt;
        while (vt.next()) |t| {
            const tb = (rd.getTile(a, t.z, t.x, t.y) catch continue) orelse continue;
            const layers = if (is_mlt)
                engine.mlt.decode(a, tb) catch continue
            else
                engine.mvt.decode(a, tb) catch continue;
            ps.setOrigin(t.origin_x, t.origin_y);
            try engine.scene.replayTile(surf, layers);
        }
        break :blk try surf.endScene(a);
    } else blk: {
        const cells = [_]engine.scene.CellRef{.{ .cell = &cell, .portrayal = streams }};
        break :blk if (view) |v|
            try engine.scene.generateView(&ps, a, a, &cells, v.lon, v.lat, v.zoom, false)
        else
            try engine.scene.generateTile(ps.asSurface(), a, a, &cells, z, x, y, false);
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes });
    if (view) |v| {
        std.debug.print("wrote {s}: view {d:.4},{d:.4} z{d:.2}, {d}x{d}px, {d} draw ops, {d} bytes\n", .{ out, v.lon, v.lat, v.zoom, size_w, size_h, ps.ops.items.len, bytes.len });
    } else {
        std.debug.print("wrote {s}: tile {d}/{d}/{d}, {d}x{d}px, {d} draw ops, {d} bytes\n", .{ out, z, x, y, size_w, size_h, ps.ops.items.len, bytes.len });
    }
}
