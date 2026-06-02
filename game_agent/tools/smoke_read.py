#!/usr/bin/env python3
"""smoke_read.py - live /state + /units table (proves the read path). Uses genapi.GameClient."""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # game_agent root
from genapi.client import GameClient  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--interval", type=float, default=1.0)
    args = ap.parse_args()
    c = GameClient(host=args.host, port=args.port)
    print("== smoke_read against", c.base, "==")

    while True:
        st = c.state()
        if not st:
            print("cannot reach API; retrying...")
            time.sleep(args.interval)
            continue
        print("frame {} paused={} inGame={}".format(st.get("frame"), st.get("paused"), st.get("inGame")))
        for p in st.get("players", []):
            if p.get("controller") == "computer" and not p.get("money"):
                continue
            n = len(c.units(player=p["index"]))
            print("  #{:<2} {:<9} {:<8} ${:<6} units={}".format(
                p["index"], p.get("controller"), p.get("side", ""), p.get("money", 0), n))
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        pass
