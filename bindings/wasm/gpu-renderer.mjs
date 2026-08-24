// WebGPU renderer for tile57 GPU scenes — the browser sibling of the
// reference shaders in shaders/ (lookout.metal, vk/*.vert|frag). The WGSL
// below is a port of those programs over the same tile57_gpu_vertex /
// tile57_gpu_quad / tile57_gpu_uniforms layouts; hold every change against
// them.
//
// The engine hands over triangulated, paint-ordered buffers
// (tile57_*_gpu_scene) and batches them into draw calls (tile57_gpu_batch).
// This renderer uploads the buffers once per scene and redraws every frame
// from uniforms alone, so pan and zoom are live between scene rebuilds.
//
// The renderer holds no engine handle — it consumes plain data, so the
// engine can live in a Web Worker while the device and buffers live here.
//
// usage:
//   const r = await GpuRenderer.create(canvas, pixelRatio, assets);
//     // assets: {layout, spritePng, glyphPng, glyphBoldPng, glyphItalicPng,
//     //          colortables} — the engine-worker's gpuAssets op
//   r.setScene(data);   // {vertex, index, quad, patterns, draws} — its gpuScene op
//   r.draw(camera);     // {lon, lat, zoom}, any frame

export const ATLAS = { NONE: 0, SPRITE: 1, GLYPH: 2, GLYPH_BOLD: 3, GLYPH_ITALIC: 4 };
const NO_PATTERN = 0xffffffff;
const PIPE = { CHART: 0, PATTERN: 1, SPRITE: 2, SDF: 3 };
const UNIFORM_SLOT = 256; // minUniformBufferOffsetAlignment

const WGSL = /* wgsl */ `
// tile57_gpu_uniforms, byte for byte (color at 96, block 128).
struct U {
  mvp: mat4x4f,
  px_to_clip: vec2f,
  size_scale: f32,
  current_scale: f32,
  cat_mask: u32,
  wrap_x: f32,
  rot_sin: f32,
  rot_cos: f32,
  color: vec4f,       // SDF halo background; unused elsewhere
  anchor_px: vec2f,   // pattern phase origin, framebuffer px
  cell_px: vec2f,     // pattern cell period, framebuffer px
}
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var tex: texture_2d<f32>;

fn rotate_local(local: vec2f) -> vec2f {
  return vec2f(local.x * u.rot_cos - local.y * u.rot_sin,
               local.x * u.rot_sin + local.y * u.rot_cos);
}
fn visible(disp_cat: u32, scamin: f32) -> bool {
  var vis = (u.cat_mask & (1u << disp_cat)) != 0u;
  if scamin > 0.0 && disp_cat != 0u && u.current_scale > scamin { vis = false; }
  return vis;
}
const HIDDEN = vec4f(0.0, 0.0, 2.0, 1.0); // z=2 -> clipped

// ---- chart: flat-colour triangles (chart.vert/frag) -----------------------
struct ChartIn {
  @location(0) world: vec2f,
  @location(1) local: vec2f,
  @location(2) scamin: f32,
  @location(3) packed: vec2u,   // disp_cat, map_align
  @location(4) color: vec4f,
  @location(5) depth: f32,
}
struct ChartOut { @builtin(position) pos: vec4f, @location(0) color: vec4f }

@vertex fn chart_vs(in: ChartIn) -> ChartOut {
  // Longitude is cyclic: draw this vertex at the world instance nearest the
  // camera, so a view straddling the antimeridian is seamless.
  let world = vec2f(in.world.x + round(u.wrap_x - in.world.x), in.world.y);
  var clip = u.mvp * vec4f(world, 0.0, 1.0);
  var local = in.local;
  if in.packed.y != 0u { local = rotate_local(local); }
  clip = vec4f(clip.xy + local * u.px_to_clip * u.size_scale * clip.w,
               in.depth * clip.w, clip.w);
  var out: ChartOut;
  out.pos = select(HIDDEN, clip, visible(in.packed.x, in.scamin));
  out.color = in.color;
  return out;
}
@fragment fn chart_fs(in: ChartOut) -> @location(0) vec4f { return in.color; }

// ---- pattern: area fill tiled from a cell (pattern.vert/frag) -------------
struct PatOut { @builtin(position) pos: vec4f }

@vertex fn pattern_vs(in: ChartIn) -> PatOut {
  let world = vec2f(in.world.x + round(u.wrap_x - in.world.x), in.world.y);
  var clip = u.mvp * vec4f(world, 0.0, 1.0);
  clip = vec4f(clip.xy, in.depth * clip.w, clip.w);
  var out: PatOut;
  out.pos = select(HIDDEN, clip, visible(in.packed.x, in.scamin));
  return out;
}
@fragment fn pattern_fs(in: PatOut) -> @location(0) vec4f {
  // Phase = (fragment - world-origin) / cell, both framebuffer px, so the
  // pattern rides the chart under a pan instead of swimming across it.
  let sz = max(u.cell_px, vec2f(1.0));
  let uv = fract((in.pos.xy - u.anchor_px) / sz);
  let c = textureSample(tex, samp, uv);
  if c.a < 0.02 { discard; }
  return c;
}

// ---- textured quads: sprites and SDF text (sprite.vert, sprite/sdf.frag) --
struct QuadIn {
  @location(0) world: vec2f,
  @location(1) local: vec2f,
  @location(2) uv: vec2f,
  @location(3) color: vec4f,
  @location(4) weight: f32,
  @location(5) scamin: f32,
  @location(6) packed: vec4u,   // disp_cat, map_align, flip, tangent_q
  @location(7) depth: f32,
}
struct QuadOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
  @location(1) color: vec4f,
  @location(2) weight: f32,
}

@vertex fn quad_vs(in: QuadIn) -> QuadOut {
  let tangent = f32(in.packed.w) / 256.0 * 6.283185307179586;
  let world = vec2f(in.world.x + round(u.wrap_x - in.world.x), in.world.y);
  var clip = u.mvp * vec4f(world, 0.0, 1.0);
  var local = in.local;
  // Keep a tangent-rotated run (a depth-contour value) upright: if the run,
  // once the view rotation is added, would read into the screen's left
  // half-plane, turn it 180 degrees about the anchor.
  if in.packed.z != 0u && (cos(tangent) * u.rot_cos - sin(tangent) * u.rot_sin) < 0.0 {
    local = -local;
  }
  if in.packed.y != 0u { local = rotate_local(local); }
  clip = vec4f(clip.xy + local * u.px_to_clip * u.size_scale * clip.w,
               in.depth * clip.w, clip.w);
  var out: QuadOut;
  out.pos = select(HIDDEN, clip, visible(in.packed.x, in.scamin));
  out.uv = in.uv;
  out.color = in.color;
  out.weight = in.weight;
  return out;
}
@fragment fn sprite_fs(in: QuadOut) -> @location(0) vec4f {
  let c = textureSample(tex, samp, in.uv) * in.color;
  if c.a < (1.0 / 255.0) { discard; }
  return c;
}
@fragment fn sdf_fs(in: QuadOut) -> @location(0) vec4f {
  let d = textureSample(tex, samp, in.uv).r;
  let w = fwidth(d);
  let a = smoothstep(0.5 - w, 0.5 + w, d);
  if in.weight > 0.0 {
    let halo_a = smoothstep(0.5 - in.weight - w, 0.5 - in.weight + w, d);
    let cov = max(a, halo_a);
    if cov <= 0.0 { discard; }
    let col = mix(u.color.rgb, in.color.rgb, a);
    return vec4f(col, cov * in.color.a);
  }
  if a <= 0.0 { discard; }
  return vec4f(in.color.rgb, in.color.a * a);
}
`;

// tile57_gpu_vertex (32 B) — see chart.vert's layout comment.
const VERTEX_LAYOUT = {
  arrayStride: 32,
  attributes: [
    { shaderLocation: 0, offset: 0, format: "float32x2" },
    { shaderLocation: 1, offset: 8, format: "float32x2" },
    { shaderLocation: 2, offset: 16, format: "float32" },
    { shaderLocation: 3, offset: 20, format: "uint8x2" },
    { shaderLocation: 4, offset: 24, format: "unorm8x4" },
    { shaderLocation: 5, offset: 28, format: "float32" },
  ],
};
// tile57_gpu_quad (44 B) — see sprite.vert's layout comment.
const QUAD_LAYOUT = {
  arrayStride: 44,
  attributes: [
    { shaderLocation: 0, offset: 0, format: "float32x2" },
    { shaderLocation: 1, offset: 8, format: "float32x2" },
    { shaderLocation: 2, offset: 16, format: "float32x2" },
    { shaderLocation: 3, offset: 24, format: "unorm8x4" },
    { shaderLocation: 4, offset: 28, format: "float32" },
    { shaderLocation: 5, offset: 32, format: "float32" },
    { shaderLocation: 6, offset: 36, format: "uint8x4" },
    { shaderLocation: 7, offset: 40, format: "float32" },
  ],
};

const BLEND = {
  color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
  alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
};

export const lonLatToWorld = (lon, lat) => {
  const r = (lat * Math.PI) / 180;
  return [(lon + 180) / 360, (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2];
};
export const worldToLonLat = (x, y) => [
  x * 360 - 180,
  (180 / Math.PI) * Math.atan(Math.sinh(Math.PI * (1 - 2 * y))),
];

// The engine's zoom -> 1:N convention (render/resolve.zig DENOM_Z0), the value
// the shaders test against per-vertex SCAMIN.
export const scaleDenom = (zoom) => 279541132 / 2 ** zoom;

async function texFromPng(device, png) {
  const bmp = await createImageBitmap(new Blob([png], { type: "image/png" }));
  const tex = device.createTexture({
    size: [bmp.width, bmp.height],
    format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
  });
  device.queue.copyExternalImageToTexture({ source: bmp }, { texture: tex }, [bmp.width, bmp.height]);
  bmp.close();
  return tex;
}

// The active palette's NODTA (no-data) colour: the SDF halo background and the
// clear colour. The colortables JSON is {tables:{DAY:{NODTA:[r,g,b],...},...}}
// -shaped; walk it tolerantly and fall back to the S-52 day value.
function nodataColor(colortablesJson, scheme = "DAY") {
  try {
    const root = JSON.parse(colortablesJson);
    const walk = (o) => {
      if (!o || typeof o !== "object") return null;
      for (const [k, v] of Object.entries(o)) {
        if (k.toUpperCase() === "NODTA") {
          if (Array.isArray(v) && v.length >= 3) return [v[0] / 255, v[1] / 255, v[2] / 255, 1];
          if (typeof v === "string" && v[0] === "#")
            return [1, 3, 5].map((i) => parseInt(v.slice(i, i + 2), 16) / 255).concat(1);
        }
      }
      for (const [k, v] of Object.entries(o)) {
        if (k.toUpperCase().includes(scheme)) { const c = walk(v); if (c) return c; }
      }
      for (const v of Object.values(o)) { const c = walk(v); if (c) return c; }
      return null;
    };
    const c = walk(root);
    if (c) return c;
  } catch { /* fall through */ }
  return [163 / 255, 180 / 255, 183 / 255, 1]; // S-52 day NODTA
}

export class GpuRenderer {
  static supported() { return typeof navigator !== "undefined" && !!navigator.gpu; }

  /** Build the device, pipelines, and atlas textures from the engine's
   * gpuAssets. `pixelRatio` must match the pixel ratio the assets were baked
   * at AND every later gpu-scene call, or the sprite UVs will not index the
   * atlas. */
  static async create(canvas, pixelRatio, assets) {
    const l = assets.layout;
    if (l.vertex !== 32 || l.quad !== 44 || l.range !== 24 || l.uniforms !== 128)
      throw new Error(`gpu ABI skew: engine says vertex=${l.vertex} quad=${l.quad} range=${l.range} uniforms=${l.uniforms}`);

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) throw new Error("WebGPU: no adapter");
    const device = await adapter.requestDevice();
    const r = new GpuRenderer();
    r.device = device;
    r.canvas = canvas;
    r.pixelRatio = pixelRatio;
    r.format = navigator.gpu.getPreferredCanvasFormat();
    r.context = canvas.getContext("webgpu");
    r.context.configure({ device, format: r.format, alphaMode: "opaque" });

    const module = device.createShaderModule({ code: WGSL });
    r.bgl = device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: "uniform", hasDynamicOffset: true } },
        { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
        { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: {} },
      ],
    });
    const layout = device.createPipelineLayout({ bindGroupLayouts: [r.bgl] });
    const pipeline = (vs, fs, buffers) =>
      device.createRenderPipeline({
        layout,
        vertex: { module, entryPoint: vs, buffers },
        fragment: { module, entryPoint: fs, targets: [{ format: r.format, blend: BLEND }] },
        primitive: { topology: "triangle-list" },
        multisample: { count: 4 },
      });
    r.pipelines = [
      pipeline("chart_vs", "chart_fs", [VERTEX_LAYOUT]),
      pipeline("pattern_vs", "pattern_fs", [VERTEX_LAYOUT]),
      pipeline("quad_vs", "sprite_fs", [QUAD_LAYOUT]),
      pipeline("quad_vs", "sdf_fs", [QUAD_LAYOUT]),
    ];
    r.sampler = device.createSampler({ magFilter: "linear", minFilter: "linear", addressModeU: "repeat", addressModeV: "repeat" });
    r.dummyTex = device.createTexture({ size: [1, 1], format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });

    // The four atlases, baked once by the engine at this density.
    r.atlases = new Array(5).fill(null);
    r.atlases[ATLAS.SPRITE] = await texFromPng(device, assets.spritePng);
    r.atlases[ATLAS.GLYPH] = await texFromPng(device, assets.glyphPng);
    r.atlases[ATLAS.GLYPH_BOLD] = await texFromPng(device, assets.glyphBoldPng);
    r.atlases[ATLAS.GLYPH_ITALIC] = await texFromPng(device, assets.glyphItalicPng);
    r.atlasHave = (1 << ATLAS.SPRITE) | (1 << ATLAS.GLYPH) | (1 << ATLAS.GLYPH_BOLD) | (1 << ATLAS.GLYPH_ITALIC);
    r.halo = nodataColor(assets.colortables);
    r.msaa = null;
    r.buffers = null;
    r.draws = [];
    return r;
  }

  // Upload one buffer (padded to 4 bytes) or null when empty.
  upload(bytes, usage) {
    if (bytes.length === 0) return null;
    const buf = this.device.createBuffer({ size: Math.ceil(bytes.length / 4) * 4, usage: usage | GPUBufferUsage.COPY_DST });
    this.device.queue.writeBuffer(buf, 0, bytes);
    return buf;
  }

  /** Upload one scene's draw-ready data (the engine-worker's gpuScene op):
   * the three buffers, the pattern cells, and the batched draw list. */
  setScene({ vertex, index, quad, patterns, draws }) {
    this.disposeScene();
    this.buffers = {
      vertex: this.upload(vertex, GPUBufferUsage.VERTEX),
      index: this.upload(index, GPUBufferUsage.INDEX),
      quad: this.upload(quad, GPUBufferUsage.VERTEX),
    };
    this.patternTex = patterns.map(({ w, h, rgba }) => {
      if (!w || !h) return null; // a cell that never rasterized: drop its draws
      const tex = this.device.createTexture({ size: [w, h], format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
      this.device.queue.writeTexture({ texture: tex }, rgba, { bytesPerRow: w * 4 }, [w, h]);
      return tex;
    });
    this.draws = draws;

    // One uniform slot per draw; one bind group per distinct texture.
    const n = Math.max(1, this.draws.length);
    this.uniforms = this.device.createBuffer({ size: n * UNIFORM_SLOT, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    const groups = new Map();
    this.bindGroup = (tex) => {
      let g = groups.get(tex);
      if (!g) {
        g = this.device.createBindGroup({
          layout: this.bgl,
          entries: [
            { binding: 0, resource: { buffer: this.uniforms, size: 128 } },
            { binding: 1, resource: this.sampler },
            { binding: 2, resource: tex.createView() },
          ],
        });
        groups.set(tex, g);
      }
      return g;
    };
  }

  disposeScene() {
    if (this.buffers) for (const b of Object.values(this.buffers)) b?.destroy();
    if (this.patternTex) for (const p of this.patternTex) p?.destroy();
    this.uniforms?.destroy();
    this.buffers = null;
    this.draws = [];
  }

  drawTexture(d) {
    if (d.pipeline === PIPE.PATTERN) return this.patternTex[d.pattern] ?? null;
    if (d.pipeline === PIPE.SPRITE || d.pipeline === PIPE.SDF) return this.atlases[d.atlas] ?? null;
    return this.dummyTex;
  }

  /** Redraw the uploaded scene for `cam` ({lon, lat, zoom}). Geometry is
   * world-anchored, so any camera renders correctly — a pan or zoom between
   * scene rebuilds is just new uniforms. */
  draw(cam) {
    const w = this.canvas.width, h = this.canvas.height;
    if (!this.msaa || this.msaa.width !== w || this.msaa.height !== h) {
      this.msaa?.destroy();
      this.msaa = this.device.createTexture({ size: [w, h], format: this.format, sampleCount: 4, usage: GPUTextureUsage.RENDER_ATTACHMENT });
    }

    const S = 256 * 2 ** cam.zoom * this.pixelRatio; // framebuffer px per world unit
    const [cx, cy] = lonLatToWorld(cam.lon, cam.lat);
    const sx = (S * 2) / w, sy = (-S * 2) / h;
    const slots = new ArrayBuffer(Math.max(1, this.draws.length) * UNIFORM_SLOT);
    for (let i = 0; i < this.draws.length; i++) {
      const d = this.draws[i];
      const f = new Float32Array(slots, i * UNIFORM_SLOT, 32);
      const u = new Uint32Array(slots, i * UNIFORM_SLOT, 32);
      f.set([sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, 0, 0, -cx * sx, -cy * sy, 0, 1]); // mvp
      f[16] = 2 / w; f[17] = -2 / h;         // px_to_clip
      f[18] = this.pixelRatio;               // size_scale
      f[19] = scaleDenom(cam.zoom);          // current_scale
      u[20] = 7 | d.catMaskOr;               // cat_mask
      f[21] = cx;                            // wrap_x
      f[22] = 0; f[23] = 1;                  // rot_sin, rot_cos (north-up)
      f[24] = d.color[0]; f[25] = d.color[1]; f[26] = d.color[2]; f[27] = d.color[3];
      if (d.pipeline === PIPE.PATTERN) {
        const tex = this.patternTex[d.pattern];
        if (tex) {
          // Phase origin = world (0,0) in framebuffer px, reduced mod the cell
          // so f32 keeps the phase exact far from the origin.
          const ox = -cx * S + w / 2, oy = -cy * S + h / 2;
          f[28] = ((ox % tex.width) + tex.width) % tex.width;
          f[29] = ((oy % tex.height) + tex.height) % tex.height;
          f[30] = tex.width; f[31] = tex.height; // cell_px
        }
      }
    }
    this.device.queue.writeBuffer(this.uniforms, 0, slots);

    const enc = this.device.createCommandEncoder();
    const [br, bg, bb] = this.halo;
    const pass = enc.beginRenderPass({
      colorAttachments: [{
        view: this.msaa.createView(),
        resolveTarget: this.context.getCurrentTexture().createView(),
        loadOp: "clear",
        clearValue: { r: br, g: bg, b: bb, a: 1 },
        storeOp: "discard",
      }],
    });
    for (let i = 0; i < this.draws.length; i++) {
      const d = this.draws[i];
      const tex = this.drawTexture(d);
      if (!tex) continue;
      pass.setPipeline(this.pipelines[d.pipeline]);
      pass.setBindGroup(0, this.bindGroup(tex), [i * UNIFORM_SLOT]);
      if (d.prim === 0) { // TRIANGLES: first/count index the index buffer
        if (!this.buffers?.vertex || !this.buffers?.index) continue;
        pass.setVertexBuffer(0, this.buffers.vertex);
        pass.setIndexBuffer(this.buffers.index, "uint32");
        pass.drawIndexed(d.count, 1, d.first);
      } else { // QUADS: first/count are quad-buffer vertices
        if (!this.buffers?.quad) continue;
        pass.setVertexBuffer(0, this.buffers.quad);
        pass.draw(d.count, 1, d.first);
      }
    }
    pass.end();
    this.device.queue.submit([enc.finish()]);
  }
}
