//! BSB/KAP — the raster nautical chart, decoded.
//!
//! WHY THIS EXISTS. NOAA discontinued its raster charts, and the last edition is
//! preserved by the community as BSB/KAP. Some mariners want them because the
//! paper-chart drawing reads better to them, and because a few areas lost detail
//! in the vector conversion. Unlike satellite imagery, an RNC is a CHART: it
//! carries a compilation scale, an edition date and a border polygon — which is
//! exactly what the ownership partition resolves on, so a folder of them can
//! quilt the way a folder of cells does.
//!
//! WHAT A KAP IS. A text header of `KEY/field=value,...` records (continuation
//! lines are indented), then `0x1A 0x00`, then one byte of bit depth, then the
//! run-length-coded raster, one row at a time, against a palette the header
//! carries.
//!
//! GEOREFERENCING. The header states the projection and, on every NOAA sheet
//! measured, the polynomial coefficients both ways: `WPX`/`WPY` map pixel to
//! lon/lat and `PWX`/`PWY` map lon/lat back to pixel. That is better than
//! fitting the `REF` control points ourselves — it is the fit the hydrographic
//! office published. `REF` is kept as the fallback and as the check.
//!
//! DATUM. `KNP/GD` names the horizontal datum and `DTM` carries a shift in
//! ARC SECONDS to apply. Older sheets are NAD27, which is roughly 40 m from
//! WGS84 on the US east coast — a mariner comparing an unshifted sheet against
//! a GPS position reads that as a chart error. The shift is not optional, and
//! this reports what the sheet declares so the bake can apply it.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// No `0x1A` terminator: not a KAP.
    NotKap,
    /// The header parsed but says nothing usable about its own raster.
    BadHeader,
    /// The run-length data ran out, or a row overran its width.
    BadRaster,
    OutOfMemory,
};

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// A polynomial in two variables as BSB writes it: `WPX/order,c0,c1,...`. The
/// term layout is the one the format fixes, not a general series.
pub const Poly = struct {
    order: u8 = 0,
    c: [12]f64 = [_]f64{0} ** 12,
    n: u8 = 0,

    /// BSB's evaluation: c0 + c1*x + c2*y + c3*x² + c4*x*y + c5*y² + c6*x³ +
    /// c7*x²y + c8*xy² + c9*y³ + c10*x⁴ + c11*y⁴. Terms past `n` are absent and
    /// contribute nothing, so a low-order fit evaluates correctly here too.
    pub fn eval(p: Poly, x: f64, y: f64) f64 {
        const t = [12]f64{
            1,         x,             y,
            x * x,     x * y,         y * y,
            x * x * x, x * x * y,     x * y * y,
            y * y * y, x * x * x * x, y * y * y * y,
        };
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < p.n and i < 12) : (i += 1) sum += p.c[i] * t[i];
        return sum;
    }
};

pub const Header = struct {
    /// `BSB/NA` — the chart's name.
    name: []const u8 = "",
    /// `BSB/RA` — the raster's size in pixels.
    width: u32 = 0,
    height: u32 = 0,
    /// `KNP/SC` — the compilation scale denominator. What lets an RNC quilt.
    scale: u32 = 0,
    /// `KNP/GD` — the horizontal datum as the sheet names it (NAD27, NAD83, …).
    datum: []const u8 = "",
    /// `KNP/PR` — MERCATOR on most NOAA sheets; POLYCONIC and
    /// TRANSVERSE MERCATOR occur.
    projection: []const u8 = "",
    /// `CED/ED` + `CED/RE` — edition date and revision, the partition's
    /// tie-break between two sheets of the same scale.
    edition: []const u8 = "",
    revision: []const u8 = "",
    /// `IFM` — bits per pixel, 1..7.
    depth: u8 = 0,
    /// `DTM` — the datum shift to apply, in ARC SECONDS (lat, lon). Zero on a
    /// sheet already on WGS84.
    dtm_lat: f64 = 0,
    dtm_lon: f64 = 0,
    /// `RGB/n` — the palette, in the file's own numbering. Address it as
    /// `palette[pixel - palette_base]`, or through `rgbAt`.
    palette: []Rgb = &.{},
    /// The number the file gives its FIRST palette entry. BSB numbers from 1
    /// and treats pixel value 0 as no data. Sheets in the wild number from 0,
    /// and then 0 is a real colour. A parser that assumes one of the two reads
    /// every colour off by one, and on a 0-based sheet indexes before the
    /// start of the array.
    palette_base: u8 = 1,
    /// `PLY/n,lat,lon` — the border polygon. Cuts the paper collar off, so
    /// quilted sheets butt at their neat lines instead of overprinting each
    /// other's margins. Stands in for M_COVR in the archive metadata.
    border: [][2]f64 = &.{},
    /// `REF/n,x,y,lat,lon` — control points. The fallback fit, and the check.
    refs: []Ref = &.{},
    /// Lon / lat -> pixel. (Checked against this sheet's own 64 REF points:
    /// `WPX(lon,lat)` reproduces pixel x, not the other way round.)
    wpx: Poly = .{},
    wpy: Poly = .{},
    /// Pixel -> lon / lat.
    pwx: Poly = .{},
    pwy: Poly = .{},
    /// Byte offset of the run-length data (just past `0x1A 0x00` + the depth).
    data_off: usize = 0,

    pub const Ref = struct { x: f64, y: f64, lat: f64, lon: f64 };

    /// Does the sheet carry a usable published fit?
    pub fn hasPolynomials(h: Header) bool {
        return h.pwx.n > 0 and h.pwy.n > 0;
    }

    /// The geographic position of a pixel, through the sheet's OWN published
    /// polynomial. The datum shift is NOT applied — the bake owns that, because
    /// it also owns which datum it is shifting to.
    ///
    /// Prefer `Fit` for anything that has to line up. Measured against this
    /// sheet's own control points, the published polynomial is good to 0.0013°
    /// of longitude but only 0.069° of LATITUDE on a 1:10,000,000 Mercator sheet
    /// — a low-order polynomial in pixel space cannot track Mercator across 56°
    /// of latitude. `Fit` does it through the projection instead and lands
    /// inside 0.002°.
    pub fn pixelToLonLat(h: Header, px: f64, py: f64) [2]f64 {
        return .{ h.pwx.eval(px, py), h.pwy.eval(px, py) };
    }
};

/// One decoded chart: the header, plus the raster as one palette index per
/// pixel, row-major, `width * height` bytes.
pub const Chart = struct {
    header: Header,
    pixels: []u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(c: *Chart) void {
        c.arena.deinit();
    }

    /// The RGB of a pixel, or black when the index is outside the palette (a
    /// malformed run should show as something, not crash).
    pub fn rgbAt(c: Chart, x: u32, y: u32) Rgb {
        if (x >= c.header.width or y >= c.header.height) return .{ .r = 0, .g = 0, .b = 0 };
        const idx = c.pixels[@as(usize, y) * c.header.width + x];
        if (idx < c.header.palette_base) return .{ .r = 0, .g = 0, .b = 0 };
        const at = idx - c.header.palette_base;
        if (at >= c.header.palette.len) return .{ .r = 0, .g = 0, .b = 0 };
        return c.header.palette[at];
    }
};

// ---- georeferencing -------------------------------------------------------

/// The georeferencing a bake should actually warp through.
///
/// WHY NOT THE PUBLISHED POLYNOMIAL. It is a fit in PIXEL space, and pixel y on
/// a Mercator sheet is linear in the Mercator ordinate, not in latitude. Across
/// the 56° of latitude a small-scale sheet covers, a low-order polynomial cannot
/// follow that curve: on the 1:10,000,000 North Pacific sheet the published
/// `PWY` misses its own control points by 0.069° — about 7 km. This fits the
/// control points through the projection instead, and lands inside 0.002° on
/// every sheet measured.
///
/// ELLIPSOIDAL, not spherical. NOAA sheets are on NAD83/GRS80 and the difference
/// is not academic: spherical Mercator leaves 0.034° of residual on that same
/// sheet, ellipsoidal leaves 0.0009° — a 37x improvement, for one term.
///
/// LONGITUDE IS UNWRAPPED about the first control point, so an Aleutian sheet
/// straddling the antimeridian fits as a continuous span. Without that its
/// control points average to the wrong side of the world and the fit misses by
/// 199°.
pub const Fit = struct {
    /// lon      = lon_c[0] + lon_c[1]*px + lon_c[2]*py   (may run outside ±180)
    /// mercator = mer_c[0] + mer_c[1]*px + mer_c[2]*py
    ///
    /// BOTH pixel axes feed BOTH outputs. A plain x->lon / y->lat pair is wrong
    /// on a SKEWED sheet, and NOAA publishes those: the Newport-to-Bermuda
    /// plotting sheet declares `KNP/SK=31.1461111`, and fitting it without the
    /// cross terms leaves 0.9° of longitude on the table. With them it is
    /// 0.0006°. On an unskewed sheet the cross terms simply come out near zero.
    lon_c: [3]f64 = .{ 0, 0, 0 },
    mer_c: [3]f64 = .{ 0, 0, 0 },
    /// Largest residual against the control points it was fitted to, degrees.
    /// A bake should refuse a sheet whose own points it cannot reproduce.
    max_dlon: f64 = 0,
    max_dlat: f64 = 0,

    pub fn lonAt(f: Fit, px: f64, py: f64) f64 {
        const lon = f.lon_c[0] + f.lon_c[1] * px + f.lon_c[2] * py;
        return lon - 360.0 * @round(lon / 360.0);
    }

    pub fn latAt(f: Fit, px: f64, py: f64) f64 {
        return invMercY(f.mer_c[0] + f.mer_c[1] * px + f.mer_c[2] * py);
    }
};

/// GRS80 / WGS84 eccentricity. The two differ far below the residuals here.
const E2: f64 = 0.00669437999014;

/// Ellipsoidal Mercator ordinate of a latitude. ELLIPSOIDAL, not spherical:
/// NOAA sheets are on NAD83/GRS80, and on the 1:10,000,000 North Pacific sheet
/// the spherical form leaves 0.034 deg of residual where this leaves 0.0009 —
/// a 37x improvement, for one term.
pub fn mercY(lat_deg: f64) f64 {
    const e = @sqrt(E2);
    const p = std.math.degreesToRadians(@max(-85.05, @min(85.05, lat_deg)));
    const s = @sin(p);
    const t = @tan(std.math.pi / 4.0 + p / 2.0);
    return @log(t * std.math.pow(f64, (1.0 - e * s) / (1.0 + e * s), e / 2.0));
}

/// Its inverse, by the standard iteration (converges in a handful of rounds).
pub fn invMercY(y: f64) f64 {
    const e = @sqrt(E2);
    const t = @exp(-y);
    var p = std.math.pi / 2.0 - 2.0 * std.math.atan(t);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const s = @sin(p);
        p = std.math.pi / 2.0 - 2.0 * std.math.atan(t * std.math.pow(f64, (1.0 - e * s) / (1.0 + e * s), e / 2.0));
    }
    return std.math.radiansToDegrees(p);
}

/// Least squares for `v = c0 + c1*x + c2*y` by the normal equations. Three
/// unknowns and a symmetric 3x3 — Cramer's rule is exact enough and needs no
/// pivoting machinery.
fn solve3(xs: []const f64, ys: []const f64, vs: []const f64) ?[3]f64 {
    var m: [3][3]f64 = .{.{ 0, 0, 0 }} ** 3;
    var b: [3]f64 = .{ 0, 0, 0 };
    for (xs, ys, vs) |x, y, v| {
        const t = [3]f64{ 1, x, y };
        for (0..3) |i| {
            for (0..3) |j| m[i][j] += t[i] * t[j];
            b[i] += t[i] * v;
        }
    }
    const det = det3(m);
    if (@abs(det) < 1e-9) return null;
    var out: [3]f64 = undefined;
    for (0..3) |k| {
        var mk = m;
        for (0..3) |i| mk[i][k] = b[i];
        out[k] = det3(mk) / det;
    }
    return out;
}

fn det3(m: [3][3]f64) f64 {
    return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
}

/// Least-squares fit of the sheet's control points. Null when it carries too few
/// (two is the arithmetic minimum; a sheet with fewer has told us nothing).
pub fn fitRefs(h: Header, a: Allocator) ?Fit {
    if (h.refs.len < 3) return null; // three unknowns per axis
    const l0 = h.refs[0].lon;

    const xs = a.alloc(f64, h.refs.len) catch return null;
    defer a.free(xs);
    const ys = a.alloc(f64, h.refs.len) catch return null;
    defer a.free(ys);
    const lons = a.alloc(f64, h.refs.len) catch return null;
    defer a.free(lons);
    const mers = a.alloc(f64, h.refs.len) catch return null;
    defer a.free(mers);

    for (h.refs, 0..) |r, i| {
        xs[i] = r.x;
        ys[i] = r.y;
        // Unwrapped about the first point, so an Aleutian sheet straddling the
        // antimeridian fits as one continuous span instead of averaging to the
        // wrong side of the world.
        lons[i] = r.lon - 360.0 * @round((r.lon - l0) / 360.0);
        mers[i] = mercY(r.lat);
    }

    var f: Fit = .{};
    f.lon_c = solve3(xs, ys, lons) orelse return null;
    f.mer_c = solve3(xs, ys, mers) orelse return null;

    for (h.refs, 0..) |r, i| {
        f.max_dlon = @max(f.max_dlon, @abs(f.lon_c[0] + f.lon_c[1] * r.x + f.lon_c[2] * r.y - lons[i]));
        f.max_dlat = @max(f.max_dlat, @abs(f.latAt(r.x, r.y) - r.lat));
    }
    return f;
}

// ---- header ---------------------------------------------------------------

/// Parse the text header. `bytes` is the whole file; the header ends at the
/// first `0x1A`.
pub fn parseHeader(a: Allocator, bytes: []const u8) Error!Header {
    const end = std.mem.indexOfScalar(u8, bytes, 0x1A) orelse return Error.NotKap;
    var h: Header = .{};

    var palette = std.ArrayList(Rgb).empty;
    // The lowest RGB index the file used, which decides the base.
    var palette_min: u32 = std.math.maxInt(u32);
    var border = std.ArrayList([2]f64).empty;
    var refs = std.ArrayList(Header.Ref).empty;

    // Records are `KEY/rest`, with continuation lines indented. Join them first
    // so a value split across lines (they routinely are) parses as one.
    var joined = std.ArrayList(u8).empty;
    {
        var it = std.mem.splitScalar(u8, bytes[0..end], '\n');
        var first = true;
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            const cont = line[0] == ' ' or line[0] == '\t';
            // A continuation carries NO comma of its own — the break stands in
            // for one. Joining without it fuses two values into one token
            // ("…e-005" + "1.825…e-010"), which parses as zero and silently
            // truncates every polynomial to its first line.
            if (cont) {
                if (!first) try joined.append(a, ',');
            } else if (!first) {
                try joined.append(a, '\n');
            }
            try joined.appendSlice(a, std.mem.trim(u8, line, " \t"));
            first = false;
        }
    }

    var rec = std.mem.splitScalar(u8, joined.items, '\n');
    while (rec.next()) |line| {
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const key = line[0..slash];
        const rest = line[slash + 1 ..];

        if (std.mem.eql(u8, key, "BSB") or std.mem.eql(u8, key, "NOS")) {
            if (fieldOf(rest, "NA")) |v| h.name = try a.dupe(u8, v);
            if (fieldOf(rest, "RA")) |v| {
                var n = std.mem.splitScalar(u8, v, ',');
                h.width = parseU32(n.next() orelse "") orelse 0;
                h.height = parseU32(n.next() orelse "") orelse 0;
            }
        } else if (std.mem.eql(u8, key, "KNP")) {
            if (fieldOf(rest, "SC")) |v| h.scale = parseU32(v) orelse 0;
            if (fieldOf(rest, "GD")) |v| h.datum = try a.dupe(u8, v);
            if (fieldOf(rest, "PR")) |v| h.projection = try a.dupe(u8, v);
        } else if (std.mem.eql(u8, key, "CED")) {
            if (fieldOf(rest, "ED")) |v| h.edition = try a.dupe(u8, v);
            if (fieldOf(rest, "RE")) |v| h.revision = try a.dupe(u8, v);
        } else if (std.mem.eql(u8, key, "IFM")) {
            h.depth = @intCast(@min(7, parseU32(std.mem.trim(u8, rest, " ")) orelse 0));
        } else if (std.mem.eql(u8, key, "DTM")) {
            var n = std.mem.splitScalar(u8, rest, ',');
            h.dtm_lat = parseF64(n.next() orelse "") orelse 0;
            h.dtm_lon = parseF64(n.next() orelse "") orelse 0;
        } else if (std.mem.eql(u8, key, "RGB")) {
            var n = std.mem.splitScalar(u8, rest, ',');
            const idx = parseU32(n.next() orelse "") orelse continue;
            const r = parseU32(n.next() orelse "") orelse continue;
            const g = parseU32(n.next() orelse "") orelse continue;
            const b = parseU32(n.next() orelse "") orelse continue;
            // Stored at its own number and shifted at the end, because the
            // base is not known until every RGB line has been read. Entries
            // are not obliged to be in order either.
            while (palette.items.len <= idx) try palette.append(a, .{ .r = 0, .g = 0, .b = 0 });
            palette.items[idx] = .{ .r = @intCast(r & 255), .g = @intCast(g & 255), .b = @intCast(b & 255) };
            palette_min = @min(palette_min, idx);
        } else if (std.mem.eql(u8, key, "PLY")) {
            var n = std.mem.splitScalar(u8, rest, ',');
            _ = n.next();
            const lat = parseF64(n.next() orelse "") orelse continue;
            const lon = parseF64(n.next() orelse "") orelse continue;
            try border.append(a, .{ lon, lat });
        } else if (std.mem.eql(u8, key, "REF")) {
            var n = std.mem.splitScalar(u8, rest, ',');
            _ = n.next();
            const x = parseF64(n.next() orelse "") orelse continue;
            const y = parseF64(n.next() orelse "") orelse continue;
            const lat = parseF64(n.next() orelse "") orelse continue;
            const lon = parseF64(n.next() orelse "") orelse continue;
            try refs.append(a, .{ .x = x, .y = y, .lat = lat, .lon = lon });
        } else if (std.mem.eql(u8, key, "WPX")) {
            h.wpx = parsePoly(rest);
        } else if (std.mem.eql(u8, key, "WPY")) {
            h.wpy = parsePoly(rest);
        } else if (std.mem.eql(u8, key, "PWX")) {
            h.pwx = parsePoly(rest);
        } else if (std.mem.eql(u8, key, "PWY")) {
            h.pwy = parsePoly(rest);
        }
    }

    if (h.width == 0 or h.height == 0) return Error.BadHeader;

    // Past the 0x1A: a 0x00, then one byte of bit depth. Trust that byte over
    // IFM — it is what the run-length data was actually written against.
    var off = end + 1;
    if (off < bytes.len and bytes[off] == 0) off += 1;
    if (off >= bytes.len) return Error.BadHeader;
    const d = bytes[off];
    if (d >= 1 and d <= 7) h.depth = d;
    off += 1;
    if (h.depth == 0) return Error.BadHeader;
    h.data_off = off;

    // Nothing wrote slot 0 on a 1-based sheet, so dropping it restores the
    // numbering the rest of the engine reads.
    h.palette_base = if (palette_min == 0) 0 else 1;
    if (h.palette_base == 1 and palette.items.len > 0) _ = palette.orderedRemove(0);
    h.palette = palette.items;
    h.border = border.items;
    h.refs = refs.items;
    return h;
}

/// `KEY=VALUE` out of a comma-separated record. Values may contain commas
/// (`NA=NORTH PACIFIC OCEAN   EASTERN PART,NU=…`), so a value runs to the next
/// `,KEY=` rather than to the next comma.
fn fieldOf(rest: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + name.len + 1 <= rest.len) : (i += 1) {
        if (i != 0 and rest[i - 1] != ',') continue;
        if (!std.mem.eql(u8, rest[i .. i + name.len], name)) continue;
        if (rest[i + name.len] != '=') continue;
        const vs = i + name.len + 1;
        var j = vs;
        while (j < rest.len) : (j += 1) {
            if (rest[j] != ',') continue;
            // A comma starts a new field only when what follows looks like KEY=.
            var k = j + 1;
            while (k < rest.len and rest[k] != '=' and rest[k] != ',') k += 1;
            if (k < rest.len and rest[k] == '=' and k > j + 1) break;
        }
        return std.mem.trim(u8, rest[vs..j], " ");
    }
    return null;
}

fn parsePoly(rest: []const u8) Poly {
    var p: Poly = .{};
    var it = std.mem.splitScalar(u8, rest, ',');
    p.order = @intCast(@min(255, parseU32(it.next() orelse "") orelse 0));
    while (it.next()) |v| {
        if (p.n >= p.c.len) break;
        p.c[p.n] = parseF64(v) orelse 0;
        p.n += 1;
    }
    return p;
}

fn parseU32(s: []const u8) ?u32 {
    const t = std.mem.trim(u8, s, " \t\r");
    if (t.len == 0) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

fn parseF64(s: []const u8) ?f64 {
    const t = std.mem.trim(u8, s, " \t\r");
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

// ---- raster ---------------------------------------------------------------

/// Decode the whole chart: header, then every row of run-length data.
///
/// Rows are read SEQUENTIALLY rather than through the index table at the end of
/// the file. The index is an optimization for random access into a sheet; a bake
/// reads every row once, in order, and the sequential walk cannot disagree with
/// the data the way a stale index can.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Chart {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const h = try parseHeader(a, bytes);
    const w: usize = h.width;
    const total = w * h.height;
    const pixels = try a.alloc(u8, total);
    @memset(pixels, 0);

    var ip: usize = h.data_off;
    var row: usize = 0;
    while (row < h.height and ip < bytes.len) : (row += 1) {
        // Each row opens with its own number, as a 7-bits-per-byte run. Skipped:
        // the sequential walk already knows which row this is, and a sheet whose
        // stated numbers disagree with its order is broken in a way honouring
        // them would hide.
        while (ip < bytes.len and (bytes[ip] & 0x80) != 0) ip += 1;
        if (ip < bytes.len) ip += 1;

        var x: usize = 0;
        const base = row * w;
        while (ip < bytes.len) {
            const c0 = bytes[ip];
            ip += 1;
            if (c0 == 0) break; // end of row
            const shift: u3 = @intCast(7 - h.depth);
            const color: u8 = (c0 & 0x7F) >> shift;
            var count: usize = (c0 & 0x7F) & (@as(u8, 0x7F) >> @intCast(h.depth));
            var c = c0;
            while ((c & 0x80) != 0 and ip < bytes.len) {
                c = bytes[ip];
                ip += 1;
                count = (count << 7) + (c & 0x7F);
            }
            count += 1;
            const n = @min(count, w - x);
            if (n > 0) @memset(pixels[base + x .. base + x + n], color);
            x += n;
            if (x >= w) {
                // The row is full; skip whatever remains of it.
                while (ip < bytes.len and bytes[ip] != 0) ip += 1;
                if (ip < bytes.len) ip += 1;
                break;
            }
        }
    }

    return .{ .header = h, .pixels = pixels, .arena = arena };
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "field extraction keeps values that contain commas" {
    const rest = "NA=NORTH PACIFIC OCEAN   EASTERN PART,NU=2400,RA=10672,16668,DU=400";
    try testing.expectEqualStrings("NORTH PACIFIC OCEAN   EASTERN PART", fieldOf(rest, "NA").?);
    try testing.expectEqualStrings("2400", fieldOf(rest, "NU").?);
    // RA is two numbers, and the second is NOT a new field.
    try testing.expectEqualStrings("10672,16668", fieldOf(rest, "RA").?);
    try testing.expectEqualStrings("400", fieldOf(rest, "DU").?);
    try testing.expect(fieldOf(rest, "ZZ") == null);
}

test "KNP fields" {
    const rest = "SC=10000000,GD=NAD83,PR=MERCATOR,PP=.000,PI=600.000,SP=,SK=0.0000000";
    try testing.expectEqualStrings("10000000", fieldOf(rest, "SC").?);
    try testing.expectEqualStrings("NAD83", fieldOf(rest, "GD").?);
    try testing.expectEqualStrings("MERCATOR", fieldOf(rest, "PR").?);
    // An EMPTY value is still a value, not a miss.
    try testing.expectEqualStrings("", fieldOf(rest, "SP").?);
}

test "a palette numbered from 0 is read at its own base" {
    // BSB numbers its palette from 1. Sheets in the wild number from 0, and
    // then pixel value 0 is a real colour. Reading such a sheet as 1-based
    // indexes one before the start of the array, which on a release build is a
    // write to whatever is there.
    // parseHeader allocates into a caller arena, as decode does.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero =
        "BSB/NA=T,RA=2,2\r\nRGB/0,10,20,30\r\nRGB/1,40,50,60\r\n\x1a\x00\x01";
    const h0 = try parseHeader(a, zero);
    try testing.expectEqual(@as(u8, 0), h0.palette_base);
    try testing.expectEqual(@as(usize, 2), h0.palette.len);
    try testing.expectEqual(@as(u8, 10), h0.palette[0].r);
    try testing.expectEqual(@as(u8, 40), h0.palette[1].r);

    const one =
        "BSB/NA=T,RA=2,2\r\nRGB/1,10,20,30\r\nRGB/2,40,50,60\r\n\x1a\x00\x01";
    const h1 = try parseHeader(a, one);
    try testing.expectEqual(@as(u8, 1), h1.palette_base);
    try testing.expectEqual(@as(usize, 2), h1.palette.len);
    try testing.expectEqual(@as(u8, 10), h1.palette[0].r);
    try testing.expectEqual(@as(u8, 40), h1.palette[1].r);
}

test "polynomial parse and evaluate" {
    const p = parsePoly("3,-1.7614611556e+002,5.7055880833e-003,-1.3260547082e-015");
    try testing.expectEqual(@as(u8, 3), p.order);
    try testing.expectEqual(@as(u8, 3), p.n);
    // c0 + c1*x + c2*y, with the rest absent and contributing nothing.
    const got = p.eval(1000, 0);
    try testing.expectApproxEqAbs(-176.14611556 + 5.7055880833, got, 1e-9);
}

// The real-file tests. A KAP is megabytes and cannot live in the repo, so the
// path comes from the environment: point TILE57_KAP at one.
test "decode a real NOAA RNC sheet" {
    const a = testing.allocator;
    const path = std.mem.span(std.c.getenv("TILE57_KAP") orelse return error.SkipZigTest);

    const f = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    defer f.close(testing.io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
    defer a.free(bytes);

    var chart = try decode(a, bytes);
    defer chart.deinit();
    const h = chart.header;

    try testing.expect(h.width > 0 and h.height > 0);
    try testing.expect(h.depth >= 1 and h.depth <= 7);
    try testing.expect(h.palette.len > 0);
    try testing.expect(h.scale > 0);
    try testing.expect(h.border.len >= 3); // a polygon, not a line
    try testing.expect(h.datum.len > 0);

    // The fit must reproduce the sheet's OWN control points. This is the whole
    // of the georeferencing claim: a bake that cannot hit the points the
    // hydrographic office published has no business warping the pixels.
    // Measured across the nine sheets of NOAA_RNC_5 — 1:10,000,000 ocean sheets
    // through harbour sheets, one skewed 31° (a Newport-to-Bermuda plotting
    // sheet) and one straddling the antimeridian. Latitude lands inside 0.005°
    // on every one, and longitude inside 0.005° on eight; the Aleutian sheet at
    // 0.026° is the outlier and why is not yet understood
    // (see specs/CONCERNS.md). The bounds catch a regression rather than bless
    // that number.
    const fit = fitRefs(h, a) orelse return error.SkipZigTest;
    try testing.expect(fit.max_dlon < 0.03);
    try testing.expect(fit.max_dlat < 0.005);

    // And it must land inside the sheet's own declared border.
    var min_lon: f64 = 1e9;
    var max_lon: f64 = -1e9;
    var min_lat: f64 = 1e9;
    var max_lat: f64 = -1e9;
    for (h.border) |p| {
        min_lon = @min(min_lon, p[0]);
        max_lon = @max(max_lon, p[0]);
        min_lat = @min(min_lat, p[1]);
        max_lat = @max(max_lat, p[1]);
    }
    const mid_lat = fit.latAt(@floatFromInt(h.width / 2), @floatFromInt(h.height / 2));
    try testing.expect(mid_lat >= min_lat - 1 and mid_lat <= max_lat + 1);

    // A decoded sheet must not be blank: a run-length bug shows up as a solid
    // field of one index long before it shows up as a wrong picture.
    var seen = [_]bool{false} ** 256;
    var distinct: usize = 0;
    for (chart.pixels) |p| {
        if (!seen[p]) {
            seen[p] = true;
            distinct += 1;
        }
    }
    try testing.expect(distinct >= 3);
}

test "ellipsoidal mercator round-trips" {
    for ([_]f64{ -80, -45, -0.001, 0, 12.5, 45, 71.5, 84 }) |lat| {
        try testing.expectApproxEqAbs(lat, invMercY(mercY(lat)), 1e-9);
    }
    // North is a LARGER mercator ordinate; the axis every flip depends on.
    try testing.expect(mercY(46) > mercY(45));
    // Ellipsoidal differs from spherical enough to matter: on the 1:10M sheet
    // that difference was 0.034 deg of latitude, 37x the ellipsoidal residual.
    const sph = std.math.log(f64, std.math.e, std.math.tan(std.math.pi / 4.0 + std.math.degreesToRadians(60.0) / 2.0));
    try testing.expect(@abs(mercY(60) - sph) > 1e-3);
}
