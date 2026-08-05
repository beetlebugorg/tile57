//! `tile57 raster info <chart>` — what a raster chart declares, beside what its
//! name claims.
//!
//! The two disagree constantly. Both community charts measured while this was
//! written declare `minzoom 9 / maxzoom 17` and are named `Z10-Z18`; a mariner
//! who trusts the name zooms into blank water at the exact moment they most
//! need the picture. So this prints the file's own answer first, and flags the
//! name when it differs — which is the whole reason the command exists.

const std = @import("std");
const raster = @import("raster");

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4 or !std.mem.eql(u8, args[2], "info")) {
        std.debug.print("usage: tile57 raster info <chart.mbtiles>\n", .{});
        return;
    }
    const path = args[3];

    var msg: raster.ErrMsg = .{};
    var rc = raster.RasterChart.open(io, a, path, &msg) catch |e| {
        std.debug.print("error: {s}: {s}", .{ path, reason(e) });
        if (msg.len > 0) std.debug.print(" ({s})", .{msg.slice()});
        std.debug.print("\n", .{});
        return;
    };
    defer rc.close();

    const i = rc.getInfo();
    const count = rc.tileCount() catch 0;

    // Only a baked RNC declares a compilation scale. Spelled out rather than
    // printed as "0", because the consequence is the part that matters.
    var scale_buf: [64]u8 = undefined;
    const scale_text = if (i.scale == 0)
        "none declared (owns no ground; cannot quilt)"
    else
        std.fmt.bufPrint(&scale_buf, "1:{d}", .{i.scale}) catch "?";

    std.debug.print(
        \\{s}
        \\  name         {s}
        \\  description  {s}
        \\  attribution  {s}
        \\
        \\  zoom         {d}..{d}{s}
        \\  encoding     {s}
        \\  tile size    {d} px
        \\  row origin   {s}
        \\  tiles        {d}
        \\  bounds       {d:.6},{d:.6},{d:.6},{d:.6}{s}
        \\  scale        {s}
        \\
    , .{
        path,
        orNone(rc.name()),
        orNone(rc.description()),
        orNone(rc.attribution()),
        i.min_zoom,
        i.max_zoom,
        if (i.zooms_declared) "" else "   (absent from the file; read off the tile index)",
        @tagName(i.encoding),
        i.tile_size,
        rc.schemeName(),
        count,
        i.west,
        i.south,
        i.east,
        i.north,
        if (i.bounds_declared) "" else "   (absent from the file; read off the tile index)",
        scale_text,
    });

    // The claim in the file name, if it makes one. Only worth printing when it
    // is wrong — a name that agrees tells the mariner nothing.
    if (zoomsInName(std.fs.path.basename(path))) |claim| {
        if (claim.lo != i.min_zoom or claim.hi != i.max_zoom) {
            std.debug.print(
                \\
                \\  the NAME claims zoom {d}..{d}. The file says {d}..{d}. Believe the file.
                \\
            , .{ claim.lo, claim.hi, i.min_zoom, i.max_zoom });
        }
    }
}

fn orNone(s: []const u8) []const u8 {
    return if (s.len == 0) "(none)" else s;
}

const ZoomClaim = struct { lo: u8, hi: u8 };

/// Pull a `Z<lo>-Z<hi>` (or `Z<lo>-<hi>`) claim out of a file name. Community
/// naming is inconsistent enough that this misses plenty; a miss is silence,
/// never a wrong answer.
fn zoomsInName(base: []const u8) ?ZoomClaim {
    var i: usize = 0;
    while (i < base.len) : (i += 1) {
        if (base[i] != 'Z' and base[i] != 'z') continue;
        var j = i + 1;
        const lo_start = j;
        while (j < base.len and std.ascii.isDigit(base[j])) j += 1;
        if (j == lo_start or j >= base.len or base[j] != '-') continue;
        const lo = std.fmt.parseInt(u8, base[lo_start..j], 10) catch continue;
        j += 1;
        if (j < base.len and (base[j] == 'Z' or base[j] == 'z')) j += 1;
        const hi_start = j;
        while (j < base.len and std.ascii.isDigit(base[j])) j += 1;
        if (j == hi_start) continue;
        const hi = std.fmt.parseInt(u8, base[hi_start..j], 10) catch continue;
        if (lo > 30 or hi > 30 or lo > hi) continue;
        return .{ .lo = lo, .hi = hi };
    }
    return null;
}

fn reason(e: anyerror) []const u8 {
    return switch (e) {
        error.OpenFailed => "could not be opened",
        error.UnknownFormat => "not a raster chart in any format tile57 reads",
        error.NotADatabase => "not an MBTiles database",
        error.NotMbtiles => "a database, but not a tileset",
        error.NoTiles => "the tileset holds no tiles",
        error.VectorTileset => "a vector tileset, not a raster chart",
        error.QueryFailed => "could not be read (truncated or corrupt?)",
        else => @errorName(e),
    };
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "zoom claims in community file names" {
    const c1 = zoomsInName("EU-SI-Full.ArcGIS.Z10-Z18.2024-08.mbtiles").?;
    try testing.expectEqual(@as(u8, 10), c1.lo);
    try testing.expectEqual(@as(u8, 18), c1.hi);

    const c2 = zoomsInName("Ru_Paramushir_Is_Navionics_Z10-Z18.mbtiles").?;
    try testing.expectEqual(@as(u8, 10), c2.lo);
    try testing.expectEqual(@as(u8, 18), c2.hi);

    // Paraschiv's set drops the second Z.
    const c3 = zoomsInName("EU-Croatia-NavionicsMarineCharts-Z10-18.zip").?;
    try testing.expectEqual(@as(u8, 10), c3.lo);
    try testing.expectEqual(@as(u8, 18), c3.hi);

    // Ralph's set names one zoom, not a range — no claim to check.
    try testing.expect(zoomsInName("Morocco-Gibraltar-Z19.mbtiles") == null);
    try testing.expect(zoomsInName("Madagascar-CMap.mbtiles") == null);
    try testing.expect(zoomsInName("chart.mbtiles") == null);
}
