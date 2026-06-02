#!/usr/bin/env python3
"""events_listen.py - print the WS /events stream. Thin wrapper over genapi.ws.stream_events.

    python3 events_listen.py
    python3 events_listen.py --duration 30
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # game_agent root
from genapi.client import GameClient  # noqa: E402


def show(ev):
    t, f = ev.get("type", "?"), ev.get("frame", "?")
    if t == "hello":
        print("hello:", ev)
    elif t == "unit_died":
        print("  [f{}] DIED   id={} killer={} player={} {}".format(
            f, ev.get("id"), ev.get("killerId"), ev.get("player"), ev.get("template")))
    elif t == "unit_produced":
        print("  [f{}] BUILT  id={} player={} {} (factory {})".format(
            f, ev.get("id"), ev.get("player"), ev.get("template"), ev.get("factoryId")))
    elif t == "structure_complete":
        print("  [f{}] STRUCT id={} player={} {}".format(
            f, ev.get("id"), ev.get("player"), ev.get("template")))
    elif t == "combat":
        print("  [f{}] COMBAT victim={} attacker={} player={} dmg={:.0f} type={}".format(
            f, ev.get("victimId"), ev.get("attackerId"), ev.get("player"),
            ev.get("amount", 0.0), ev.get("damageType")))
    else:
        print("  [f{}] {} {}".format(f, t, ev))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None, help="REST port (WS = REST+1)")
    ap.add_argument("--duration", type=float, default=None)
    args = ap.parse_args()
    c = GameClient(host=args.host, port=args.port)
    print("== /events listener -> ws://{}:{}/events ==".format(c.host, c.ws_port))
    n = 0
    try:
        for ev in c.events(duration=args.duration):
            show(ev)
            if ev.get("type") not in ("hello",):
                n += 1
    except (KeyboardInterrupt, ConnectionError) as e:
        print("(stopped: {})".format(e))
    print("total events: {}".format(n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
