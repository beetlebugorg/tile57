const std = @import("std");
const engine = @import("engine");
const assets = @import("assets");
const bundle = @import("bundle"); // chart-bundle pipeline (asset emitters etc.) — the lib owns it
const common = @import("common.zig");
const Flags = common.Flags;
const usageErr = common.usageErr;
const resolveRulesDir = common.resolveRulesDir;
const resolveCatalogDir = common.resolveCatalogDir;
const VERSION = common.VERSION;
const DEFAULT_MINZOOM = common.DEFAULT_MINZOOM;
const DEFAULT_MAXZOOM = common.DEFAULT_MAXZOOM;
const DEFAULT_LRU_BUDGET = common.DEFAULT_LRU_BUDGET;
const DEFAULT_SUPER_DZ = common.DEFAULT_SUPER_DZ;

/// `bake <cell.000 | ENC_ROOT> -o <out-dir> [--rules DIR] [--catalog DIR]
///  [--minzoom N] [--maxzoom N] [--lru N] [--superdz N] [--created ISO8601]` —
/// THE bake command. A single cell or a whole ENC_ROOT, streamed through the same
/// lazy banded bake into a self-contained chart bundle: tiles/chart.pmtiles +
/// assets/colortables.json + sprite-mln + style-{day,dusk,night}.json +
/// manifest.json (pins schema_version, couples tiles to portrayal).
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var rules: ?[]const u8 = null;
    var catalog: ?[]const u8 = null;
    var created: []const u8 = "";
    var minzoom: u8 = DEFAULT_MINZOOM;
    var maxzoom: u8 = DEFAULT_MAXZOOM;
    var lru: usize = DEFAULT_LRU_BUDGET; // lazy-bake tuning: parsed cells held resident
    var super_dz: u8 = DEFAULT_SUPER_DZ; // lazy-bake tuning: spatial super-tile depth
    var format: engine.scene.TileFormat = .mlt; // tile encoding: mlt (default) or mvt
    var existing: []const u8 = ""; // cross-pack best-available: a peer pack's ENC_ROOT
    var partition_debug = false; // emit the ownership-partition debug PMTiles instead of a bundle
    var part_band: i8 = -1; // partition-debug: <0 = band governing each zoom; 0..5 = one band's map

    var f = Flags{ .args = args };
    while (f.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--existing")) {
            existing = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            rules = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--catalog")) {
            catalog = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--created")) {
            created = f.val(arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--minzoom")) {
            minzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--maxzoom")) {
            maxzoom = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--lru")) {
            lru = f.int(usize, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--superdz")) {
            super_dz = f.int(u8, arg) orelse return;
        } else if (std.mem.eql(u8, arg, "--format")) {
            const v = f.val(arg) orelse return;
            format = if (std.mem.eql(u8, v, "mlt")) .mlt else if (std.mem.eql(u8, v, "mvt")) .mvt else return usageErr("--format must be mvt or mlt");
        } else if (std.mem.eql(u8, arg, "--partition-debug")) {
            partition_debug = true;
        } else if (std.mem.eql(u8, arg, "--band")) {
            const v = f.val(arg) orelse return;
            part_band = bandArg(v) orelse return usageErr("--band must be a rank 0..5 or a name (berthing..overview)");
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
    if (minzoom > maxzoom) return usageErr("--minzoom must be <= --maxzoom");
    if (maxzoom > 24) return usageErr("--maxzoom too large (max 24)");
    if (lru < 1) return usageErr("--lru must be >= 1");

    // Debug: emit the ownership partition (which cell owns which ground per band) as a
    // single PMTiles with no portrayed content, for eyeballing the composite quilt.
    if (partition_debug) {
        // Full overview→approach range by default (z13+ shows harbor detail but the
        // face-tile count grows ~4^z, so raise --maxzoom on demand).
        const dbg_minz: u8 = if (minzoom == DEFAULT_MINZOOM) 0 else minzoom;
        const dbg_maxz: u8 = if (maxzoom == DEFAULT_MAXZOOM) 12 else maxzoom;
        const nc = bundle.bakePartitionDebug(io, a, base_path, out_dir, dbg_minz, dbg_maxz, part_band) catch |err| {
            std.debug.print("error: partition-debug bake of {s} failed ({s})\n", .{ base_path, @errorName(err) });
            return;
        };
        std.debug.print("partition-debug: {d} cell(s) -> {s} (z{d}-{d}, band {d}, layer \"partition\": cell/cscl/band/tier/oi/color)\n", .{ nc, out_dir, dbg_minz, dbg_maxz, part_band });
        return;
    }

    // The whole tiles + assets + manifest pipeline lives in the `bundle` lib module
    // (bundle.bakeBundle) so any consumer (the C ABI, a Go/JS binding) emits the same
    // package; the CLI just resolves args -> options and prints the summary.
    const res = bundle.bakeBundle(io, a, .{
        .input = base_path,
        .out_dir = out_dir,
        .rules_dir = resolveRulesDir(rules),
        .catalog_dir = resolveCatalogDir(catalog),
        .generator = VERSION,
        .created = created,
        .minzoom = minzoom,
        .maxzoom = maxzoom,
        .lru = lru,
        .super_dz = super_dz,
        .format = format,
        .existing_input = existing,
    }) catch |err| {
        std.debug.print("error: cannot bake {s} ({s})\n", .{ base_path, @errorName(err) });
        return;
    };

    std.debug.print(
        "bundled {d} cell(s) -> {s}/\n  tiles/chart.pmtiles + assets/colortables.json + sprite-mln + style-{{day,dusk,night}}.json + manifest.json (schema {s})\n",
        .{ res.cell_count, out_dir, assets.SCHEMA_VERSION },
    );
}

// Parse a --band value: a rank 0..5, or a navigational-purpose name (finest→coarsest).
fn bandArg(v: []const u8) ?i8 {
    const names = [_][]const u8{ "berthing", "harbor", "approach", "coastal", "general", "overview" };
    for (names, 0..) |nm, i| if (std.mem.eql(u8, v, nm)) return @intCast(i);
    const n = std.fmt.parseInt(i8, v, 10) catch return null;
    return if (n < 0 or n > 5) null else n;
}
