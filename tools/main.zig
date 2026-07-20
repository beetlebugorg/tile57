//! tile57 — the offline S-57 -> PMTiles baker / inspector CLI.
//!
//! Subcommands:
//!   bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [-j N]
//!       Bake each chart to <out-dir>/tiles/<STEM>.pmtiles and write the ownership
//!       partition to <out-dir>/partition.tpart — the live-composite structure a
//!       runtime compositor serves tiles from on demand.
//!   inspect <file.pmtiles> [z x y]
//!       Parse a PMTiles archive (header + directory) and, if z/x/y is given,
//!       read+gunzip+decode that tile and list its MVT layers.
//!   cell <file.000>
//!       Decode + summarise an S-57 chart (record tally, bounds, topology).
//!   version
//!       Print the baker version.
//!   help
//!       Print usage.
//!
//! This file is the thin dispatcher: it parses the first arg (the subcommand)
//! and routes to the matching per-command module's `run`. Each subcommand lives
//! in its own tools/<cmd>.zig; the shared helpers live in tools/common.zig.

const std = @import("std");
const common = @import("common.zig");

const bake = @import("bake.zig");
const compose_tile = @import("compose_tile.zig");
const assets = @import("assets.zig");
const sprite = @import("sprite.zig");
const pattern = @import("pattern.zig");
const sprite_mln = @import("sprite_mln.zig");
const style = @import("style.zig");
const tiledump = @import("tiledump.zig");
const render = @import("render.zig");
const ascii = @import("ascii.zig");
const explore = @import("explore.zig");
const cells = @import("cells.zig");
const catalog = @import("catalog.zig");
const features = @import("features.zig");
const inspect = @import("inspect.zig");
const zoomsizes = @import("zoomsizes.zig");
const audit_holes = @import("audit_holes.zig");
const audit_pairs = @import("audit_pairs.zig");
const objlcount = @import("objlcount.zig");
const cell = @import("cell.zig");
const s101dump = @import("s101dump.zig");
const partdbg_png = @import("partdbg_png.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const sub: []const u8 = if (args.len >= 2) args[1] else "help";

    if (std.mem.eql(u8, sub, "bake")) {
        return bake.run(io, arena, args);
    }
    if (std.mem.eql(u8, sub, "compose-tile")) {
        return compose_tile.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "assets")) {
        return assets.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "sprite")) {
        return sprite.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "pattern")) {
        return pattern.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "sprite-mln")) {
        return sprite_mln.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "style")) {
        return style.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "tiledump")) {
        return tiledump.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "png") or std.mem.eql(u8, sub, "renderpng")) {
        return render.run(io, arena, args, .png);
    }
    if (std.mem.eql(u8, sub, "partdbg-png")) {
        return partdbg_png.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "pdf")) {
        return render.run(io, arena, args, .pdf);
    }

    if (std.mem.eql(u8, sub, "ascii")) {
        return ascii.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "explore") or std.mem.eql(u8, sub, "inspect-s57")) {
        return explore.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "cells")) {
        return cells.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "catalog")) {
        return catalog.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "features")) {
        return features.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "inspect")) {
        return inspect.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "zoomsizes")) {
        return zoomsizes.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "audit-holes")) {
        return audit_holes.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "audit-pairs")) {
        return audit_pairs.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "objlcount")) {
        return objlcount.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "cell")) {
        return cell.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "s101")) {
        return s101dump.run(io, arena, args);
    }

    if (std.mem.eql(u8, sub, "version") or std.mem.eql(u8, sub, "--version")) {
        std.debug.print("{s}\n", .{common.VERSION});
        return;
    }

    common.printUsage();
}
