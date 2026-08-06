//! RasterChart — one open raster chart.
//!
//! A chart made of pictures rather than features. Three things arrive as one:
//! satellite imagery the mariner downloaded, another vendor's chart rendered to
//! tiles, and an RNC baked from a BSB/KAP sheet. All three answer the same
//! question — give me the picture at (z, x, y) — and none of them answers any of
//! the questions `Chart` does.
//!
//! WHAT THE KINDS SHARE AND WHERE THEY PART. They differ on exactly one axis, and
//! it is the one that decides quilting: a compilation scale and a coverage
//! polygon. A baked RNC carries both, so it composes through the ownership
//! partition by scale band and edition date, exactly as a vector chart does. A
//! community MBTiles carries neither, so it can own no ground — and `compose`
//! already skips a chart that can own no ground, which is the rule it applies to
//! a vector chart embedding no coverage today. Nothing above here has to ask
//! which kind of file it came from.
//!
//! The format is decided by what the file IS, never by its extension. Community
//! files arrive named `.mbtiles`, unpacked from a `.zip` to no extension at all,
//! and whatever else the contributor felt like.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mbtiles = @import("mbtiles.zig");
const tiles = @import("tiles");
const pmtiles = tiles.pmtiles;
const filemap = tiles.filemap;
const coverage = @import("coverage");

pub const Error = mbtiles.Error || error{
    /// The file opened but is not a raster chart in any format we read.
    UnknownFormat,
};

pub const Encoding = mbtiles.Encoding;

/// What a raster chart declares about itself.
pub const Info = struct {
    min_zoom: u8 = 0,
    max_zoom: u8 = 0,
    encoding: Encoding = .unknown,
    tile_size: u32 = 256,
    west: f64 = -180.0,
    south: f64 = -85.05112878,
    east: f64 = 180.0,
    north: f64 = 85.05112878,
    /// Compilation scale denominator, or 0 when the chart declares none. A baked
    /// RNC carries its `SC`; a community MBTiles has no such thing. 0 means the
    /// chart can own no ground and takes no part in ownership resolution.
    scale: u32 = 0,
    /// True when the zoom range / bounds came from the file rather than being
    /// recomputed from its tile index. A host reporting provenance wants to know.
    zooms_declared: bool = false,
    bounds_declared: bool = false,
};

pub const RasterChart = struct {
    src: Source,

    const Source = union(enum) {
        mbtiles: mbtiles.Reader,
        archive: Archive,
    };

    /// A baked RNC: the per-chart PMTiles archive the KAP bake writes, mmap'd
    /// where it sits, plus the coverage its metadata embeds. The mapping is what
    /// lets a mariner carry a whole quilt of sheets — the archives are paged in
    /// by the kernel and never fully resident.
    const Archive = struct {
        map: []align(std.heap.page_size_min) const u8,
        reader: pmtiles.Reader,
        /// Owns the decoded coverage and the two strings below.
        arena: std.heap.ArenaAllocator,
        cov: ?coverage.ChartCoverage = null,
        name: [:0]const u8 = "",
        description: [:0]const u8 = "",
    };

    /// The two labels the archive metadata carries, as far as this handle cares.
    const MetaNames = struct { name: []const u8 = "", description: []const u8 = "" };

    /// Open a raster chart at `path`, read-only. `msg` (null to ignore) receives
    /// the underlying reader's own text when the open fails. Close with `close`.
    ///
    /// The format is decided by what the file IS, not by the extension: a PMTiles
    /// archive names itself in its first seven bytes, and SQLite reports "not a
    /// database" for anything that is not one, so an MBTiles identifies itself
    /// too. `io` is used only for the archive path (SQLite opens its own file).
    pub fn open(io: std.Io, gpa: Allocator, path: [*:0]const u8, msg: ?*mbtiles.ErrMsg) Error!RasterChart {
        if (openArchive(io, gpa, std.mem.span(path))) |arc| return .{ .src = .{ .archive = arc } };
        const r = mbtiles.Reader.open(gpa, path, msg) catch |e| return switch (e) {
            error.NotADatabase => Error.UnknownFormat,
            else => e,
        };
        return .{ .src = .{ .mbtiles = r } };
    }

    /// The baked-archive probe: map the file and let the PMTiles header speak.
    /// Null for anything that is not one — including a file that will not open,
    /// which the MBTiles path reports with SQLite's own words.
    fn openArchive(io: std.Io, gpa: Allocator, path: []const u8) ?Archive {
        var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer f.close(io);
        const st = f.stat(io) catch return null;
        const len: usize = @intCast(st.size);
        if (len < pmtiles.HEADER_LEN) return null;
        const map = filemap.mapReadonly(f.handle, len) catch return null;
        const reader = pmtiles.Reader.init(gpa, map) catch {
            filemap.unmap(map);
            return null;
        };
        var arc = Archive{ .map = map, .reader = reader, .arena = std.heap.ArenaAllocator.init(gpa) };
        // The chart's own coverage, scale and identity, exactly where the ENC
        // bake puts a cell's: the metadata JSON's "coverage" key. An archive
        // without it owns no ground and simply cannot quilt.
        if (reader.header.metadata_length > 0) {
            const raw = map[@intCast(reader.header.metadata_offset)..][0..@intCast(reader.header.metadata_length)];
            const a = arc.arena.allocator();
            // The JSON text and the parser's scratch go through gpa and are gone
            // before the handle settles; only the decoded rings stay.
            const json: ?[]const u8 = switch (reader.header.internal_compression) {
                .none => raw,
                .gzip => tiles.gzip.decompress(gpa, raw) catch null,
                else => null,
            };
            if (json) |j| {
                defer if (reader.header.internal_compression == .gzip) gpa.free(@constCast(j));
                arc.cov = coverage.decodeFromMetadata(a, gpa, j) catch null;
                // What the sheet calls itself, for a host that has to label it:
                // the bake writes the chart identity as "name" and the sheet's
                // own title as "description".
                if (std.json.parseFromSlice(MetaNames, gpa, j, .{ .ignore_unknown_fields = true })) |p| {
                    defer p.deinit();
                    arc.name = a.dupeZ(u8, p.value.name) catch "";
                    arc.description = a.dupeZ(u8, p.value.description) catch "";
                } else |_| {}
            }
        }
        return arc;
    }

    pub fn close(rc: *RasterChart) void {
        switch (rc.src) {
            .mbtiles => |*r| r.close(),
            .archive => |*arc| {
                arc.reader.deinit();
                arc.arena.deinit();
                filemap.unmap(arc.map);
            },
        }
    }

    pub fn getInfo(rc: *const RasterChart) Info {
        return switch (rc.src) {
            .archive => |*arc| .{
                // The archive states its own window, and it means it: the bake
                // stops at the sheet's native resolution, so a host wanting a
                // closer look overzooms the top level rather than finding
                // invented detail in the file.
                .min_zoom = arc.reader.header.min_zoom,
                .max_zoom = arc.reader.header.max_zoom,
                .encoding = switch (arc.reader.header.tile_type) {
                    .png => .png,
                    .jpeg => .jpeg,
                    .webp => .webp,
                    else => .unknown,
                },
                .tile_size = 256,
                .west = @as(f64, @floatFromInt(arc.reader.header.min_lon_e7)) / 1e7,
                .south = @as(f64, @floatFromInt(arc.reader.header.min_lat_e7)) / 1e7,
                .east = @as(f64, @floatFromInt(arc.reader.header.max_lon_e7)) / 1e7,
                .north = @as(f64, @floatFromInt(arc.reader.header.max_lat_e7)) / 1e7,
                // The sheet's own compilation scale, which is what lets it quilt.
                .scale = if (arc.cov) |cv| @intCast(@max(0, cv.cscl)) else 0,
                .zooms_declared = true,
                .bounds_declared = true,
            },
            .mbtiles => |*r| .{
                .min_zoom = r.meta.min_zoom,
                .max_zoom = r.meta.max_zoom,
                .encoding = r.meta.encoding,
                .tile_size = r.meta.tile_size,
                .west = r.meta.west,
                .south = r.meta.south,
                .east = r.meta.east,
                .north = r.meta.north,
                // An MBTiles states no compilation scale, so it can own no
                // ground. This is the whole of the difference from a baked RNC.
                .scale = 0,
                .zooms_declared = r.meta.zooms_declared,
                .bounds_declared = r.meta.bounds_declared,
            },
        };
    }

    /// The encoded picture for (z,x,y) in XYZ addressing, or null when the chart
    /// has no tile there — the ORDINARY case for a pyramid clipped to a
    /// coastline. Caller owns the bytes.
    ///
    /// Not internally synchronized. A host streaming tiles from a worker
    /// serializes its own access, as it does for a chart.
    pub fn tile(rc: *RasterChart, gpa: Allocator, z: u8, x: u32, y: u32) Error!?[]u8 {
        return switch (rc.src) {
            .mbtiles => |*r| try r.tile(gpa, z, x, y),
            // A tile the archive does not hold is null, not an error — a baked
            // sheet addresses only the tiles its neat line touches, so most of
            // its own bounding box is absent by design.
            .archive => |*arc| arc.reader.getTile(gpa, z, x, y) catch |e| switch (e) {
                error.OutOfMemory => Error.OutOfMemory,
                else => Error.QueryFailed,
            },
        };
    }

    /// The archive backing a baked RNC, for a compositor to quilt over: the
    /// PMTiles reader plus the coverage its metadata embeds. Both are BORROWED —
    /// the chart must outlive whatever composes it. Null for an MBTiles, which
    /// has neither.
    pub fn pmtilesReader(rc: *RasterChart) ?*pmtiles.Reader {
        return switch (rc.src) {
            .archive => |*arc| &arc.reader,
            else => null,
        };
    }

    /// The chart's coverage + compilation scale + date, as embedded in the
    /// archive metadata. Null when the chart carries none, which is the whole of
    /// why a community MBTiles can own no ground.
    pub fn decodedCoverage(rc: *const RasterChart) ?coverage.ChartCoverage {
        return switch (rc.src) {
            .archive => |*arc| arc.cov,
            else => null,
        };
    }

    /// What the chart calls itself. Borrowed from the handle; valid until close,
    /// and NUL-terminated for the C ABI. Any may be empty. None is a capture
    /// date — no MBTiles carries one.
    pub fn name(rc: *const RasterChart) [:0]const u8 {
        return switch (rc.src) {
            .mbtiles => |*r| r.meta.name,
            .archive => |*arc| arc.name,
        };
    }

    pub fn description(rc: *const RasterChart) [:0]const u8 {
        return switch (rc.src) {
            .mbtiles => |*r| r.meta.description,
            .archive => |*arc| arc.description,
        };
    }

    pub fn attribution(rc: *const RasterChart) [:0]const u8 {
        return switch (rc.src) {
            .mbtiles => |*r| r.meta.attribution,
            // An RNC's attribution is the hydrographic office's, and the KAP
            // carries it as free-text notes rather than as a field. Better empty
            // than invented.
            .archive => "",
        };
    }

    // ---- diagnostics ------------------------------------------------------
    // For `tile57 raster info`, not for a view. Neither is on the C ABI: a host
    // needs neither (the y flip is already applied, and a count costs a scan).

    /// How many tiles the chart holds. Scans an index.
    pub fn tileCount(rc: *RasterChart) Error!u64 {
        return switch (rc.src) {
            .mbtiles => |*r| try r.tileCount(),
            .archive => |*arc| arc.reader.header.num_addressed_tiles,
        };
    }

    /// Which corner the SOURCE counts its rows from, before the reader
    /// normalizes to XYZ. Worth printing: a chart that looks plausible but
    /// mirrors north-to-south is a scheme the producer mislabelled.
    pub fn schemeName(rc: *const RasterChart) []const u8 {
        return switch (rc.src) {
            .mbtiles => |*r| @tagName(r.meta.scheme),
            .archive => "xyz", // PMTiles addresses tiles the way the web serves them
        };
    }
};

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "a file that is not a chart is refused as an unknown format" {
    // A real file that is definitely not a database, with no temp-file dance:
    // this repo's own build script, relative to the build root the test runs in.
    // Skips rather than fails when invoked from somewhere else.
    const r = RasterChart.open(testing.io, testing.allocator, "build.zig", null);
    if (r) |_| {
        return error.TestUnexpectedResult;
    } else |e| switch (e) {
        Error.UnknownFormat => {},
        Error.OpenFailed => return error.SkipZigTest, // not run from the build root
        else => return e,
    }
}

test "a missing file reports the open failure" {
    try testing.expectError(Error.OpenFailed, RasterChart.open(testing.io, testing.allocator, "/nonexistent/chart.mbtiles", null));
}

test "open a real chart through the RasterChart handle" {
    const a = testing.allocator;
    const path = std.c.getenv("TILE57_MBTILES") orelse return error.SkipZigTest;

    var rc = try RasterChart.open(testing.io, a, path, null);
    defer rc.close();

    const info = rc.getInfo();
    try testing.expect(info.max_zoom >= info.min_zoom);
    try testing.expect(info.encoding != .unknown);
    try testing.expectEqual(@as(u32, 0), info.scale); // an MBTiles owns no ground
    try testing.expect(info.east > info.west and info.north > info.south);

    // Out of the declared range answers null, not an error.
    try testing.expect((try rc.tile(a, 31, 0, 0)) == null);
}
