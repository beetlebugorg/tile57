//! `bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [-j N]` — produce a
//! LIVE-composite structure on disk. Bake each chart to its OWN native-scale PMTiles under
//! `<out-dir>/<STEM>/` (with its M_COVR coverage embedded in the metadata), then open a resident
//! compositor over them and write the ownership partition to `<out-dir>/partition.tpart`. There is
//! NO merged archive: a runtime compositor (`ComposeSource` / the `compose-tile` command / the C
//! ABI `tile57_compose_*`) serves any tile ON DEMAND from this structure, so the per-chart bakes stay
//! dumb + cacheable and the partition holds all cross-cell ownership. Native scale only — deeper
//! coarse zooms are left to the client camera + MapLibre overzoom.

const std = @import("std");
const chart = @import("chart"); // per-chart bake (bakeChartBytes) + freeBytes
const compose = @import("compose"); // openComposeSourceFiles + serializePartition (the resident compositor)
const common = @import("common.zig");
const auxfiles = @import("engine").auxfiles;
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;

/// Default bake threads. A concurrent bake holds a whole cell's parse + portray +
/// raster working set, so this is bounded by MEMORY, not cores — half the cores,
/// capped, keeps a big ENC_ROOT from thrashing on a laptop. Override with -j.
fn defaultWorkers() usize {
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(cpus / 2, 8));
}

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    // Bake threads. Each concurrent bake holds a whole cell's parse + portray + raster
    // working set, so this is a MEMORY bound, not a core count — hence a modest default
    // rather than one thread per core. Tile generation within a cell is serial, so N
    // workers stay N threads.
    var workers: usize = defaultWorkers();
    // The text and pictures the cells point at travel with the chart by default:
    // a pick report that cannot read its caution note is worth less than the
    // few kilobytes.
    var want_aux = true;

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--workers")) {
            const v = f.val(arg) orelse return;
            workers = std.fmt.parseInt(usize, v, 10) catch return usageErr("-j/--workers expects a positive integer");
            if (workers == 0) return usageErr("-j/--workers must be >= 1");
        } else if (std.mem.eql(u8, arg, "--no-aux")) {
            want_aux = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown flag");
        } else if (base == null) {
            base = arg;
        } else {
            return usageErr("unexpected argument (cell updates are auto-discovered next to the .000)");
        }
    }
    const base_path = base orelse return usageErr("missing <cell.000 | ENC_ROOT> input");
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const rules_dir = resolveRulesDir(rules);

    // The per-chart archive paths that back the compositor.
    var archive_paths = std.ArrayList([]const u8).empty;
    var aux_written: usize = 0;

    {
        // Bake each chart (dedup by stem — a boundary chart shared by two districts bakes once)
        // to its own <out-dir>/<STEM>/<STEM>.pmtiles, the shape an exchange set uses.
        try std.Io.Dir.cwd().createDirPath(io, out_dir);

        var cell_paths = std.ArrayList([]const u8).empty;
        var aux_files = std.ArrayList(auxfiles.File).empty;
        if (std.mem.endsWith(u8, base_path, ".000")) {
            try cell_paths.append(a, base_path);
            // The cell's own directory holds the files it references.
            if (want_aux) {
                const stem = std.fs.path.stem(std.fs.path.basename(base_path));
                if (std.fs.path.dirname(base_path)) |cell_dir| {
                    var dir = std.Io.Dir.cwd().openDir(io, cell_dir, .{ .iterate = true }) catch null;
                    if (dir) |*d| {
                        defer d.close(io);
                        var it = d.iterate();
                        while (it.next(io) catch null) |entry| {
                            if (entry.kind != .file or !auxfiles.isContent(entry.name)) continue;
                            const p = std.fs.path.join(a, &.{ cell_dir, entry.name }) catch continue;
                            const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited) catch continue;
                            aux_files.append(a, .{ .owner = stem, .name = entry.name, .bytes = bytes }) catch {};
                        }
                    }
                }
            }
        } else {
            var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return usageErr("cannot open ENC_ROOT");
            defer dir.close(io);
            var seen = std.StringHashMap(void).init(a);
            var walker = dir.walk(a) catch return usageErr("cannot walk ENC_ROOT");
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (want_aux and auxfiles.isContent(entry.path)) {
                    const p = std.fs.path.join(a, &.{ base_path, entry.path }) catch continue;
                    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited) catch continue;
                    // The exchange set puts a cell's files in the cell's own
                    // directory, so that directory names the owner. Both names
                    // must be COPIED: the walker reuses one buffer for the path,
                    // so a borrowed slice becomes the next entry's name.
                    const owner = a.dupe(u8, std.fs.path.basename(std.fs.path.dirname(entry.path) orelse "")) catch continue;
                    const name = a.dupe(u8, entry.path) catch continue;
                    aux_files.append(a, .{ .owner = owner, .name = name, .bytes = bytes }) catch {};
                    continue;
                }
                if (!std.mem.endsWith(u8, entry.path, ".000")) continue;
                const stem = std.fs.path.stem(std.fs.path.basename(entry.path));
                if (seen.contains(stem)) continue;
                seen.put(a.dupe(u8, stem) catch continue, {}) catch {};
                cell_paths.append(a, std.fs.path.join(a, &.{ base_path, entry.path }) catch continue) catch {};
            }
        }
        if (cell_paths.items.len == 0) return usageErr("no .000 cells found");

        // Name every output up front, then hand the whole batch to the engine's
        // parallel bake. It writes and frees each archive as it finishes, so peak
        // memory tracks the worker count rather than the cell count.
        var out_paths = std.ArrayList([]const u8).empty;
        for (cell_paths.items) |cp| {
            const stem = std.fs.path.stem(std.fs.path.basename(cp));
            // One directory per chart, as the exchange set does it: the archive
            // and the files that chart references travel together.
            const chart_dir = std.fs.path.join(a, &.{ out_dir, stem }) catch continue;
            std.Io.Dir.cwd().createDirPath(io, chart_dir) catch continue;
            const name = std.fmt.allocPrint(a, "{s}.pmtiles", .{stem}) catch continue;
            out_paths.append(a, std.fs.path.join(a, &.{ chart_dir, name }) catch continue) catch {};
        }
        if (out_paths.items.len != cell_paths.items.len) return usageErr("out of memory naming archives");

        // The referenced text and pictures, beside the chart that names them.
        for (cell_paths.items) |cp| {
            const stem = std.fs.path.stem(std.fs.path.basename(cp));
            var mine = std.ArrayList(auxfiles.File).empty;
            for (aux_files.items) |af| {
                if (std.mem.eql(u8, af.owner, stem)) mine.append(a, af) catch {};
            }
            if (mine.items.len == 0) continue;
            const chart_dir = std.fs.path.join(a, &.{ out_dir, stem }) catch continue;
            aux_written += auxfiles.writeDir(io, a, chart_dir, mine.items) catch |err| blk: {
                std.debug.print("warning: aux files not written for {s} ({s})\n", .{ stem, @errorName(err) });
                break :blk 0;
            };
        }

        const n_workers = @min(workers, cell_paths.items.len);
        if (cell_paths.items.len > 1) {
            std.debug.print("baking {d} cell(s) across {d} worker(s)…\n", .{ cell_paths.items.len, n_workers });
        }
        const baked = chart.bakeChartsToFiles(io, cell_paths.items, out_paths.items, rules_dir, n_workers, null, null);
        if (baked == 0) return usageErr("no cells baked (no .000 with M_COVR found)");

        // bakeChartsToFiles reports a count, not which ones — a cell with no M_COVR
        // coverage writes nothing and is not composable, so keep only the archives
        // that actually landed.
        for (out_paths.items) |op| {
            var fh = std.Io.Dir.cwd().openFile(io, op, .{}) catch continue;
            fh.close(io);
            archive_paths.append(a, op) catch {};
        }
        if (archive_paths.items.len == 0) return usageErr("no cells baked (no .000 with M_COVR found)");
    }

    // Sort the archive paths so the ownership tie-break (which falls back to input order for
    // archives carrying identical (date, name) keys) and the partition it produces are deterministic.
    std.mem.sort([]const u8, archive_paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    // Open the resident compositor over the per-chart archives (mmap'd) and serialize its ownership
    // partition to <out-dir>/partition.tpart — the sidecar a runtime open loads to skip the build.
    const src = (compose.ComposeSource.openFiles(io, a, archive_paths.items, null) catch |err| {
        std.debug.print("error: open compose source failed ({s})\n", .{@errorName(err)});
        return;
    }) orelse return usageErr("no coverage-carrying archives (nothing to compose)");
    defer src.deinit();

    const part_bytes = src.serializePartition(a) catch |err| {
        std.debug.print("error: partition serialization failed ({s})\n", .{@errorName(err)});
        return;
    };
    const part_path = try std.fs.path.join(a, &.{ out_dir, "partition.tpart" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part_path, .data = part_bytes });

    if (aux_written > 0) {
        std.debug.print("  {d} auxiliary file(s) beside their charts\n", .{aux_written});
    }

    std.debug.print(
        "live structure -> {s}/\n  {d} per-chart directory(s) + partition.tpart (serve z {d}..{d})\n",
        .{ out_dir, src.readers.len, src.minz, src.loop_max },
    );
}
