#!/usr/bin/env python3
"""smoke_control.py - tempo control test: pause freezes the frame, step advances +N, resume continues.

Uses genapi.GameClient. The on-screen game visibly freezes / steps / resumes.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # game_agent root
from genapi.client import GameClient  # noqa: E402


def frame(c):
    h = c.healthz() or {}
    return h.get("frame")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--steps", type=int, default=3)
    args = ap.parse_args()
    c = GameClient(host=args.host, port=args.port)
    print("== smoke_control against", c.base, "==")

    print("running frame:", frame(c))
    print("pause:", c.pause())
    f1 = frame(c); time.sleep(1.0); f2 = frame(c)
    print("frozen? {} == {} -> {}".format(f1, f2, f1 == f2))
    print("step {}:".format(args.steps), c.step(args.steps))
    time.sleep(0.5)
    print("frame after step: {} (expected ~{})".format(frame(c), (f2 or 0) + args.steps))
    print("resume:", c.resume())
    time.sleep(1.0)
    print("advancing? frame now:", frame(c))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
