//! Native S-101 (S-100 Part 10a) dataset reader. An S-101 ENC rides on the SAME
//! ISO/IEC 8211 container as S-57 (so `iso8211.zig` is reused verbatim), but the
//! record model is the S-100 General Feature Model — a wholly different schema.
//! This module decodes that schema into typed records; `native.zig` then assembles
//! them into an `s57.Cell` geometry shell plus native `adapter.Adapted` portrayal
//! records, so a native S-101 cell renders through the existing pipeline WITHOUT
//! the S-57 -> S-101 adapter.
//!
//! The decisive property (verified against the SHOM France test cells): an S-101
//! dataset carries its OWN in-band code tables (`FTCS`/`ATCS`/`ITCS`/…) that map the
//! numeric feature/attribute codes used on the wire to the S-101 camelCase class
//! and attribute NAMES — the exact vocabulary the portrayal rules consume. So we
//! read the target names straight from the dataset; no external catalogue lookup is
//! needed to resolve them.
//!
//! Record model (S-100 Part 10a), keyed by the leading field tag of each ISO 8211
//! data record:
//!   DSID/DSSI  dataset id + structure (coord multiplication factors, record counts)
//!   ATCS/…/ARCS  code tables (numeric code <-> S-101 name)
//!   CSID/CRSH  coordinate reference system (WGS84 / EPSG:4326 for ENC)
//!   PRID + C2IT     point         (one lat/lon tuple)
//!   MRID + C3IL     multipoint    (soundings: lat/lon/depth tuples)
//!   CRID + PTAS+C2IL curve        (begin/end node refs + interior vertices)
//!   CCID + CUCO     composite curve (ordered constituent curves w/ orientation)
//!   SRID + RIAS     surface       (bounding curves/composite-curves w/ ORNT+USAG)
//!   FRID + FOID+ATTR+SPAS+FASC+MASK  feature (type code, id, attributes, spatial
//!                    association, feature associations, masking)
//!   IRID + ATTR+INAS  information type (attribute-only meta record)
//!
//! Record-name codes (RCNM/RRNM), used to dispatch spatial associations:
//!   100 feature · 110 point · 115 multipoint · 120 curve · 125 composite curve ·
//!   130 surface · 150 information.
//!
//! Coordinates: signed 32-bit integers, latitude first (YCOO, XCOO[, ZCOO]);
//! degrees = value / CMFx (CMFX/CMFY from DSSI, typically 1e7); depth = ZCOO / CMFZ.

const std = @import("std");
const Allocator = std.mem.Allocator;
const s57 = @import("s57");
const iso = s57.iso8211; // the shared ISO 8211 container reader

const UT: u8 = 0x1f; // subfield (unit) terminator

// --- Record-name codes (RCNM / RRNM) --------------------------------------
pub const RCNM_POINT: u8 = 110;
pub const RCNM_MULTIPOINT: u8 = 115;
pub const RCNM_CURVE: u8 = 120;
pub const RCNM_COMPOSITE: u8 = 125;
pub const RCNM_SURFACE: u8 = 130;
pub const RCNM_FEATURE: u8 = 100;
pub const RCNM_INFO: u8 = 150;

// --- Little-endian binary subfield decoders -------------------------------
// ISO 8211 binary subfields are little-endian (Intel). `b11`=u8, `b12`=u16,
// `b14`=u32, `b24`=i32, `b48`=f64. Out-of-range offsets yield 0 (a truncated
// field is treated as absent rather than crashing the whole cell).
fn u8at(b: []const u8, o: usize) u8 {
    return if (o < b.len) b[o] else 0;
}
fn u16le(b: []const u8, o: usize) u16 {
    if (o + 2 > b.len) return 0;
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn u32le(b: []const u8, o: usize) u32 {
    if (o + 4 > b.len) return 0;
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}
fn i32le(b: []const u8, o: usize) i32 {
    return @bitCast(u32le(b, o));
}
fn f64le(b: []const u8, o: usize) f64 {
    if (o + 8 > b.len) return 0;
    var v: u64 = 0;
    inline for (0..8) |i| v |= @as(u64, b[o + i]) << (8 * i);
    return @bitCast(v);
}

// --- Typed records --------------------------------------------------------

/// DSSI structure parameters. The coordinate multiplication factors scale the
/// integer coordinates to degrees; the counts pre-size the assembly.
pub const Params = struct {
    cmfx: f64 = 1e7, // coordinate multiplication factor, longitude
    cmfy: f64 = 1e7, // coordinate multiplication factor, latitude
    cmfz: f64 = 10, // sounding (Z) multiplication factor
    n_info: u32 = 0,
    n_point: u32 = 0,
    n_multipoint: u32 = 0,
    n_curve: u32 = 0,
    n_composite: u32 = 0,
    n_surface: u32 = 0,
    n_feature: u32 = 0,
};

/// A bidirectional numeric-code <-> S-101-name table (FTCS/ATCS/ITCS/…). Names are
/// borrowed slices into the dataset's ISO 8211 arena (kept alive by `Dataset`).
pub const CodeTable = struct {
    by_code: std.AutoHashMapUnmanaged(u16, []const u8) = .{},

    pub fn name(self: CodeTable, code: u16) ?[]const u8 {
        return self.by_code.get(code);
    }
};

/// One decoded S-100 attribute occurrence (the ATTR field's repeating group).
/// `paix` is the 1-based position, within this same ATTR field, of the parent
/// (complex) attribute this one belongs to — 0 means it is a direct attribute of
/// the feature/information root. `atix` is the sibling-instance index. Complex
/// (container) attributes carry an empty `val` and are referenced as a `paix` by
/// their sub-attributes; simple attributes carry a value.
pub const Attr = struct {
    name: []const u8 = "", // resolved S-101 attribute name (from THIS file's ATCS)
    natc: u16, // numeric attribute code (per the source file's table)
    atix: u16,
    paix: u16,
    atin: u8,
    val: []const u8,
};

/// One SPAS entry: the feature's association to a spatial record. `rrnm` names the
/// spatial record type (point/multipoint/curve/composite/surface); `rrid` its RCID.
pub const SpatialAssoc = struct {
    rrnm: u8,
    rrid: u32,
    ornt: u8, // 1=forward, 2=reverse, 255=null
    usag: u8 = 0, // 1=exterior, 2=interior, 3=truncated by data limit (from RIAS; SPAS carries none)
    mask: u8 = 0, // from the MASK field, joined by rrid
    saui: u8 = 1, // Spatial Association Update Indicator: 1=insert, 2=delete (in a MODIFY update)
};

/// One FASC entry: a feature-to-feature association. `rrid` is the associated
/// FEATURE record's RCID (not an FOID); `narc` the association-role code (ARCS).
pub const FeatureAssoc = struct {
    rrid: u32,
    nfac: u16, // feature-association-class code (FACS)
    narc: u16, // association-role code (ARCS)
};

pub const Foid = struct { agen: u16 = 0, fidn: u32 = 0, fids: u16 = 0 };

// Every record carries its RUIN (update instruction) + RVER (version). A base record
// is RUIN=1 (insert) / RVER=1; an update record's RUIN drives the record-level merge.
pub const FeatureRec = struct {
    rcid: u32,
    class: []const u8 = "", // resolved S-101 feature class (from THIS file's FTCS)
    nftc: u16, // feature type code (per the source file's table)
    ruin: u8 = 1,
    version: u16 = 1,
    foid: Foid = .{},
    attrs: []const Attr = &.{},
    spas: []SpatialAssoc = &.{},
    fasc: []const FeatureAssoc = &.{},
};

pub const PointRec = struct { rcid: u32, lon: f64, lat: f64, ruin: u8 = 1, version: u16 = 1 };
pub const MultiRec = struct { rcid: u32, soundings: []const s57.Sounding, ruin: u8 = 1, version: u16 = 1 };
pub const CurveRec = struct {
    rcid: u32,
    begin_rcid: u32 = 0, // referenced point record RCID (PTAS TOPI=1)
    end_rcid: u32 = 0, // PTAS TOPI=2
    interior: []const s57.LonLat = &.{}, // C2IL vertices between the begin and end nodes
    ruin: u8 = 1,
    version: u16 = 1,
};
pub const CompositeMember = struct { rrid: u32, ornt: u8 };
pub const CompositeRec = struct { rcid: u32, members: []CompositeMember, ruin: u8 = 1, version: u16 = 1 };
pub const RingRef = struct { rrnm: u8, rrid: u32, ornt: u8, usag: u8 };
pub const SurfaceRec = struct { rcid: u32, rings: []RingRef, ruin: u8 = 1, version: u16 = 1 };

pub const InfoRec = struct { rcid: u32, itype: []const u8 = "", nitc: u16, attrs: []const Attr = &.{}, ruin: u8 = 1, version: u16 = 1 };

pub const Dataset = struct {
    // All record bytes (names, values, geometry) are duped into this arena, so the
    // per-file ISO 8211 readers are transient — none is retained. This lets records
    // from several files (a base plus its updates) coexist after their sources close.
    arena: std.heap.ArenaAllocator,
    params: Params = .{},
    feature_codes: CodeTable = .{}, // FTCS (the base file's, for tooling; records carry resolved names)
    attr_codes: CodeTable = .{}, // ATCS
    info_codes: CodeTable = .{}, // ITCS
    assoc_codes: CodeTable = .{}, // ARCS (roles)

    features: []FeatureRec = &.{},
    points: []PointRec = &.{},
    multis: []MultiRec = &.{},
    curves: []CurveRec = &.{},
    composites: []CompositeRec = &.{},
    surfaces: []SurfaceRec = &.{},
    infos: []InfoRec = &.{},

    pub fn deinit(self: *Dataset) void {
        self.arena.deinit();
    }

    // Names resolved at decode time (via the source file's tables) so a merged
    // dataset is consistent even though each file has its OWN numeric code space.
    pub fn featureName(self: Dataset, f: FeatureRec) ?[]const u8 {
        if (f.class.len > 0) return f.class;
        return self.feature_codes.name(f.nftc);
    }
    pub fn attrName(self: Dataset, a: Attr) ?[]const u8 {
        if (a.name.len > 0) return a.name;
        return self.attr_codes.name(a.natc);
    }
};

/// Is `bytes` a native S-101 dataset (rather than an S-57 cell)? Both share the
/// ISO 8211 container, so we discriminate on the DDR field schema: an S-101 DDR
/// defines the in-band code-table fields (`FTCS`, the feature-type code table),
/// which no S-57 DDR ever carries. Cheap — parses only the DDR record.
pub fn detect(bytes: []const u8) bool {
    // The DDR is the first record; its field-control entries are keyed by the real
    // tags. `iso.parse` reads the whole file, but on a non-S-101 file we simply
    // return false and the caller falls through to the S-57 reader. To keep
    // detection cheap we scan the DDR's field-control tags via a throwaway parse of
    // just enough — but `iso` exposes no DDR-only parse, so match on the tag bytes
    // in the DDR directory area instead.
    return ddrHasTag(bytes, "FTCS");
}

/// True when the ISO 8211 DDR (first record) declares a data-descriptive field with
/// tag `tag`. Walks only the first record's directory, so it is O(#DDR fields) and
/// never touches the data records.
fn ddrHasTag(bytes: []const u8, tag: []const u8) bool {
    if (bytes.len < 24) return false;
    const field_area_start = asciiInt(bytes[12..17]) orelse return false;
    if (field_area_start < 24 or field_area_start > bytes.len) return false;
    const size_len = digit(bytes[20]) orelse return false;
    const size_pos = digit(bytes[21]) orelse return false;
    const size_tag = digit(bytes[23]) orelse return false;
    const entry = size_tag + size_len + size_pos;
    var p: usize = 24;
    while (p + entry <= field_area_start) : (p += entry) {
        if (bytes[p] == 0x1e) break; // directory terminator
        if (size_tag == tag.len and std.mem.eql(u8, bytes[p .. p + size_tag], tag)) return true;
    }
    return false;
}

fn asciiInt(b: []const u8) ?usize {
    var v: usize = 0;
    var any = false;
    for (b) |c| {
        if (c == ' ') continue;
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        any = true;
    }
    return if (any) v else 0;
}
fn digit(c: u8) ?u8 {
    return if (c >= '0' and c <= '9') c - '0' else null;
}

/// The header (coordinate factors + code tables) of one ISO 8211 file. Each file —
/// a base cell OR one of its updates — has its OWN numeric code space, so its records
/// resolve their class/attribute NAMES against ITS tables before merging.
const Tables = struct {
    params: Params = .{},
    fc: CodeTable = .{}, // FTCS (feature classes)
    ac: CodeTable = .{}, // ATCS (attributes)
    ic: CodeTable = .{}, // ITCS (information types)
    arc: CodeTable = .{}, // ARCS (association roles)
};

/// A record set being merged by (RCNM, RCID). `Idx(T)` keeps insertion order with a
/// last-wins rcid index; a delete tombstones the slot, `flatten` drops tombstones.
fn Idx(comptime T: type) type {
    return struct {
        const Self = @This();
        list: std.ArrayList(?T) = .empty,
        idx: std.AutoHashMapUnmanaged(u32, usize) = .{},

        fn upsert(self: *Self, a: Allocator, rcid: u32, rec: T) !void {
            if (self.idx.get(rcid)) |i| {
                self.list.items[i] = rec;
            } else {
                try self.list.append(a, rec);
                try self.idx.put(a, rcid, self.list.items.len - 1);
            }
        }
        fn remove(self: *Self, rcid: u32) void {
            if (self.idx.fetchRemove(rcid)) |kv| self.list.items[kv.value] = null;
        }
        fn get(self: *Self, rcid: u32) ?*T {
            const i = self.idx.get(rcid) orelse return null;
            return if (self.list.items[i]) |*r| r else null;
        }
        fn flatten(self: *Self, a: Allocator) ![]T {
            var out = std.ArrayList(T).empty;
            for (self.list.items) |m| if (m) |x| try out.append(a, x);
            return out.items;
        }
    };
}

const Merge = struct {
    features: Idx(FeatureRec) = .{},
    points: Idx(PointRec) = .{},
    multis: Idx(MultiRec) = .{},
    curves: Idx(CurveRec) = .{},
    composites: Idx(CompositeRec) = .{},
    surfaces: Idx(SurfaceRec) = .{},
    infos: Idx(InfoRec) = .{},
};

/// Parse a native S-101 base cell (no updates). Caller must `deinit` the result.
pub fn parse(gpa: Allocator, bytes: []const u8) !Dataset {
    return parseWithUpdates(gpa, bytes, &.{});
}

/// Parse a native S-101 base cell and apply its sequential update files (`.001`,
/// `.002`, … in order), merging records by (RCNM, RCID): RUIN 1=insert, 2=delete,
/// 3=modify (S-100 Part 10a §4a-4.5). Names resolve per file (each carries its own
/// code tables). All kept bytes are duped into the result's arena, so the base and
/// update ISO readers are transient. Pass an empty `updates` for a plain base cell.
pub fn parseWithUpdates(gpa: Allocator, base: []const u8, updates: []const []const u8) !Dataset {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var m: Merge = .{};

    // Lazy: pre-validate each file with the eager parser's acceptance rules
    // (allocation-free), then decode straight out of the bytes — no arena-built
    // record model. Validating up front keeps the eager semantics: a malformed
    // BASE fails the parse, and a corrupt UPDATE is rejected whole (keep prior
    // state) rather than half-applied.
    try iso.validate(base);
    const base_tables = try readHeader(a, base);
    try decodeInto(a, &m, base, base_tables);

    for (updates) |u| {
        iso.validate(u) catch break; // reject a corrupt update; keep prior state
        const t = readHeader(a, u) catch break;
        decodeInto(a, &m, u, t) catch break;
    }

    return .{
        .arena = arena,
        .params = base_tables.params,
        .feature_codes = base_tables.fc,
        .attr_codes = base_tables.ac,
        .info_codes = base_tables.ic,
        .assoc_codes = base_tables.arc,
        .features = try m.features.flatten(a),
        .points = try m.points.flatten(a),
        .multis = try m.multis.flatten(a),
        .curves = try m.curves.flatten(a),
        .composites = try m.composites.flatten(a),
        .surfaces = try m.surfaces.flatten(a),
        .infos = try m.infos.flatten(a),
    };
}

/// Decode one ISO file's data records into the merge set, applying each record's
/// RUIN. A delete needs only the identity; insert/modify decode fully (resolving
/// names via `t`'s tables). Spatial-record modify replaces; feature modify applies
/// the SAUI-indicated spatial-association edits (see `modifyFeature`).
fn decodeInto(a: Allocator, m: *Merge, bytes: []const u8, t: Tables) !void {
    // The caller pre-validated `bytes` (iso.validate), so the tolerant walk
    // sees exactly the records the eager parse built.
    var it = iso.iterate(bytes);
    _ = it.next(); // skip the DDR (its directory declares the same tags)
    while (it.next()) |rec| {
        const lead = rec.firstTag() orelse continue;
        if (std.mem.eql(u8, lead, "PRID")) {
            const p = rec.field("PRID").?;
            const rcid = u32le(p, 1);
            if (u8at(p, 7) == 2) {
                m.points.remove(rcid);
            } else if (rec.field("C2IT")) |c| {
                try m.points.upsert(a, rcid, .{
                    .rcid = rcid,
                    .lat = @as(f64, @floatFromInt(i32le(c, 0))) / t.params.cmfy,
                    .lon = @as(f64, @floatFromInt(i32le(c, 4))) / t.params.cmfx,
                    .ruin = u8at(p, 7),
                    .version = u16le(p, 5),
                });
            }
        } else if (std.mem.eql(u8, lead, "MRID")) {
            const md = rec.field("MRID").?;
            const rcid = u32le(md, 1);
            if (u8at(md, 7) == 2) {
                m.multis.remove(rcid);
            } else {
                const snds = if (rec.field("C3IL")) |c| try parseSoundings(a, c, t.params) else &[_]s57.Sounding{};
                try m.multis.upsert(a, rcid, .{ .rcid = rcid, .soundings = snds, .ruin = u8at(md, 7), .version = u16le(md, 5) });
            }
        } else if (std.mem.eql(u8, lead, "CRID")) {
            const c = rec.field("CRID").?;
            if (u8at(c, 7) == 2) m.curves.remove(u32le(c, 1)) else try m.curves.upsert(a, u32le(c, 1), try parseCurve(a, rec, t.params));
        } else if (std.mem.eql(u8, lead, "CCID")) {
            const c = rec.field("CCID").?;
            if (u8at(c, 7) == 2) m.composites.remove(u32le(c, 1)) else try m.composites.upsert(a, u32le(c, 1), try parseComposite(a, rec));
        } else if (std.mem.eql(u8, lead, "SRID")) {
            const s = rec.field("SRID").?;
            if (u8at(s, 7) == 2) m.surfaces.remove(u32le(s, 1)) else try m.surfaces.upsert(a, u32le(s, 1), try parseSurface(a, rec));
        } else if (std.mem.eql(u8, lead, "FRID")) {
            const f = rec.field("FRID").?;
            const rcid = u32le(f, 1);
            if (u8at(f, 9) == 2) {
                m.features.remove(rcid);
            } else {
                const decoded = try parseFeature(a, rec, t);
                if (decoded.ruin == 3) {
                    if (m.features.get(rcid)) |ex| {
                        try modifyFeature(a, ex, decoded);
                        continue;
                    }
                }
                try m.features.upsert(a, rcid, decoded);
            }
        } else if (std.mem.eql(u8, lead, "IRID")) {
            const ir = rec.field("IRID").?;
            const rcid = u32le(ir, 1);
            if (u8at(ir, 9) == 2) {
                m.infos.remove(rcid);
            } else {
                const nitc = u16le(ir, 5);
                const attrs = if (rec.field("ATTR")) |at| try parseAttrs(a, at, t.ac) else &[_]Attr{};
                try m.infos.upsert(a, rcid, .{
                    .rcid = rcid,
                    .itype = try a.dupe(u8, t.ic.name(nitc) orelse ""),
                    .nitc = nitc,
                    .attrs = attrs,
                    .ruin = u8at(ir, 9),
                    .version = u16le(ir, 7),
                });
            }
        }
        // CSID/CRSH/CSAX/VDAT (CRS) are WGS84/EPSG:4326 for ENC; the whole engine
        // already assumes geographic lon/lat, so nothing to carry.
    }
}

/// Apply a feature MODIFY update to the existing record. Attributes/FASC are replaced
/// when the update carries them (a MODIFY that omits a field leaves it unchanged);
/// spatial associations are edited per-entry by SAUI (2=delete the matching RRID,
/// 1=add), matching the S-164 reference behaviour (e.g. swap a surface for a re-cut one).
fn modifyFeature(a: Allocator, ex: *FeatureRec, upd: FeatureRec) !void {
    if (upd.attrs.len > 0) ex.attrs = upd.attrs;
    if (upd.fasc.len > 0) ex.fasc = upd.fasc;
    if (upd.foid.agen != 0 or upd.foid.fidn != 0 or upd.foid.fids != 0) ex.foid = upd.foid;
    if (upd.spas.len > 0) {
        var spas = std.ArrayList(SpatialAssoc).empty;
        for (ex.spas) |sp| {
            var deleted = false;
            for (upd.spas) |usp| {
                if (usp.saui == 2 and usp.rrnm == sp.rrnm and usp.rrid == sp.rrid) deleted = true;
            }
            if (!deleted) try spas.append(a, sp);
        }
        for (upd.spas) |usp| if (usp.saui != 2) try spas.append(a, usp);
        ex.spas = spas.items;
    }
    ex.version = upd.version;
}

/// Read a file's coordinate factors + code tables from its DSID record (the first
/// data record). Code-table names are duped into `a`, so they outlive the ISO reader.
fn readHeader(a: Allocator, bytes: []const u8) !Tables {
    var t: Tables = .{};
    var it = iso.iterate(bytes);
    _ = it.next(); // skip the DDR (its directory declares a DSID schema entry)
    while (it.next()) |rec| {
        const lead = rec.firstTag() orelse continue;
        if (!std.mem.eql(u8, lead, "DSID")) continue;
        try parseDatasetRecord(a, rec, &t.params, &t.fc, &t.ac, &t.ic, &t.arc);
        break;
    }
    return t;
}

fn parseDatasetRecord(
    a: Allocator,
    rec: iso.RecordView,
    params: *Params,
    feature_codes: *CodeTable,
    attr_codes: *CodeTable,
    info_codes: *CodeTable,
    assoc_codes: *CodeTable,
) !void {
    if (rec.field("DSSI")) |s| {
        // (3b48,10b14): DCOX,DCOY,DCOZ (origin, unused) then CMFX,CMFY,CMFZ then the
        // seven record counts NOIR,NOPN,NOMN,NOCN,NOXN,NOSN,NOFR.
        params.cmfx = @floatFromInt(u32le(s, 24));
        params.cmfy = @floatFromInt(u32le(s, 28));
        params.cmfz = @floatFromInt(u32le(s, 32));
        if (params.cmfx <= 0) params.cmfx = 1e7;
        if (params.cmfy <= 0) params.cmfy = 1e7;
        if (params.cmfz <= 0) params.cmfz = 10;
        params.n_info = u32le(s, 36);
        params.n_point = u32le(s, 40);
        params.n_multipoint = u32le(s, 44);
        params.n_curve = u32le(s, 48);
        params.n_composite = u32le(s, 52);
        params.n_surface = u32le(s, 56);
        params.n_feature = u32le(s, 60);
    }
    if (rec.field("FTCS")) |t| feature_codes.* = try parseCodeTable(a, t);
    if (rec.field("ATCS")) |t| attr_codes.* = try parseCodeTable(a, t);
    if (rec.field("ITCS")) |t| info_codes.* = try parseCodeTable(a, t);
    if (rec.field("ARCS")) |t| assoc_codes.* = try parseCodeTable(a, t);
}

/// A code table field: repeating `(A, b12)` = a UT-terminated name followed by a
/// little-endian u16 code. Builds the code -> name direction (the only one we read).
fn parseCodeTable(a: Allocator, data: []const u8) !CodeTable {
    var t: CodeTable = .{};
    var i: usize = 0;
    while (i < data.len) {
        const ut = std.mem.indexOfScalarPos(u8, data, i, UT) orelse break;
        const code = u16le(data, ut + 1);
        try t.by_code.put(a, code, try a.dupe(u8, data[i..ut])); // dupe: the ISO reader is transient
        i = ut + 3;
    }
    return t;
}

/// ATTR field: repeating `(3b12,b11,A)` = NATC,ATIX,PAIX (u16), ATIN (u8), then a
/// UT-terminated ASCII value. Preserves order (PAIX references the 1-based position).
/// Resolves each NATC to its S-101 name via `ac` and dupes name + value into `a`.
fn parseAttrs(a: Allocator, data: []const u8, ac: CodeTable) ![]const Attr {
    var out = std.ArrayList(Attr).empty;
    var i: usize = 0;
    while (i + 7 <= data.len) {
        const natc = u16le(data, i);
        const atix = u16le(data, i + 2);
        const paix = u16le(data, i + 4);
        const atin = u8at(data, i + 6);
        i += 7;
        const ut = std.mem.indexOfScalarPos(u8, data, i, UT) orelse data.len;
        const val = data[i..ut];
        i = ut + 1;
        try out.append(a, .{
            .name = try a.dupe(u8, ac.name(natc) orelse ""),
            .natc = natc,
            .atix = atix,
            .paix = paix,
            .atin = atin,
            .val = try a.dupe(u8, val),
        });
    }
    return out.items;
}

/// C3IL soundings: a 1-byte leading subfield then repeating `3b24` (YCOO,XCOO,ZCOO).
fn parseSoundings(a: Allocator, data: []const u8, params: Params) ![]const s57.Sounding {
    if (data.len < 1) return &.{};
    const body = data[1..]; // skip the leading b11 subfield
    const n = body.len / 12;
    var out = try a.alloc(s57.Sounding, n);
    for (0..n) |k| {
        const o = k * 12;
        out[k] = s57.Sounding.init(
            @as(f64, @floatFromInt(i32le(body, o + 4))) / params.cmfx, // XCOO -> lon
            @as(f64, @floatFromInt(i32le(body, o))) / params.cmfy, // YCOO -> lat
            @as(f64, @floatFromInt(i32le(body, o + 8))) / params.cmfz, // ZCOO -> depth
        );
    }
    return out;
}

fn parseCurve(a: Allocator, rec: iso.RecordView, params: Params) !CurveRec {
    const c = rec.field("CRID").?;
    var cr: CurveRec = .{ .rcid = u32le(c, 1) };
    // PTAS: repeating `(b11,b14,b11)` = RRNM,RRID,TOPI. TOPI 1=begin node, 2=end.
    if (rec.field("PTAS")) |p| {
        var o: usize = 0;
        while (o + 6 <= p.len) : (o += 6) {
            const rrid = u32le(p, o + 1);
            switch (u8at(p, o + 5)) {
                1 => cr.begin_rcid = rrid,
                2 => cr.end_rcid = rrid,
                else => {},
            }
        }
    }
    // C2IL: repeating `2b24` (YCOO,XCOO) — the interior vertices.
    if (rec.field("C2IL")) |cl| {
        const n = cl.len / 8;
        var pts = try a.alloc(s57.LonLat, n);
        for (0..n) |k| {
            const o = k * 8;
            pts[k] = s57.LonLat.init(
                @as(f64, @floatFromInt(i32le(cl, o + 4))) / params.cmfx,
                @as(f64, @floatFromInt(i32le(cl, o))) / params.cmfy,
            );
        }
        cr.interior = pts;
    }
    return cr;
}

fn parseComposite(a: Allocator, rec: iso.RecordView) !CompositeRec {
    const c = rec.field("CCID").?;
    var members = std.ArrayList(CompositeMember).empty;
    // CUCO: repeating `(b11,b14,b11)` = RRNM(curve),RRID,ORNT.
    if (rec.field("CUCO")) |u| {
        var o: usize = 0;
        while (o + 6 <= u.len) : (o += 6) {
            try members.append(a, .{ .rrid = u32le(u, o + 1), .ornt = u8at(u, o + 5) });
        }
    }
    return .{ .rcid = u32le(c, 1), .members = members.items };
}

fn parseSurface(a: Allocator, rec: iso.RecordView) !SurfaceRec {
    const s = rec.field("SRID").?;
    var rings = std.ArrayList(RingRef).empty;
    // RIAS: repeating `(b11,b14,3b11)` = RRNM,RRID,ORNT,USAG,RAUI.
    if (rec.field("RIAS")) |r| {
        var o: usize = 0;
        while (o + 8 <= r.len) : (o += 8) {
            try rings.append(a, .{
                .rrnm = u8at(r, o),
                .rrid = u32le(r, o + 1),
                .ornt = u8at(r, o + 5),
                .usag = u8at(r, o + 6),
            });
        }
    }
    return .{ .rcid = u32le(s, 1), .rings = rings.items };
}

fn parseFeature(a: Allocator, rec: iso.RecordView, t: Tables) !FeatureRec {
    const f = rec.field("FRID").?;
    const nftc = u16le(f, 5);
    var fr: FeatureRec = .{
        .rcid = u32le(f, 1),
        .class = try a.dupe(u8, t.fc.name(nftc) orelse ""),
        .nftc = nftc,
        .ruin = u8at(f, 9),
        .version = u16le(f, 7),
    };
    if (rec.field("FOID")) |o| {
        fr.foid = .{ .agen = u16le(o, 0), .fidn = u32le(o, 2), .fids = u16le(o, 6) };
    }
    if (rec.field("ATTR")) |at| fr.attrs = try parseAttrs(a, at, t.ac);

    // SPAS: repeating `(b11,b14,b11,2b14,b11)` = RRNM,RRID,ORNT,SMIN,SMAX,SAUI. A
    // feature may carry several (a surface plus a masked line, etc.), and the writer
    // may split them across multiple SPAS fields, so collect every SPAS field. SAUI
    // (last byte) drives association edits in a MODIFY update (see modifyFeature).
    var spas = std.ArrayList(SpatialAssoc).empty;
    var spas_it = rec.fields();
    while (spas_it.next()) |fld| {
        if (!std.mem.eql(u8, fld.tag, "SPAS")) continue;
        var o: usize = 0;
        while (o + 15 <= fld.data.len) : (o += 15) {
            try spas.append(a, .{ .rrnm = u8at(fld.data, o), .rrid = u32le(fld.data, o + 1), .ornt = u8at(fld.data, o + 5), .saui = u8at(fld.data, o + 14) });
        }
    }
    fr.spas = spas.items;

    // MASK: repeating `(b11,b14,2b11)` = RRNM,RRID,MIND,MUIN. Join by rrid onto the
    // matching spatial association so the masking survives into the geometry shell.
    var mask_it = rec.fields();
    while (mask_it.next()) |fld| {
        if (!std.mem.eql(u8, fld.tag, "MASK")) continue;
        var o: usize = 0;
        while (o + 7 <= fld.data.len) : (o += 7) {
            const rrid = u32le(fld.data, o + 1);
            const mind = u8at(fld.data, o + 5); // 1=mask, 2=show, 255=null
            for (fr.spas) |*sp| if (sp.rrid == rrid) {
                sp.mask = mind;
            };
        }
    }

    // FASC: repeating `(b11,b14,2b12,b11)` group head = RRNM,RRID,NFAC,NARC,FAUI
    // (a nested ATTR block may follow per S-100, ignored here — role + target suffice).
    var fasc = std.ArrayList(FeatureAssoc).empty;
    var fasc_it = rec.fields();
    while (fasc_it.next()) |fld| {
        if (!std.mem.eql(u8, fld.tag, "FASC")) continue;
        // Only the fixed head is decoded; if the field packs multiple heads they are
        // 11 bytes each up to the first ATTR sub-structure. Decode the leading head.
        if (fld.data.len >= 11) {
            try fasc.append(a, .{ .rrid = u32le(fld.data, 1), .nfac = u16le(fld.data, 5), .narc = u16le(fld.data, 7) });
        }
    }
    fr.fasc = fasc.items;
    return fr;
}

// -------------------------------------------------------------------------
test "detect distinguishes an S-101 DDR from an S-57 DDR" {
    // Minimal DDR leaders + directories (no data records needed for detect()).
    // Tag size 4, len size 3, pos size 4; field_area_start points past the directory.
    // S-101: a directory that declares FTCS. S-57: one that declares VRID.
    const a = std.testing.allocator;
    inline for (.{ .{ "FTCS", true }, .{ "VRID", false } }) |case| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(a);
        // one directory entry (tag, len=000, pos=0000) + FT
        const dir = case[0] ++ "0000000" ++ "\x1e";
        const field_area_start = 24 + dir.len;
        var leader: [24]u8 = undefined;
        @memset(&leader, ' ');
        _ = std.fmt.bufPrint(leader[0..5], "{d:0>5}", .{field_area_start}) catch unreachable;
        leader[6] = 'L';
        _ = std.fmt.bufPrint(leader[12..17], "{d:0>5}", .{field_area_start}) catch unreachable;
        leader[20] = '3'; // size_of_field_length
        leader[21] = '4'; // size_of_field_position
        leader[23] = '4'; // size_of_field_tag
        try buf.appendSlice(a, &leader);
        try buf.appendSlice(a, dir);
        try std.testing.expectEqual(case[1], detect(buf.items));
    }
}

test "Idx merges records by rcid: upsert / delete / flatten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ix: Idx(PointRec) = .{};
    try ix.upsert(a, 10, .{ .rcid = 10, .lon = 0, .lat = 0 });
    try ix.upsert(a, 11, .{ .rcid = 11, .lon = 1, .lat = 1 });
    try ix.upsert(a, 12, .{ .rcid = 12, .lon = 2, .lat = 2 });
    ix.remove(11); // delete 11
    try ix.upsert(a, 10, .{ .rcid = 10, .lon = 9, .lat = 9 }); // modify-in-place 10
    const out = try ix.flatten(a);
    try std.testing.expectEqual(@as(usize, 2), out.len); // 11 tombstoned
    try std.testing.expectEqual(@as(u32, 10), out[0].rcid);
    try std.testing.expectEqual(@as(f64, 9), out[0].lon); // replaced value
    try std.testing.expectEqual(@as(u32, 12), out[1].rcid);
}

test "modifyFeature applies SAUI spatial-association edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ex: FeatureRec = .{
        .rcid = 1,
        .nftc = 0,
        .spas = try a.dupe(SpatialAssoc, &.{
            .{ .rrnm = 130, .rrid = 10, .ornt = 1 },
            .{ .rrnm = 130, .rrid = 11, .ornt = 1 },
        }),
    };
    // A MODIFY that removes the association to surface 11 and adds surface 12.
    const upd: FeatureRec = .{
        .rcid = 1,
        .nftc = 0,
        .version = 2,
        .spas = try a.dupe(SpatialAssoc, &.{
            .{ .rrnm = 130, .rrid = 11, .ornt = 1, .saui = 2 }, // delete
            .{ .rrnm = 130, .rrid = 12, .ornt = 1, .saui = 1 }, // insert
        }),
    };
    try modifyFeature(a, &ex, upd);
    try std.testing.expectEqual(@as(usize, 2), ex.spas.len);
    try std.testing.expectEqual(@as(u32, 10), ex.spas[0].rrid); // kept
    try std.testing.expectEqual(@as(u32, 12), ex.spas[1].rrid); // inserted (11 removed)
    try std.testing.expectEqual(@as(u16, 2), ex.version);
}
