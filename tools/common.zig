//! Shared CLI helpers for the tile57 subcommands: the argv flag cursor, the
//! rules/catalogue resolvers, the bundle emitter aliases, the terminal/mercator
//! geometry helpers, and the usage/error printers. Imported by the per-command
//! modules (and the dispatcher in main.zig).

const std = @import("std");
const bundle = @import("bundle"); // chart-bundle pipeline (asset emitters etc.) — the lib owns it

pub const VERSION = "tile57 0.1.0";

pub const DEFAULT_MINZOOM: u8 = 8;
pub const DEFAULT_MAXZOOM: u8 = 16;

// Lazy-baker tuning (bake-root): LRU budget = parsed cells kept loaded across
// super-tiles; super-tile depth = how far below a band's min zoom the spatial
// batch tile sits. Overridable via --lru / --superdz for tuning.
pub const DEFAULT_LRU_BUDGET: usize = 256;
pub const DEFAULT_SUPER_DZ: u8 = 3;

// Env access lives in the Lua C shim (Zig 0.16 gates env behind std.Io);
// returns the S-101 rules dir from TILE57_S101_RULES or null. Mirrors capi.zig.
extern fn tg_env_rules() callconv(.c) ?[*:0]const u8;

// Resolve the S-101 rules directory: explicit --rules, else TILE57_S101_RULES,
// else "" — which tells the portrayal engine to use the rules embedded in the
// binary (rules_embed.zig), so tile57 needs no on-disk catalogue. A non-empty
// path is layered onto package.path ahead of the embedded searcher, so an
// explicit dir always wins.
pub fn resolveRulesDir(explicit: ?[]const u8) []const u8 {
    if (explicit) |d| return d;
    if (tg_env_rules()) |dirz| return std.mem.span(dirz);
    return "";
}

// Flag cursor shared by the subcommands: walk argv[2..], pull a value (or an int)
// for a flag, and on a missing/bad value print usage and yield null so the caller
// can `orelse return`. next() pre-increments, so its first call returns argv[2].
pub const Flags = struct {
    args: []const [:0]const u8,
    i: usize = 1,

    pub fn next(f: *Flags) ?[]const u8 {
        f.i += 1;
        return if (f.i < f.args.len) f.args[f.i] else null;
    }
    pub fn val(f: *Flags, flag: []const u8) ?[]const u8 {
        f.i += 1;
        if (f.i >= f.args.len) {
            std.debug.print("error: missing value for {s}\n\n", .{flag});
            printUsage();
            return null;
        }
        return f.args[f.i];
    }
    pub fn int(f: *Flags, comptime T: type, flag: []const u8) ?T {
        const v = f.val(flag) orelse return null;
        return std.fmt.parseInt(T, v, 10) catch {
            std.debug.print("error: {s} must be an integer\n\n", .{flag});
            printUsage();
            return null;
        };
    }
};

// ---- assets / bundle ----------------------------------------------------

// Resolve the PortrayalCatalog directory: explicit arg, else "" — which tells the
// asset emitters below to use the catalogue embedded in the binary (catalog_embed
// / catalog), so the CLI needs no on-disk catalogue. A non-empty path reads the
// assets from disk instead, overriding the embedded copy.
pub fn resolveCatalogDir(explicit: ?[]const u8) []const u8 {
    return explicit orelse "";
}

// "embedded" when the catalogue is served from the binary (dir == ""), else `dir`
// — for the per-command progress prints.
pub fn catalogLabel(dir: []const u8) []const u8 {
    return if (dir.len == 0) "embedded" else dir;
}

// ---- assets / bundle emitters: moved to src/bundle.zig (the lib owns the pipeline;
// the CLI is a thin wrapper). Aliased so the command handlers below are unchanged. --
pub const emitColorTables = bundle.emitColorTables;
pub const emitLinestyles = bundle.emitLinestyles;
pub const emitSprites = bundle.emitSprites;
pub const emitPatterns = bundle.emitPatterns;
pub const emitSpriteMln = bundle.emitSpriteMln;
pub const colorTablesBytes = bundle.colorTablesBytes;
pub const linestylesBytes = bundle.linestylesBytes;
pub const spriteAtlasBytes = bundle.spriteAtlasBytes;
pub const patternAtlasBytes = bundle.patternAtlasBytes;
pub const spriteMlnBytes = bundle.spriteMlnBytes;
pub const DEFAULT_CSS = bundle.DEFAULT_CSS;

// A lon/lat's Web-Mercator world-pixel position on a `world`-pixel globe.
pub fn worldPxOf(lon: f64, lat: f64, world: f64) [2]f64 {
    const rad = lat * std.math.pi / 180.0;
    const y = std.math.log(f64, std.math.e, std.math.tan(std.math.pi / 4.0 + rad / 2.0));
    return .{
        (lon + 180.0) / 360.0 * world,
        (1.0 - y / std.math.pi) / 2.0 * world,
    };
}

// Shift a latitude by `px` screen pixels (positive = north) on a `world`-pixel
// Web-Mercator globe — exact Mercator, so panning doesn't drift at high lat.
pub fn mercShift(lat: f64, px: f64, world: f64) f64 {
    const rad = lat * std.math.pi / 180.0;
    const y = std.math.log(f64, std.math.e, std.math.tan(std.math.pi / 4.0 + rad / 2.0));
    const y2 = y + px * 2.0 * std.math.pi / world;
    const lat2 = (2.0 * std.math.atan(std.math.exp(y2)) - std.math.pi / 2.0) * 180.0 / std.math.pi;
    return std.math.clamp(lat2, -85.0, 85.0);
}

// The controlling terminal's {cols, rows, xpixel, ypixel}, or null when
// stdout isn't a TTY (or the platform gives us no TIOCGWINSZ) — the `ascii`
// grid's no-wrap default and the `--sixel` pixel geometry. xpixel/ypixel are
// 0 when the terminal doesn't report them.
// The std.Progress terminal-size pattern (Io.operate device_io_control).
pub fn terminalSize(io: std.Io) ?[4]u32 {
    if (@import("builtin").os.tag == .windows) return null;
    const f = std.Io.File.stdout();
    if ((f.isTty(io) catch return null) == false) return null;
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = (io.operate(.{ .device_io_control = .{
        .file = f,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return null).device_io_control;
    if (err < 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ ws.col, ws.row, ws.xpixel, ws.ypixel };
}

// The terminal's character-cell size in pixels for sixel geometry: reported
// xpixel/ypixel over cols/rows when available, else the common 10x20 guess.
pub fn cellPx(ts: ?[4]u32) [2]u32 {
    if (ts) |t| {
        if (t[2] > 0 and t[3] > 0) return .{ @max(4, t[2] / t[0]), @max(8, t[3] / t[1]) };
    }
    return .{ 10, 20 };
}

pub fn usageErr(msg: []const u8) void {
    std.debug.print("error: {s}\n\n", .{msg});
    printUsage();
}

pub fn printUsage() void {
    std.debug.print(
        \\{s} — offline S-57 -> PMTiles baker / inspector
        \\
        \\usage:
        \\  tile57 bake <cell.000 | ENC_ROOT> -o <out-dir> [options]
        \\      Bake a single S-57 cell OR a whole ENC_ROOT (every <CELL>.000 +
        \\      its auto-discovered updates, zoom-banded per cell by compilation
        \\      scale) into a self-contained chart bundle, streamed to disk:
        \\      <out>/tiles/chart.pmtiles + assets/colortables.json + sprite-mln +
        \\      style-{{day,dusk,night}}.json + manifest.json (pins schema_version,
        \\      couples tiles to portrayal).
        \\      -o, --output DIR    output bundle directory (required)
        \\      --rules DIR         S-101 portrayal rules directory (default: embedded)
        \\      --catalog DIR       PortrayalCatalog (default: parent of --rules)
        \\      --minzoom N         lowest zoom to bake (default {d})
        \\      --maxzoom N         highest zoom to bake (default {d})
        \\      --created ISO8601   stamp the manifest (no wall clock in-process)
        \\      --lru N             parsed cells held resident (lazy-bake tuning; trade
        \\                          memory for fewer re-parses; default {d})
        \\      --superdz N         spatial super-tile depth below a band's min zoom
        \\                          (lazy-bake tuning; default {d})
        \\      --format mlt|mvt    tile encoding (default mlt = MapLibre Tile;
        \\                          mvt = Mapbox Vector Tile, kept for consumers
        \\                          without an MLT decoder)
        \\  tile57 assets <portrayal-catalog-dir> -o <out-dir>
        \\      Emit just the portrayal assets (colortables.json today) for a
        \\      catalogue, independent of any cell.
        \\  tile57 style <portrayal-catalog-dir> --scheme day -o <out.json>
        \\      Emit one MapLibre style.json (colours from the catalogue, or
        \\      --colortables FILE). --scheme day|dusk|night; --source-tiles/
        \\      --pmtiles-url pick the source; --sprite/--glyphs enable symbol/text
        \\      layers; --minzoom/--maxzoom.
        \\  tile57 png|pdf <cell.000 | bundle.pmtiles> <z> <x> <y> -o <out> [--size N] [--palette P]
        \\  tile57 png|pdf <source> --view <lon,lat,zoom> --size WxH -o <out>
        \\      Render a tile or a view through the native S-52 pixel path:
        \\      PNG raster or deterministic vector PDF (real text objects).
        \\      Sources: an S-57 cell (single-cell portrayal) or a baked .pmtiles
        \\      bundle (tile replay). --dq data-quality overlay; --scale F
        \\      physical-size multiplier; --palette day|dusk|night.
        \\  tile57 ascii <cell.000 | bundle.pmtiles> --view <lon,lat,zoom> [--size COLSxROWS (default: terminal size)] [--ansi] [--kitty]
        \\      The chart on stdout as a Unicode text grid (the example render
        \\      backend). --ansi adds xterm-256 color; --palette day|dusk|night.
        \\  tile57 explore <cell.000 | ENC_ROOT --view LON,LAT,ZOOM> [--class ACR[,ACR..]] [--object FOID|RCID|INDEX]
        \\      Dump, per feature, the RAW S-57 (class + attributes), the S-101
        \\      portrayal instruction stream (raw + parsed), and the resolved
        \\      Surface draw calls. Takes a SINGLE .000 cell (auto-applying its
        \\      .001+ updates), or an ENC_ROOT with --view LON,LAT,ZOOM (or a
        \\      "…/#v=LON,LAT,ZOOM" share URL) to pull just the cells under that
        \\      viewport (--viewport WxH overrides the assumed 1280x800 screen).
        \\      --zoom N picks the resolving tile; --json; --no-resolve skips the draw-call pass;
        \\      --tui opens the two-pane explorer (arrows select, / filters, q
        \\      quits); --kitty adds, in console mode, an isolated thumbnail of
        \\      each feature's resolved render, and in the TUI a LIVE CELL MAP that
        \\      frames the selection (whole cell on a class header, zoomed in to
        \\      frame a feature; m toggles map-only) — for graphics terminals.
        \\  tile57 inspect <file.pmtiles> [z x y]
        \\  tile57 cell <file.000>
        \\  tile57 objlcount <file.000> <objl> [prim]   (corpus scan: find cells with an object class)
        \\  tile57 version
        \\  tile57 help
        \\
    , .{ VERSION, DEFAULT_MINZOOM, DEFAULT_MAXZOOM, DEFAULT_LRU_BUDGET, DEFAULT_SUPER_DZ });
}
