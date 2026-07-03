const std = @import("std");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveCatalogDir = common.resolveCatalogDir;
const catalogLabel = common.catalogLabel;
const DEFAULT_CSS = common.DEFAULT_CSS;
const emitSprites = common.emitSprites;

/// `sprite <portrayal-catalog-dir> -o <out-dir> [--css daySvgStyle.css]` — emit
/// the S-101 symbol atlas (sprite.json + sprite.png) for a palette.
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
    const json_path = try std.fs.path.join(a, &.{ out_dir, "sprite.json" });
    const png_path = try std.fs.path.join(a, &.{ out_dir, "sprite.png" });
    const atlas = try emitSprites(io, a, catalog_dir, css, json_path, png_path);
    std.debug.print("emitted sprite atlas from {s} (css {s})\n  {s} ({d} bytes)\n  {s} ({d} bytes)\n", .{ catalogLabel(catalog_dir), css, json_path, atlas.json.len, png_path, atlas.png.len });
}
