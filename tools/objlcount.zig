const std = @import("std");
const engine = @import("engine");

// Lean corpus scan: count features of one object class (optionally one
// primitive) in a single cell, parse-only (no topology assembly), one line
// per matching cell — drive a whole ENC_ROOT with `find … | xargs -P`. Used
// to find real cells that exercise a conversion change (e.g. a point DAMCON).
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 4) {
        std.debug.print("usage: tile57 objlcount <file.000> <objl> [prim]\n", .{});
        return;
    }
    const path = args[2];
    const want_objl = std.fmt.parseInt(u16, args[3], 10) catch {
        std.debug.print("error: objl must be an integer\n", .{});
        return;
    };
    const want_prim: ?u8 = if (args.len >= 5) (std.fmt.parseInt(u8, args[4], 10) catch null) else null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch {
        std.debug.print("{s} READ_ERROR\n", .{path});
        return;
    };
    var cell = engine.s57.parseCell(a, data) catch {
        std.debug.print("{s} PARSE_ERROR\n", .{path});
        return;
    };
    defer cell.deinit();
    // objl 0 = histogram mode: emit every object class that appears as a POINT
    // (prim 1) in this cell, one line each. One corpus sweep then aggregates which
    // classes ever occur as points — cross-reference against S-101 rules with no
    // Point branch to find latent "renders nothing" bugs (as for point DAMCON).
    if (want_objl == 0) {
        var hist = [_]usize{0} ** 1024;
        for (cell.features) |f| if (f.prim == 1 and f.objl < 1024) {
            hist[f.objl] += 1;
        };
        for (hist, 0..) |cnt, objl| if (cnt > 0)
            std.debug.print("objl={d} point={d}\n", .{ objl, cnt });
        return;
    }
    var pc = [_]usize{0} ** 256;
    for (cell.features) |f| if (f.objl == want_objl) {
        pc[f.prim] += 1;
    };
    const total = pc[1] + pc[2] + pc[3] + pc[255];
    const match = if (want_prim) |wp| pc[wp] > 0 else total > 0;
    if (match) {
        std.debug.print("{s} objl={d} point={d} line={d} area={d} none={d}\n", .{ path, want_objl, pc[1], pc[2], pc[3], pc[255] });
        // Locate matches of the requested primitive (default point) + dump their
        // attributes, one delimitable block per feature (helps pin the tile a change
        // lands in, identify an unknown class by its attribute codes, and scan the
        // corpus for per-feature attribute presence on line/area classes too).
        const dump_prim: u8 = want_prim orelse 1;
        for (cell.features) |f| if (f.objl == want_objl and f.prim == dump_prim) {
            std.debug.print("    feature rcid={d} prim={d}\n", .{ f.rcid, f.prim });
            if (f.prim == 1) if (cell.pointGeometry(f)) |p|
                std.debug.print("      point @ lon={d:.6} lat={d:.6}\n", .{ p.lon(), p.lat() });
            for (f.attrs) |at|
                std.debug.print("      attr {d} = \"{s}\"\n", .{ at.code, std.mem.trim(u8, at.value, " ") });
        };
    }
    return;
}
