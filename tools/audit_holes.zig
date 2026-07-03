const std = @import("std");
const engine = @import("engine");

// Archive-wide fill-down hole audit (district-pack z6–z8 acceptance): a tile
// that HAS content at z+1 but whose parent at z is EMPTY, inside coverage, is
// a defect — the low-zoom hole the band-handoff fill-down closes. Enumerates
// present tiles from the directory (inverse-hilbert), then counts distinct
// absent parents that have >=1 present child. Per-zoom breakdown + total.
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 audit-holes <file.pmtiles>\n", .{});
        return;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var r = try engine.pmtiles.Reader.init(a, data);
    defer r.deinit();
    // Recover (z,x,y) from a hilbert tile id (inverse of pmtiles.zxyToTileId).
    const idToZxy = struct {
        fn f(tid_in: u64) struct { z: u8, x: u32, y: u32 } {
            var acc: u64 = 0;
            var z: u6 = 0;
            while (z < 32) : (z += 1) {
                const n = @as(u64, 1) << (2 * z);
                if (tid_in < acc + n) break;
                acc += n;
            }
            var t = tid_in - acc;
            const side: u64 = @as(u64, 1) << z;
            var x: u64 = 0;
            var y: u64 = 0;
            var s: u64 = 1;
            while (s < side) : (s *= 2) {
                const rx: u64 = 1 & (t / 2);
                const ry: u64 = 1 & (t ^ rx);
                if (ry == 0) {
                    if (rx == 1) {
                        x = s -% 1 -% x;
                        y = s -% 1 -% y;
                    }
                    const tmp = x;
                    x = y;
                    y = tmp;
                }
                x += s * rx;
                y += s * ry;
                t /= 4;
            }
            return .{ .z = z, .x = @intCast(x), .y = @intCast(y) };
        }
    }.f;
    // Collect every present (z,x,y) key.
    var present = std.AutoHashMap(u64, void).init(a);
    const key = struct {
        fn f(z: u8, x: u32, y: u32) u64 {
            return (@as(u64, z) << 48) | (@as(u64, x) << 24) | @as(u64, y);
        }
    }.f;
    const Walk = struct {
        fn f(rd: *engine.pmtiles.Reader, a2: std.mem.Allocator, dir: []const engine.pmtiles.Entry, out: *std.AutoHashMap(u64, void), idfn: anytype, keyfn: anytype) !void {
            for (dir) |e| {
                if (e.run_length == 0) {
                    const raw0 = rd.bytes[@intCast(rd.header.leaf_dir_offset + e.offset)..][0..e.length];
                    const raw = if (rd.header.internal_compression == .gzip) try engine.gzip.decompress(a2, raw0) else raw0;
                    const leaf = try engine.pmtiles.deserializeDir(a2, raw);
                    try f(rd, a2, leaf, out, idfn, keyfn);
                    continue;
                }
                var k: u64 = 0;
                while (k < e.run_length) : (k += 1) {
                    const zxy = idfn(e.tile_id + k);
                    try out.put(keyfn(zxy.z, zxy.x, zxy.y), {});
                }
            }
        }
    };
    try Walk.f(&r, a, r.root, &present, idToZxy, key);
    // For each present tile, test its parent; a distinct absent parent with a
    // present child is one hole. Bucketed by the PARENT zoom.
    var holes = std.AutoHashMap(u64, void).init(a);
    var per_zoom = [_]usize{0} ** 25;
    var it = present.keyIterator();
    while (it.next()) |kp| {
        const z: u8 = @intCast(kp.* >> 48);
        if (z == 0 or z <= r.header.min_zoom) continue;
        const x: u32 = @intCast((kp.* >> 24) & 0xFFFFFF);
        const y: u32 = @intCast(kp.* & 0xFFFFFF);
        const pk = key(z - 1, x / 2, y / 2);
        if (present.contains(pk)) continue;
        if ((try holes.getOrPut(pk)).found_existing) continue;
        per_zoom[z - 1] += 1;
    }
    if (args.len >= 4 and std.mem.eql(u8, args[3], "-v")) {
        var hit = holes.keyIterator();
        while (hit.next()) |hk| std.debug.print("    hole {d}/{d}/{d}\n", .{ @as(u8, @intCast(hk.* >> 48)), @as(u32, @intCast((hk.* >> 24) & 0xFFFFFF)), @as(u32, @intCast(hk.* & 0xFFFFFF)) });
    }
    std.debug.print("{s}\n  present tiles: {d}  zoom {d}..{d}\n", .{ args[2], present.count(), r.header.min_zoom, r.header.max_zoom });
    std.debug.print("  fill-down holes (absent parent with a present child), by parent zoom:\n", .{});
    var total: usize = 0;
    for (per_zoom, 0..) |c, z| if (c > 0) {
        std.debug.print("    z{d:<2} {d}\n", .{ z, c });
        total += c;
    };
    std.debug.print("  TOTAL holes: {d}\n", .{total});
    return;
}
