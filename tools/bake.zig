//! `bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [--from-archives]` — produce a
//! LIVE-composite structure on disk. Bake each chart to its OWN native-scale PMTiles under
//! `<out-dir>/tiles/` (with its M_COVR coverage embedded in the metadata), then open a resident
//! compositor over them and write the ownership partition to `<out-dir>/partition.tpart`. There is
//! NO merged archive: a runtime compositor (`ComposeSource` / the `compose-tile` command / the C
//! ABI `tile57_compose_*`) serves any tile ON DEMAND from this structure, so the per-chart bakes stay
//! dumb + cacheable and the partition holds all cross-cell ownership. Native scale only — deeper
//! coarse zooms are left to the client camera + MapLibre overzoom.
//!
//! `--from-archives`: `<base>` is ALREADY a directory of per-chart archives (*.pmtiles / *.cell.tmp);
//! skip the bake and only (re)build the partition sidecar into `<out-dir>/partition.tpart` over them
//! — the fast re-partition loop over a tiles dir.

const std = @import("std");
const chart = @import("chart"); // per-chart bake (bakeChartBytes) + freeBytes
const compose = @import("compose"); // openComposeSourceFiles + serializePartition (the resident compositor)
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;

// ---- overall bake progress --------------------------------------------------
// Cells bake in parallel (bakeChartsToFiles), so the unit is charts-done, not
// tiles. The engine's per-cell LABEL callback fires (ctx, index) as each chart
// finishes — possibly CONCURRENTLY from worker threads and out of order — so we
// map index -> name from our own `names` list, count completions with an atomic,
// and format into a stack-local buffer (no shared mutable state, no lock). TTY
// redraws one \r bar tagged with the chart that just finished; piped prints one
// line per chart so a log names everything it baked.
const BAR_W = 24;

const Prog = struct {
    io: std.Io,
    tty: bool,
    total: u32,
    names: []const []const u8, // stems in in_paths index order
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn put(self: *Prog, s: []const u8) void {
        std.Io.File.stderr().writeStreamingAll(self.io, s) catch {};
    }

    fn cell(self: *Prog, idx: u32) void {
        const d = self.done.fetchAdd(1, .monotonic) + 1; // completions counted here (order-free)
        const name: []const u8 = if (idx < self.names.len) self.names[idx] else "?";
        var buf: [256]u8 = undefined;
        if (!self.tty) {
            self.put(std.fmt.bufPrint(&buf, "  [{d}/{d}] {s}\n", .{ d, self.total, name }) catch return);
            return;
        }
        const pct: u32 = if (self.total == 0) 0 else @min(100, d * 100 / self.total);
        const filled = BAR_W * pct / 100;
        var bar: [BAR_W * 3]u8 = undefined; // UTF-8 block glyphs are 3 bytes
        var w: usize = 0;
        for (0..BAR_W) |i| {
            const g = if (i < filled) "█" else "░";
            @memcpy(bar[w .. w + g.len], g);
            w += g.len;
        }
        self.put(std.fmt.bufPrint(&buf, "\r\x1b[2K  {s} {d:>3}%  {d}/{d}  ·  {s}", .{ bar[0..w], pct, d, self.total, name }) catch return);
    }

    fn finish(self: *Prog, baked: usize) void {
        var buf: [96]u8 = undefined;
        const noun: []const u8 = if (baked == 1) "chart" else "charts";
        const line = if (self.tty)
            std.fmt.bufPrint(&buf, "\r\x1b[2K  \x1b[32m✓\x1b[0m baked {d} {s}\n", .{ baked, noun }) catch return
        else
            std.fmt.bufPrint(&buf, "  baked {d} {s}\n", .{ baked, noun }) catch return;
        self.put(line);
    }
};

fn onCell(ctx: ?*anyopaque, idx: u32) callconv(.c) void {
    const self: *Prog = @ptrCast(@alignCast(ctx orelse return));
    self.cell(idx);
}

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var from_archives = false; // <base> is a dir of pre-baked archives — skip baking, only build the partition

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--from-archives")) {
            from_archives = true;
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

    if (from_archives) {
        // <base> is a directory of pre-baked *.pmtiles / *.cell.tmp — read them in place.
        var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return usageErr("cannot open archives dir");
        defer dir.close(io);
        var walker = dir.walk(a) catch return usageErr("cannot walk archives dir");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".cell.tmp") and !std.mem.endsWith(u8, entry.path, ".pmtiles")) continue;
            archive_paths.append(a, std.fs.path.join(a, &.{ base_path, entry.path }) catch continue) catch {};
        }
        if (archive_paths.items.len == 0) return usageErr("no *.pmtiles / *.cell.tmp archives found");
        std.debug.print("re-partition: {d} pre-baked archives from {s}\n", .{ archive_paths.items.len, base_path });
    } else {
        // Bake each chart (dedup by stem — a boundary chart shared by two districts bakes once)
        // to its own <out-dir>/tiles/<STEM>.pmtiles.
        const tiles_dir = try std.fs.path.join(a, &.{ out_dir, "tiles" });
        try std.Io.Dir.cwd().createDirPath(io, tiles_dir);

        // Enumerate the input cells (a single .000, or every .000 in an ENC_ROOT) and
        // the mirrored <tiles>/<STEM>.pmtiles each bakes to. Same path for one file or
        // many — a single cell is just a one-item batch.
        var in_paths = std.ArrayList([]const u8).empty;
        var out_paths = std.ArrayList([]const u8).empty;
        var names = std.ArrayList([]const u8).empty; // chart stems, index-aligned with in_paths
        if (std.mem.endsWith(u8, base_path, ".000")) {
            const stem = std.fs.path.stem(std.fs.path.basename(base_path));
            try in_paths.append(a, base_path);
            try out_paths.append(a, try std.fs.path.join(a, &.{ tiles_dir, try std.fmt.allocPrint(a, "{s}.pmtiles", .{stem}) }));
            try names.append(a, stem);
        } else {
            var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return usageErr("cannot open ENC_ROOT");
            defer dir.close(io);
            var seen = std.StringHashMap(void).init(a);
            var walker = dir.walk(a) catch return usageErr("cannot walk ENC_ROOT");
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".000")) continue;
                const stem_t = std.fs.path.stem(std.fs.path.basename(entry.path));
                if (seen.contains(stem_t)) continue;
                const stem = a.dupe(u8, stem_t) catch continue; // entry.path is transient — own the stem
                seen.put(stem, {}) catch {};
                const in_path = std.fs.path.join(a, &.{ base_path, entry.path }) catch continue;
                const name = std.fmt.allocPrint(a, "{s}.pmtiles", .{stem}) catch continue;
                in_paths.append(a, in_path) catch continue;
                out_paths.append(a, std.fs.path.join(a, &.{ tiles_dir, name }) catch continue) catch continue;
                names.append(a, stem) catch continue;
            }
        }
        if (in_paths.items.len == 0) return usageErr("no .000 cells found");

        // Bake every cell IN PARALLEL (one worker per core, memory-bounded), each writing
        // its own archive; the label callback names each chart as it finishes.
        var prog = Prog{ .io = io, .tty = std.Io.File.stderr().isTty(io) catch false, .total = @intCast(in_paths.items.len), .names = names.items };
        const workers = std.Thread.getCpuCount() catch 1;
        const baked = chart.bakeChartsToFiles(io, in_paths.items, out_paths.items, rules_dir, workers, null, &prog, onCell);
        prog.finish(baked);

        // Collect the archives that actually landed (a cell with no M_COVR bakes nothing)
        // by walking the tiles dir — the same *.pmtiles set the partition composes over.
        var tdir = std.Io.Dir.cwd().openDir(io, tiles_dir, .{ .iterate = true }) catch return usageErr("cannot reopen tiles dir");
        defer tdir.close(io);
        var tw = tdir.walk(a) catch return usageErr("cannot walk tiles dir");
        defer tw.deinit();
        while (tw.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".pmtiles")) continue;
            archive_paths.append(a, std.fs.path.join(a, &.{ tiles_dir, entry.path }) catch continue) catch {};
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

    std.debug.print(
        "live structure -> {s}/\n  {d} per-chart archive(s){s} + partition.tpart (serve z {d}..{d})\n",
        .{ out_dir, src.readers.len, if (from_archives) " (in place)" else " under tiles/", src.minz, src.loop_max },
    );
}
