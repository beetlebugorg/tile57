//! S-57 -> S-101 portrayal attribute-coverage check
//! (Tasks 2-3 of the conformance-testability brief; see
//! specs/conformance-testability.md). Run it: `zig build s101-coverage`
//! (append `-- --json out.json` / `-- --fail-on-new tools/s101_coverage_baseline.json`).
//! The gate baseline lives at tools/s101_coverage_baseline.json (tracked; /specs/
//! is gitignored). Regenerate it after an intended change with --write-baseline.
//!
//! 1. STATIC READ-SET (Task 2): scan the vendored S-101 Portrayal Catalogue Lua
//!    rules and, per feature-class rule, collect every attribute the rule reads
//!    via the literal idiom `feature.<attributeName>`. Reads are propagated
//!    through the `require 'X'` graph so a class's read-set includes the shared
//!    sub-rules it calls (DepthArea -> DEPARE03 -> {depthRangeMinimumValue,
//!    restriction}). Reads are intersected with the real attribute universe from
//!    vendor/s101/catalogue.json, dropping framework pseudo-properties
//!    (PrimitiveType, Code, spatialAssociations, ...).
//!
//! 2. ADAPTER COVERAGE (Task 3): classify each consumed attribute as
//!      (a) SOURCED   - non-empty S-57 `alias` in catalogue.json, so the adapter's
//!                      resolveAttrByCode forwards it (s101_adapt.zig:468).
//!      (b) DEFAULTED - the adapter synthesizes it without an S-57 alias (light
//!                      sectors, topmark, featureName<-OBJNAM, zoneOfConfidence
//!                      <-CATZOC, ...; ADAPTER_SYNTHESIZED below).
//!      (c) NEITHER   - no S-57 source and the adapter does not synthesize it. The
//!                      rule reads a missing input, silently takes a default
//!                      branch, renders a plausible-but-wrong chart. THE
//!                      DELIVERABLE THAT MATTERS — each is a latent render bug.
//!
//! Pure Zig std (json + std.Io), no imports from the tree, so CI can build+run it
//! early and cheaply. Sibling of tools/bake.zig; wired as the `s101-coverage`
//! build step.

const std = @import("std");

const CATALOGUE = "vendor/s101/catalogue.json";
const S57CODES = "vendor/s101/s57codes.json";
const PERMITTED = "vendor/s101/permitted.json"; // per-class permitted enum values the adapter enforces
const RULES_DIR = "vendor/S-101_Portrayal-Catalogue/PortrayalCatalog/Rules";

// Attributes the adapter synthesizes/derives WITHOUT a direct S-57 alias.
// Sourced verbatim from src/s100/s101_adapt.zig (2026-07-01); grow this when the
// adapter grows new synthesis.
const ADAPTER_SYNTHESIZED = [_][]const u8{
    // orientation / clearance complexes (s101_adapt.zig:122-127, 494-501)
    "orientation",                      "orientationValue",
    "verticalClearanceClosed",          "verticalClearanceFixed",
    "verticalClearanceOpen",            "verticalClearanceValue",
    "horizontalClearanceFixed",         "horizontalClearanceValue",
    // Gate's HORCLR -> horizontalClearanceOpen (class-keyed; the other 8 classes that
    // reference it bind …Fixed, so its absence there is an expected-absence)
    "horizontalClearanceOpen",
    // openingBridge synthesized from CATBRG 2..8 for BRIDGE->Bridge (s101_adapt.zig)
             "openingBridge",
    // current velocity CURVEL -> speed.speedMaximum (s101_adapt.zig complex_from_simple)
    "speed",                            "speedMaximum",
    "speedMinimum",
    // NATSUR list -> surfaceCharacteristics[].natureOfSurface for SeabedArea
    // (s101_adapt.zig buildSurfaceCharacteristics; off-list values dropped)
                        "surfaceCharacteristics",
    // CATMOR {1,2} -> categoryOfDolphin for MORFAC-routed Dolphin (same coding)
    "categoryOfDolphin",
    // VALLMA -> valueOfLocalMagneticAnomaly.magneticAnomalyValue (LocalMagneticAnomaly)
                   "valueOfLocalMagneticAnomaly",
    "magneticAnomalyValue",
    // inTheWater: producer spatial derivation (point over DEPARE and not over LNDARE),
    // no S-57 source (s101_adapt.zig readsInTheWater); true-only, else absent
                "inTheWater",
    // light sector + rhythm synthesis (s101_adapt.zig:376-431, 697-710)
    "sectorCharacteristics",            "lightSector",
    "sectorLimit",                      "sectorLimitOne",
    "sectorLimitTwo",                   "sectorBearing",
    "directionalCharacter",             "rhythmOfLight",
    "lightCharacteristic",              "signalGroup",
    "signalPeriod",                     "valueOfNominalRange",
    "lightVisibility",
    // featureName from OBJNAM (s101_adapt.zig:466, 477-480)
                     "featureName",
    "name",                             "language",
    "nameUsage",
    // zoneOfConfidence from M_QUAL CATZOC (s101_adapt.zig:482-489)
                           "zoneOfConfidence",
    "categoryOfZoneOfConfidenceInData",
    // topmark fold (s101_adapt.zig:513-522, 641-643)
    "topmark",
    "topmarkDaymarkShape",
    // QUAPOS aggregate -> feature attr (s101_adapt.zig:552-557)
                 "qualityOfHorizontalMeasurement",
    // depth range served for DepthArea/DepthContour (s101_adapt.zig:607-610)
    "depthRangeMinimumValue",
    // underwater-hazard depths for UDWHAZ05/OBSTRN07/WRECKS05 (s101_adapt.zig:544-549):
    // defaultClearanceDepth always, surroundingDepth when the danger sits in a depth area
              "surroundingDepth",
    "defaultClearanceDepth",
};

// ---- S-65 Annex B value-level rules (the "correctness" axis) ----------------
// The coverage buckets above answer "is the attribute supplied?". These answer
// "is the supplied VALUE valid S-101?". A slot is at-risk when the adapter
// forwards a raw S-57 value that S-65 says must be remapped, dropped, or is off
// the S-101 allowable list. Keyed by S-57 acronym/object (matching S-65 and
// specs/s57-s101-conversion-gaps.md); translated to S-101 names at run time via
// the catalogue alias maps, so only attributes a rule ACTUALLY reads surface.

const AttrNote = struct { acr: []const u8, note: []const u8 };
// Global value transforms — any feature reading the attribute is at risk (S-65 §2.2.3.x).
const VALUE_REMAP = [_]AttrNote{
    .{ .acr = "TECSOU", .note = "TECSOU 6/7 prohibited, 14->17 (S-65 2.2.3.5)" },
    .{ .acr = "QUASOU", .note = "QUASOU 5 prohibited -> DepthNoBottomFound/drop (2.2.3.3)" },
    .{ .acr = "QUAPOS", .note = "QUAPOS remap 3/6/7/8/9/11->4, drop 1/2/10 (2.2.3)" },
    .{ .acr = "CATBRG", .note = "CATBRG -> categoryOfOpeningBridge restructure (4.8.10)" },
};

// Acronyms whose VALUE_REMAP the adapter now applies before the value reaches a
// rule (s101_adapt.zig s65RemapValue / s65RemapQuapos): the prohibited/remapped
// values are dropped or mapped, and every surviving value is inside the S-101
// allowable list — so the "remap" concern is retired. The per-object RESTRICTED
// allowable-list axis, if any, is still reported (a separate concern). Grow this as
// the adapter grows transforms. (QUAPOS: no rule reads qualityOfHorizontalMeasurement
// today, so it never surfaced at-risk; listed for when a reader appears. CATBRG ->
// categoryOfOpeningBridge is realized via filterPermitted [3,4,5,7] on Bridge once
// BRIDGE routes to the Bridge class; no rule reads that attr either.)
const VALUE_REMAP_DONE = [_][]const u8{ "TECSOU", "QUASOU", "QUAPOS", "CATBRG" };

const AttrObjs = struct { acr: []const u8, objs: []const []const u8 };
// Per-object restricted allowable-value lists (S-65 Table A-1/A-2; gaps doc §A.3).
const RESTRICTED = [_]AttrObjs{
    .{ .acr = "NATCON", .objs = &.{ "BCNCAR", "BCNISD", "BCNLAT", "BCNSAW", "BCNSPP", "BOYSPP", "BRIDGE", "BUISGL", "DAMCON", "DAYMAR", "DYKCON", "FNCLNE", "GATCON", "GRIDRN", "HRBFAC", "LITFLT", "LITVES", "LNDMRK", "PYLONS", "RUNWAY", "SILTNK", "ROADWY", "MORFAC" } },
    .{ .acr = "STATUS", .objs = &.{ "AIRARE", "BERTHS", "BUISGL", "CHKPNT", "CONVYR", "FSHFAC", "GRIDRN", "HRBARE", "ICEARE", "LNDARE", "LNDMRK", "LOGPON", "OFSPLF", "PILBOP", "PRDARE", "RIVERS", "ROADWY", "SILTNK", "SLCONS", "TUNNEL", "UWTROC", "MORFAC" } },
    .{ .acr = "CATSPM", .objs = &.{ "BCNSPP", "BOYSPP", "DAYMAR" } },
    .{ .acr = "CONDTN", .objs = &.{ "FLODOC", "FORSTC", "RAILWY", "ROADWY", "TUNNEL", "OSPARE", "MORFAC" } },
    .{ .acr = "TECSOU", .objs = &.{ "DWRTCL", "DWRTPT", "RCRTCL", "RECTRC", "SOUNDG", "TWRTPT" } },
    .{ .acr = "QUASOU", .objs = &.{ "BERTHS", "FAIRWY", "RECTRC", "SOUNDG" } },
    .{ .acr = "RESTRN", .objs = &.{ "CBLARE", "DMPGRD", "DRGARE", "PIPARE", "TESARE" } },
    .{ .acr = "COLOUR", .objs = &.{ "COALNE", "LIGHTS", "SLOGRD", "SLOTOP" } },
    .{ .acr = "CATCBL", .objs = &.{ "CBLARE", "CBLSUB" } },
    .{ .acr = "NATSUR", .objs = &.{ "SLOGRD", "SLOTOP", "UWTROC" } },
    .{ .acr = "EXPSOU", .objs = &.{ "MARCUL", "UWTROC" } },
    .{ .acr = "MARSYS", .objs = &.{ "BCNCAR", "BCNISD", "BCNLAT", "BCNSAW", "BCNSPP", "BOYCAR", "BOYINB", "BOYISD", "BOYLAT", "BOYSAW", "BOYSPP", "LIGHTS", "M_NSYS" } },
    .{ .acr = "WATLEV", .objs = &.{ "GRIDRN", "LNDRGN" } },
    .{ .acr = "PRODCT", .objs = &.{ "CONVYR", "PIPARE", "PIPSOL" } },
    .{ .acr = "CATVEG", .objs = &.{"VEGATN"} },
    .{ .acr = "CATROS", .objs = &.{"RDOSTA"} },
    .{ .acr = "LITCHR", .objs = &.{"LIGHTS"} },
    .{ .acr = "BOYSHP", .objs = &.{"MORFAC"} },
};

// `enforced` = the adapter drops this attribute write-side (s101_adapt.zig DROP_ATTRS /
// isDroppedAttr), so the value never reaches a rule and the slot is NOT at-risk even if
// a rule reads it. Defaults true: every §E pair below is enforced. A future §E entry the
// adapter hasn't wired yet sets `.enforced = false` and still flags (the CI safety net,
// like VALUE_REMAP vs VALUE_REMAP_DONE). Keep this table in sync with s101_adapt.zig.
const ObjAttr = struct { obj: []const u8, acr: []const u8, enforced: bool = true };
// Per-object attribute drops — "will not be converted" for that feature (gaps doc §E).
// Enforced write-side by the adapter; the entries stay as the §E reference + safety net.
const DROP = [_]ObjAttr{
    .{ .obj = "DEPARE", .acr = "QUASOU" }, .{ .obj = "CBLSUB", .acr = "DRVAL1" },
    .{ .obj = "CBLSUB", .acr = "DRVAL2" }, .{ .obj = "CONZNE", .acr = "STATUS" },
    .{ .obj = "BOYINB", .acr = "MARSYS" }, .{ .obj = "BOYINB", .acr = "VERLEN" },
    .{ .obj = "PONTON", .acr = "NATCON" }, .{ .obj = "LNDRGN", .acr = "NATQUA" },
    .{ .obj = "OFSPLF", .acr = "NATCON" }, .{ .obj = "RADSTA", .acr = "DATEND" },
    .{ .obj = "RADSTA", .acr = "DATSTA" }, .{ .obj = "RDOSTA", .acr = "ORIENT" },
    .{ .obj = "MAGVAR", .acr = "DATEND" }, .{ .obj = "MAGVAR", .acr = "DATSTA" },
    .{ .obj = "SWPARE", .acr = "QUASOU" }, .{ .obj = "SWPARE", .acr = "SOUACC" },
    .{ .obj = "SWPARE", .acr = "TECSOU" }, .{ .obj = "SOUNDG", .acr = "EXPSOU" },
    .{ .obj = "DRYDOC", .acr = "HORACC" }, .{ .obj = "FLODOC", .acr = "HORACC" },
    .{ .obj = "OBSTRN", .acr = "NATCON" }, .{ .obj = "OBSTRN", .acr = "NATQUA" },
    .{ .obj = "M_QUAL", .acr = "TECSOU" }, // prohibited for Quality of Bathymetric Data (S-65 §2.2.3.1)
};

const NO_STRS: []const []const u8 = &.{};
fn listHas(list: []const []const u8, want: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, want)) return true;
    return false;
}

const RiskEntry = struct { class: []const u8, attr: []const u8, kind: []const u8, note: []const u8 };
fn riskRank(k: []const u8) u8 {
    if (std.mem.eql(u8, k, "drop")) return 0;
    if (std.mem.eql(u8, k, "remap")) return 1;
    return 2; // restricted
}
fn lessRisk(_: void, x: RiskEntry, y: RiskEntry) bool {
    const rx = riskRank(x.kind);
    const ry = riskRank(y.kind);
    if (rx != ry) return rx < ry;
    const c = std.mem.order(u8, x.class, y.class);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, x.attr, y.attr) == .lt;
}

const StrSet = std.StringHashMap(void);
const StrList = std.ArrayList([]const u8);

const Module = struct {
    reads: StrSet,
    reqs: StrList,
};

fn isIdent(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

/// Collect `feature.<ident>` reads (dot form only, so `feature:method` calls and
/// `featurePortrayal.` are ignored). Matches the Python `feature\.([A-Za-z_]\w*)`.
fn scanReads(a: std.mem.Allocator, text: []const u8, set: *StrSet) !void {
    const needle = "feature.";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, needle)) |p| {
        i = p + needle.len;
        if (p > 0 and isIdent(text[p - 1])) continue; // word boundary before "feature"
        if (i >= text.len or !isAlpha(text[i])) continue;
        var j = i;
        while (j < text.len and isIdent(text[j])) : (j += 1) {}
        try set.put(text[i..j], {});
    }
    _ = a;
}

/// Collect `require 'X'` / `require('X'` targets (module = file stem).
fn scanReqs(a: std.mem.Allocator, text: []const u8, list: *StrList) !void {
    const needle = "require";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, needle)) |p| {
        i = p + needle.len;
        if (p > 0 and isIdent(text[p - 1])) continue;
        var j = i;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
        if (j < text.len and text[j] == '(') {
            j += 1;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
        }
        if (j >= text.len or text[j] != '\'') continue;
        j += 1;
        const start = j;
        while (j < text.len and text[j] != '\'') : (j += 1) {}
        if (j <= text.len and j > start) try list.append(a, text[start..j]);
    }
}

/// Transitive union of a module's own reads and everything it require()s.
fn addClosure(mods: *const std.StringHashMap(Module), mod: []const u8, seen: *StrSet, out: *StrSet) !void {
    if (seen.contains(mod)) return;
    try seen.put(mod, {});
    const m = mods.get(mod) orelse return;
    var it = m.reads.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    for (m.reqs.items) |req| try addClosure(mods, req, seen, out);
}

fn readJson(io: std.Io, a: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    return parsed.value; // parsed arena kept alive by `a` (process arena); never deinit
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn jesc(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '"' or c == '\\') try b.append(a, '\\');
        try b.append(a, c);
    }
    return b.items;
}

const AttrCat = struct { name: []const u8, cat: []const u8 };
fn lessAttrCat(_: void, x: AttrCat, y: AttrCat) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}
const CEntry = struct { name: []const u8, classes: []const []const u8 };
fn lessC(_: void, x: CEntry, y: CEntry) bool {
    if (x.classes.len != y.classes.len) return x.classes.len > y.classes.len; // count desc
    return std.mem.order(u8, x.name, y.name) == .lt;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);

    var json_out: ?[]const u8 = null;
    var fail_baseline: ?[]const u8 = null;
    var write_baseline: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--json") and idx + 1 < args.len) {
            idx += 1;
            json_out = args[idx];
        } else if (std.mem.eql(u8, arg, "--fail-on-new") and idx + 1 < args.len) {
            idx += 1;
            fail_baseline = args[idx];
        } else if (std.mem.eql(u8, arg, "--write-baseline") and idx + 1 < args.len) {
            idx += 1;
            write_baseline = args[idx];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\usage: zig build s101-coverage [-- FLAGS]
                \\  --json PATH            write the full machine-readable report
                \\  --write-baseline PATH  write the current (c) list as a baseline
                \\  --fail-on-new PATH     exit 1 if the (c) list has attrs not in baseline
                \\
            , .{});
            return;
        }
    }

    // ---- catalogue: attribute universe + S-57-sourceable set ----
    const cat = try readJson(io, a, CATALOGUE);
    const s57 = try readJson(io, a, S57CODES);

    // Per-class permitted enum values the adapter enforces (filterPermitted): a
    // "Class.attr" here means an off-list value is dropped before portrayal, so the
    // S-65 "restricted allowable value" concern for that slot is handled — retire it.
    const permitted = readJson(io, a, PERMITTED) catch std.json.Value{ .null = {} };
    var enforced = StrSet.init(a);
    if (permitted == .object) {
        for (permitted.object.keys()) |cls| {
            const av = permitted.object.get(cls).?;
            if (av != .object) continue;
            for (av.object.keys()) |attr|
                try enforced.put(try std.fmt.allocPrint(a, "{s}.{s}", .{ cls, attr }), {});
        }
    }

    var s57_acr = StrSet.init(a); // acronyms of real S-57 attributes
    if (s57.object.get("attr")) |av| if (av == .object) {
        var it = av.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try s57_acr.put(e.value_ptr.string, {});
    };

    var universe = StrSet.init(a);
    var sourceable = StrSet.init(a);
    var attr_acrs = std.StringHashMap([]const []const u8).init(a); // S-101 attr -> its S-57 acronyms
    for ([_][]const u8{ "simpleAttrs", "complexAttrs" }) |group| {
        const gv = cat.object.get(group) orelse continue;
        if (gv != .object) continue;
        for (gv.object.keys()) |name| {
            try universe.put(name, {});
            const meta = gv.object.get(name).?;
            if (meta == .object) if (meta.object.get("alias")) |al| if (al == .array) {
                var acrs = StrList.empty;
                for (al.array.items) |x| if (x == .string) {
                    try acrs.append(a, x.string);
                    if (s57_acr.contains(x.string)) try sourceable.put(name, {});
                };
                try attr_acrs.put(name, acrs.items);
            };
        }
    }

    var ftypes = StrSet.init(a); // real feature-class codes
    var class_objs = std.StringHashMap([]const []const u8).init(a); // S-101 class -> its S-57 objects
    if (cat.object.get("featureTypes")) |ftv| if (ftv == .object) {
        for (ftv.object.keys()) |k| {
            try ftypes.put(k, {});
            const e = ftv.object.get(k).?;
            if (e == .object) if (e.object.get("alias")) |al| if (al == .array) {
                var objs = StrList.empty;
                for (al.array.items) |x| if (x == .string) try objs.append(a, x.string);
                try class_objs.put(k, objs.items);
            };
        }
    };

    var synth = StrSet.init(a);
    for (ADAPTER_SYNTHESIZED) |s| try synth.put(s, {});

    // ---- scan the Lua rules into a module graph ----
    var mods = std.StringHashMap(Module).init(a);
    var dir = try std.Io.Dir.cwd().openDir(io, RULES_DIR, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".lua")) continue;
        const path = try a.dupe(u8, entry.path);
        const text = dir.readFileAlloc(io, path, a, .unlimited) catch continue;
        const stem = try a.dupe(u8, std.fs.path.stem(std.fs.path.basename(path)));
        var m = Module{ .reads = StrSet.init(a), .reqs = StrList.empty };
        try scanReads(a, text, &m.reads);
        try scanReqs(a, text, &m.reqs);
        try mods.put(stem, m);
    }

    // ---- per feature-class rule: closure ∩ universe, then classify ----
    var class_names = StrList.empty;
    {
        var it = mods.keyIterator();
        while (it.next()) |k| if (ftypes.contains(k.*)) try class_names.append(a, k.*);
    }
    std.mem.sort([]const u8, class_names.items, {}, lessStr);

    var c_map = std.StringHashMap(StrList).init(a); // (c) attr -> classes reading it
    var per_class = std.ArrayList([]AttrCat).empty; // aligned with class_names.items (Task 2 table)
    var at_risk = std.ArrayList(RiskEntry).empty; // (a)/(b) slots whose VALUE needs S-65 work
    var n_slots: usize = 0;
    var na: usize = 0;
    var nb: usize = 0;
    var nc: usize = 0;
    for (class_names.items) |cls| {
        var seen = StrSet.init(a);
        var consumed = StrSet.init(a);
        try addClosure(&mods, cls, &seen, &consumed);
        var row = std.ArrayList(AttrCat).empty;
        var it = consumed.keyIterator();
        while (it.next()) |k| {
            const attr = k.*;
            if (!universe.contains(attr)) continue; // drop framework pseudo-props
            n_slots += 1;
            var catg: []const u8 = undefined;
            if (sourceable.contains(attr)) {
                na += 1;
                catg = "a-sourced";
            } else if (synth.contains(attr)) {
                nb += 1;
                catg = "b-defaulted";
            } else {
                nc += 1;
                catg = "c-neither";
                const gop = try c_map.getOrPut(attr);
                if (!gop.found_existing) gop.value_ptr.* = StrList.empty;
                try gop.value_ptr.append(a, cls);
            }
            try row.append(a, .{ .name = attr, .cat = catg });

            // Correctness axis: the adapter supplies this ((a) or (b)), but does the
            // raw S-57 value survive S-65 conversion? Skip (c) — a missing attr has no value.
            if (!std.mem.eql(u8, catg, "c-neither")) {
                const acrs = attr_acrs.get(attr) orelse NO_STRS;
                const objs = class_objs.get(cls) orelse NO_STRS;
                var rk: ?[]const u8 = null;
                var rn: []const u8 = "";
                for (DROP) |d| if (listHas(acrs, d.acr) and listHas(objs, d.obj)) {
                    if (d.enforced) continue; // adapter drops it write-side; never reaches the rule
                    rk = "drop";
                    rn = try std.fmt.allocPrint(a, "{s} prohibited on {s} (S-65 will-not-convert); adapter forwards it", .{ d.acr, cls });
                    break;
                };
                if (rk == null) for (VALUE_REMAP) |v| if (listHas(acrs, v.acr) and !listHas(&VALUE_REMAP_DONE, v.acr)) {
                    rk = "remap";
                    rn = v.note;
                    break;
                };
                // The adapter enforces the FC per-class permitted list (filterPermitted),
                // so a slot it covers is no longer at risk — skip the S-65 restricted flag.
                const slot_key = try std.fmt.allocPrint(a, "{s}.{s}", .{ cls, attr });
                if (rk == null and !enforced.contains(slot_key)) restr: for (RESTRICTED) |r| {
                    if (!listHas(acrs, r.acr)) continue;
                    for (r.objs) |o| if (listHas(objs, o)) {
                        rk = "restricted";
                        rn = try std.fmt.allocPrint(a, "{s} allowable-value list restricted for {s} (S-65 Table A-2)", .{ r.acr, cls });
                        break :restr;
                    };
                };
                if (rk) |kind| try at_risk.append(a, .{ .class = cls, .attr = attr, .kind = kind, .note = rn });
            }
        }
        std.mem.sort(AttrCat, row.items, {}, lessAttrCat);
        try per_class.append(a, row.items);
    }

    // ---- tally the (a)/(b) at-risk slots ----
    std.mem.sort(RiskEntry, at_risk.items, {}, lessRisk);
    var nd: usize = 0;
    var nr: usize = 0;
    var nx: usize = 0;
    for (at_risk.items) |e| {
        if (std.mem.eql(u8, e.kind, "drop")) nd += 1 else if (std.mem.eql(u8, e.kind, "remap")) nr += 1 else nx += 1;
    }

    // ---- sort the (c) list by (count desc, name asc) ----
    var c_entries = std.ArrayList(CEntry).empty;
    {
        var it = c_map.iterator();
        while (it.next()) |e| {
            std.mem.sort([]const u8, e.value_ptr.items, {}, lessStr);
            try c_entries.append(a, .{ .name = e.key_ptr.*, .classes = e.value_ptr.items });
        }
    }
    std.mem.sort(CEntry, c_entries.items, {}, lessC);

    // ---- human report ----
    std.debug.print("S-101 portrayal attribute coverage  ({d} feature-class rules scanned)\n", .{class_names.items.len});
    std.debug.print("  consumed attr-slots: {d}   (a) sourced: {d}   (b) defaulted: {d}   (c) NEITHER: {d}\n", .{ n_slots, na, nb, nc });
    std.debug.print("  distinct (c) attributes: {d}   at-risk (a)/(b) values: {d} ({d} drop, {d} remap, {d} restricted)\n\n", .{ c_entries.items.len, at_risk.items.len, nd, nr, nx });
    std.debug.print("== (c) LIST — portrayal-consumed, adapter neither sources nor defaults ==\n", .{});
    std.debug.print("   (each is a latent silent-default render bug)\n\n", .{});
    for (c_entries.items) |ce| {
        std.debug.print("  {s:<38} read by {d:>3} class(es): ", .{ ce.name, ce.classes.len });
        const shown = @min(ce.classes.len, 6);
        for (ce.classes[0..shown], 0..) |cl, k| std.debug.print("{s}{s}", .{ if (k == 0) "" else ", ", cl });
        if (ce.classes.len > shown) std.debug.print(", +{d} more", .{ce.classes.len - shown});
        std.debug.print("\n", .{});
    }

    std.debug.print("\n== (a)/(b) AT-RISK — supplied, but the raw S-57 VALUE needs S-65 conversion ==\n", .{});
    std.debug.print("   (coverage shows these covered; the forwarded value may be invalid/remapped in S-101)\n\n", .{});
    for (at_risk.items) |e| {
        const label = try std.fmt.allocPrint(a, "{s}.{s}", .{ e.class, e.attr });
        std.debug.print("  [{s:<10}] {s:<56} {s}\n", .{ e.kind, label, e.note });
    }

    // ---- optional JSON report (keys are identifiers, so no escaping needed) ----
    if (json_out) |path| {
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(a, "{\n  \"summary\": {");
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "\"classes\":{d},\"consumed_slots\":{d},\"a_sourced\":{d},\"b_defaulted\":{d},\"c_neither\":{d},\"distinct_c\":{d},\"at_risk\":{d},\"at_risk_drop\":{d},\"at_risk_remap\":{d},\"at_risk_restricted\":{d}", .{ class_names.items.len, n_slots, na, nb, nc, c_entries.items.len, at_risk.items.len, nd, nr, nx }));
        try buf.appendSlice(a, "},\n  \"c_list\": {\n");
        for (c_entries.items, 0..) |ce, ci| {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "    \"{s}\": [", .{ce.name}));
            for (ce.classes, 0..) |cl, k| try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}\"{s}\"", .{ if (k == 0) "" else ", ", cl }));
            try buf.appendSlice(a, if (ci + 1 < c_entries.items.len) "],\n" else "]\n");
        }
        try buf.appendSlice(a, "  },\n  \"per_class\": {\n"); // Task 2: feature class -> {attr: category}
        for (class_names.items, 0..) |cls, ki| {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "    \"{s}\": {{", .{cls}));
            for (per_class.items[ki], 0..) |ac, k| try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}\"{s}\":\"{s}\"", .{ if (k == 0) "" else ", ", ac.name, ac.cat }));
            try buf.appendSlice(a, if (ki + 1 < class_names.items.len) "},\n" else "}\n");
        }
        try buf.appendSlice(a, "  },\n  \"at_risk\": [\n"); // correctness axis: supplied but value needs S-65 work
        for (at_risk.items, 0..) |e, ri| {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "    {{\"class\":\"{s}\",\"attr\":\"{s}\",\"kind\":\"{s}\",\"note\":\"{s}\"}}{s}\n", .{ e.class, e.attr, e.kind, try jesc(a, e.note), if (ri + 1 < at_risk.items.len) "," else "" }));
        }
        try buf.appendSlice(a, "  ]\n}\n");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
        std.debug.print("\nwrote {s}\n", .{path});
    }

    // ---- baseline write / CI gate ----
    if (write_baseline) |path| {
        var cnames = StrList.empty;
        for (c_entries.items) |ce| try cnames.append(a, ce.name);
        std.mem.sort([]const u8, cnames.items, {}, lessStr);
        var rkeys = StrList.empty; // "Class.attr" keys for at-risk slots
        for (at_risk.items) |e| try rkeys.append(a, try std.fmt.allocPrint(a, "{s}.{s}", .{ e.class, e.attr }));
        std.mem.sort([]const u8, rkeys.items, {}, lessStr);
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(a, "{\n  \"c_list\": [");
        for (cnames.items, 0..) |nm, k| try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}\"{s}\"", .{ if (k == 0) "" else ", ", nm }));
        try buf.appendSlice(a, "],\n  \"at_risk\": [");
        for (rkeys.items, 0..) |nm, k| try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}\"{s}\"", .{ if (k == 0) "" else ", ", nm }));
        try buf.appendSlice(a, "]\n}\n");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
        std.debug.print("wrote baseline {s} ({d} c_list, {d} at_risk)\n", .{ path, cnames.items.len, rkeys.items.len });
        return;
    }
    if (fail_baseline) |path| {
        const base = try readJson(io, a, path);
        var known_c = StrSet.init(a);
        var known_r = StrSet.init(a);
        if (base == .object) {
            if (base.object.get("c_list")) |cv| if (cv == .array) for (cv.array.items) |x| if (x == .string) try known_c.put(x.string, {});
            if (base.object.get("at_risk")) |rv| if (rv == .array) for (rv.array.items) |x| if (x == .string) try known_r.put(x.string, {});
        }
        var new_c = StrList.empty;
        for (c_entries.items) |ce| if (!known_c.contains(ce.name)) try new_c.append(a, ce.name);
        var new_r = StrList.empty;
        for (at_risk.items) |e| {
            const key = try std.fmt.allocPrint(a, "{s}.{s}", .{ e.class, e.attr });
            if (!known_r.contains(key)) try new_r.append(a, key);
        }
        std.mem.sort([]const u8, new_c.items, {}, lessStr);
        std.mem.sort([]const u8, new_r.items, {}, lessStr);
        if (new_c.items.len > 0 or new_r.items.len > 0) {
            if (new_c.items.len > 0) {
                std.debug.print("\nFAIL: {d} new (c) attribute(s):", .{new_c.items.len});
                for (new_c.items) |nm| std.debug.print(" {s}", .{nm});
                std.debug.print("\n", .{});
            }
            if (new_r.items.len > 0) {
                std.debug.print("FAIL: {d} new at-risk (a)/(b) slot(s):", .{new_r.items.len});
                for (new_r.items) |nm| std.debug.print(" {s}", .{nm});
                std.debug.print("\n", .{});
            }
            std.process.exit(1);
        }
        std.debug.print("\nOK: no new (c) or at-risk slots vs baseline\n", .{});
    }
}
