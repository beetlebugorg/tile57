//! `bake <cell.000 | ENC_ROOT | chart.KAP | BSB_ROOT> -o <out-dir> [--rules DIR]
//! [-j N]` — produce a LIVE-composite structure on disk. Bake each chart to its OWN native-scale PMTiles under
//! `<out-dir>/<STEM>/` (with its M_COVR coverage embedded in the metadata), then open a resident
//! compositor over them and write the ownership partition to `<out-dir>/partition.tpart`. There is
//! NO merged archive: a runtime compositor (`ComposeSource` / the `compose-tile` command / the C
//! ABI `tile57_compose_*`) serves any tile ON DEMAND from this structure, so the per-chart bakes stay
//! dumb + cacheable and the partition holds all cross-cell ownership. Native scale only — deeper
//! coarse zooms are left to the client camera + MapLibre overzoom.

const std = @import("std");
const chart = @import("chart"); // per-chart bake (bakeChartBytes) + freeBytes
const compose = @import("compose"); // openComposeSourceFiles + serializePartition (the resident compositor)
const raster = @import("raster"); // the BSB/KAP bake + the raster chart handle
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

// ---- bake progress ---------------------------------------------------------
// Charts bake in parallel, so the unit of progress is charts done, not tiles.
// The engine's per-chart label callback fires (ctx, index) as each one finishes,
// from worker threads and out of order, so the index maps back to a name through
// the input list this tool owns. A terminal gets one \r bar tagged with the chart
// that just finished; a pipe gets one line per chart, so a log names everything
// that was baked.

/// The bar's width in glyphs.
const BAR_W = 24;

const Prog = struct {
    tty: bool,
    total: u32,
    /// The bake's input paths, in index order. A path's stem names the chart.
    paths: []const []const u8,
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Serializes the lines, as the sheet bake does: one print per chart against
    /// a bake measured in hundreds of milliseconds.
    say: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cell(self: *Prog, idx: u32) void {
        const d = self.done.fetchAdd(1, .monotonic) + 1;
        const name = if (idx < self.paths.len)
            std.fs.path.stem(std.fs.path.basename(self.paths[idx]))
        else
            "?";

        while (self.say.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
        defer self.say.store(false, .release);

        if (!self.tty) {
            std.debug.print("  [{d}/{d}] {s}\n", .{ d, self.total, name });
            return;
        }
        const pct: u32 = if (self.total == 0) 0 else @min(100, d * 100 / self.total);
        const filled = BAR_W * pct / 100;
        var bar: [BAR_W * 3]u8 = undefined; // the block glyphs are three bytes each
        var w: usize = 0;
        for (0..BAR_W) |i| {
            const g = if (i < filled) "█" else "░";
            @memcpy(bar[w..][0..g.len], g);
            w += g.len;
        }
        // The last chart ends the line, so the bake profile that follows starts
        // on one of its own.
        const tail: []const u8 = if (d >= self.total) "\n" else "";
        std.debug.print("\r\x1b[2K  {s} {d:>3}%  {d}/{d}  ·  {s}{s}", .{ bar[0..w], pct, d, self.total, name, tail });
    }
};

fn onCell(ctx: ?*anyopaque, idx: u32) callconv(.c) void {
    const self: *Prog = @ptrCast(@alignCast(ctx orelse return));
    self.cell(idx);
}

/// The walk that finds the charts, counted as it goes. A walk cannot know its
/// total until it ends, so this counts rather than fills a bar: the charts
/// found, and the referenced files read beside them. An exchange set is tens of
/// thousands of entries and every referenced file is read here, so the walk is
/// the part of a bake that was silent longest.
///
/// A terminal redraws one line in place and erases it when the bake starts,
/// which announces the same chart count. A pipe gets one line at the end,
/// because a line per file would bury the bake below it.
const Scan = struct {
    tty: bool,
    charts: u32 = 0,
    files: u32 = 0,
    /// Entries seen, for the redraw interval below.
    seen: u32 = 0,

    /// Redraw every this many entries. The walk visits far more entries than it
    /// keeps, and a write per entry costs more than the walk.
    const EVERY = 16;

    fn step(self: *Scan) void {
        self.seen += 1;
        if (!self.tty or self.seen % EVERY != 0) return;
        std.debug.print("\r\x1b[2K  scanning… {d} chart(s), {d} file(s)", .{ self.charts, self.files });
    }

    fn finish(self: *Scan) void {
        if (self.tty) {
            std.debug.print("\r\x1b[2K", .{});
            return;
        }
        std.debug.print("  scanned {d} chart(s), {d} file(s)\n", .{ self.charts, self.files });
    }
};

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
    const base_path = base orelse return usageErr("missing <cell.000 | ENC_ROOT | chart.KAP | BSB_ROOT> input");
    const out_dir = out orelse return usageErr("missing -o/--output <out-dir>");
    const rules_dir = resolveRulesDir(rules);

    // Which kind of library is this? A compositor holds ONE kind, so a bake
    // writes one: vector charts from .000 cells, raster charts from BSB/KAP
    // sheets. A directory holding both cannot be one library, and quietly
    // baking half of it would be worse than saying so.
    {
        const sheets = try findSheets(io, a, base_path);
        if (sheets.len > 0) {
            if (try holdsCells(io, base_path)) return usageErr("this directory holds both .000 cells and .KAP sheets; bake them separately (a compositor holds one kind of chart)");
            return bakeSheets(io, a, sheets, out_dir, workers);
        }
    }

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
            var scan = Scan{ .tty = std.Io.File.stderr().isTty(io) catch false };
            defer scan.finish();
            while (walker.next(io) catch null) |entry| {
                scan.step();
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
                    scan.files += 1;
                    continue;
                }
                if (!std.mem.endsWith(u8, entry.path, ".000")) continue;
                const stem = std.fs.path.stem(std.fs.path.basename(entry.path));
                if (seen.contains(stem)) continue;
                seen.put(a.dupe(u8, stem) catch continue, {}) catch {};
                cell_paths.append(a, std.fs.path.join(a, &.{ base_path, entry.path }) catch continue) catch {};
                scan.charts += 1;
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
        var prog = Prog{
            .tty = std.Io.File.stderr().isTty(io) catch false,
            .total = @intCast(cell_paths.items.len),
            .paths = cell_paths.items,
        };
        const baked = chart.bakeChartsToFiles(io, cell_paths.items, out_paths.items, rules_dir, n_workers, null, &prog, onCell);
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

// ---- the raster half: BSB/KAP sheets --------------------------------------

/// Case-insensitive suffix test. NOAA ships `.KAP`; other producers (and any
/// mariner who has renamed a file) ship `.kap`.
fn endsWithIgnoreCase(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext);
}

/// Every KAP sheet at `base`: the file itself, or every `*.KAP` under a
/// BSB_ROOT. Empty when this is not a raster input at all.
fn findSheets(io: std.Io, a: std.mem.Allocator, base: []const u8) ![]const []const u8 {
    var found = std.ArrayList([]const u8).empty;
    if (endsWithIgnoreCase(base, ".kap")) {
        try found.append(a, base);
        return found.toOwnedSlice(a);
    }
    var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var walker = dir.walk(a) catch return &.{};
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or !endsWithIgnoreCase(entry.path, ".kap")) continue;
        // The walker reuses one buffer for the path, so a borrowed slice becomes
        // the next entry's name.
        found.append(a, std.fs.path.join(a, &.{ base, entry.path }) catch continue) catch {};
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return found.toOwnedSlice(a);
}

/// Does `base` hold any S-57 cell? Used only to refuse a mixed directory.
fn holdsCells(io: std.Io, base: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".000")) return true;
    }
    return false;
}

/// Bake each sheet to its own `<out>/<STEM>/<STEM>.pmtiles`, then write the
/// ownership partition over the lot — the same structure the ENC bake writes,
/// which is the whole point: a folder of RNCs composes the way a folder of cells
/// does, through `tile57_compose_rasters`.
fn bakeSheets(io: std.Io, a: std.mem.Allocator, sheets: []const []const u8, out_dir: []const u8, workers: usize) !void {
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    // A sheet bake holds a whole decoded raster (a large ocean sheet is ~180 Mpx)
    // plus the pyramid it warps into, so the CLI's process arena is the wrong
    // home for it — and a worker thread must not share it anyway. Everything
    // per-sheet goes through libc's allocator and is freed as each sheet lands.
    const gpa = std.heap.c_allocator;

    var ctx = SheetCtx{
        .next = std.atomic.Value(usize).init(0),
        .sheets = sheets,
        .out_dir = out_dir,
        .out = try a.alloc(?[]const u8, sheets.len),
    };
    for (ctx.out) |*o| o.* = null;

    // Sheets are independent, so this is a plain fan-out. `workers` is a MEMORY
    // bound, exactly as it is for cells: each thread holds one whole sheet.
    var n = @max(@min(workers, sheets.len), 1);
    if (n > MAX_SHEET_WORKERS) n = MAX_SHEET_WORKERS;
    if (sheets.len > 1) std.debug.print("baking {d} sheet(s) across {d} worker(s)…\n", .{ sheets.len, n });
    if (n <= 1) {
        sheetWorker(&ctx);
    } else {
        var threads: [MAX_SHEET_WORKERS]std.Thread = undefined;
        var spawned: usize = 0;
        while (spawned < n - 1) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, sheetWorker, .{&ctx}) catch break;
        }
        sheetWorker(&ctx); // this thread is a worker too
        for (threads[0..spawned]) |t| t.join();
    }

    var archive_paths = std.ArrayList([]const u8).empty;
    for (ctx.out) |o| {
        if (o) |arc_path| archive_paths.append(a, arc_path) catch {};
    }
    if (archive_paths.items.len == 0) return usageErr("no sheet baked");

    // The partition, over the archives as a HOST sees them: opened as raster
    // charts and composed through tile57_compose_rasters' own path, so the
    // sidecar this writes is the partition that open will build.
    var charts = std.ArrayList(*raster.RasterChart).empty;
    var archives = std.ArrayList(compose.ChartArchive).empty;
    defer for (charts.items) |rc| {
        rc.close();
        gpa.destroy(rc);
    };
    for (archive_paths.items) |p| {
        const pz = a.dupeZ(u8, p) catch continue;
        const opened = raster.RasterChart.open(io, gpa, pz, null) catch |e| {
            std.debug.print("warning: {s} not reopened ({s})\n", .{ p, @errorName(e) });
            continue;
        };
        const rc = gpa.create(raster.RasterChart) catch continue;
        rc.* = opened;
        charts.append(a, rc) catch {};
        const rd = rc.pmtilesReader() orelse continue;
        const cov = rc.decodedCoverage() orelse continue;
        archives.append(a, .{ .reader = rd, .cov = cov }) catch {};
    }
    const src = (compose.ComposeSource.openRasters(gpa, archives.items, null) catch |e| {
        std.debug.print("error: open raster compositor failed ({s})\n", .{@errorName(e)});
        return;
    }) orelse return usageErr("no sheet carries a compilation scale and a border polygon");
    defer src.deinit();

    const part_bytes = src.serializePartition(a) catch |e| {
        std.debug.print("error: partition serialization failed ({s})\n", .{@errorName(e)});
        return;
    };
    const part_path = try std.fs.path.join(a, &.{ out_dir, "partition.tpart" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part_path, .data = part_bytes });

    std.debug.print(
        "live structure -> {s}/\n  {d} raster chart(s) + partition.tpart (serve z {d}..{d})\n",
        .{ out_dir, src.readers.len, src.minz, src.loop_max },
    );
}

/// A hard ceiling on sheet-bake threads; the CLI normally passes far fewer.
const MAX_SHEET_WORKERS = 32;

/// The fan-out state: sheets in, one archive path out per sheet (null where the
/// sheet was refused). Only `next` is shared mutable state — every worker writes
/// its own slot — so the whole of the synchronisation is one atomic and the
/// print lock.
const SheetCtx = struct {
    next: std.atomic.Value(usize),
    sheets: []const []const u8,
    out_dir: []const u8,
    out: []?[]const u8,
    /// Serializes the progress lines. A spin is the right shape here — Zig 0.16
    /// moved std.Thread.Mutex behind an Io this tool does not take, and the
    /// contended region is one print per sheet against a bake measured in
    /// hundreds of milliseconds.
    say: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(ctx: *SheetCtx) void {
        while (ctx.say.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
    }
    fn unlock(ctx: *SheetCtx) void {
        ctx.say.store(false, .release);
    }

    /// A warning from a worker, printed whole rather than interleaved with
    /// another thread's.
    fn warn(ctx: *SheetCtx, comptime fmt: []const u8, args: anytype) void {
        ctx.lock();
        defer ctx.unlock();
        std.debug.print("warning: " ++ fmt ++ "\n", args);
    }
};

fn sheetWorker(ctx: *SheetCtx) void {
    const gpa = std.heap.c_allocator;
    // Its own std.Io: the CLI's belongs to the main thread's event loop, and a
    // sheet bake is file reads and one big write.
    const threaded = gpa.create(std.Io.Threaded) catch return;
    threaded.* = .init(gpa, .{});
    defer {
        threaded.deinit();
        gpa.destroy(threaded);
    }
    const io = threaded.io();

    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.sheets.len) return;
        const path = ctx.sheets[i];
        const stem = std.fs.path.stem(std.fs.path.basename(path));
        const kap = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            ctx.warn("{s} not read ({s})", .{ path, @errorName(e) });
            continue;
        };
        defer gpa.free(kap);
        const baked = raster.bakebsb.bakeBytes(gpa, kap, stem) catch |e| {
            ctx.warn("{s} not baked ({s})", .{ path, reasonOf(e) });
            continue;
        };
        defer gpa.free(baked.bytes);

        // One directory per chart, as the ENC bake does it: the archive and
        // whatever travels with that chart live together.
        const chart_dir = std.fs.path.join(gpa, &.{ ctx.out_dir, stem }) catch continue;
        defer gpa.free(chart_dir);
        std.Io.Dir.cwd().createDirPath(io, chart_dir) catch {};
        const name = std.fmt.allocPrint(gpa, "{s}.pmtiles", .{stem}) catch continue;
        defer gpa.free(name);
        const arc_path = std.fs.path.join(gpa, &.{ chart_dir, name }) catch continue;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = arc_path, .data = baked.bytes }) catch |e| {
            gpa.free(arc_path);
            ctx.warn("{s} not written ({s})", .{ arc_path, @errorName(e) });
            continue;
        };
        ctx.out[i] = arc_path;
        ctx.lock();
        defer ctx.unlock();
        std.debug.print("  {s}: 1:{d}, z{d}..{d}, {d} tiles, fit {d:.2} px -> {s}\n", .{
            stem, baked.scale, baked.min_zoom, baked.max_zoom, baked.tiles, baked.fit_px, arc_path,
        });
    }
}

/// Why a sheet was refused, in words a mariner can act on.
fn reasonOf(e: anyerror) []const u8 {
    return switch (e) {
        error.NotKap => "not a BSB/KAP sheet",
        error.BadHeader => "the header says nothing usable about its raster",
        error.BadRaster => "the run-length data is truncated or malformed",
        error.NoGeoreference => "too few REF control points to place it",
        error.FitResidual => "the fit cannot reproduce its own control points",
        error.NoBorder => "no PLY border polygon, so it can own no ground",
        error.Empty => "its raster and its stated position do not overlap",
        else => @errorName(e),
    };
}
