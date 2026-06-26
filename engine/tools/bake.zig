//! engine CLI.
//!
//!   bake inspect <file.pmtiles> [z x y]
//!       Parse a PMTiles archive (header + directory) and, if z/x/y is given,
//!       read+gunzip+decode that tile and list its MVT layers. Used to validate
//!       the Zig reader against the Go reference archive.
//!
//! Baking from S-57 cells lands at M6 (decode -> portrayal -> tile).

const std = @import("std");
const engine = @import("engine");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "inspect")) {
        if (args.len < 3) {
            std.debug.print("usage: bake inspect <file.pmtiles> [z x y]\n", .{});
            return;
        }
        const path = args[2];
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var r = try engine.pmtiles.Reader.init(arena, data);
        defer r.deinit();
        const h = r.header;
        std.debug.print(
            "{s}\n  zoom {d}..{d}  addressed={d} entries={d} contents={d}  tile_comp={s} internal={s}\n",
            .{ path, h.min_zoom, h.max_zoom, h.num_addressed_tiles, h.num_tile_entries, h.num_tile_contents, @tagName(h.tile_compression), @tagName(h.internal_compression) },
        );
        if (args.len >= 6) {
            const z = try std.fmt.parseInt(u8, args[3], 10);
            const x = try std.fmt.parseInt(u32, args[4], 10);
            const y = try std.fmt.parseInt(u32, args[5], 10);
            if (try r.getTile(arena, z, x, y)) |tile| {
                const layers = try engine.mvt.decode(arena, tile);
                std.debug.print("  tile {d}/{d}/{d}: {d} bytes, {d} layers:\n", .{ z, x, y, tile.len, layers.len });
                for (layers) |L| {
                    std.debug.print("    {s}: {d} features (extent {d})\n", .{ L.name, L.features.len, L.extent });
                }
            } else std.debug.print("  tile {d}/{d}/{d}: not found\n", .{ z, x, y });
        }
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "cell")) {
        const path = args[2];
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var file = try engine.iso8211.parse(arena, data);
        defer file.deinit();
        const L = file.ddr.leader;
        std.debug.print(
            "{s}\n  DDR: interchange={c} version={c} tag_size={d} field_controls={d}\n  data records: {d}\n",
            .{ path, L.interchange_level, L.version, L.size_of_field_tag, file.field_controls.len, file.records.len },
        );
        // Tally the S-57 record kind by its leading field.
        var dsid: usize = 0;
        var frid: usize = 0;
        var vrid: usize = 0;
        var other: usize = 0;
        for (file.records) |r| {
            if (r.field("FRID") != null) frid += 1 else if (r.field("VRID") != null) vrid += 1 else if (r.field("DSID") != null) dsid += 1 else other += 1;
        }
        std.debug.print("  DSID={d} feature(FRID)={d} vector(VRID)={d} other={d}\n", .{ dsid, frid, vrid, other });

        // S-57 model: coordinate factors, geometry bounds, a few object classes.
        var cell = try engine.s57.parseCell(arena, data);
        defer cell.deinit();
        std.debug.print("  S-57: comf={d} cscl=1:{d}  vectors={d} features={d}\n", .{ cell.params.comf, cell.params.cscl, cell.vectors.len, cell.features.len });
        if (cell.bounds()) |b| {
            std.debug.print("  geometry bounds: lon [{d:.4}, {d:.4}]  lat [{d:.4}, {d:.4}]\n", .{ b[0], b[2], b[1], b[3] });
        }
        const named = [_]struct { objl: u16, name: []const u8 }{
            .{ .objl = 42, .name = "DEPARE" }, .{ .objl = 30, .name = "COALNE" },
            .{ .objl = 129, .name = "SOUNDG" }, .{ .objl = 71, .name = "LNDARE" },
            .{ .objl = 122, .name = "SLCONS" }, .{ .objl = 74, .name = "DEPCNT" },
        };
        for (named) |nm| {
            var c: usize = 0;
            for (cell.features) |f| {
                if (f.objl == nm.objl) c += 1;
            }
            if (c > 0) std.debug.print("    {s}(objl {d}): {d}\n", .{ nm.name, nm.objl, c });
        }

        // Topology assembly: resolve feature geometry via FSPT/VRPT/edges/nodes.
        var line_feats: usize = 0;
        var line_verts: usize = 0;
        var pt_feats: usize = 0;
        var sample_ok = false;
        const gb = cell.bounds();
        for (cell.features) |f| {
            if (f.prim == 2 or f.prim == 3) {
                const g = try cell.lineGeometry(arena, f);
                if (g.len >= 2) {
                    line_feats += 1;
                    line_verts += g.len;
                    if (!sample_ok and gb != null) {
                        const p = g[0];
                        sample_ok = p.lon >= gb.?[0] - 1e-6 and p.lon <= gb.?[2] + 1e-6 and
                            p.lat >= gb.?[1] - 1e-6 and p.lat <= gb.?[3] + 1e-6;
                    }
                }
            } else if (f.prim == 1) {
                if (cell.pointGeometry(f) != null) pt_feats += 1;
            }
        }
        std.debug.print("  assembled: {d} line/area features ({d} verts), {d} point features; sample in-bounds={}\n", .{ line_feats, line_verts, pt_feats, sample_ok });

        // prim histogram for DEPCNT(74) and SOUNDG(129).
        for ([_]u16{ 42, 30, 74, 129 }) |objl| {
            var pc = [_]usize{0} ** 256;
            for (cell.features) |f| if (f.objl == objl) {
                pc[f.prim] += 1;
            };
            std.debug.print("  objl {d} prim: point(1)={d} line(2)={d} area(3)={d} none(255)={d}\n", .{ objl, pc[1], pc[2], pc[3], pc[255] });
        }

        // Find features whose assembled geometry has an anomalously long
        // segment (a "jump"): symptom of concatenating non-contiguous FSPT
        // edges. Flag any segment longer than 10% of the cell diagonal.
        if (gb) |b| {
            const diag = @sqrt((b[2] - b[0]) * (b[2] - b[0]) + (b[3] - b[1]) * (b[3] - b[1]));
            const thresh = 0.10 * diag;
            var jumpy: usize = 0;
            var worst_objl: u16 = 0;
            var worst_len: f64 = 0;
            for (cell.features) |f| {
                if (f.prim != 2 and f.prim != 3) continue;
                // Measure the longest segment WITHIN each connected part (the
                // render uses lineGeometryParts, so per-part is what matters).
                const parts = cell.lineGeometryParts(arena, f) catch continue;
                var maxseg: f64 = 0;
                for (parts) |g| {
                    var i: usize = 1;
                    while (i < g.len) : (i += 1) {
                        const dx = g[i].lon - g[i - 1].lon;
                        const dy = g[i].lat - g[i - 1].lat;
                        const d = @sqrt(dx * dx + dy * dy);
                        if (d > maxseg) maxseg = d;
                    }
                }
                if (maxseg > thresh) {
                    jumpy += 1;
                    if (maxseg > worst_len) {
                        worst_len = maxseg;
                        worst_objl = f.objl;
                    }
                }
            }
            std.debug.print("  per-part geometry jumps (>10% cell diag): {d} features; worst objl={d} seg={d:.4} (diag={d:.4})\n", .{ jumpy, worst_objl, worst_len, diag });
        }

        // Confirm DRVAL1/DRVAL2 attribute codes on a sample DEPARE.
        for (cell.features) |f| {
            if (f.objl == 42 and f.attrs.len > 0) {
                std.debug.print("  sample DEPARE attrs: ", .{});
                for (f.attrs) |x| std.debug.print("[{d}]={s} ", .{ x.code, x.value });
                if (f.attrFloat(engine.s57.ATTR_DRVAL1)) |d| std.debug.print("-> DRVAL1={d:.1}", .{d});
                std.debug.print("\n", .{});
                break;
            }
        }
        return;
    }

    std.debug.print(
        "engine — usage:\n  bake inspect <file.pmtiles> [z x y]\n  bake cell <file.000>\n" ++
            "(baking from S-57 cells comes at M6)\n",
        .{},
    );
}
