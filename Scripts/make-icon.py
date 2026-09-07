#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns with no external dependencies.

The icon is the house style in one glyph: a flat black macOS squircle holding a white
island capsule and a grey minimal bubble, the Dynamic Island's two-activity state.

The squircle is Apple's *continuous* rounded square rather than a circular rounded rect: the
same corner construction the app draws the island with (see NotchShape.swift). Its corner
radius is 22.37% of the content square and each corner reaches 1.528665 * r along the two
edges it joins, so the curvature ramps in from the flat edge instead of starting abruptly.
The outline is rasterised exactly — the corner Bezier is inverted per scanline — rather than
approximated with a superellipse.
"""
import math, struct, zlib, os, sys
from bisect import bisect_right

SIZE = 1024

# How far a continuous corner of radius r reaches along each of its edges.
CORNER_REACH = 1.528665

# The corner as ten control points (a start point plus three cubic c1/c2/end triples),
# normalised so it reaches exactly 1 along each edge: vertex at the origin, edges along +x
# and +y, so the curve runs from (1, 0) to (0, 1). Same table as SmoothCorner.unit in
# Sources/MacNotchIsland/Shapes/NotchShape.swift.
CORNER = [
    (1.000000000, 0.000000000),
    (0.677580883, 0.000000000),
    (0.516371325, 0.000000000),
    (0.390285378, 0.055584046),
    (0.240850768, 0.121461177),
    (0.121461177, 0.240850768),
    (0.055584046, 0.390285378),
    (0.000000000, 0.516371325),
    (0.000000000, 0.677580883),
    (0.000000000, 1.000000000),
]


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def _corner_table(samples=4000):
    """(v, u) samples along the normalised corner. v rises monotonically 0 -> 1, so the pairs
    invert the curve: given how far a scanline sits from the edge, they give the inset."""
    vs, us = [], []
    for seg in range(3):
        p0, p1, p2, p3 = CORNER[seg * 3:seg * 3 + 4]
        for i in range(samples + 1):
            if seg and i == 0:
                continue                      # segment start == previous segment end
            t = i / samples
            k = 1.0 - t
            w0, w1, w2, w3 = k * k * k, 3 * k * k * t, 3 * k * t * t, t * t * t
            us.append(w0 * p0[0] + w1 * p1[0] + w2 * p2[0] + w3 * p3[0])
            vs.append(w0 * p0[1] + w1 * p1[1] + w2 * p2[1] + w3 * p3[1])
    return vs, us


CORNER_V, CORNER_U = _corner_table()


def corner_inset(v):
    """The corner's inset from the vertex, `v` of the way in from the edge it meets (0 -> 1)."""
    if v <= 0.0:
        return 1.0
    if v >= 1.0:
        return 0.0
    i = bisect_right(CORNER_V, v)
    if i <= 0:
        return CORNER_U[0]
    if i >= len(CORNER_V):
        return CORNER_U[-1]
    v0, v1 = CORNER_V[i - 1], CORNER_V[i]
    u0, u1 = CORNER_U[i - 1], CORNER_U[i]
    if v1 == v0:
        return u0
    return u0 + (u1 - u0) * (v - v0) / (v1 - v0)


def squircle_half_width(dy, half, span):
    """Half-width of the continuous-cornered square at vertical offset `dy` from its centre."""
    ay = abs(dy)
    if ay > half:
        return 0.0
    if ay <= half - span:
        return half
    return half - span * corner_inset((half - ay) / span)


def sdf_capsule(px, py, ax, ay, bx, by, r):
    pax, pay = px - ax, py - ay
    bax, bay = bx - ax, by - ay
    h = clamp((pax * bax + pay * bay) / (bax * bax + bay * bay))
    return math.hypot(pax - bax * h, pay - bay * h) - r


def sdf_circle(px, py, cx, cy, r):
    return math.hypot(px - cx, py - cy) - r


def coverage(d):
    # 1px anti-aliasing band
    return clamp(0.5 - d)


def render(size):
    s = size / SIZE
    sub = 4                                   # vertical supersampling; horizontal is exact
    buf = bytearray(size * size * 4)
    # macOS icon grid: content square of 824/1024, corners at 22.37% of it
    half = 412 * s
    span = min(CORNER_REACH * 0.2237 * 824 * s, half)
    cx = cy = size / 2
    # island capsule + bubble, centred as a group
    cap_w, cap_h = 430 * s, 150 * s
    bubble_d = 150 * s
    gap = 40 * s
    group_w = cap_w + gap + bubble_d
    left = cx - group_w / 2
    cap_ax = left + cap_h / 2
    cap_bx = left + cap_w - cap_h / 2
    bub_cx = left + cap_w + gap + bubble_d / 2
    ycen = cy - 8 * s
    for y in range(size):
        spans = []
        for k in range(sub):
            hw = squircle_half_width(y + (k + 0.5) / sub - cy, half, span)
            spans.append((cx - hw, cx + hw))
        lo_min = min(a for a, _ in spans)
        lo_max = max(a for a, _ in spans)
        hi_min = min(b for _, b in spans)
        hi_max = max(b for _, b in spans)
        if hi_max <= lo_min:
            continue                          # row misses the squircle entirely
        py = y + 0.5
        for x in range(max(0, int(lo_min)), min(size, int(hi_max) + 1)):
            if x >= lo_max and x + 1 <= hi_min:
                bg = 1.0
            else:
                acc = 0.0
                for a, b in spans:
                    lo = a if a > x else x
                    hi = b if b < x + 1 else x + 1
                    if hi > lo:
                        acc += hi - lo
                bg = acc / sub
            if bg <= 0.0:
                continue
            px = x + 0.5
            cap = coverage(sdf_capsule(px, py, cap_ax, ycen, cap_bx, ycen, cap_h / 2))
            bub = coverage(sdf_circle(px, py, bub_cx, ycen, bubble_d / 2))
            # composite: black ground, white capsule, grey (#8E8E93) bubble
            r = g = b = 0.0
            r = r * (1 - cap) + 1.0 * cap; g = g * (1 - cap) + 1.0 * cap; b = b * (1 - cap) + 1.0 * cap
            r = r * (1 - bub) + (0x8E / 255) * bub; g = g * (1 - bub) + (0x8E / 255) * bub; b = b * (1 - bub) + (0x93 / 255) * bub
            i = (y * size + x) * 4
            buf[i] = int(r * 255 + 0.5); buf[i + 1] = int(g * 255 + 0.5); buf[i + 2] = int(b * 255 + 0.5); buf[i + 3] = int(bg * 255 + 0.5)
    return bytes(buf)

def png(size, rgba):
    raw = b''.join(b'\x00' + rgba[y * size * 4:(y + 1) * size * 4] for y in range(size))
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'Resources', 'AppIcon.icns')
    # icns element types by pixel size (all PNG payloads)
    types = {1024: b'ic10', 512: b'ic09', 256: b'ic08', 128: b'ic07', 64: b'icp6', 32: b'icp5', 16: b'icp4'}
    retina = {512: b'ic14', 256: b'ic13', 64: b'ic12', 32: b'ic11'}
    elements = []
    for size in (1024, 512, 256, 128, 64, 32, 16):
        data = png(size, render(size))
        elements.append(types[size] + struct.pack('>I', len(data) + 8) + data)
        if size in retina:
            elements.append(retina[size] + struct.pack('>I', len(data) + 8) + data)
        print(f'  {size}px {len(data)} bytes', flush=True)
    body = b''.join(elements)
    with open(out, 'wb') as f:
        f.write(b'icns' + struct.pack('>I', len(body) + 8) + body)
    print('wrote', out)

if __name__ == '__main__':
    main()
