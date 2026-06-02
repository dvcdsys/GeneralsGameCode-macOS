#!/usr/bin/env python3
"""demo.py - the read->act Definition-of-Done loop, on genapi.GameClient + WorldModel.

Discover the external player -> snapshot units -> pause -> move -> resume -> confirm the centroid
moved. Prints PASS/FAIL.

    python3 demo.py
    python3 demo.py --dx 800 --dy 0
"""

import argparse
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # game_agent root
from genapi.client import GameClient  # noqa: E402
from genapi.world import WorldModel  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--dx", type=float, default=600.0)
    ap.add_argument("--dy", type=float, default=0.0)
    ap.add_argument("--max-units", type=int, default=40)
    args = ap.parse_args()
    c = GameClient(host=args.host, port=args.port)

    print("== M1 demo against", c.base, "==")
    h = c.healthz()
    if not h:
        print("FAIL: cannot reach API")
        return 1
    print("healthz:", h)

    me = c.external_player()
    if not me:
        print("FAIL: no external player. Launch with GEN_AUTO_EXTERNAL=1.")
        return 1
    idx = me["index"]
    print("external player: index={} side={} relationToLocal={}".format(
        idx, me.get("side"), me.get("relationToLocal")))

    units = c.units(player=idx)
    if not units:
        print("FAIL: external player has 0 units.")
        return 1
    ids = [u["id"] for u in units][: args.max_units]
    c0 = WorldModel.centroid(units)
    print("units: {} (commanding {}), centroid={}".format(len(units), len(ids), c0))

    print("pause:", c.pause())
    target = {"x": c0[0] + args.dx, "y": c0[1] + args.dy, "z": 0.0}
    res = c.command(idx, ids, "move", {"pos": target})
    print("command move -> {}: {}".format(target, res))
    if not (isinstance(res, dict) and res.get("accepted")):
        print("FAIL: command not accepted")
        return 1
    print("resume:", c.resume())

    moved = 0.0
    for _ in range(15):
        time.sleep(1.0)
        c1 = WorldModel.centroid(c.units(player=idx))
        if c1:
            moved = math.hypot(c1[0] - c0[0], c1[1] - c0[1])
            print("  centroid={}  moved={:.0f}".format(tuple(round(v) for v in c1), moved))
            if moved > 50.0:
                break

    if moved > 50.0:
        print("PASS: external units moved {:.0f} units after the API command.".format(moved))
        return 0
    print("FAIL: units did not move (moved={:.0f}).".format(moved))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
