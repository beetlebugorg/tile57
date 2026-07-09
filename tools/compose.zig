//! `compose <cell.000 | ENC_ROOT | archive-dir> -o <out.pmtiles> [--rules DIR] [--keep-cells]
//! [--from-archives]` — the
//! per-cell composite bake, disk-to-disk. Bake each cell to its OWN native-scale PMTiles (with
//! its M_COVR coverage embedded in the metadata), written to a temp file so only ONE cell's
//! archive is ever resident; then stream them through the ownership partition into one merged
//! PMTiles (bundle.composeArchivesToFile mmaps the per-cell files, so the whole cell set is
//! never loaded into memory at once). This is the two-stage model that retires the streaming
//! in-bake cross-cell combiner. Native scale only for now — cross-band overscale one zoom past
//! each band; deeper coarse-only zooms are left to the client camera + MapLibre overzoom.

const std = @import("std");
const engine = @import("engine");
const chart = @import("chart"); // per-cell bake (bakeCellBytes) + freeBytes
const bundle = @import("bundle"); // composeArchivesToFile (the partition-driven compositor)
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var keep_cells = false; // retain the per-cell temp PMTiles (a reusable cache) instead of deleting
    var from_archives = false; // compose a dir of pre-baked archives (skip the bake)

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--keep-cells")) {
            keep_cells = true;
        } else if (std.mem.eql(u8, arg, "--from-archives")) {
            from_archives = true; // <base> is a DIR of pre-baked *.cell.tmp / *.pmtiles — skip baking
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (base == null) {
            base = arg;
        } else {
            return usageErr("unexpected argument (cell updates are auto-discovered next to the .000)");
        }
    }
    const base_path = base orelse return usageErr("missing <cell.000 | ENC_ROOT> input");
    const out_path = out orelse return usageErr("missing -o/--output <out.pmtiles>");
    const rules_dir = resolveRulesDir(rules);

    // 1. Enumerate the cell .000 paths (dedup by stem — a boundary cell shared by two districts
    //    bakes once).
    var cell_paths = std.ArrayList([]const u8).empty;
    if (std.mem.endsWith(u8, base_path, ".000")) {
        try cell_paths.append(a, base_path);
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return usageErr("cannot open ENC_ROOT");
        defer dir.close(io);
        var seen = std.StringHashMap(void).init(a);
        var walker = dir.walk(a) catch return usageErr("cannot walk ENC_ROOT");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".000")) continue;
            const stem = std.fs.path.stem(std.fs.path.basename(entry.path));
            if (seen.contains(stem)) continue;
            seen.put(a.dupe(u8, stem) catch continue, {}) catch {};
            cell_paths.append(a, std.fs.path.join(a, &.{ base_path, entry.path }) catch continue) catch {};
        }
    }
    if (!from_archives and cell_paths.items.len == 0) return usageErr("no .000 cells found");

    // 2. Bake each cell to its own temp PMTiles file (one cell resident at a time — the bytes
    //    are freed as soon as they are written).
    var tmp_paths = std.ArrayList([]const u8).empty;
    defer if (!keep_cells and !from_archives) for (tmp_paths.items) |p| {
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    };
    if (from_archives) {
        // <base> is a directory of pre-baked *.cell.tmp / *.pmtiles — compose them directly.
        // The fast recompose loop over a --keep-cells cache: the bake (~minutes for a
        // district) is skipped, only the partition + compose (~seconds to minutes) reruns.
        var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return usageErr("cannot open archives dir");
        defer dir.close(io);
        var walker = dir.walk(a) catch return usageErr("cannot walk archives dir");
        defer walker.deinit();
        while (walker.next(io) catch |err| blk: {
            // A mid-walk I/O error would silently compose a PARTIAL cell set — say so.
            std.debug.print("  warn: archive walk aborted early ({s}); composing what was found\n", .{@errorName(err)});
            break :blk null;
        }) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".cell.tmp") and !std.mem.endsWith(u8, entry.path, ".pmtiles")) continue;
            tmp_paths.append(a, std.fs.path.join(a, &.{ base_path, entry.path }) catch continue) catch {};
        }
        // Sort the archive paths: the ownership tie-break falls back to input order for
        // archives carrying identical (date, name) keys (e.g. two generations of one
        // cell in a polluted cache), and directory enumeration order is unspecified —
        // sorting makes any such tie, and the composed bytes, deterministic.
        std.mem.sort([]const u8, tmp_paths.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        std.debug.print("recompose: {d} pre-baked archives from {s}\n", .{ tmp_paths.items.len, base_path });
    } else for (cell_paths.items) |cp| {
        const arc = (chart.bakeCellBytes(cp, rules_dir) catch |err| {
            std.debug.print("  warn: bake of {s} failed ({s}); skipping\n", .{ cp, @errorName(err) });
            continue;
        }) orelse continue;
        defer chart.freeBytes(arc);
        const stem = std.fs.path.stem(std.fs.path.basename(cp));
        const tmp = std.fmt.allocPrint(a, "{s}.{s}.cell.tmp", .{ out_path, stem }) catch continue;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = arc }) catch continue;
        tmp_paths.append(a, tmp) catch {};
        if (tmp_paths.items.len % 25 == 0) std.debug.print("  baked {d}/{d} cells…\n", .{ tmp_paths.items.len, cell_paths.items.len });
    }
    if (tmp_paths.items.len == 0) return usageErr("no cells baked (no .000 with M_COVR found)");

    // 3. Stream-compose the per-cell files into one PMTiles (mmap in, streamed out — the cell
    //    set is never all resident).
    const nc = bundle.composeArchivesToFile(io, a, tmp_paths.items, out_path, null) catch |err| {
        std.debug.print("error: compose failed ({s})\n", .{@errorName(err)});
        return;
    };
    if (nc == 0) {
        std.debug.print("compose produced no tiles\n", .{});
        return;
    }
    std.debug.print("composed {d} cell(s) -> {s}{s}\n", .{ nc, out_path, if (keep_cells) " (per-cell temp files kept)" else "" });
}
