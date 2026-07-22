const std = @import("std");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const font = @import("render").font;
const glyphpbf = @import("sprite").glyphpbf;

const Face = struct { name: []const u8, bytes: []const u8 };

/// `emit-glyphs -o <out-dir>` — write MapLibre glyph-PBF fontstacks for the three
/// embedded Noto Sans faces (Regular / Bold / Italic) that the label-tier resolver
/// selects. Emits `<out>/<fontstack>/<range>.pbf` for the Latin ranges (0-511),
/// so a GL client serving `<glyphs>/{fontstack}/{range}.pbf` renders bold place
/// names and italic hydrography.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var out: ?[]const u8 = null;
    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        }
    }
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");

    const faces = [_]Face{
        .{ .name = "Noto Sans Regular", .bytes = font.notosans },
        .{ .name = "Noto Sans Bold", .bytes = font.notosans_bold },
        .{ .name = "Noto Sans Italic", .bytes = font.notosans_italic },
    };
    // Latin + Latin-1 + Latin Extended-A cover ENC place names.
    const ranges = [_]u21{ 0, 256 };

    for (faces) |fc| {
        const dir = try std.fs.path.join(a, &.{ out_dir, fc.name });
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var total: usize = 0;
        for (ranges) |start| {
            const pbf = try glyphpbf.encodeRange(a, fc.bytes, fc.name, start);
            const path = try std.fmt.allocPrint(a, "{s}/{d}-{d}.pbf", .{ dir, start, start + 255 });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pbf });
            total += pbf.len;
        }
        std.debug.print("  {s}/  ({d} ranges, {d} bytes)\n", .{ fc.name, ranges.len, total });
    }
    std.debug.print("emitted glyph fontstacks -> {s}\n", .{out_dir});
}
