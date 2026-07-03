const std = @import("std");
const engine = @import("engine");

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    // Exchange-set catalogue JSON (the tile57_catalog_entries ABI).
    if (args.len < 3) {
        std.debug.print("usage: tile57 catalog <CATALOG.031>\n", .{});
        return;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    const entries = engine.s57.parseCatalog(a, data) orelse {
        std.debug.print("parse error\n", .{});
        return;
    };
    var out = std.ArrayList(u8).empty;
    try out.append(a, '[');
    for (entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(a, ",\n ");
        try out.print(a, "{{\"file\":\"{s}\",\"longName\":\"{s}\",\"impl\":\"{s}\"", .{ e.path, e.long_name, e.impl });
        if (e.bbox) |b| try out.print(a, ",\"bbox\":[{d},{d},{d},{d}]", .{ b[0], b[1], b[2], b[3] });
        try out.append(a, '}');
    }
    try out.appendSlice(a, "]\n");
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
    return;
}
