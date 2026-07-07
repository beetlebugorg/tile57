// C glue for the S-101 sprite/pattern atlas: nanosvg (parse + AA rasterize) and
// stb_image_write (PNG encode), behind a tiny C ABI the Zig side calls. The Zig
// side does the CSS flatten / viewBox normalization (sprite.zig) and hands us a
// self-contained, viewBox-"0 0 W H" SVG; we only rasterize + PNG-encode.
//
// Vendored single headers: vendor/nanosvg (zlib license), vendor/stb (public
// domain). They need libc (malloc/memcpy/math/sscanf) — the same requirement
// Lua already imposes on the bake tool, so no new dependency class.

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#define NANOSVG_ALL_COLOR_KEYWORDS
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

// One glyph's signed-distance field for the SDF text atlas. `font`/`font_len` is
// the TrueType file; `cp` a codepoint; `em_px` the pixels one em maps to (the
// field resolution); `pad` the SDF spread in px. Returns a malloc'd single-channel
// SDF bitmap (w*h, 128 = edge, >128 inside) and sets its size, the top-left pixel
// offset from the pen origin (y down), and the pen advance — all in `em_px` units,
// so the caller normalizes by em_px to get size-independent (em) metrics. NULL for
// blank glyphs (space): *w=*h=0 but *advance is still set. Free with tg_glyph_free.
unsigned char *tg_glyph_sdf(const unsigned char *font, int font_len, int cp,
                            float em_px, int pad, int *w, int *h,
                            int *xoff, int *yoff, float *advance) {
    (void)font_len;
    stbtt_fontinfo f;
    if (!stbtt_InitFont(&f, font, stbtt_GetFontOffsetForIndex(font, 0))) return NULL;
    float scale = stbtt_ScaleForMappingEmToPixels(&f, em_px);
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f, cp, &adv, &lsb);
    *advance = (float)adv * scale;
    unsigned char onedge = 128;
    float dist_scale = 127.0f / (float)pad; // ±pad px -> the byte range
    *w = 0; *h = 0; *xoff = 0; *yoff = 0;
    return stbtt_GetCodepointSDF(&f, scale, cp, pad, onedge, dist_scale, w, h, xoff, yoff);
}
void tg_glyph_free(unsigned char *p) { stbtt_FreeSDF(p, NULL); }

// Rasterize a flattened SVG (viewBox normalized to "0 0 W H") at `scale` device
// px per user unit. Forces even-odd winding on every shape — the S-101 danger
// glyphs are compound paths whose inner subpath is a hole, and nonzero winding
// fills it solid (matches the Go oracle's symbols.Render). `svg` must be a
// NUL-terminated, writable buffer (nsvgParse mutates it). Returns malloc'd
// straight-alpha RGBA8 (w*h*4) and sets *out_w/*out_h; NULL on error. Free with
// tg_svg_free.
unsigned char *tg_svg_rasterize(char *svg, float scale, int *out_w, int *out_h) {
    NSVGimage *img = nsvgParse(svg, "px", 96.0f);
    if (!img) return NULL;
    for (NSVGshape *s = img->shapes; s; s = s->next) s->fillRule = NSVG_FILLRULE_EVENODD;
    int w = (int)ceilf(img->width * scale);
    int h = (int)ceilf(img->height * scale);
    if (w < 1 || h < 1) { nsvgDelete(img); return NULL; }
    unsigned char *dst = (unsigned char *)calloc((size_t)w * (size_t)h * 4u, 1);
    if (!dst) { nsvgDelete(img); return NULL; }
    NSVGrasterizer *r = nsvgCreateRasterizer();
    nsvgRasterize(r, img, 0.0f, 0.0f, scale, dst, w, h, w * 4);
    nsvgDeleteRasterizer(r);
    nsvgDelete(img);
    *out_w = w;
    *out_h = h;
    return dst;
}

struct png_buf { unsigned char *data; int len; int cap; };

static void png_cb(void *ctx, void *data, int size) {
    struct png_buf *b = (struct png_buf *)ctx;
    if (b->len + size > b->cap) {
        int nc = b->cap * 2;
        if (nc < b->len + size) nc = b->len + size;
        b->data = (unsigned char *)realloc(b->data, (size_t)nc);
        b->cap = nc;
    }
    memcpy(b->data + b->len, data, (size_t)size);
    b->len += size;
}

// Encode straight-alpha RGBA8 (w*h*4) as a PNG. Returns malloc'd bytes and sets
// *out_len; NULL on error. Free with tg_svg_free.
unsigned char *tg_png_encode(const unsigned char *rgba, int w, int h, int *out_len) {
    struct png_buf b = {NULL, 0, 0};
    if (!stbi_write_png_to_func(png_cb, &b, w, h, 4, rgba, w * 4)) {
        free(b.data);
        return NULL;
    }
    *out_len = b.len;
    return b.data;
}

// Parse a flattened SVG (viewBox-normalized, like tg_svg_rasterize's input) and
// serialize its shapes as an f32 stream for the Zig side — the PARSE half of
// nanosvg, split from rasterization so the render engine can replay symbol
// geometry as vector paths on its own canvases (raster tile, PDF) instead of
// blitting pre-rasterized bitmaps. Stream grammar, all f32:
//
//   per shape:  1.0,
//               fill?(0/1),  fr, fg, fb, fa,          (0..255)
//               stroke?(0/1), sr, sg, sb, sa, stroke_width,
//     per path: 2.0, npts, closed?(0/1), x0,y0, cp1x,cp1y,cp2x,cp2y,x1,y1, ...
//   end:        0.0
//
// Path points are nanosvg's cubic-bezier runs (npts = 1 + 3n), in the SVG's
// user units (mm for the S-101 catalogue). Coordinates are untransformed —
// nanosvg has already applied the document transforms. Returns a malloc'd f32
// buffer (count in *out_n); free with tg_svg_free. NULL on parse error.
float *tg_svg_parse_paths(char *svg, int *out_n) {
    NSVGimage *img = nsvgParse(svg, "px", 96.0f);
    if (!img) return NULL;

    /* size pass: 12 floats per shape header (marker, fill flag + rgba,
     * stroke flag + rgba + width), 3 + npts*2 per path */
    size_t n = 1; /* end marker */
    for (NSVGshape *s = img->shapes; s; s = s->next) {
        if (!(s->flags & NSVG_FLAGS_VISIBLE)) continue;
        n += 12;
        for (NSVGpath *p = s->paths; p; p = p->next) n += 3 + (size_t)p->npts * 2;
    }
    float *buf = (float *)malloc(n * sizeof(float));
    if (!buf) { nsvgDelete(img); return NULL; }

    size_t i = 0;
    for (NSVGshape *s = img->shapes; s; s = s->next) {
        if (!(s->flags & NSVG_FLAGS_VISIBLE)) continue;
        buf[i++] = 1.0f;
        /* nanosvg colors are 0xAABBGGRR; opacity multiplies alpha */
        unsigned fc = s->fill.color, sc = s->stroke.color;
        int has_fill = s->fill.type == NSVG_PAINT_COLOR;
        int has_stroke = s->stroke.type == NSVG_PAINT_COLOR && s->strokeWidth > 0;
        buf[i++] = has_fill ? 1.0f : 0.0f;
        buf[i++] = (float)(fc & 0xff);
        buf[i++] = (float)((fc >> 8) & 0xff);
        buf[i++] = (float)((fc >> 16) & 0xff);
        buf[i++] = has_fill ? (float)((fc >> 24) & 0xff) * s->opacity : 0.0f;
        buf[i++] = has_stroke ? 1.0f : 0.0f;
        buf[i++] = (float)(sc & 0xff);
        buf[i++] = (float)((sc >> 8) & 0xff);
        buf[i++] = (float)((sc >> 16) & 0xff);
        buf[i++] = has_stroke ? (float)((sc >> 24) & 0xff) * s->opacity : 0.0f;
        buf[i++] = s->strokeWidth;
        for (NSVGpath *p = s->paths; p; p = p->next) {
            buf[i++] = 2.0f;
            buf[i++] = (float)p->npts;
            buf[i++] = p->closed ? 1.0f : 0.0f;
            memcpy(buf + i, p->pts, (size_t)p->npts * 2 * sizeof(float));
            i += (size_t)p->npts * 2;
        }
    }
    buf[i++] = 0.0f;
    nsvgDelete(img);
    *out_n = (int)i;
    return buf;
}

void tg_svg_free(void *p) { free(p); }
