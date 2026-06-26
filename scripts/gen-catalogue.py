#!/usr/bin/env python3
"""Distill the S-101 FeatureCatalogue.xml into a compact catalogue.json that the
Zig portrayal binding loads (std.json), avoiding an XML parser in Zig.

Extracts, per the Host* contract:
  - simpleAttrs:   code -> valueType (+ S-57 alias)
  - complexAttrs:  code -> [[subRef, lower, upper], ...]
  - featureTypes:  code -> {alias:[...], primitives:[...], bindings:[[ref,lo,up]]}
  - informationTypes: code -> {bindings}
upper = -1 means infinite.

Usage: gen-catalogue.py tilegen/vendor/s101/FeatureCatalogue.xml -o tilegen/vendor/s101/catalogue.json
"""
import argparse, json, sys
import xml.etree.ElementTree as ET


def local(tag):
    return tag.rsplit("}", 1)[-1]


def child_text(elem, name):
    for c in elem:
        if local(c.tag) == name:
            return (c.text or "").strip()
    return None


def children(elem, name):
    return [c for c in elem if local(c.tag) == name]


def bindings(elem, binding_tag):
    out = []
    for b in children(elem, binding_tag):
        ref, lo, up = None, 0, 1
        for c in b:
            lt = local(c.tag)
            if lt == "attribute":
                ref = c.get("ref")
            elif lt == "multiplicity":
                for m in c:
                    mt = local(m.tag)
                    if mt == "lower":
                        lo = int((m.text or "0").strip())
                    elif mt == "upper":
                        up = -1 if m.get("infinite") == "true" else int((m.text or "1").strip())
        if ref:
            out.append([ref, lo, up])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xml")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    root = ET.parse(a.xml).getroot()
    simple, complexa, features, infos = {}, {}, {}, {}

    for elem in root.iter():
        lt = local(elem.tag)
        if lt == "S100_FC_SimpleAttribute":
            code = child_text(elem, "code")
            if code:
                simple[code] = {
                    "valueType": child_text(elem, "valueType") or "text",
                    "alias": [c.text.strip() for c in children(elem, "alias") if c.text],
                }
        elif lt == "S100_FC_ComplexAttribute":
            code = child_text(elem, "code")
            if code:
                complexa[code] = {
                    "bindings": bindings(elem, "subAttributeBinding"),
                    "alias": [c.text.strip() for c in children(elem, "alias") if c.text],
                }
        elif lt == "S100_FC_FeatureType":
            code = child_text(elem, "code")
            if code:
                features[code] = {
                    "alias": [c.text.strip() for c in children(elem, "alias") if c.text],
                    "primitives": [c.text.strip() for c in children(elem, "permittedPrimitives") if c.text],
                    "bindings": bindings(elem, "attributeBinding"),
                }
        elif lt == "S100_FC_InformationType":
            code = child_text(elem, "code")
            if code:
                infos[code] = {"bindings": bindings(elem, "attributeBinding")}

    cat = {"simpleAttrs": simple, "complexAttrs": complexa,
           "featureTypes": features, "informationTypes": infos}
    with open(a.out, "w") as f:
        json.dump(cat, f, separators=(",", ":"))
    print(f"wrote {a.out}: {len(features)} feature types, {len(simple)} simple attrs, "
          f"{len(complexa)} complex attrs, {len(infos)} info types", file=sys.stderr)


if __name__ == "__main__":
    main()
