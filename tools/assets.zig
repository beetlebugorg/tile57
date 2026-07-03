const std = @import("std");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveCatalogDir = common.resolveCatalogDir;
const catalogLabel = common.catalogLabel;
const DEFAULT_CSS = common.DEFAULT_CSS;
const emitColorTables = common.emitColorTables;
const emitLinestyles = common.emitLinestyles;
const emitSprites = common.emitSprites;
const emitPatterns = common.emitPatterns;

/// `assets <portrayal-catalog-dir> -o <out-dir>` — emit the portrayal assets
/// (colortables.json today; linestyles/sprites/glyphs to follow) for a catalogue.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const catalog_dir = resolveCatalogDir(catalog);

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const ct_path = try std.fs.path.join(a, &.{ out_dir, "colortables.json" });
    const json = try emitColorTables(io, a, catalog_dir, ct_path);
    const ls_path = try std.fs.path.join(a, &.{ out_dir, "linestyles.json" });
    const ls = try emitLinestyles(io, a, catalog_dir, ls_path);
    const sj_path = try std.fs.path.join(a, &.{ out_dir, "sprite.json" });
    const sp_path = try std.fs.path.join(a, &.{ out_dir, "sprite.png" });
    const atlas = try emitSprites(io, a, catalog_dir, DEFAULT_CSS, sj_path, sp_path);
    const pj_path = try std.fs.path.join(a, &.{ out_dir, "patterns.json" });
    const pp_path = try std.fs.path.join(a, &.{ out_dir, "patterns.png" });
    const pat = try emitPatterns(io, a, catalog_dir, DEFAULT_CSS, pj_path, pp_path);
    std.debug.print("emitted assets from {s}\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n", .{ catalogLabel(catalog_dir), ct_path, json.len, ls_path, ls.len, sj_path, atlas.json.len, sp_path, atlas.png.len, pj_path, pat.json.len, pp_path, pat.png.len });
}
