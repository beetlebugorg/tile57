const std = @import("std");
const engine = @import("engine");

// Per-zoom size/count stats for a PMTiles archive (verification aid: the
// scamin-standalone coarse-tile growth measurement). Walks every directory
// entry (root + leaves) and sums compressed tile bytes per zoom; run-length
// entries count each addressed tile once at the shared length.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 zoomsizes <file.pmtiles>\n", .{});
        return;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var r = try engine.pmtiles.Reader.init(a, data);
    defer r.deinit();
    var counts = [_]usize{0} ** 25;
    var sizes = [_]u64{0} ** 25;
    const zoomOf = struct {
        fn f(tid: u64) u8 {
            var acc: u64 = 0;
            var z: u6 = 0;
            while (z < 25) : (z += 1) {
                const n = @as(u64, 1) << (2 * z);
                if (tid < acc + n) return @intCast(z);
                acc += n;
            }
            return 24;
        }
    }.f;
    const Walk = struct {
        fn f(rd: *engine.pmtiles.Reader, a2: std.mem.Allocator, dir: []const engine.pmtiles.Entry, cnt: *[25]usize, sz: *[25]u64) !void {
            for (dir) |e| {
                if (e.run_length == 0) {
                    const raw0 = rd.bytes[@intCast(rd.header.leaf_dir_offset + e.offset)..][0..e.length];
                    const raw = if (rd.header.internal_compression == .gzip)
                        try engine.gzip.decompress(a2, raw0)
                    else
                        raw0;
                    const leaf = try engine.pmtiles.deserializeDir(a2, raw);
                    try f(rd, a2, leaf, cnt, sz);
                    continue;
                }
                var k: u64 = 0;
                while (k < e.run_length) : (k += 1) {
                    const z = zoomOf(e.tile_id + k);
                    cnt[z] += 1;
                    sz[z] += e.length;
                }
            }
        }
    };
    try Walk.f(&r, a, r.root, &counts, &sizes);
    std.debug.print("zoom  tiles      bytes    avg\n", .{});
    for (counts, sizes, 0..) |c, s, z| if (c > 0)
        std.debug.print("z{d:<3} {d:>6} {d:>10} {d:>6}\n", .{ z, c, s, s / c });
    return;
}
