//! `compose <cell.000 | ENC_ROOT> -o <out.pmtiles> [--rules DIR]` — the per-cell composite
//! bake. Bake each cell to its OWN native-scale PMTiles (with its M_COVR coverage embedded in
//! the metadata), then combine them via the ownership partition into ONE merged PMTiles
//! (bundle.composeArchives). This is the two-stage model that retires the streaming in-bake
//! cross-cell combiner: dumb, cacheable per-cell bakes + a compositor driven by precomputed
//! per-band ownership. Native scale only for now — cross-band zoom expansion is a later stage.

const std = @import("std");
const engine = @import("engine");
const chart = @import("chart"); // per-cell bake (bakeCellBytes) + freeBytes
const bundle = @import("bundle"); // composeArchives (the partition-driven compositor)
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
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

    // 1. Bake each cell to its own per-cell PMTiles (native band scale, coverage embedded).
    //    Archive bytes are owned by chart's global allocator (free with chart.freeBytes).
    var archives = std.ArrayList([]u8).empty;
    defer {
        for (archives.items) |arc| chart.freeBytes(arc);
        archives.deinit(a);
    }

    if (std.mem.endsWith(u8, base_path, ".000")) {
        if (try chart.bakeCellBytes(base_path, rules_dir)) |arc| try archives.append(a, arc);
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return usageErr("cannot open ENC_ROOT");
        defer dir.close(io);
        var seen = std.StringHashMap(void).init(a);
        var walker = dir.walk(a) catch return usageErr("cannot walk ENC_ROOT");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".000")) continue;
            const stem = std.fs.path.stem(std.fs.path.basename(entry.path));
            if (seen.contains(stem)) continue; // a boundary cell shared by two districts: once
            seen.put(a.dupe(u8, stem) catch continue, {}) catch {};
            const full = std.fs.path.join(a, &.{ base_path, entry.path }) catch continue;
            const arc = (chart.bakeCellBytes(full, rules_dir) catch |err| {
                std.debug.print("  warn: bake of {s} failed ({s}); skipping\n", .{ stem, @errorName(err) });
                continue;
            }) orelse continue;
            try archives.append(a, arc);
            if (archives.items.len % 25 == 0) std.debug.print("  baked {d} cells…\n", .{archives.items.len});
        }
    }
    if (archives.items.len == 0) return usageErr("no cells baked (no .000 with M_COVR found)");

    // 2. Combine the per-cell archives via the ownership partition into one PMTiles.
    const composed = (bundle.composeArchives(a, archives.items) catch |err| {
        std.debug.print("error: compose failed ({s})\n", .{@errorName(err)});
        return;
    }) orelse {
        std.debug.print("compose produced no tiles\n", .{});
        return;
    };

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = composed });
    std.debug.print("composed {d} cell(s) -> {s} ({d} bytes)\n", .{ archives.items.len, out_path, composed.len });
}
