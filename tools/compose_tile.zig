//! `compose-tile <archive-dir> <z> <x> <y> [--load-partition FILE] [-o out] [--bench N]` — serve one
//! composed tile ON DEMAND from a resident ownership partition + mmap'd per-cell archives (the
//! runtime-compositor path), byte-identical to the batch. `--bench N` then serves an N×N tile block
//! around (x,y) to report per-tile serving latency, amortising the one-time open.
//!
//! `compose-tile <archive-dir> --scan Z0[..Z1] [--load-partition FILE]` — compose EVERY tile in the
//! source bounds at those zooms and report each tile whose clip left an open ring walk (the
//! geometry boolean's wedge-artifact diagnostic): on correct booleans the count is always zero, so
//! any hit names a broken tile exactly. The artifact sweep to run after touching the boolean.

const std = @import("std");
const engine = @import("engine");
const compose = @import("compose");
const geometry = @import("geometry");
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;

// Monotonic nanoseconds (std.time has no Timer in this toolchain).
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var dir_path: ?[]const u8 = null;
    var zs: ?[]const u8 = null;
    var xs: ?[]const u8 = null;
    var ys: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var load_partition: ?[]const u8 = null;
    var bench: u32 = 0;
    var scan: ?[]const u8 = null;

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--load-partition")) {
            load_partition = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--bench")) {
            bench = f.int(u32, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--scan")) {
            scan = f.val(arg) orelse return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (dir_path == null) {
            dir_path = arg;
        } else if (zs == null) {
            zs = arg;
        } else if (xs == null) {
            xs = arg;
        } else if (ys == null) {
            ys = arg;
        } else return usageErr("unexpected argument");
    }
    const dir = dir_path orelse return usageErr("missing <archive-dir>");
    // --scan Z0[..Z1] needs no positional tile address.
    var scan_z0: u8 = 0;
    var scan_z1: u8 = 0;
    if (scan) |sv| {
        if (std.mem.indexOf(u8, sv, "..")) |dots| {
            scan_z0 = std.fmt.parseInt(u8, sv[0..dots], 10) catch return usageErr("bad --scan zoom");
            scan_z1 = std.fmt.parseInt(u8, sv[dots + 2 ..], 10) catch return usageErr("bad --scan zoom");
        } else {
            scan_z0 = std.fmt.parseInt(u8, sv, 10) catch return usageErr("bad --scan zoom");
            scan_z1 = scan_z0;
        }
        if (scan_z1 < scan_z0) return usageErr("bad --scan zoom range");
    }
    const z = if (scan != null) 0 else std.fmt.parseInt(u8, zs orelse return usageErr("missing z"), 10) catch return usageErr("bad z");
    const tx = if (scan != null) 0 else std.fmt.parseInt(u32, xs orelse return usageErr("missing x"), 10) catch return usageErr("bad x");
    const ty = if (scan != null) 0 else std.fmt.parseInt(u32, ys orelse return usageErr("missing y"), 10) catch return usageErr("bad y");

    // Enumerate the per-cell archives (sorted, like `compose --from-archives`).
    var paths = std.ArrayList([]const u8).empty;
    {
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return usageErr("cannot open archive dir");
        defer d.close(io);
        var walker = d.walk(a) catch return usageErr("cannot walk archive dir");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".cell.tmp") and !std.mem.endsWith(u8, entry.path, ".pmtiles")) continue;
            paths.append(a, std.fs.path.join(a, &.{ dir, entry.path }) catch continue) catch {};
        }
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    if (paths.items.len == 0) return usageErr("no *.cell.tmp / *.pmtiles archives found");

    // Read the partition sidecar, if provided (a missing/stale one just rebuilds inside open).
    var load_bytes: ?[]const u8 = null;
    if (load_partition) |lp| load_from: {
        var lf = std.Io.Dir.cwd().openFile(io, lp, .{}) catch break :load_from;
        defer lf.close(io);
        const st = lf.stat(io) catch break :load_from;
        const n: usize = @intCast(st.size);
        if (n == 0) break :load_from;
        const buf = a.alloc(u8, n) catch break :load_from;
        _ = lf.readPositionalAll(io, buf, 0) catch break :load_from;
        load_bytes = buf;
    }

    // Open the resident source (mmap archives + partition once) — the amortised cost.
    const open_t0 = nowNs();
    const src = (compose.openComposeSourceFiles(io, a, paths.items, load_bytes) catch |err| {
        std.debug.print("error: open compose source failed ({s})\n", .{@errorName(err)});
        return;
    }) orelse {
        std.debug.print("no coverage-carrying archives in {s}\n", .{dir});
        return;
    };
    defer src.deinit();
    const open_ms = @as(f64, @floatFromInt(nowNs() - open_t0)) / 1e6;
    std.debug.print("opened {d} cell(s), partition {s}, in {d:.1} ms (serve z {d}..{d})\n", .{ src.readers.len, if (load_bytes != null) "loaded" else "built", open_ms, src.minz, src.loop_max });

    // Artifact sweep: compose every in-bounds tile at the scan zooms and report
    // each one whose clip dead-ended a ring walk (open chain ⇒ chord artifact).
    if (scan != null) {
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        var bad_tiles: usize = 0;
        var total: usize = 0;
        var sz = scan_z0;
        while (sz <= scan_z1) : (sz += 1) {
            const scale: f64 = @floatFromInt(@as(u32, 1) << @intCast(sz));
            const tl = engine.tile.lonLatToWorld(src.bounds[0], src.bounds[3]);
            const br = engine.tile.lonLatToWorld(src.bounds[2], src.bounds[1]);
            const x0 = compose.worldAxisToTile(tl[0], scale);
            const x1 = compose.worldAxisToTile(br[0], scale);
            const y0 = compose.worldAxisToTile(tl[1], scale);
            const y1 = compose.worldAxisToTile(br[1], scale);
            var zx = x0;
            while (zx <= x1) : (zx += 1) {
                var zy = y0;
                while (zy <= y1) : (zy += 1) {
                    const before = geometry.boolean.open_chain_walks;
                    const big_before = geometry.boolean.large_open_chains;
                    const aa = arena_state.allocator();
                    const r = src.tile(aa, sz, zx, zy) catch |err| {
                        std.debug.print("z{d}/{d}/{d}: ERROR {s}\n", .{ sz, zx, zy, @errorName(err) });
                        continue;
                    };
                    if (r.tile != null) total += 1;
                    const chains = geometry.boolean.open_chain_walks - before;
                    const big = geometry.boolean.large_open_chains - big_before;
                    if (chains > 0) {
                        bad_tiles += 1;
                        std.debug.print("z{d}/{d}/{d}: {d} open chain(s), {d} large\n", .{ sz, zx, zy, chains, big });
                    }
                    _ = arena_state.reset(.retain_capacity);
                }
            }
            std.debug.print("scan z{d} done ({d} composed so far, {d} bad)\n", .{ sz, total, bad_tiles });
        }
        std.debug.print("scan complete: {d} tiles composed, {d} with open chains\n", .{ total, bad_tiles });
        return;
    }

    // Serve the requested tile.
    const serve_t0 = nowNs();
    const res = try src.tile(a, z, tx, ty);
    const tile = res.tile;
    const serve_ms = @as(f64, @floatFromInt(nowNs() - serve_t0)) / 1e6;
    if (tile) |t| {
        std.debug.print("served z{d}/{d}/{d}: {d} bytes (raw MLT, owned={}) in {d:.3} ms\n", .{ z, tx, ty, t.len, res.owned, serve_ms });
        if (out) |op| std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = t }) catch |err|
            std.debug.print("  warn: could not write {s} ({s})\n", .{ op, @errorName(err) });
        a.free(t);
    } else std.debug.print("z{d}/{d}/{d}: no cell owns this tile (null) in {d:.3} ms\n", .{ z, tx, ty, serve_ms });

    // Optional benchmark: serve an N×N block around (tx,ty), reporting amortised per-tile latency.
    if (bench > 0) {
        const half = bench / 2;
        var served: usize = 0;
        var bytes: usize = 0;
        const bench_t0 = nowNs();
        var dx: u32 = 0;
        while (dx < bench) : (dx += 1) {
            var dy: u32 = 0;
            while (dy < bench) : (dy += 1) {
                const bx = (tx + dx) -| half;
                const by = (ty + dy) -| half;
                const tl = (src.tile(a, z, bx, by) catch continue).tile;
                if (tl) |t| {
                    served += 1;
                    bytes += t.len;
                    a.free(t);
                }
            }
        }
        const total_ms = @as(f64, @floatFromInt(nowNs() - bench_t0)) / 1e6;
        const n: f64 = @floatFromInt(bench * bench);
        std.debug.print("bench: {d}/{d} tiles owned, queried {d} in {d:.1} ms = {d:.3} ms/tile ({d} bytes total)\n", .{ served, @as(u32, bench * bench), @as(u32, bench * bench), total_ms, total_ms / n, bytes });
    }
}
