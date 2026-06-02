#!/usr/bin/env python3
"""map_view.py - render how the agent "sees" the map to a PNG (pure-stdlib zlib). Uses genapi.

Terrain coloured by cell type + height relief; objects overlaid with category markers. This is the
static counterpart of the interactive ui/map_live.html.

    python3 map_view.py --out /tmp/gen_world.png --scale 4 --armies-only
"""

import argparse
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # game_agent root
from genapi.client import GameClient  # noqa: E402
from genapi.world import WorldModel  # noqa: E402


def write_png(path, width, height, rgb):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


TYPE_COLOR = {0: (196, 190, 150), 1: (54, 110, 200), 2: (96, 74, 52), 3: (135, 135, 135),
              4: (120, 66, 54), 6: (32, 32, 36), 255: (255, 0, 255)}
REL_COLOR = {"self": (60, 230, 60), "ally": (60, 220, 220), "enemy": (235, 45, 45), "neutral": (170, 170, 170)}
ECON, TECH, GARR = (255, 210, 63), (194, 100, 255), (255, 140, 26)


def classify(u):
    tags = set(u.get("tags", []))
    cat = u.get("category")
    if "supply_source" in tags or "cash_generator" in tags:
        return "econ"
    if "tech_building" in tags or "capturable" in tags:
        return "tech"
    if "garrisonable" in tags:
        return "garr"
    if cat in ("structure", "defense") or "structure" in tags:
        return "neutral_b" if u.get("relationToLocal") == "neutral" else "struct"
    return "unit" if cat == "unit" else "prop"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--out", default="/tmp/gen_world.png")
    ap.add_argument("--scale", type=int, default=4)
    ap.add_argument("--ds", type=int, default=1)
    ap.add_argument("--armies-only", action="store_true")
    args = ap.parse_args()
    c = GameClient(host=args.host, port=args.port)
    print("== map_view against", c.base, "==")

    w = WorldModel(c.map(ds=args.ds), c.units(), c.players())
    if not w.width:
        print("FAIL: no map (not in a game?)")
        return 1
    W, H, cs = w.width, w.height, w.cell
    print("grid: {}x{} cells, cellSize={} world-units, heightRange=[{:.0f},{:.0f}]".format(
        W, H, cs, w.h_min, w.h_max))

    scale = max(1, args.scale)
    iw, ih = W * scale, H * scale
    img = bytearray(iw * ih * 3)

    def put(px, py, rgb):
        if 0 <= px < iw and 0 <= py < ih:
            o = (py * iw + px) * 3
            img[o], img[o + 1], img[o + 2] = rgb

    def fill(px, py, r, rgb):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                put(px + dx, py + dy, rgb)

    def ring(px, py, r, rgb):
        for d in range(-r, r + 1):
            put(px + d, py - r, rgb); put(px + d, py + r, rgb)
            put(px - r, py + d, rgb); put(px + r, py + d, rgb)

    for cy in range(H):
        for cx in range(W):
            i = cy * W + cx
            base = TYPE_COLOR.get(w.types[i] if i < len(w.types) else 255, TYPE_COLOR[255])
            hh = (w.height_data[i] if (w.height_data and i < len(w.height_data)) else 128) / 255.0
            sh = 0.55 + 0.45 * hh
            rgb = tuple(min(255, int(v * sh)) for v in base)
            iy0, ix0 = (H - 1 - cy) * scale, cx * scale
            for dy in range(scale):
                row = (iy0 + dy) * iw
                for dx in range(scale):
                    o = (row + ix0 + dx) * 3
                    img[o], img[o + 1], img[o + 2] = rgb

    counts = {}
    for u in w.units:
        if "x" not in u:
            continue
        cx, cy = int(u["x"] / cs), int(u["y"] / cs)
        if not (0 <= cx < W and 0 <= cy < H):
            continue
        k = classify(u)
        counts[k] = counts.get(k, 0) + 1
        if args.armies_only and k == "prop":
            continue
        px, py = cx * scale + scale // 2, (H - 1 - cy) * scale + scale // 2
        rel = REL_COLOR.get(u.get("relationToLocal"), REL_COLOR["neutral"])
        if k == "unit":
            fill(px, py, 1, rel)
        elif k == "struct":
            fill(px, py, 3, rel); ring(px, py, 3, (0, 0, 0))
        elif k == "neutral_b":
            fill(px, py, 3, (140, 147, 163))
        elif k == "econ":
            fill(px, py, 3, ECON); ring(px, py, 4, (0, 0, 0))
        elif k == "tech":
            fill(px, py, 2, (42, 24, 64)); ring(px, py, 4, TECH)
        elif k == "garr":
            ring(px, py, 4, GARR); ring(px, py, 3, GARR)
        else:
            put(px, py, (90, 97, 110))

    print("overlay:", ", ".join("{}={}".format(k, v) for k, v in sorted(counts.items())))
    write_png(args.out, iw, ih, img)
    print("wrote {} ({}x{} px)".format(args.out, iw, ih))
    print("legend: tan=clear/buildable blue=water brown=cliff dark=obstacle | "
          "yellow=oil/supply purple=tech orange=garrison | dots: green=self cyan=ally red=enemy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
