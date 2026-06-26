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


def build(pmtiles_path, palette, scheme):
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

    return {
        "version": 8,
        "name": f"chartplotter-native ({scheme}, M1)",
        "sources": {"chart": {"type": "vector", "url": src_url}},
        "layers": layers,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pmtiles", required=True)
    ap.add_argument("--colortables", required=True)
    ap.add_argument("--scheme", default="day", choices=["day", "dusk", "night"])
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    palette = json.load(open(a.colortables))[a.scheme]
    style = build(a.pmtiles, palette, a.scheme)
    with open(a.out, "w") as f:
        json.dump(style, f, indent=1)
    print(f"wrote {a.out}: {len(style['layers'])} layers, source -> {style['sources']['chart']['url']}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
