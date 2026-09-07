#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns with no external dependencies.

The icon is the house style in one glyph: a flat black macOS squircle holding a white
island capsule and a grey minimal bubble, the Dynamic Island's two-activity state.
"""
import math, struct, zlib, os, sys

SIZE = 1024

def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x

def sdf_round_rect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    ox, oy = max(qx, 0.0), max(qy, 0.0)
    return math.hypot(ox, oy) + min(max(qx, qy), 0.0) - r

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
    buf = bytearray(size * size * 4)
    # macOS icon grid: content square of 824/1024 with ~22.4% corner radius
    half = 412 * s
    radius = 185 * s
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
    i = 0
    for y in range(size):
        py = y + 0.5
        for x in range(size):
            px = x + 0.5
            bg = coverage(sdf_round_rect(px, py, cx, cy, half, half, radius))
            if bg <= 0.0:
                i += 4
                continue
            cap = coverage(sdf_capsule(px, py, cap_ax, ycen, cap_bx, ycen, cap_h / 2))
            bub = coverage(sdf_circle(px, py, bub_cx, ycen, bubble_d / 2))
            # composite: black ground, white capsule, grey (#8E8E93) bubble
            r = g = b = 0.0
            r = r * (1 - cap) + 1.0 * cap; g = g * (1 - cap) + 1.0 * cap; b = b * (1 - cap) + 1.0 * cap
            r = r * (1 - bub) + (0x8E / 255) * bub; g = g * (1 - bub) + (0x8E / 255) * bub; b = b * (1 - bub) + (0x93 / 255) * bub
            a = bg
            buf[i] = int(r * 255 + 0.5); buf[i + 1] = int(g * 255 + 0.5); buf[i + 2] = int(b * 255 + 0.5); buf[i + 3] = int(a * 255 + 0.5)
            i += 4
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
