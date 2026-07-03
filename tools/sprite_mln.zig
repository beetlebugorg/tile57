const std = @import("std");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveCatalogDir = common.resolveCatalogDir;
const catalogLabel = common.catalogLabel;
const DEFAULT_CSS = common.DEFAULT_CSS;
const emitSpriteMln = common.emitSpriteMln;

/// `sprite-mln <portrayal-catalog-dir> -o <out-dir> [--css daySvgStyle.css]` —
/// emit the MapLibre-ready sprite (sprite-mln.{json,png} + @2x): pivot-centred
/// symbols, ctr: bbox-centred variants, and pat: area-fill patterns.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var catalog: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var css: []const u8 = DEFAULT_CSS;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--css")) {
            css = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (catalog == null) {
            catalog = arg;
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const catalog_dir = resolveCatalogDir(catalog);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    // Catalogue-only: no tiles, so no sounding composites (the bundle adds those).
    const atlas = try emitSpriteMln(io, a, catalog_dir, css, out_dir, "sprite-mln", &.{});
    std.debug.print("emitted sprite-mln from {s} (css {s})\n  sprite-mln.json ({d} bytes) + .png ({d} bytes) + @2x\n", .{ catalogLabel(catalog_dir), css, atlas.json.len, atlas.png.len });
}
