#!/usr/bin/env python3
"""Pre-expand the Go-emitted symbol atlas into a MapLibre-format sprite sheet.

The Go `emit-assets` sprite.json uses {x,y,w,h,pivot_x,pivot_y} and the web app
registers each symbol at runtime as a PIVOT-CENTRED image (MapLibre always draws
an icon centred on the point, so the S-52 pivot must be moved to the image
centre). MapLibre Native has no such runtime step, so we bake the centred images
into a real sprite sheet here (port of SpriteBuilder.centredSymbol).

Output: <out>.png + <out>.json (MapLibre sprite format: {x,y,width,height,
pixelRatio}). Symbol ids keep their bare S-52 names; a "ctr:"-prefixed copy
(glyph centred on its bounding box, pivot ignored) is added for the pivot_center
area-symbol case.

Usage: build_sprite.py --sprite reference/assets/sprite.json -o reference/assets/sprite-mln
"""
import argparse, json, math, os
from PIL import Image


def centred(cell, img, by_pivot=True):
    x, y, w, h = cell["x"], cell["y"], cell["w"], cell["h"]
    sub = img.crop((x, y, x + w, y + h))
    if not by_pivot:
        return sub  # raw cell; MapLibre centres the bbox on the point
    px, py = cell.get("pivot_x", w / 2), cell.get("pivot_y", h / 2)
    halfW = max(px, w - px)
    halfH = max(py, h - py)
    W = max(1, math.ceil(2 * halfW))
    H = max(1, math.ceil(2 * halfH))
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    canvas.paste(sub, (round(W / 2 - px), round(H / 2 - py)))
    return canvas


def pack(images, pad=1, atlas_w=2048):
    """Simple shelf packing. images: list of (id, PIL.Image). Returns (atlas, meta)."""
    items = sorted(images, key=lambda it: it[1].height, reverse=True)
    x = y = row_h = 0
    placed = {}
    for iid, im in items:
        w, h = im.width, im.height
        if x + w + pad > atlas_w:
            x = 0
            y += row_h + pad
            row_h = 0
        placed[iid] = (x, y, im)
        x += w + pad
        row_h = max(row_h, h)
    atlas_h = y + row_h + pad
    # round up to a power-of-two-ish height (not required, just tidy)
    atlas = Image.new("RGBA", (atlas_w, max(1, atlas_h)), (0, 0, 0, 0))
    meta = {}
    for iid, (px, py, im) in placed.items():
        atlas.paste(im, (px, py))
        meta[iid] = {"x": px, "y": py, "width": im.width, "height": im.height, "pixelRatio": 1}
    return atlas, meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sprite", required=True, help="emitted sprite.json (png alongside)")
    ap.add_argument("-o", "--out", required=True, help="output base path (writes .png + .json)")
    ap.add_argument("--ctr", action="store_true", default=True,
                    help="also emit ctr:<name> bbox-centred variants")
    a = ap.parse_args()

    sj = json.load(open(a.sprite))
    png = os.path.join(os.path.dirname(a.sprite), "sprite.png")
    img = Image.open(png).convert("RGBA")

    images = []
    for name, cell in sj.items():
        if name == "_meta" or not isinstance(cell, dict) or "w" not in cell:
            continue
        images.append((name, centred(cell, img, by_pivot=True)))
        if a.ctr:
            images.append(("ctr:" + name, centred(cell, img, by_pivot=False)))

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    atlas, meta = pack(images)

    # MapLibre requests @2x when the map pixel ratio is high (retina / desktop
    # HiDPI), so an @2x sheet must exist or the WHOLE sprite fails to load. We
    # emit @2x as an identical copy (pixelRatio 1): correct physical size on
    # retina, just not extra-crisp. A true 2x sheet needs the Go pipeline to
    # rasterise the symbol SVGs at 2x (some centred symbols already exceed
    # MapLibre's 1024px image limit when naively upscaled).
    for suffix in ("", "@2x"):
        out = a.out + suffix
        atlas.save(out + ".png")
        with open(out + ".json", "w") as f:
            json.dump(meta, f)
    print(f"wrote {a.out}(.png/.json) + @2x ({atlas.width}x{atlas.height}, {len(meta)} images)")


if __name__ == "__main__":
    main()
