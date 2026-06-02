#!/usr/bin/env python3
"""run_agent.py - drive a harness agent against a live stand. Run from the game_agent root.

    python3 run_agent.py                  # scripted baseline
    python3 run_agent.py --agent scripted --hz 0.5
    GEN_API_PORT=3459 python3 run_agent.py

The Ollama (qwen/gemma 7B) agent will register here once implemented (see docs/AGENT.md).
"""

import argparse

from agent.base import run
from agent.scripted import ScriptedAgent
from genapi.client import GameClient

AGENTS = {"scripted": ScriptedAgent}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", default="scripted", choices=sorted(AGENTS))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--hz", type=float, default=0.5, help="decisions per second")
    ap.add_argument("--view", default="self", help="fog view: 'self', 'none', or a player index")
    ap.add_argument("--max-ticks", type=int, default=None)
    args = ap.parse_args()

    view = None if args.view == "none" else ("self" if args.view == "self" else int(args.view))
    client = GameClient(host=args.host, port=args.port)
    print("== running agent '{}' against {} ==".format(args.agent, client.base))
    run(AGENTS[args.agent](), client, hz=args.hz, view=view, max_ticks=args.max_ticks)


if __name__ == "__main__":
    raise SystemExit(main())
