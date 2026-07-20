//! Polygon tessellation: contours in, triangles out.
//!
//! Thin Zig wrapper over vendored libtess2 (SGI Free Software License B — see
//! vendor/libtess2/LICENSE.txt). It exists because a GPU surface needs triangles
//! and the rest of the engine only ever needed scanline fills, so nothing here
//! could be reused.
//!
//! The winding rule is not a detail to default: S-52 area fills are NONZERO,
//! while symbol and glyph outlines are EVEN-ODD — that is what makes the counter
//! of an 'o' a hole and keeps a compound symbol's disjoint contours from bridging
//! into each other.
//!
//! libtess2 is C for now; a Zig port is its own change. When it lands it is also
//! a candidate to replace the hand-rolled sweep in src/geometry (boolean.zig).

const std = @import("std");
const c = @cImport({
    @cInclude("tesselator.h");
});

pub const Rule = enum {
    /// Area fills: a point is inside when the winding number is non-zero.
    nonzero,
    /// Symbol + glyph outlines: a point is inside when crossings are odd, so a
    /// counter-wound inner contour cuts a hole.
    even_odd,

    fn toC(self: Rule) c_int {
        return switch (self) {
            .nonzero => c.TESS_WINDING_NONZERO,
            .even_odd => c.TESS_WINDING_ODD,
        };
    }
};

/// Triangles from one tessellation. `verts` is xy pairs; `indices` are triangle
/// corners into it (3 per triangle). Both borrow the Tessellator's arena and are
/// invalidated by the next `run` or by `deinit`.
pub const Triangles = struct {
    verts: []const f32,
    indices: []const u32,

    pub fn triangleCount(self: Triangles) usize {
        return self.indices.len / 3;
    }
};

/// Reusable tessellator. Allocating one per call is wasteful — libtess2 keeps
/// internal pools that amortise across runs — so a surface should own one for
/// the whole scene.
pub const Tessellator = struct {
    handle: ?*c.TESStesselator,
    /// Scratch for the caller's flattened contour points, reused across runs so a
    /// scene does not allocate per feature.
    scratch: std.ArrayList(f32) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !Tessellator {
        return .{ .handle = c.tessNewTess(null) orelse return error.OutOfMemory, .gpa = gpa };
    }

    pub fn deinit(self: *Tessellator) void {
        if (self.handle) |h| c.tessDeleteTess(h);
        self.handle = null;
        self.scratch.deinit(self.gpa);
    }

    /// Tessellate `contours` (each a closed ring of xy pairs) under `rule`.
    /// Returns null when the input degenerates to nothing — a ring with fewer
    /// than 3 points, or an area that collapses — which is not an error: the
    /// engine emits such rings after clipping and they simply draw nothing.
    pub fn run(self: *Tessellator, contours: []const []const [2]f32, rule: Rule) !?Triangles {
        const h = self.handle orelse return error.NoTessellator;
        var any = false;
        for (contours) |ring| {
            if (ring.len < 3) continue;
            self.scratch.clearRetainingCapacity();
            try self.scratch.ensureUnusedCapacity(self.gpa, ring.len * 2);
            for (ring) |p| {
                self.scratch.appendAssumeCapacity(p[0]);
                self.scratch.appendAssumeCapacity(p[1]);
            }
            c.tessAddContour(h, 2, self.scratch.items.ptr, @sizeOf(f32) * 2, @intCast(ring.len));
            any = true;
        }
        if (!any) return null;
        if (c.tessTesselate(h, rule.toC(), c.TESS_POLYGONS, 3, 2, null) == 0) return error.TessellationFailed;

        const nverts: usize = @intCast(c.tessGetVertexCount(h));
        const nelems: usize = @intCast(c.tessGetElementCount(h));
        if (nverts == 0 or nelems == 0) return null;
        const vp = c.tessGetVertices(h) orelse return null;
        const ep = c.tessGetElements(h) orelse return null;

        // libtess2 marks a dropped corner with TESS_UNDEF; skip those triangles
        // rather than emitting garbage indices.
        const UNDEF: c_int = ~@as(c_int, 0);
        var idx = std.ArrayList(u32).empty;
        errdefer idx.deinit(self.gpa);
        try idx.ensureTotalCapacity(self.gpa, nelems * 3);
        for (0..nelems) |e| {
            const a = ep[e * 3];
            const b = ep[e * 3 + 1];
            const d = ep[e * 3 + 2];
            if (a == UNDEF or b == UNDEF or d == UNDEF) continue;
            idx.appendAssumeCapacity(@intCast(a));
            idx.appendAssumeCapacity(@intCast(b));
            idx.appendAssumeCapacity(@intCast(d));
        }
        if (idx.items.len == 0) {
            idx.deinit(self.gpa);
            return null;
        }
        return .{ .verts = vp[0 .. nverts * 2], .indices = try idx.toOwnedSlice(self.gpa) };
    }
};

const testing = std.testing;

/// Twice the signed area of a triangle — the sign tells orientation, and the sum
/// over a tessellation must equal the polygon's own area if no area was invented
/// or lost.
fn area2(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f64 {
    return (@as(f64, bx) - ax) * (@as(f64, cy) - ay) - (@as(f64, cx) - ax) * (@as(f64, by) - ay);
}

fn totalArea(t: Triangles) f64 {
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < t.indices.len) : (i += 3) {
        const a = t.indices[i] * 2;
        const b = t.indices[i + 1] * 2;
        const d = t.indices[i + 2] * 2;
        sum += @abs(area2(t.verts[a], t.verts[a + 1], t.verts[b], t.verts[b + 1], t.verts[d], t.verts[d + 1])) / 2;
    }
    return sum;
}

test "tess: a square triangulates to its own area" {
    var t = try Tessellator.init(testing.allocator);
    defer t.deinit();
    const sq = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const out = (try t.run(&.{&sq}, .nonzero)).?;
    defer testing.allocator.free(out.indices);
    try testing.expect(out.triangleCount() >= 2);
    try testing.expectApproxEqAbs(@as(f64, 100), totalArea(out), 0.01);
}

test "tess: even-odd cuts a counter, nonzero fills it" {
    // The distinction that matters for glyphs: the same two contours are a ring
    // under even-odd and a solid square under nonzero (both wound the same way).
    var t = try Tessellator.init(testing.allocator);
    defer t.deinit();
    const outer = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_][2]f32{ .{ 3, 3 }, .{ 7, 3 }, .{ 7, 7 }, .{ 3, 7 } };

    const holed = (try t.run(&.{ &outer, &inner }, .even_odd)).?;
    defer testing.allocator.free(holed.indices);
    try testing.expectApproxEqAbs(@as(f64, 100 - 16), totalArea(holed), 0.01);

    const solid = (try t.run(&.{ &outer, &inner }, .nonzero)).?;
    defer testing.allocator.free(solid.indices);
    try testing.expectApproxEqAbs(@as(f64, 100), totalArea(solid), 0.01);
}

test "tess: degenerate input is null, not an error" {
    var t = try Tessellator.init(testing.allocator);
    defer t.deinit();
    const two = [_][2]f32{ .{ 0, 0 }, .{ 1, 1 } }; // fewer than 3 points
    try testing.expectEqual(@as(?Triangles, null), try t.run(&.{&two}, .nonzero));
    try testing.expectEqual(@as(?Triangles, null), try t.run(&.{}, .nonzero));
    // A zero-area sliver has nothing to draw either.
    const sliver = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 0 } };
    if (try t.run(&.{&sliver}, .nonzero)) |out| {
        defer testing.allocator.free(out.indices);
        try testing.expectApproxEqAbs(@as(f64, 0), totalArea(out), 0.01);
    }
}

test "tess: self-intersecting bowtie is handled, not garbage" {
    // Real ENC rings self-intersect after clipping. libtess2's sweep resolves
    // them; the two lobes of a bowtie are 25 units each under nonzero.
    var t = try Tessellator.init(testing.allocator);
    defer t.deinit();
    const bowtie = [_][2]f32{ .{ 0, 0 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 10 } };
    const out = (try t.run(&.{&bowtie}, .nonzero)).?;
    defer testing.allocator.free(out.indices);
    try testing.expectApproxEqAbs(@as(f64, 50), totalArea(out), 0.01);
}
