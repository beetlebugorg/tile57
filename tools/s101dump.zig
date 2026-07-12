//! `tile57 s101 <file.000>` — inspect a native S-101 (S-100 Part 10a) dataset:
//! detection, DSSI parameters, code-table sizes, record counts, a feature-class
//! histogram, and a couple of sample features with their attributes. A ground-truth
//! check for the native reader against real datasets.

const std = @import("std");
const engine = @import("engine");
const s101 = engine.s101;

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: tile57 s101 <file.000> [--features N]\n", .{});
        return;
    }
    const path = args[2];
    var want_features: usize = 3;
    if (args.len >= 5 and std.mem.eql(u8, args[3], "--features")) {
        want_features = std.fmt.parseInt(usize, args[4], 10) catch 3;
    }

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    std.debug.print("{s}\n  detected S-101: {}\n", .{ path, s101.dataset.detect(data) });
    if (!s101.dataset.detect(data)) {
        std.debug.print("  (not a native S-101 dataset)\n", .{});
        return;
    }

    var ds = try s101.dataset.parse(a, data);
    defer ds.deinit();
    const p = ds.params;
    std.debug.print(
        "  params: cmfx={d} cmfy={d} cmfz={d}\n  DSSI counts: point={d} multi={d} curve={d} composite={d} surface={d} feature={d} info={d}\n",
        .{ p.cmfx, p.cmfy, p.cmfz, p.n_point, p.n_multipoint, p.n_curve, p.n_composite, p.n_surface, p.n_feature, p.n_info },
    );
    std.debug.print(
        "  parsed: points={d} multis={d} curves={d} composites={d} surfaces={d} features={d} infos={d}\n",
        .{ ds.points.len, ds.multis.len, ds.curves.len, ds.composites.len, ds.surfaces.len, ds.features.len, ds.infos.len },
    );
    std.debug.print("  code tables: feature={d} attr={d} info={d} assoc={d}\n", .{
        ds.feature_codes.by_code.count(),
        ds.attr_codes.by_code.count(),
        ds.info_codes.by_code.count(),
        ds.assoc_codes.by_code.count(),
    });

    // Feature-class histogram (by S-101 class name).
    var hist = std.StringHashMap(usize).init(a);
    var unresolved: usize = 0;
    for (ds.features) |f| {
        const nm = ds.featureName(f) orelse {
            unresolved += 1;
            continue;
        };
        const gop = try hist.getOrPut(nm);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    std.debug.print("  feature classes: {d} distinct ({d} unresolved codes)\n", .{ hist.count(), unresolved });
    // Print the histogram sorted by count desc.
    const Entry = struct { name: []const u8, n: usize };
    var entries = std.ArrayList(Entry).empty;
    var it = hist.iterator();
    while (it.next()) |e| try entries.append(a, .{ .name = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.n > y.n;
        }
    }.lt);
    for (entries.items) |e| std.debug.print("    {d:>5}  {s}\n", .{ e.n, e.name });

    // Sample features with attributes.
    var shown: usize = 0;
    for (ds.features) |f| {
        if (shown >= want_features) break;
        if (f.attrs.len < 3) continue;
        const nm = ds.featureName(f) orelse continue;
        var prim: []const u8 = "?";
        if (f.spas.len > 0) prim = switch (f.spas[0].rrnm) {
            s101.dataset.RCNM_POINT => "Point",
            s101.dataset.RCNM_MULTIPOINT => "Multipoint",
            s101.dataset.RCNM_CURVE, s101.dataset.RCNM_COMPOSITE => "Curve",
            s101.dataset.RCNM_SURFACE => "Surface",
            else => "?",
        };
        std.debug.print("\n  FEATURE rcid={d} class={s} primitive={s} attrs={d} spas={d} fasc={d}\n", .{ f.rcid, nm, prim, f.attrs.len, f.spas.len, f.fasc.len });
        for (f.attrs) |at| {
            const an = ds.attrName(at) orelse "?";
            const v = if (at.val.len > 60) at.val[0..60] else at.val;
            std.debug.print("      natc={d:>3}({s}) atix={d} paix={d} val={s}\n", .{ at.natc, an, at.atix, at.paix, v });
        }
        shown += 1;
    }

    // --- Geometry-shell assembly (the s57.Cell the renderer consumes) --------
    var loaded = try s101.native.parseDataset(a, data);
    defer loaded.cell.deinit();
    const cell = loaded.cell;
    std.debug.print("\n  assembled shell: features={d} adapted={d} vectors={d} nodes={d} edges={d} soundingVecs={d}\n", .{
        cell.features.len, loaded.adapted.len, cell.vectors.len, cell.nodes.count(), cell.edges.count(), cell.sounding_vecs.count(),
    });
    if (cell.bounds()) |b| std.debug.print("  geometry bounds: lon [{d:.5}, {d:.5}]  lat [{d:.5}, {d:.5}]\n", .{ b[0], b[2], b[1], b[3] });
    // Spot-check assembled geometry per primitive: pick the first area/line/point
    // adapted feature and report the vertex/part counts the accessors return.
    var did_area = false;
    var did_line = false;
    var did_pt = false;
    for (loaded.adapted) |ad| {
        const f = cell.features[ad.feature_index];
        if (f.prim == 3 and !did_area) {
            const parts = cell.geometryParts(a, f) catch &[_][]engine.s57.LonLat{};
            var verts: usize = 0;
            for (parts) |pp| verts += pp.len;
            std.debug.print("  area  {s}: {d} parts / {d} verts\n", .{ ad.code, parts.len, verts });
            did_area = true;
        } else if (f.prim == 2 and !did_line) {
            const parts = cell.geometryParts(a, f) catch &[_][]engine.s57.LonLat{};
            var verts: usize = 0;
            for (parts) |pp| verts += pp.len;
            std.debug.print("  line  {s}: {d} parts / {d} verts\n", .{ ad.code, parts.len, verts });
            did_line = true;
        } else if (f.prim == 1 and !did_pt) {
            if (cell.pointGeometry(f)) |pt| {
                std.debug.print("  point {s}: lon={d:.5} lat={d:.5}\n", .{ ad.code, pt.lon(), pt.lat() });
                did_pt = true;
            }
        }
    }
    // Soundings are emitted directly (not in `adapted`); report the first one.
    for (cell.features) |f| {
        if (f.objl != 129) continue;
        const snds = cell.soundingsFor(a, f) catch &[_]engine.s57.Sounding{};
        if (snds.len > 0) {
            std.debug.print("  sounding: {d} depth pts, first depth={d:.1}m\n", .{ snds.len, snds[0].depth });
            break;
        }
    }

    // --- Portrayal audit: run the rules and count ok / empty / ERROR streams -----
    engine.portray.setQuiet(true);
    const streams = engine.portray.portrayCellWithAdapted(a, &cell, loaded.adapted, "", .{}) catch {
        std.debug.print("  portrayal FAILED to run\n", .{});
        return;
    };
    var ok: usize = 0;
    var empty: usize = 0;
    var errored: usize = 0;
    var err_by_class = std.StringHashMap(usize).init(a);
    for (loaded.adapted) |ad| {
        const s = if (ad.feature_index < streams.len) streams[ad.feature_index] else null;
        if (s == null) {
            empty += 1;
        } else if (std.mem.startsWith(u8, s.?, "ERROR:")) {
            errored += 1;
            const gop = try err_by_class.getOrPut(ad.code);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        } else ok += 1;
    }
    std.debug.print("\n  portrayal: ok={d} empty={d} ERROR={d} (of {d} adapted)\n", .{ ok, empty, errored, loaded.adapted.len });
    if (errored > 0) {
        var eit = err_by_class.iterator();
        while (eit.next()) |e| std.debug.print("    ERROR x{d}: {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    }
}
