#!/usr/bin/env python3
"""Extract the S-57 object-class and attribute code -> acronym tables from the
Go reference (objectclass.go's objectClassCode map + s57attributes.csv) into a
compact s57codes.json. Chained with catalogue.json's S-57 aliases, this gives
OBJL/ATTL (numeric) -> S-101 feature/attribute code for the adaptation.

Usage: gen-s57codes.py --go ../chartplotter-go -o tilegen/vendor/s101/s57codes.json
"""
import argparse, csv, json, re, os, sys


def parse_objclasses(go_dir):
    path = os.path.join(go_dir, "internal/s57/parser/objectclass.go")
    src = open(path).read()
    # Grab the objectClassCode = map[int]string{ ... } block.
    m = re.search(r"objectClassCode\s*=\s*map\[int\]string\{(.*?)\n\}", src, re.S)
    block = m.group(1) if m else src
    out = {}
    for code, acr in re.findall(r'(\d+):\s*"([A-Z0-9]+)"', block):
        out[code] = acr
    return out


def parse_attrs(go_dir):
    path = os.path.join(go_dir, "internal/s57/parser/s57attributes.csv")
    out = {}
    with open(path, newline="") as f:
        r = csv.reader(f)
        next(r, None)  # header
        for row in r:
            if len(row) >= 3 and row[0].strip().strip('"').isdigit():
                acr = row[2].strip().strip('"')
                if acr:
                    out[row[0].strip().strip('"')] = acr
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--go", default="../chartplotter-go")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    data = {"obj": parse_objclasses(a.go), "attr": parse_attrs(a.go)}
    with open(a.out, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(f"wrote {a.out}: {len(data['obj'])} object classes, {len(data['attr'])} attributes",
          file=sys.stderr)


if __name__ == "__main__":
    main()
