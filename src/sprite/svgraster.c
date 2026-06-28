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

void tg_svg_free(void *p) { free(p); }
