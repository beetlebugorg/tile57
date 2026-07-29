//! Turning a scene's ranges into a host's draw calls.
//!
//! `gpu.zig` hands back ranges in paint order; a host still has to decide, per
//! range, which pipeline draws it, which atlas it samples, what the uniform
//! block should say, and whether it can be folded into the previous draw. That
//! decision is the same on every backend — it is a reading of `Range.kind`,
//! `prim`, `atlas` and `pattern`, all of which this engine defines — but it was
//! written out three times in the lookout backends, and the three had already
//! diverged: one of them never merged at all, so it issued a draw per range
//! where the others issued one per run.
//!
//! So: `batch()` reads a scene and writes a list of draw items. What stays with
//! the host is everything the engine cannot know — its pipeline objects, its
//! textures, its command encoder — plus any pass structure of its own (the
//! Metal backend runs an extra front-to-back depth pass over opaque triangles
//! first, an early-z optimization that `exclude_opaque_tris` keeps out of here).
//!
//! Nothing in this file allocates or touches the GPU: it is a pure function
//! from (ranges, per-frame host scalars) to draw items, which is what makes it
//! testable at all — see the tests at the bottom.

const std = @import("std");
const gpu = @import("gpu.zig");

/// Which of the four pipelines draws an item. The host maps these onto its own
/// pipeline objects; the engine only says which program the range needs.
pub const Pipeline = enum(u8) {
    /// Flat-colour triangles; colour arrives per vertex.
    chart = 0,
    /// Area fill tiled from a pattern cell texture.
    pattern = 1,
    /// Textured quads from the sprite atlas.
    sprite = 2,
    /// SDF glyph quads, with the halo tiers.
    sdf = 3,
};

/// Per-frame host state the classification depends on. Everything here is a
/// scalar the engine cannot derive from a scene: mariner toggles, display
/// density, the active palette's background, and which atlases the host
/// actually managed to upload.
pub const Opts = extern struct {
    /// The mariner's text switch. Off drops every TEXT range.
    text_on: bool = true,
    /// The mariner's soundings switch. Off drops every SOUNDING range.
    sound_on: bool = true,
    /// Leave opaque, pattern-less triangle ranges out — for a host that draws
    /// them in its own depth-tested pass first.
    exclude_opaque_tris: bool = false,
    /// Bit per `AtlasId` the host has a texture for. A missing bold or italic
    /// tier falls back to the regular glyph atlas; a missing regular atlas or
    /// sprite sheet drops the range, because there is nothing to sample.
    atlas_have: u8 = 0xFF,
    /// The active palette's background (its NODATA), which the SDF fragment
    /// stage draws label halos in — a hardcoded white one glares at night.
    halo: [4]f32 = .{ 0, 0, 0, 1 },
};

/// One draw call. `first`/`count` index the same buffers `Range` does, so a
/// merged item is just a wider slice of them.
///
/// The three uniform fields are the ONLY parts of the block that vary per draw;
/// the host builds its frame uniform once and applies these over it. They are
/// also exactly what the merge compares, so two items that differ in any of
/// them stay separate draws.
pub const Draw = extern struct {
    first: u32,
    count: u32,
    /// `gpu.Prim`.
    prim: u8,
    /// `Pipeline`.
    pipeline: u8,
    /// `gpu.AtlasId` AFTER the missing-tier fallback — the atlas to bind, not
    /// the one the range asked for.
    atlas: u8,
    _pad: u8 = 0,
    /// Index into the scene's patterns, or `gpu.NO_PATTERN`. The host looks its
    /// own cell texture up by this and derives the uniform's `cell_px` from the
    /// texture's size — which is why no pattern data is needed here at all.
    /// Comparing this index is exactly equivalent to comparing the dimensions
    /// it implies, so the merge stays correct without them.
    ///
    /// A pattern whose cell never rasterized is the host's to drop (only it
    /// knows what uploaded); the flat fill underneath has already been laid
    /// down, so skipping the draw is right.
    pattern: u32,
    /// OR into the uniform's `cat_mask`. Soundings ride the mariner's soundings
    /// switch, NOT the OTHER display category: S-52 files SOUNDG under OTHER,
    /// but a mariner asking for soundings is not asking for seabed and cables.
    /// The engine tags them OTHER, so this forces that bit on for these draws
    /// only — SCAMIN still culls them.
    cat_mask_or: u32,
    /// The uniform's `color`. The halo colour on SDF items; opaque black
    /// otherwise, where no pipeline reads it.
    color: [4]f32,
};

fn atlasHas(have: u8, id: gpu.AtlasId) bool {
    return have & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(id)))) != 0;
}

/// Resolve which atlas a quad range actually samples, honouring the host's
/// missing-tier fallback. Null = nothing to sample, so drop the range.
fn resolveAtlas(want: gpu.AtlasId, have: u8) ?gpu.AtlasId {
    return switch (want) {
        .glyph_bold, .glyph_italic => if (atlasHas(have, want))
            want
        else if (atlasHas(have, .glyph)) .glyph else null,
        .glyph => if (atlasHas(have, .glyph)) .glyph else null,
        else => if (atlasHas(have, .sprite)) .sprite else null,
    };
}

/// Classify one range. Null = it draws nothing: gated off by a mariner switch,
/// or an opaque triangle the host draws in its own pass, or a quad whose atlas
/// the host never uploaded.
fn classify(r: gpu.Range, opts: Opts) ?Draw {
    switch (r.kind) {
        .text => if (!opts.text_on) return null,
        .sounding => if (!opts.sound_on) return null,
        else => {},
    }
    var it = Draw{
        .first = r.first,
        .count = r.count,
        .prim = @intFromEnum(r.prim),
        .pipeline = @intFromEnum(Pipeline.chart),
        .atlas = @intFromEnum(gpu.AtlasId.none),
        .pattern = gpu.NO_PATTERN,
        .cat_mask_or = if (r.kind == .sounding) @as(u32, 1) << 2 else 0,
        .color = .{ 0, 0, 0, 1 },
    };
    switch (r.prim) {
        .triangles => {
            if (opts.exclude_opaque_tris and (r.flags & 1) != 0 and r.pattern == gpu.NO_PATTERN) return null;
            if (r.pattern != gpu.NO_PATTERN) {
                it.pipeline = @intFromEnum(Pipeline.pattern);
                it.pattern = r.pattern;
            }
        },
        .quads => {
            const atlas = resolveAtlas(r.atlas, opts.atlas_have) orelse return null;
            const glyph = atlas != .sprite;
            it.atlas = @intFromEnum(atlas);
            it.pipeline = @intFromEnum(if (glyph) Pipeline.sdf else Pipeline.sprite);
            if (glyph) it.color = opts.halo;
        },
    }
    return it;
}

/// True when `b` can be folded onto the end of `a`: same draw spec, and `b`
/// starts exactly where `a` ends. Contiguity is what keeps a merge honest —
/// a dropped range breaks it, so merging can never draw gated-off content, and
/// merged primitives rasterize in the order they would have anyway.
fn mergeable(a: Draw, b: Draw) bool {
    return a.prim == b.prim and a.pipeline == b.pipeline and a.atlas == b.atlas and
        a.pattern == b.pattern and a.cat_mask_or == b.cat_mask_or and
        std.mem.eql(u8, std.mem.asBytes(&a.color), std.mem.asBytes(&b.color)) and
        a.first + a.count == b.first;
}

/// Batch a scene's ranges into draw calls, writing at most `out.len`. Returns
/// how many draws the batch HAS — a return greater than `out.len` means the
/// buffer was too small and the caller should retry with that size; nothing
/// partial is ever safe to draw, since a truncated batch silently omits chart.
///
/// Takes only ranges: the batcher never needs the vertex, quad or pattern
/// buffers, and saying so keeps a host from having to hold a whole scene alive
/// just to ask this question.
pub fn batch(ranges: []const gpu.Range, opts: Opts, out: []Draw) usize {
    var n: usize = 0;
    var open: ?Draw = null;
    for (ranges) |r| {
        const it = classify(r, opts) orelse continue;
        if (open) |*o| {
            if (mergeable(o.*, it)) {
                o.count += it.count;
                continue;
            }
            if (n < out.len) out[n] = o.*;
            n += 1;
        }
        open = it;
    }
    if (open) |o| {
        if (n < out.len) out[n] = o;
        n += 1;
    }
    return n;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "the C mirrors in tile57.h have these layouts" {
    // tile57_gpu_batch_opts / tile57_gpu_draw are hand-written C; nothing else
    // would notice them drifting from these until a host read garbage.
    try testing.expectEqual(@as(usize, 20), @sizeOf(Opts));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Opts, "halo"));

    try testing.expectEqual(@as(usize, 36), @sizeOf(Draw));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Draw, "pattern"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Draw, "cat_mask_or"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(Draw, "color"));
}

fn tri(first: u32, count: u32, kind: gpu.Kind) gpu.Range {
    return .{
        .first = first,
        .count = count,
        .paint_key = 0,
        .pattern = gpu.NO_PATTERN,
        .color = .{ 0, 0, 0, 255 },
        .kind = kind,
        .prim = .triangles,
        .atlas = .none,
    };
}

fn quad(first: u32, count: u32, atlas: gpu.AtlasId) gpu.Range {
    return .{
        .first = first,
        .count = count,
        .paint_key = 0,
        .pattern = gpu.NO_PATTERN,
        .color = .{ 0, 0, 0, 255 },
        .kind = .text,
        .prim = .quads,
        .atlas = atlas,
    };
}

test "contiguous ranges of one spec collapse into a single draw" {
    const ranges = [_]gpu.Range{ tri(0, 30, .area), tri(30, 12, .area), tri(42, 6, .area) };
    var out: [8]Draw = undefined;
    const n = batch(&ranges, .{}, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 0), out[0].first);
    try testing.expectEqual(@as(u32, 48), out[0].count);
}

test "a gap in the index stream breaks the run" {
    const ranges = [_]gpu.Range{ tri(0, 30, .area), tri(60, 12, .area) };
    var out: [8]Draw = undefined;
    try testing.expectEqual(@as(usize, 2), batch(&ranges, .{}, &out));
}

test "a gated-off range breaks contiguity instead of being drawn through" {
    // Text between two fills: with text off the fills are no longer adjacent in
    // the index stream, so they must NOT merge across the hole.
    const ranges = [_]gpu.Range{ tri(0, 30, .area), tri(30, 6, .text), tri(36, 12, .area) };
    var out: [8]Draw = undefined;
    const n = batch(&ranges, .{ .text_on = false }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 30), out[0].count);
    try testing.expectEqual(@as(u32, 36), out[1].first);
}

test "soundings force the OTHER category bit on, and only for their own draws" {
    const ranges = [_]gpu.Range{ tri(0, 6, .sounding), tri(6, 6, .area) };
    var out: [8]Draw = undefined;
    const n = batch(&ranges, .{}, &out);
    try testing.expectEqual(@as(usize, 2), n); // the differing cat_mask splits them
    try testing.expectEqual(@as(u32, 1) << 2, out[0].cat_mask_or);
    try testing.expectEqual(@as(u32, 0), out[1].cat_mask_or);
}

test "a missing bold tier falls back to the regular glyph atlas" {
    const have: u8 = (1 << @intFromEnum(gpu.AtlasId.glyph)) | (1 << @intFromEnum(gpu.AtlasId.sprite));
    const ranges = [_]gpu.Range{quad(0, 6, .glyph_bold)};
    var out: [4]Draw = undefined;
    try testing.expectEqual(@as(usize, 1), batch(&ranges, .{ .atlas_have = have }, &out));
    try testing.expectEqual(@intFromEnum(gpu.AtlasId.glyph), out[0].atlas);
    try testing.expectEqual(@intFromEnum(Pipeline.sdf), out[0].pipeline);
}

test "no glyph atlas at all drops the range rather than sampling nothing" {
    const have: u8 = 1 << @intFromEnum(gpu.AtlasId.sprite);
    const ranges = [_]gpu.Range{quad(0, 6, .glyph)};
    var out: [4]Draw = undefined;
    try testing.expectEqual(@as(usize, 0), batch(&ranges, .{ .atlas_have = have }, &out));
}

test "glyph items carry the halo colour, sprites do not" {
    const ranges = [_]gpu.Range{ quad(0, 6, .glyph), quad(6, 6, .sprite) };
    var out: [4]Draw = undefined;
    const n = batch(&ranges, .{ .halo = .{ 0.1, 0.2, 0.3, 1 } }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(f32, 0.2), out[0].color[1]);
    try testing.expectEqual(@as(f32, 0), out[1].color[1]);
}

test "a patterned fill takes the pattern pipeline and carries its cell index" {
    var ranges = [_]gpu.Range{tri(0, 6, .area)};
    ranges[0].pattern = 3;
    var out: [4]Draw = undefined;
    try testing.expectEqual(@as(usize, 1), batch(&ranges, .{}, &out));
    try testing.expectEqual(@intFromEnum(Pipeline.pattern), out[0].pipeline);
    try testing.expectEqual(@as(u32, 3), out[0].pattern);
}

test "fills using different pattern cells never merge" {
    // The host derives cell_px from each cell's texture, so a merge across two
    // cells would tile the second one at the first one's period.
    var ranges = [_]gpu.Range{ tri(0, 6, .area), tri(6, 6, .area) };
    ranges[0].pattern = 1;
    ranges[1].pattern = 2;
    var out: [4]Draw = undefined;
    try testing.expectEqual(@as(usize, 2), batch(&ranges, .{}, &out));
}

test "excluding opaque triangles leaves the blended ones alone" {
    var ranges = [_]gpu.Range{ tri(0, 6, .area), tri(6, 6, .area) };
    ranges[0].flags = 1; // opaque
    var out: [4]Draw = undefined;
    const n = batch(&ranges, .{ .exclude_opaque_tris = true }, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 6), out[0].first);
}

test "a batch longer than the buffer reports what it needed and writes no more" {
    const ranges = [_]gpu.Range{ tri(0, 6, .area), tri(60, 6, .area), tri(120, 6, .area) };
    var out: [1]Draw = undefined;
    try testing.expectEqual(@as(usize, 3), batch(&ranges, .{}, &out));
    try testing.expectEqual(@as(u32, 0), out[0].first); // only the first landed
}
