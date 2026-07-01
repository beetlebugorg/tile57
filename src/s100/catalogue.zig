//! S-101 Feature Catalogue loader. The compact, committed catalogue.json
//! (vendor/s101/catalogue.json; distilled from the vendored FeatureCatalogue.xml)
//! is embedded and parsed once; C-ABI accessors (tgc_*) let lua_shim.c build the Lua tables
//! the Host*TypeInfo/TypeCodes callbacks return, and resolve S-57 aliases ->
//! S-101 codes for the adaptation.

const std = @import("std");

// Provided via build.zig addAnonymousImport (the file lives under vendor/,
// outside the module's src/ root, so it can't be embedded by relative path).
const json_bytes = @embedFile("catalogue_json");
const s57codes_bytes = @embedFile("s57codes_json"); // {obj:{code:acronym}, attr:{code:acronym}}
// Per-feature-class permitted enumerate values, distilled from the FeatureCatalogue
// attributeBinding <permittedValues> (S-65 Table A-2 "restricted allowable values").
// {className: {attrName: [values]}}; a present list means the adapter drops S-57
// values off it before portrayal.
const permitted_bytes = @embedFile("permitted_json");

pub const Binding = struct { ref: []const u8, lower: i32, upper: i32 };

const Catalogue = struct {
    parsed: std.json.Parsed(std.json.Value),
    codes_parsed: ?std.json.Parsed(std.json.Value) = null,
    feature_codes: [][]const u8,
    simple_codes: [][]const u8,
    complex_codes: [][]const u8,
    info_codes: [][]const u8,
    feature_bindings: std.StringHashMap([]Binding),
    complex_bindings: std.StringHashMap([]Binding),
    info_bindings: std.StringHashMap([]Binding),
    simple_valuetype: std.StringHashMap([]const u8),
    feature_alias: std.StringHashMap([]const u8), // UPPER(S-57 acronym) -> S-101 code
    attr_alias: std.StringHashMap([]const u8),
    obj_acronym: std.AutoHashMap(u16, []const u8), // S-57 OBJL -> acronym
    attr_acronym: std.AutoHashMap(u16, []const u8), // S-57 ATTL -> acronym
    permitted_parsed: ?std.json.Parsed(std.json.Value) = null,
    permitted: std.StringHashMap(std.StringHashMap([]const i64)), // class -> attr -> permitted enum values
};

var g_cat: ?Catalogue = null;

fn upper(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

fn parseBindings(a: std.mem.Allocator, v: std.json.Value) []Binding {
    const arr = switch (v) {
        .array => |x| x,
        else => return &.{},
    };
    var list = std.ArrayList(Binding).empty;
    for (arr.items) |item| {
        const t = switch (item) {
            .array => |x| x,
            else => continue,
        };
        if (t.items.len < 3) continue;
        const ref = switch (t.items[0]) {
            .string => |s| s,
            else => continue,
        };
        const lo: i32 = switch (t.items[1]) {
            .integer => |n| @intCast(n),
            else => 0,
        };
        const up: i32 = switch (t.items[2]) {
            .integer => |n| @intCast(n),
            else => 1,
        };
        list.append(a, .{ .ref = ref, .lower = lo, .upper = up }) catch {};
    }
    return list.items;
}

/// Parse + cache the embedded catalogue now (idempotent). Call once before using
/// the tgc_*/resolve* accessors from multiple threads: the lazy load itself isn't
/// thread-safe, but once warmed the cached tables are read-only.
pub fn warmUp() void {
    ensureLoaded();
}

fn ensureLoaded() void {
    if (g_cat != null) return;
    const a = std.heap.page_allocator; // process-lifetime
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_bytes, .{}) catch return;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    var cat = Catalogue{
        .parsed = parsed,
        .feature_codes = &.{},
        .simple_codes = &.{},
        .complex_codes = &.{},
        .info_codes = &.{},
        .feature_bindings = std.StringHashMap([]Binding).init(a),
        .complex_bindings = std.StringHashMap([]Binding).init(a),
        .info_bindings = std.StringHashMap([]Binding).init(a),
        .simple_valuetype = std.StringHashMap([]const u8).init(a),
        .feature_alias = std.StringHashMap([]const u8).init(a),
        .attr_alias = std.StringHashMap([]const u8).init(a),
        .obj_acronym = std.AutoHashMap(u16, []const u8).init(a),
        .attr_acronym = std.AutoHashMap(u16, []const u8).init(a),
        .permitted = std.StringHashMap(std.StringHashMap([]const i64)).init(a),
    };

    // featureTypes
    if (root.get("featureTypes")) |ftv| if (ftv == .object) {
        const ft = ftv.object;
        var codes = std.ArrayList([]const u8).empty;
        for (ft.keys()) |code| {
            const entry = ft.get(code).?.object;
            codes.append(a, code) catch {};
            cat.feature_bindings.put(code, parseBindings(a, entry.get("bindings") orelse .null)) catch {};
            if (entry.get("alias")) |al| if (al == .array) for (al.array.items) |av| {
                if (av == .string) cat.feature_alias.put(upper(a, av.string), code) catch {};
            };
        }
        cat.feature_codes = codes.items;
    };
    // simpleAttrs
    if (root.get("simpleAttrs")) |sav| if (sav == .object) {
        const sa = sav.object;
        var codes = std.ArrayList([]const u8).empty;
        for (sa.keys()) |code| {
            const entry = sa.get(code).?.object;
            codes.append(a, code) catch {};
            if (entry.get("valueType")) |vt| if (vt == .string) cat.simple_valuetype.put(code, vt.string) catch {};
            if (entry.get("alias")) |al| if (al == .array) for (al.array.items) |av| {
                if (av == .string) cat.attr_alias.put(upper(a, av.string), code) catch {};
            };
        }
        cat.simple_codes = codes.items;
    };
    // complexAttrs
    if (root.get("complexAttrs")) |cav| if (cav == .object) {
        const ca = cav.object;
        var codes = std.ArrayList([]const u8).empty;
        for (ca.keys()) |code| {
            const entry = ca.get(code).?.object;
            codes.append(a, code) catch {};
            cat.complex_bindings.put(code, parseBindings(a, entry.get("bindings") orelse .null)) catch {};
            if (entry.get("alias")) |al| if (al == .array) for (al.array.items) |av| {
                if (av == .string) cat.attr_alias.put(upper(a, av.string), code) catch {};
            };
        }
        cat.complex_codes = codes.items;
    };
    // informationTypes (SpatialQuality etc.) — served to the Lua framework so
    // spatial-quality information associations resolve (S-65 §2.2.3, Gap D).
    if (root.get("informationTypes")) |itv| if (itv == .object) {
        const it = itv.object;
        var codes = std.ArrayList([]const u8).empty;
        for (it.keys()) |code| {
            const entry = it.get(code).?.object;
            codes.append(a, code) catch {};
            cat.info_bindings.put(code, parseBindings(a, entry.get("bindings") orelse .null)) catch {};
        }
        cat.info_codes = codes.items;
    };

    // S-57 numeric code -> acronym tables.
    if (std.json.parseFromSlice(std.json.Value, a, s57codes_bytes, .{})) |cp| {
        cat.codes_parsed = cp;
        if (cp.value == .object) {
            const co = cp.value.object;
            if (co.get("obj")) |ov| if (ov == .object) {
                for (ov.object.keys()) |k| {
                    const code = std.fmt.parseInt(u16, k, 10) catch continue;
                    if (ov.object.get(k).? == .string)
                        cat.obj_acronym.put(code, ov.object.get(k).?.string) catch {};
                }
            };
            if (co.get("attr")) |av| if (av == .object) {
                for (av.object.keys()) |k| {
                    const code = std.fmt.parseInt(u16, k, 10) catch continue;
                    if (av.object.get(k).? == .string)
                        cat.attr_acronym.put(code, av.object.get(k).?.string) catch {};
                }
            };
        }
    } else |_| {}

    // Per-class permitted enumerate values: {class:{attr:[ints]}}.
    if (std.json.parseFromSlice(std.json.Value, a, permitted_bytes, .{})) |pp| {
        cat.permitted_parsed = pp;
        if (pp.value == .object) {
            for (pp.value.object.keys()) |cls| {
                const av = pp.value.object.get(cls).?;
                if (av != .object) continue;
                var attrs = std.StringHashMap([]const i64).init(a);
                for (av.object.keys()) |attr| {
                    const arr = av.object.get(attr).?;
                    if (arr != .array) continue;
                    var vals = std.ArrayList(i64).empty;
                    for (arr.array.items) |x| if (x == .integer) vals.append(a, x.integer) catch {};
                    attrs.put(attr, vals.items) catch {};
                }
                cat.permitted.put(cls, attrs) catch {};
            }
        }
    } else |_| {}

    g_cat = cat;
}

/// The S-101 permitted enumerate values for `attr` on feature class `class`
/// (FeatureCatalogue attributeBinding <permittedValues>), or null when the binding
/// places no restriction. A forwarded S-57 value outside this list "will not
/// convert" (S-65 Table A-2) and the adapter drops it.
pub fn permittedValues(class: []const u8, attr: []const u8) ?[]const i64 {
    ensureLoaded();
    const c = &(g_cat orelse return null);
    const attrs = c.permitted.getPtr(class) orelse return null;
    return attrs.get(attr);
}

/// S-57 OBJL (numeric) -> S-101 feature class code, via acronym.
pub fn resolveFeatureByObjl(objl: u16) ?[]const u8 {
    ensureLoaded();
    const c = &(g_cat orelse return null);
    const acr = c.obj_acronym.get(objl) orelse return null;
    return resolveFeature(acr);
}

/// S-57 OBJL (numeric) -> S-57 acronym (e.g. 75 -> "LIGHTS", 308 -> "M_QUAL").
/// Used to tag MVT features with `class` so the client's S-52 portrayal filters
/// (data quality, meta boundaries, light text) can select by object class. The
/// s57codes table omits the meta object classes (M_*, OBJL >= 300), so fall back
/// to a small table of the ones the client filters on.
pub fn acronymByObjl(objl: u16) ?[]const u8 {
    ensureLoaded();
    if (g_cat) |*c| if (c.obj_acronym.get(objl)) |acr| return acr;
    return switch (objl) {
        300 => "M_ACCY",
        301 => "M_HOPA",
        302 => "M_COVR",
        303 => "M_CSCL",
        304 => "M_HDAT",
        305 => "M_NPUB",
        306 => "M_NSYS",
        307 => "M_PROD",
        308 => "M_QUAL",
        309 => "M_SDAT",
        310 => "M_SREL",
        311 => "M_UNIT",
        312 => "M_VDAT",
        else => null,
    };
}

/// S-57 ATTL (numeric) -> S-101 attribute code, via acronym.
pub fn resolveAttrByCode(attl: u16) ?[]const u8 {
    ensureLoaded();
    const c = &(g_cat orelse return null);
    const acr = c.attr_acronym.get(attl) orelse return null;
    return resolveAttr(acr);
}

/// S-57 ATTL (numeric) -> S-57 acronym (e.g. 116 -> "OBJNAM"). Used to resolve a
/// SYMINS TX/TE attribute reference (given by acronym) back to a feature attr code.
pub fn attrAcronym(attl: u16) ?[]const u8 {
    ensureLoaded();
    const c = &(g_cat orelse return null);
    return c.attr_acronym.get(attl);
}

// ---- Zig-side lookups (for s101_adapt) -----------------------------------

pub fn resolveFeature(s57_acronym: []const u8) ?[]const u8 {
    ensureLoaded();
    const c = &(g_cat orelse return null);
    var buf: [64]u8 = undefined;
    if (s57_acronym.len > buf.len) return null;
    for (s57_acronym, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return c.feature_alias.get(buf[0..s57_acronym.len]);
}

pub fn resolveAttr(s57_acronym: []const u8) ?[]const u8 {
    ensureLoaded();
    const c = &(g_cat orelse return null);
    var buf: [64]u8 = undefined;
    if (s57_acronym.len > buf.len) return null;
    for (s57_acronym, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return c.attr_alias.get(buf[0..s57_acronym.len]);
}

pub fn isComplex(code: []const u8) bool {
    ensureLoaded();
    const c = &(g_cat orelse return false);
    return c.complex_bindings.contains(code);
}

/// True when `code` is a feature class in the catalogue (mirrors Go's
/// `e.cat.FeatureTypes[code]` existence check). Every featureType is registered
/// in feature_bindings during load, so membership there is the class set.
pub fn hasFeature(code: []const u8) bool {
    ensureLoaded();
    const c = &(g_cat orelse return false);
    return c.feature_bindings.contains(code);
}

// ---- C-ABI accessors (for lua_shim.c) ------------------------------------

export fn tgc_loaded() callconv(.c) bool {
    ensureLoaded();
    return g_cat != null;
}

export fn tgc_feature_count() callconv(.c) usize {
    ensureLoaded();
    return if (g_cat) |c| c.feature_codes.len else 0;
}
export fn tgc_feature_code(i: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const s = g_cat.?.feature_codes[i];
    out_len.* = s.len;
    return s.ptr;
}
export fn tgc_simple_count() callconv(.c) usize {
    ensureLoaded();
    return if (g_cat) |c| c.simple_codes.len else 0;
}
export fn tgc_simple_code(i: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const s = g_cat.?.simple_codes[i];
    out_len.* = s.len;
    return s.ptr;
}
export fn tgc_complex_count() callconv(.c) usize {
    ensureLoaded();
    return if (g_cat) |c| c.complex_codes.len else 0;
}
export fn tgc_complex_code(i: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const s = g_cat.?.complex_codes[i];
    out_len.* = s.len;
    return s.ptr;
}

export fn tgc_info_count() callconv(.c) usize {
    ensureLoaded();
    return if (g_cat) |c| c.info_codes.len else 0;
}
export fn tgc_info_code(i: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const s = g_cat.?.info_codes[i];
    out_len.* = s.len;
    return s.ptr;
}

fn bindingsOf(map: *std.StringHashMap([]Binding), code: []const u8) []Binding {
    return map.get(code) orelse &.{};
}

export fn tgc_info_binding_count(code_ptr: [*]const u8, code_len: usize) callconv(.c) usize {
    const c = &(g_cat orelse return 0);
    return bindingsOf(&c.info_bindings, code_ptr[0..code_len]).len;
}

export fn tgc_feature_binding_count(code_ptr: [*]const u8, code_len: usize) callconv(.c) usize {
    const c = &(g_cat orelse return 0);
    return bindingsOf(&c.feature_bindings, code_ptr[0..code_len]).len;
}
export fn tgc_complex_binding_count(code_ptr: [*]const u8, code_len: usize) callconv(.c) usize {
    const c = &(g_cat orelse return 0);
    return bindingsOf(&c.complex_bindings, code_ptr[0..code_len]).len;
}

/// Fill ref/lower/upper for binding j of `code`. kind 0=feature, 1=complex, 2=information type.
export fn tgc_binding(kind: u8, code_ptr: [*]const u8, code_len: usize, j: usize, ref_out: *[*]const u8, ref_len: *usize, lower: *i32, upper_out: *i32) callconv(.c) void {
    const c = &(g_cat orelse return);
    const code = code_ptr[0..code_len];
    const b = switch (kind) {
        0 => bindingsOf(&c.feature_bindings, code),
        1 => bindingsOf(&c.complex_bindings, code),
        else => bindingsOf(&c.info_bindings, code),
    };
    if (j >= b.len) return;
    ref_out.* = b[j].ref.ptr;
    ref_len.* = b[j].ref.len;
    lower.* = b[j].lower;
    upper_out.* = b[j].upper;
}

export fn tgc_simple_valuetype(code_ptr: [*]const u8, code_len: usize, out_len: *usize) callconv(.c) [*]const u8 {
    const c = &(g_cat orelse {
        out_len.* = 4;
        return "text";
    });
    const vt = c.simple_valuetype.get(code_ptr[0..code_len]) orelse "text";
    out_len.* = vt.len;
    return vt.ptr;
}

test "catalogue loads + resolves aliases + bindings" {
    try std.testing.expect(tgc_loaded());
    try std.testing.expect(tgc_feature_count() > 100);
    try std.testing.expectEqualStrings("DepthArea", resolveFeature("DEPARE").?);
    try std.testing.expectEqualStrings("depthRangeMinimumValue", resolveAttr("DRVAL1").?);
    try std.testing.expect(isComplex("featureName"));
    // DepthArea binds depthRangeMinimumValue.
    var found = false;
    const c = &g_cat.?;
    for (c.feature_bindings.get("DepthArea").?) |b| {
        if (std.mem.eql(u8, b.ref, "depthRangeMinimumValue")) found = true;
    }
    try std.testing.expect(found);
}

test "permitted enumerate values load from the FC binding lists" {
    // CableArea restricts categoryOfCable to {1,7,10} (S-65 Table A-2).
    const cbl = permittedValues("CableArea", "categoryOfCable").?;
    try std.testing.expectEqualSlices(i64, &.{ 1, 7, 10 }, cbl);
    // UnderwaterAwashRock restricts status to {18} only.
    try std.testing.expectEqualSlices(i64, &.{18}, permittedValues("UnderwaterAwashRock", "status").?);
    // An unrestricted (class, attr) pair returns null (no filtering).
    try std.testing.expect(permittedValues("DepthArea", "depthRangeMinimumValue") == null);
}
