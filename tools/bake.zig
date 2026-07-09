//! `bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [--from-archives]` — produce a
//! LIVE-composite structure on disk. Bake each cell to its OWN native-scale PMTiles under
//! `<out-dir>/tiles/` (with its M_COVR coverage embedded in the metadata), then open a resident
//! compositor over them and write the ownership partition to `<out-dir>/partition.tpart`. There is
//! NO merged archive: a runtime compositor (`ComposeSource` / the `compose-tile` command / the C
//! ABI `tile57_compose_*`) serves any tile ON DEMAND from this structure, so the per-cell bakes stay
//! dumb + cacheable and the partition holds all cross-cell ownership. Native scale only — deeper
//! coarse zooms are left to the client camera + MapLibre overzoom.
//!
//! `--from-archives`: `<base>` is ALREADY a directory of per-cell archives (*.pmtiles / *.cell.tmp);
//! skip the bake and only (re)build the partition sidecar into `<out-dir>/partition.tpart` over them
//! — the fast re-partition loop over a tiles dir.

const std = @import("std");
const chart = @import("chart"); // per-cell bake (bakeCellBytes) + freeBytes
const bundle = @import("bundle"); // openComposeSourceFiles + serializePartition (the resident compositor)
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;

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

    // The per-cell archive paths that back the compositor.
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
        // Bake each cell (dedup by stem — a boundary cell shared by two districts bakes once)
        // to its own <out-dir>/tiles/<STEM>.pmtiles.
        const tiles_dir = try std.fs.path.join(a, &.{ out_dir, "tiles" });
        try std.Io.Dir.cwd().createDirPath(io, tiles_dir);

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
        if (cell_paths.items.len == 0) return usageErr("no .000 cells found");

        for (cell_paths.items) |cp| {
            const arc = (chart.bakeCellBytes(cp, rules_dir) catch |err| {
                std.debug.print("  warn: bake of {s} failed ({s}); skipping\n", .{ cp, @errorName(err) });
                continue;
            }) orelse continue; // no M_COVR coverage — not a composable cell
            defer chart.freeBytes(arc);
            const stem = std.fs.path.stem(std.fs.path.basename(cp));
            const name = std.fmt.allocPrint(a, "{s}.pmtiles", .{stem}) catch continue;
            const arc_path = std.fs.path.join(a, &.{ tiles_dir, name }) catch continue;
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = arc_path, .data = arc }) catch |err| {
                std.debug.print("  warn: could not write {s} ({s})\n", .{ arc_path, @errorName(err) });
                continue;
            };
            archive_paths.append(a, arc_path) catch {};
            if (archive_paths.items.len % 25 == 0) std.debug.print("  baked {d}/{d} cells…\n", .{ archive_paths.items.len, cell_paths.items.len });
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

    // Open the resident compositor over the per-cell archives (mmap'd) and serialize its ownership
    // partition to <out-dir>/partition.tpart — the sidecar a runtime open loads to skip the build.
    const src = (bundle.openComposeSourceFiles(io, a, archive_paths.items, null) catch |err| {
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
        "live structure -> {s}/\n  {d} per-cell archive(s){s} + partition.tpart (serve z {d}..{d})\n",
        .{ out_dir, src.readers.len, if (from_archives) " (in place)" else " under tiles/", src.minz, src.loop_max },
    );
}
