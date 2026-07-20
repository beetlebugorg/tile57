//! Shared CLI helpers for the tile57 subcommands: the argv flag cursor, the
//! rules/catalogue resolvers, the bundle emitter aliases, the terminal/mercator
//! geometry helpers, and the usage/error printers. Imported by the per-command
//! modules (and the dispatcher in main.zig).

const std = @import("std");
const bundle = @import("bundle"); // chart-bundle pipeline (asset emitters etc.) — the lib owns it

pub const VERSION = "tile57 0.3.0";

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
        \\  tile57 bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [-j N]
        \\      Produce a live-composite structure: bake each chart (a single .000 +
        \\      its auto-discovered updates, OR every <CELL>.000 in an ENC_ROOT, at
        \\      native band scale) to its own <out>/tiles/<STEM>.pmtiles with M_COVR
        \\      coverage embedded, then write the ownership partition to
        \\      <out>/partition.tpart. A runtime compositor (compose-tile / the C ABI)
        \\      serves any tile ON DEMAND from this structure — there is no merged archive.
        \\      -o, --output DIR    output directory (required)
        \\      --rules DIR         S-101 portrayal rules directory (default: embedded)
        \\      -j, --workers N     bake threads (default: min(cores/2, 8)). A MEMORY
        \\                          bound: each worker holds a whole cell's working set.
        \\
    , .{VERSION});
}
