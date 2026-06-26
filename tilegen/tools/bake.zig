//! tilegen CLI.
//!
//!   bake inspect <file.pmtiles> [z x y]
//!       Parse a PMTiles archive (header + directory) and, if z/x/y is given,
//!       read+gunzip+decode that tile and list its MVT layers. Used to validate
//!       the Zig reader against the Go reference archive.
//!
//! Baking from S-57 cells lands at M6 (decode -> portrayal -> tile).

const std = @import("std");
const tilegen = @import("tilegen");

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
        var r = try tilegen.pmtiles.Reader.init(arena, data);
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
                const layers = try tilegen.mvt.decode(arena, tile);
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
        var file = try tilegen.iso8211.parse(arena, data);
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
        return;
    }

    std.debug.print(
        "tilegen — usage:\n  bake inspect <file.pmtiles> [z x y]\n  bake cell <file.000>\n" ++
            "(baking from S-57 cells comes at M6)\n",
        .{},
    );
}
