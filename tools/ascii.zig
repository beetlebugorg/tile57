const std = @import("std");
const engine = @import("engine");
const render = @import("render");
const chart = @import("chart");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const worldPxOf = common.worldPxOf;
const mercShift = common.mercShift;
const terminalSize = common.terminalSize;
const cellPx = common.cellPx;

// tile57 ascii <cell.000 | bundle.pmtiles> --view <lon,lat,zoom>
//     [--size COLSxROWS (default: terminal size)] [--palette day|dusk|night] [--ansi] [--tui] [--kitty] [--rules DIR]
// The chart on stdout as a Unicode text grid — the render-engine EXAMPLE
// backend (src/render/ascii.zig): the same chart layer + view driver as
// `tile57 png`, with the AsciiSurface at the end instead of the pixel one.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 ascii <cell.000|bundle.pmtiles> --view <lon,lat,zoom> [--size COLSxROWS (default: terminal size)] [--palette day|dusk|night] [--ansi] [--tui] [--kitty] [--rules DIR]\n", .{});
        return;
    }
    const path = args[2];
    var cols: u32 = 100;
    var rows: u32 = 36;
    var size_given = false;
    var palette: render.resolve.PaletteId = .day;
    var rules: ?[]const u8 = null;
    var ansi = false;
    var tui = false;
    var kitty = false;
    var view: ?struct { lon: f64, lat: f64, zoom: f64 } = null;
    var f = Flags{ .args = args, .i = 2 };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "--view")) {
            const v = f.next() orelse return usageErr("--view needs lon,lat,zoom");
            var it = std.mem.splitScalar(u8, v, ',');
            const lon = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lon");
            const lat = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view lat");
            const zm = std.fmt.parseFloat(f64, it.next() orelse "") catch return usageErr("bad --view zoom");
            view = .{ .lon = lon, .lat = lat, .zoom = zm };
        } else if (std.mem.eql(u8, arg, "--size")) {
            const v = f.next() orelse return usageErr("--size needs COLSxROWS");
            const xi = std.mem.indexOfScalar(u8, v, 'x') orelse return usageErr("bad --size");
            cols = std.fmt.parseInt(u32, v[0..xi], 10) catch return usageErr("bad --size");
            rows = std.fmt.parseInt(u32, v[xi + 1 ..], 10) catch return usageErr("bad --size");
            size_given = true;
        } else if (std.mem.eql(u8, arg, "--palette")) {
            const v = f.next() orelse return usageErr("--palette needs a value");
            palette = std.meta.stringToEnum(render.resolve.PaletteId, v) orelse return usageErr("palette must be day|dusk|night");
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.next() orelse return usageErr("--rules needs a dir");
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi = true;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            tui = true;
        } else if (std.mem.eql(u8, arg, "--kitty")) {
            kitty = true;
        } else return usageErr("unknown flag");
    }
    const v = view orelse return usageErr("--view lon,lat,zoom is required");
    // No explicit --size: fit the terminal (minus a prompt line) so the
    // picture never line-wraps; non-TTY output (pipes/files) keeps the fixed
    // default. ANSI mode additionally brackets its output in DECAWM
    // autowrap-off (see AsciiSurface), so even an over-wide grid clips at the
    // right edge instead of wrapping.
    if (!size_given) {
        if (terminalSize(io)) |ts| {
            cols = @max(20, ts[0]);
            rows = @max(10, ts[1] -| 1);
        }
    }
    if (cols == 0 or rows == 0) return usageErr("--size must be positive");

    engine.portray.setQuiet(true);
    // Baked tiles are the only multi-cell path: an ENC_ROOT is baked first,
    // then the bundle's .pmtiles is rendered (tile replay).
    const is_dir = blk: {
        var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch break :blk false;
        d.close(io);
        break :blk true;
    };
    if (is_dir) {
        std.debug.print("ENC_ROOT live rendering removed — bake first:\n  tile57 bake {s} -o <out>\n  tile57 ascii <out>/tiles/chart.pmtiles --view ...\n", .{path});
        return;
    }
    const c = if (std.mem.endsWith(u8, path, ".pmtiles")) blk: {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        break :blk chart.Chart.openBytes(data, .pmtiles, rules) catch return usageErr("cannot open bundle");
    } else chart.Chart.openPath(path, rules, false) catch return usageErr("cannot open source");
    defer c.deinit();

    var m = render.resolve.MarinerSettings{ .display_other = true };
    m.scheme = switch (palette) {
        .day => .day,
        .dusk => .dusk,
        .night => .night,
    };
    if (tui) return runAsciiTui(io, a, c, v.lon, v.lat, v.zoom, palette, &m, ansi, kitty);

    if (kitty) {
        // Real S-52 pixels inline via the kitty graphics protocol (Ghostty,
        // Kitty, WezTerm, Konsole): the grid's cell count times the
        // terminal's cell-pixel size (or the 10x20 guess off-TTY).
        const cp = cellPx(terminalSize(io));
        const png_bytes = c.renderView(v.lon, v.lat, v.zoom, cols * cp[0], rows * cp[1], palette, &m, .png, null) catch return usageErr("render failed");
        defer chart.freeBytes(png_bytes);
        const seq = render.kitty.encodePng(a, png_bytes) catch return usageErr("encode failed");
        std.Io.File.stdout().writeStreamingAll(io, seq) catch {};
        std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
        return;
    }

    const text = c.renderAscii(v.lon, v.lat, v.zoom, cols, rows, palette, &m, ansi) catch return usageErr("render failed");
    defer chart.freeBytes(text);
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

// `tile57 ascii --tui`: an interactive pan/zoom loop around the ascii surface.
// Arrow keys pan by an eighth of the view, +/- zoom by half a level, q (or
// ctrl-c) quits. cbreak-style input (no echo/canonical, OPOST kept so \n still
// carriage-returns), alternate screen + hidden cursor, terminal re-measured
// every frame so a resize just repaints.
fn runAsciiTui(io: std.Io, a: std.mem.Allocator, c: *chart.Chart, lon0: f64, lat0: f64, zoom0: f64, palette: render.resolve.PaletteId, m: *render.resolve.MarinerSettings, ansi: bool, kitty: bool) !void {
    // The interactive TUI is POSIX-only: std.posix.termios is `void` on Windows,
    // so gate the whole raw-mode body out at comptime (same idiom as common.zig's
    // terminalSize). The non-interactive `ascii` render paths stay cross-platform.
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

    var lon = lon0;
    var lat = lat0;
    var zoom = zoom0;
    var last: [2]u32 = .{ 0, 0 };
    // kitty pan cache: per zoom step, a 3x-viewport region image lives in the
    // terminal's store; panning inside it is a ~40-byte placement escape.
    // Slots are keyed by round(zoom*2) and evicted round-robin.
    const Region = struct { zkey: i32 = std.math.minInt(i32), id: u32 = 0, tl_x: f64 = 0, tl_y: f64 = 0, w: u32 = 0, h: u32 = 0 };
    var regions: [3]Region = .{ .{}, .{}, .{} };
    var evict: usize = 0;
    while (true) {
        const ts_raw = terminalSize(io);
        const ts = ts_raw orelse .{ 100, 37, 0, 0 };
        const cols = @max(20, ts[0]);
        const rows = @max(10, ts[1]) - 1; // chart rows; the last line is the status bar
        if (cols != last[0] or rows != last[1]) {
            stdout.writeStreamingAll(io, "\x1b[2J") catch {};
            last = .{ cols, rows };
        }
        // Frame: kitty mode paints the REAL S-52 pixel portrayal (PNG through
        // the kitty graphics protocol) sized to the chart rows' pixel extent;
        // ascii mode paints the text grid.
        const cp = cellPx(ts_raw);
        const view_w: u32 = if (kitty) cols * cp[0] else cols;
        const view_h: u32 = if (kitty) rows * cp[1] else rows * 2; // ascii cell = 1x2 px
        if (kitty) {
            // World-pixel geometry at this zoom (256*2^zoom px globe).
            const world_px = 256.0 * std.math.pow(f64, 2.0, zoom);
            const vc = worldPxOf(lon, lat, world_px);
            const zkey: i32 = @intFromFloat(@round(zoom * 2.0));
            var reg: ?*@TypeOf(regions[0]) = null;
            for (&regions) |*r| if (r.zkey == zkey) {
                reg = r;
            };
            // A cached region only survives if the whole viewport still fits.
            var off_x: f64 = 0;
            var off_y: f64 = 0;
            if (reg) |r| {
                if (r.w < view_w or r.h < view_h) {
                    reg = null; // terminal grew past the cached region
                } else {
                    off_x = vc[0] - @as(f64, @floatFromInt(view_w)) / 2.0 - r.tl_x;
                    off_y = vc[1] - @as(f64, @floatFromInt(view_h)) / 2.0 - r.tl_y;
                    if (off_x < 0 or off_y < 0 or
                        off_x > @as(f64, @floatFromInt(r.w - view_w)) or
                        off_y > @as(f64, @floatFromInt(r.h - view_h))) reg = null;
                }
            }
            if (reg == null) {
                // (Re)render a 3x-viewport region centred here and transmit it
                // into an evicted slot. The render is the slow step (~a few
                // seconds); everything until the region's edge is then free.
                // Loader note on the status line — the region render blocks
                // for a few seconds and this is the only sign of life.
                const note = std.fmt.allocPrint(a, "\x1b[{d};1H\x1b[7m rendering\xe2\x80\xa6 \x1b[0m\x1b[K", .{rows + 1}) catch break;
                stdout.writeStreamingAll(io, note) catch {};
                a.free(note);
                const r = &regions[evict];
                evict = (evict + 1) % regions.len;
                r.zkey = zkey;
                if (r.id == 0) r.id = @intCast(100 + evict);
                r.w = view_w * 3;
                r.h = view_h * 3;
                r.tl_x = vc[0] - @as(f64, @floatFromInt(r.w)) / 2.0;
                r.tl_y = vc[1] - @as(f64, @floatFromInt(r.h)) / 2.0;
                const png_bytes = c.renderView(lon, lat, zoom, r.w, r.h, palette, m, .png, null) catch break;
                const seq = render.kitty.transmitPng(a, png_bytes, r.id) catch break;
                chart.freeBytes(png_bytes);
                stdout.writeStreamingAll(io, seq) catch {};
                a.free(seq);
                reg = r;
                off_x = vc[0] - @as(f64, @floatFromInt(view_w)) / 2.0 - r.tl_x;
                off_y = vc[1] - @as(f64, @floatFromInt(view_h)) / 2.0 - r.tl_y;
            }
            const pl = render.kitty.place(a, reg.?.id, @intFromFloat(@max(0, off_x)), @intFromFloat(@max(0, off_y)), view_w, view_h) catch break;
            stdout.writeStreamingAll(io, render.kitty.delete_all) catch {};
            stdout.writeStreamingAll(io, "\x1b[H") catch {};
            stdout.writeStreamingAll(io, pl) catch {};
            a.free(pl);
        } else {
            const text = c.renderAscii(lon, lat, zoom, cols, rows, palette, m, ansi) catch break;
            stdout.writeStreamingAll(io, "\x1b[H") catch {};
            stdout.writeStreamingAll(io, text) catch {};
            chart.freeBytes(text);
        }
        const status = std.fmt.allocPrint(a, "\x1b[{d};1H\x1b[7m \xe2\x86\x90\xe2\x86\x91\xe2\x86\x93\xe2\x86\x92 pan  +/- zoom  q quit  {d:.4},{d:.4} z{d:.2} \x1b[0m\x1b[K", .{ rows + 1, lat, lon, zoom }) catch break;
        stdout.writeStreamingAll(io, status) catch {};

        // Drain a whole read of input before re-rendering: key-repeat (a held
        // arrow) coalesces several ESC [ A/B/C/D sequences into one read, so
        // parse the buffer as a stream and apply every key — one repaint per
        // batch keeps a held arrow smooth instead of frames-behind.
        var b: [64]u8 = undefined;
        const n = std.posix.read(stdin_fd, &b) catch break;
        if (n == 0) break;
        // Pan steps: an eighth of the view span, in the frame's own pixels
        // (ascii cell = 1x2 px; sixel = real pixels) on a 256*2^zoom px world.
        const world = 256.0 * std.math.pow(f64, 2.0, zoom);
        const dlon = @as(f64, @floatFromInt(view_w)) / 8.0 * 360.0 / world;
        const dy_px = @as(f64, @floatFromInt(view_h)) / 8.0;
        var i: usize = 0;
        while (i < n) {
            if (b[i] == 0x1b and i + 2 < n and b[i + 1] == '[') {
                switch (b[i + 2]) {
                    'A' => lat = mercShift(lat, dy_px, world),
                    'B' => lat = mercShift(lat, -dy_px, world),
                    'C' => lon = @min(180, lon + dlon),
                    'D' => lon = @max(-180, lon - dlon),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b[i]) {
                '+', '=' => zoom = @min(18.0, zoom + 0.5),
                '-', '_' => zoom = @max(3.0, zoom - 0.5),
                'q', 'Q', 0x03 => return,
                else => {},
            }
            i += 1;
        }
    }
}

// ===========================================================================
// `tile57 explore` — the S-57 + S-101 learning / debug tool.
//
// For every feature of a cell it surfaces THREE data levels the engine already
// computes (it invents nothing):
//   1. Raw S-57       — object-class acronym + the acronym→value attribute map
//                       + geometry primitive (s57.Cell + catalogue).
//   2. S-101 portrayal — the ';'-separated Key:Value instruction stream the Lua
//                       rules emit (portray.portrayCell), RAW and PARSED into
//                       symbols / lines / fills / texts / aug figures
//                       (s101_instr.parse).
//   3. Resolved calls — what the portrayal BECOMES after geometry resolution:
//                       the Surface vtable calls, captured by the recording
//                       InspectSurface (render/inspect.zig) driven through
//                       scene.appendTile, matched back to each feature by its
//                       S-57 attribute fingerprint (FeatureMeta.s57_json).
// ===========================================================================
