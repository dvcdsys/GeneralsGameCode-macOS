#!/usr/bin/env python3
"""session.py - print /session (seed / headless / replay / outcome). Uses genapi.GameClient.

    python3 session.py
    python3 session.py --watch
    python3 session.py --set-seed 12345
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # game_agent root
from genapi.client import GameClient  # noqa: E402


def show(s):
    if not isinstance(s, dict):
        print("  (no session data)", s)
        return
    rep, out = s.get("replay", {}), s.get("outcome", {})
    print("  inGame={} frame={} paused={} seed={} headless={}".format(
        s.get("inGame"), s.get("frame"), s.get("paused"), s.get("seed"), s.get("headless")))
    print("  replay: mode={} playingBack={}".format(rep.get("mode"), rep.get("playingBack")))
    print("  outcome: localResult={} decided={} endFrame={}".format(
        out.get("localResult"), out.get("decided"), out.get("endFrame")))
    for p in out.get("players", []):
        flag = "WON" if p.get("victory") else ("LOST" if p.get("defeated") else "...")
        print("    player {:>2} ({:<8}) {}".format(p.get("index"), p.get("controller"), flag))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--set-seed", type=int, default=None)
    args = ap.parse_args()
    c = GameClient(host=args.host, port=args.port)
    print("== /session against", c.base, "==")

    if args.set_seed is not None:
        print("POST /session seed={} -> {}".format(args.set_seed, c.set_seed(args.set_seed)))

    s = c.session()
    if not s:
        print("FAIL: cannot reach API")
        return 1
    show(s)

    if args.watch:
        print("watching until decided (Ctrl-C to stop)...")
        try:
            while True:
                time.sleep(2.0)
                s = c.session()
                if isinstance(s, dict) and s.get("outcome", {}).get("decided"):
                    print("DECIDED:")
                    show(s)
                    return 0
                print("  frame={} localResult={}".format(
                    s.get("frame") if isinstance(s, dict) else "?",
                    (s or {}).get("outcome", {}).get("localResult")))
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
