#!/usr/bin/env python3
"""Minimal PMTiles v3 reader + MVT decoder for inspection.

Extracts one tile from a .pmtiles archive and dumps each layer's feature
property key/values (and a geometry-type/coord count). Pure-python, no deps.

Usage: mvt_inspect.py ARCHIVE Z X Y [--layer NAME] [--limit N]
"""
import sys, struct, gzip, argparse
from collections import Counter


def read_varint(buf, pos):
    shift = 0
    result = 0
    while True:
        b = buf[pos]; pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, pos


def zigzag(n):
    return (n >> 1) ^ -(n & 1)


def parse_dir(buf):
    """Return list of (tile_id, run_length, offset, length)."""
    pos = 0
    n, pos = read_varint(buf, pos)
    ids = [0] * n
    last = 0
    for i in range(n):
        d, pos = read_varint(buf, pos)
        last += d
        ids[i] = last
    runs = [0] * n
    for i in range(n):
        runs[i], pos = read_varint(buf, pos)
    lengths = [0] * n
    for i in range(n):
        lengths[i], pos = read_varint(buf, pos)
    offsets = [0] * n
    for i in range(n):
        v, pos = read_varint(buf, pos)
        if v == 0 and i > 0:
            offsets[i] = offsets[i - 1] + lengths[i - 1]
        else:
            offsets[i] = v - 1
    return list(zip(ids, runs, offsets, lengths))


def zxy_to_tileid(z, x, y):
    acc = 0
    for t in range(z):
        acc += (1 << t) * (1 << t)
    n = 1 << z
    # Hilbert d2xy inverse (xy2d)
    rx = ry = 0
    d = 0
    s = n // 2
    while s > 0:
        rx = 1 if (x & s) > 0 else 0
        ry = 1 if (y & s) > 0 else 0
        d += s * s * ((3 * rx) ^ ry)
        # rotate
        if ry == 0:
            if rx == 1:
                x = s - 1 - x
                y = s - 1 - y
            x, y = y, x
        s //= 2
    return acc + d


def get_tile(path, z, x, y):
    raw = open(path, 'rb').read()
    hdr = raw[:127]
    (root_off, root_len, meta_off, meta_len, leaf_off, leaf_len,
     data_off, data_len, *_ ) = struct.unpack_from('<QQQQQQQQ', hdr, 8)
    icomp = hdr[97]; tcomp = hdr[98]
    def maybe_decomp(b, comp):
        return gzip.decompress(b) if comp == 2 else b
    tid = zxy_to_tileid(z, x, y)
    d = parse_dir(maybe_decomp(raw[root_off:root_off + root_len], icomp))
    for (eid, run, off, length) in d:
        if eid <= tid < eid + max(run, 1):
            blob = raw[data_off + off: data_off + off + length]
            return maybe_decomp(blob, tcomp)
    # try leaf dirs (single level)
    for (eid, run, off, length) in d:
        if run == 0:
            leaf = maybe_decomp(raw[leaf_off + off: leaf_off + off + length], icomp)
            for (e2, r2, o2, l2) in parse_dir(leaf):
                if e2 <= tid < e2 + max(r2, 1):
                    blob = raw[data_off + o2: data_off + o2 + l2]
                    return maybe_decomp(blob, tcomp)
    return None


def parse_value(buf):
    pos = 0
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        field = key >> 3; wt = key & 7
        if field == 1 and wt == 2:
            ln, pos = read_varint(buf, pos); return buf[pos:pos+ln].decode('utf-8', 'replace')
        elif field == 2 and wt == 5:
            v = struct.unpack_from('<f', buf, pos)[0]; pos += 4; return v
        elif field == 3 and wt == 1:
            v = struct.unpack_from('<d', buf, pos)[0]; pos += 8; return v
        elif field == 4 and wt == 0:
            v, pos = read_varint(buf, pos); return v
        elif field == 5 and wt == 0:
            v, pos = read_varint(buf, pos); return v
        elif field == 6 and wt == 0:
            v, pos = read_varint(buf, pos); return zigzag(v)
        elif field == 7 and wt == 0:
            v, pos = read_varint(buf, pos); return bool(v)
        else:
            return None
    return None


def parse_layer(buf):
    pos = 0
    name = None; extent = 4096; keys = []; values = []; features = []
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        field = key >> 3; wt = key & 7
        if field == 1 and wt == 2:
            ln, pos = read_varint(buf, pos); name = buf[pos:pos+ln].decode(); pos += ln
        elif field == 2 and wt == 2:
            ln, pos = read_varint(buf, pos); features.append(buf[pos:pos+ln]); pos += ln
        elif field == 3 and wt == 2:
            ln, pos = read_varint(buf, pos); keys.append(buf[pos:pos+ln].decode()); pos += ln
        elif field == 4 and wt == 2:
            ln, pos = read_varint(buf, pos); values.append(parse_value(buf[pos:pos+ln])); pos += ln
        elif field == 5 and wt == 0:
            extent, pos = read_varint(buf, pos)
        elif field == 15 and wt == 0:
            _, pos = read_varint(buf, pos)
        else:
            if wt == 2:
                ln, pos = read_varint(buf, pos); pos += ln
            elif wt == 0:
                _, pos = read_varint(buf, pos)
            elif wt == 5:
                pos += 4
            elif wt == 1:
                pos += 8
    return name, extent, keys, values, features


def feature_props(fbuf, keys, values):
    pos = 0; tags = []; gtype = 0
    while pos < len(fbuf):
        key, pos = read_varint(fbuf, pos)
        field = key >> 3; wt = key & 7
        if field == 2 and wt == 2:
            ln, pos = read_varint(fbuf, pos)
            end = pos + ln
            while pos < end:
                v, pos = read_varint(fbuf, pos); tags.append(v)
        elif field == 3 and wt == 0:
            gtype, pos = read_varint(fbuf, pos)
        elif field == 1 and wt == 0:
            _, pos = read_varint(fbuf, pos)
        elif field == 4 and wt == 2:
            ln, pos = read_varint(fbuf, pos); pos += ln  # skip geometry
        else:
            if wt == 2:
                ln, pos = read_varint(fbuf, pos); pos += ln
            elif wt == 0:
                _, pos = read_varint(fbuf, pos)
            elif wt == 5:
                pos += 4
            elif wt == 1:
                pos += 8
    props = {}
    for i in range(0, len(tags) - 1, 2):
        props[keys[tags[i]]] = values[tags[i + 1]]
    return gtype, props


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('archive'); ap.add_argument('z', type=int)
    ap.add_argument('x', type=int); ap.add_argument('y', type=int)
    ap.add_argument('--layer'); ap.add_argument('--limit', type=int, default=8)
    a = ap.parse_args()
    data = get_tile(a.archive, a.z, a.x, a.y)
    if not data:
        print("tile not found"); sys.exit(1)
    pos = 0
    while pos < len(data):
        key, pos = read_varint(data, pos)
        field = key >> 3; wt = key & 7
        if field == 3 and wt == 2:
            ln, pos = read_varint(data, pos)
            name, extent, keys, values, feats = parse_layer(data[pos:pos+ln]); pos += ln
            if a.layer and name != a.layer:
                continue
            print(f"\n=== layer '{name}'  extent={extent}  features={len(feats)}  keys={keys}")
            # tally color_token / dash / class if present
            for fld in ('color_token', 'dash', 'class', 'pattern_name', 'symbol_name'):
                if fld in keys:
                    c = Counter()
                    for fb in feats:
                        _, p = feature_props(fb, keys, values)
                        c[p.get(fld)] += 1
                    print(f"   {fld}: {dict(c)}")
            for fb in feats[:a.limit]:
                gt, p = feature_props(fb, keys, values)
                print(f"   gtype={gt} {p}")
        else:
            if wt == 2:
                ln, pos = read_varint(data, pos); pos += ln
            elif wt == 0:
                _, pos = read_varint(data, pos)
            elif wt == 5:
                pos += 4
            elif wt == 1:
                pos += 8


if __name__ == '__main__':
    main()
