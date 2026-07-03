const std = @import("std");
const engine = @import("engine");
const chart = @import("chart"); // streaming ENC_ROOT open + quilted view render

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = a;
    // GeoJSON feature query (the tile57_chart_features ABI).
    if (args.len < 4) {
        std.debug.print("usage: tile57 features <cell.000 | ENC_ROOT> <ACR[,ACR...]>\n", .{});
        return;
    }
    engine.portray.setQuiet(true);
    const c = chart.Chart.openPath(args[2], null, false) catch {
        std.debug.print("cannot open {s}\n", .{args[2]});
        return;
    };
    defer c.deinit();
    const json = (c.featuresJson(args[3]) catch null) orelse {
        std.debug.print("no matching features\n", .{});
        return;
    };
    defer chart.freeBytes(json);
    var stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, json) catch {};
    stdout.writeStreamingAll(io, "\n") catch {};
    return;
}
