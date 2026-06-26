#!/usr/bin/env python3
"""Generate a minimal static MapLibre style.json for the chartplotter-native M1
milestone: render a Go-baked PMTiles chart archive (areas + lines) with the S-52
day palette resolved client-side from color tokens.

This is a faithful, minimal port of the web frontend's chart-style.mjs /
s52-style.mjs (areasFillColor + the line layers) with default mariner contours.
Symbols, soundings, text, patterns (which need sprites/glyphs) come at M2.

Usage:
  build_style.py --pmtiles /abs/path.pmtiles --colortables reference/assets/colortables.json \
                 --scheme day -o style/chart-day.json
"""
import argparse, json, os, sys

FALLBACK = "#ff00ff"

# Default mariner depth contours (S-52): shallow=2, safety=10, deep=30 m.
SHC, SFC, DPC = 2, 10, 30


def color_match(token_expr, palette, fallback=FALLBACK):
    """["match", token_expr, TOK, hex, ..., fallback] — resolve an S-52 color
    token expression to an RGB hex for this palette."""
    m = ["match", token_expr]
    for tok, hexv in palette.items():
        m += [tok, hexv]
    m.append(fallback)
    return m


def color_expr(prop, palette, fallback=FALLBACK):
    return color_match(["coalesce", ["get", prop], ""], palette, fallback)


def seabed_token_expr():
    """SEABED01 (S-52 §13.2.15): depth area DRVAL1/DRVAL2 vs contours -> token.
    Four-shade water, deepest band first (case: first match wins)."""
    d1 = ["coalesce", ["get", "drval1"], -1]
    d2 = ["coalesce", ["get", "drval2"], 0]
    band = lambda x: ["all", [">=", d1, x], [">", d2, x]]
    return ["case",
            band(DPC), "DEPDW",
            band(SFC), "DEPMD",
            band(SHC), "DEPMS",
            band(0), "DEPVS",
            "DEPIT"]


def areas_fill_color(palette):
    """Depth areas (carry drval1) shade via SEABED01; everything else uses its
    baked color_token."""
    return ["case",
            ["has", "drval1"], color_match(seabed_token_expr(), palette, FALLBACK),
            color_expr("color_token", palette, FALLBACK)]


def line_paint(palette, dash=None):
    p = {"line-color": color_expr("color_token", palette),
         "line-width": ["coalesce", ["get", "width_px"], 1]}
    if dash:
        p["line-dasharray"] = dash
    return p


FONT = ["Noto Sans Regular"]

# Sprite atlas pixels-per-unit (sprite.json _meta.px_per_unit). icon-size =
# feature scale / atlasPpu (so scale==atlasPpu -> size 1).
ATLAS_PPU = 0.08


def point_symbol_image():
    """OBSTRN/WRECKS danger swap (sym_deep when deeper than safety contour) +
    pivot_center 'ctr:' variant. Port of s52-style.mjs pointSymbolImage with
    default safety contour."""
    name = ["case",
            ["all", ["has", "sym_deep"], [">", ["coalesce", ["get", "danger_depth"], 0], SFC]],
            ["get", "sym_deep"],
            ["get", "symbol_name"]]
    return ["case",
            ["==", ["coalesce", ["get", "pivot_center"], 0], 1],
            ["concat", "ctr:", name],
            name]


def icon_size():
    return ["/", ["coalesce", ["get", "scale"], ATLAS_PPU], ATLAS_PPU]


SAFETY_DEPTH = 10  # mariner default; soundings <= this use the bold (S) glyphs


def soundings_image():
    """SNDFRM04: depth <= safety depth uses bold sym_s, else faint sym_g; older
    tiles fall back to symbol_names. Port of s52-style.mjs soundingsIconImage
    (metric). The names are pre-composited into the sprite by build_sprite.py."""
    return ["case",
            ["has", "sym_s"],
            ["case", ["<=", ["coalesce", ["get", "depth"], 0], SAFETY_DEPTH],
             ["get", "sym_s"], ["get", "sym_g"]],
            ["get", "symbol_names"]]


def point_symbol_layers():
    """Point symbols (buoys/beacons/lights/...). Split by rotation reference:
    screen-up (viewport) vs true-north (map), per S-52 ROT."""
    common = {
        "icon-image": point_symbol_image(), "icon-size": icon_size(),
        "icon-rotate": ["coalesce", ["get", "rotation_deg"], 0],
        "icon-allow-overlap": True, "icon-ignore-placement": True, "symbol-z-order": "source",
    }
    return [
        {"id": "point_symbols", "type": "symbol", "source": "chart", "source-layer": "point_symbols",
         "filter": ["!=", ["coalesce", ["get", "rot_north"], 0], 1],
         "layout": {**common, "icon-rotation-alignment": "viewport"}},
        {"id": "point_symbols-north", "type": "symbol", "source": "chart", "source-layer": "point_symbols",
         "filter": ["==", ["coalesce", ["get", "rot_north"], 0], 1],
         "layout": {**common, "icon-rotation-alignment": "map"}},
    ]

# S-52 halign/valign -> data-driven MapLibre text-anchor (port of chart-style.mjs).
_VROW = ["match", ["coalesce", ["get", "valign"], "middle"], "top", "top", "bottom", "bottom", "center"]
TEXT_ANCHOR = ["match", ["concat", _VROW, "|", ["coalesce", ["get", "halign"], "center"]],
               "center|left", "left", "center|right", "right", "center|center", "center",
               "top|center", "top", "bottom|center", "bottom",
               "top|left", "top-left", "top|right", "top-right",
               "bottom|left", "bottom-left", "bottom|right", "bottom-right",
               "center"]

# Collision priority: lower sort-key placed first = wins. Rank by text group
# (tgrp), then larger font wins within a tier.
TEXT_SORT_KEY = ["-",
                 ["match", ["coalesce", ["get", "tgrp"], -1],
                  11, 0, [21, 26, 29], 100, 23, 50, 150],
                 ["coalesce", ["get", "font_size_px"], 10]]


def text_color(scheme, palette):
    if scheme == "day":
        return color_expr("color_token", palette, "#000000")
    return "#aab7bf" if scheme == "night" else "#dde7ec"


def text_halo_color(scheme):
    return "rgba(255,255,255,0.9)" if scheme == "day" else "rgba(0,0,0,0.85)"


def text_layers(palette, scheme):
    """General collidable text + an always-on LIGHTS characteristic layer
    (port of chart-style.mjs textLayers + light-text). Mariner text-group
    filtering is omitted at M2 (all groups shown)."""
    halo = {"text-halo-color": text_halo_color(scheme), "text-halo-width": 1.4, "text-halo-blur": 0.5}
    return [
        {"id": "light-text", "type": "symbol", "source": "chart", "source-layer": "text",
         "filter": ["==", ["get", "class"], "LIGHTS"],
         "layout": {
             "text-field": ["coalesce", ["get", "text"], ""], "text-font": FONT,
             "text-size": ["coalesce", ["get", "font_size_px"], 10],
             "text-anchor": "top", "text-offset": [0, 0.4], "text-justify": "left",
             "symbol-sort-key": ["-", 0, ["coalesce", ["get", "font_size_px"], 10]],
             "text-allow-overlap": False, "text-optional": True},
         "paint": {"text-color": text_color(scheme, palette), **halo}},
        {"id": "text", "type": "symbol", "source": "chart", "source-layer": "text",
         "filter": ["!=", ["get", "class"], "LIGHTS"],
         "layout": {
             "text-field": ["coalesce", ["get", "text"], ""], "text-font": FONT,
             "text-size": ["coalesce", ["get", "font_size_px"], 11],
             "text-anchor": TEXT_ANCHOR, "symbol-sort-key": TEXT_SORT_KEY,
             "text-allow-overlap": False, "text-optional": True},
         "paint": {"text-color": text_color(scheme, palette), **halo}},
    ]


def build(pmtiles_path, palette, scheme, glyphs_dir=None, sprite_base=None,
          source_tiles=None, minzoom=0, maxzoom=16):
    sea = palette.get("DEPDW", "#93aebb")
    src_url = "pmtiles://file://" + os.path.abspath(pmtiles_path)

    layers = [
        {"id": "background", "type": "background", "paint": {"background-color": sea}},
    ]

    # areas fill + its SCAMIN clone. (SCAMIN gating omitted at M1 — both shown.)
    for sl in ("areas", "areas_scamin"):
        layers.append({
            "id": "fill-" + sl, "type": "fill", "source": "chart", "source-layer": sl,
            "paint": {"fill-color": areas_fill_color(palette), "fill-antialias": True},
        })

    # area fill patterns (sprite required): tiled DRGARE/FOUL/quality fills.
    if sprite_base:
        for sl in ("area_patterns", "area_patterns_scamin"):
            layers.append({
                "id": "fillpat-" + sl, "type": "fill", "source": "chart", "source-layer": sl,
                "paint": {"fill-pattern": ["concat", "pat:", ["coalesce", ["get", "pattern_name"], ""]]},
            })

    # lines: solid / dashed / dotted, each over base + _scamin source-layers.
    line_specs = [
        ("solid", ["==", ["coalesce", ["get", "dash"], "solid"], "solid"], None),
        ("dashed", ["==", ["get", "dash"], "dashed"], [4, 3]),
        ("dotted", ["==", ["get", "dash"], "dotted"], [1, 2]),
    ]
    for sl in ("lines", "lines_scamin"):
        for name, filt, dash in line_specs:
            layers.append({
                "id": f"{sl}-{name}", "type": "line", "source": "chart", "source-layer": sl,
                "filter": filt, "paint": line_paint(palette, dash),
            })

    # complex (symbolised) lines: baked as real geometry, drawn as solid strokes.
    for sl in ("complex_lines", "complex_lines_scamin"):
        layers.append({
            "id": "complex-" + sl, "type": "line", "source": "chart", "source-layer": sl,
            "paint": line_paint(palette),
        })

    # light sector limit lines (LIGHTS sectors): thin solid/dashed rays from the
    # light to each sector boundary. Carries color_token/width_px/dash like the
    # plain line layers, so reuse line_specs + line_paint.
    for name, filt, dash in line_specs:
        layers.append({
            "id": f"sector_lines-{name}", "type": "line", "source": "chart",
            "source-layer": "sector_lines",
            "filter": filt, "paint": line_paint(palette, dash),
        })

    # point symbols (sprite required) — above lines, below text.
    if sprite_base:
        layers += point_symbol_layers()
        # spot soundings (depth numbers), drawn as pre-composited digit glyphs.
        layers.append({
            "id": "soundings", "type": "symbol", "source": "chart", "source-layer": "soundings",
            "layout": {"icon-image": soundings_image(), "icon-size": icon_size(),
                       "icon-allow-overlap": False}})

    # text labels (glyphs required) — drawn above everything.
    layers += text_layers(palette, scheme)

    # Source: a tiles-template vector source (e.g. zigtiles://{z}/{x}/{y}, served
    # by the Zig FileSource) or, by default, the native pmtiles:// archive.
    if source_tiles:
        chart_source = {"type": "vector", "tiles": [source_tiles],
                        "minzoom": minzoom, "maxzoom": maxzoom}
    else:
        chart_source = {"type": "vector", "url": src_url}

    style = {
        "version": 8,
        "name": f"chartplotter-native ({scheme}, M2)",
        "sources": {"chart": chart_source},
        "layers": layers,
    }
    if glyphs_dir:
        style["glyphs"] = "file://" + os.path.abspath(glyphs_dir) + "/{fontstack}/{range}.pbf"
    if sprite_base:
        style["sprite"] = "file://" + os.path.abspath(sprite_base)
    return style


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pmtiles", required=True)
    ap.add_argument("--colortables", required=True)
    ap.add_argument("--scheme", default="day", choices=["day", "dusk", "night"])
    ap.add_argument("--glyphs", help="glyphs dir (…/{fontstack}/{range}.pbf); enables text")
    ap.add_argument("--sprite", help="sprite base path (…/sprite-mln, no extension); enables symbols")
    ap.add_argument("--source-tiles", help="use a tiles URL template (e.g. zigtiles://{z}/{x}/{y}) instead of pmtiles://")
    ap.add_argument("--minzoom", type=int, default=9)
    ap.add_argument("--maxzoom", type=int, default=16)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    palette = json.load(open(a.colortables))[a.scheme]
    style = build(a.pmtiles, palette, a.scheme, glyphs_dir=a.glyphs, sprite_base=a.sprite,
                  source_tiles=a.source_tiles, minzoom=a.minzoom, maxzoom=a.maxzoom)
    with open(a.out, "w") as f:
        json.dump(style, f, indent=1)
    src = style["sources"]["chart"]
    where = src.get("url") or (src.get("tiles") or [""])[0]
    print(f"wrote {a.out}: {len(style['layers'])} layers, source -> {where}", file=sys.stderr)


if __name__ == "__main__":
    main()
