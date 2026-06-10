#!/usr/bin/env python3
"""run_agent.py - drive a harness agent against a live stand. Run from the game_agent root.

    python3 run_agent.py                          # scripted baseline (no LLM, single cadence)
    python3 run_agent.py --agent ollama           # LLM planner + skill/task executor (two-tier)
    GEN_API_PORT=3459 python3 run_agent.py --agent ollama --model qwen3.5:9b

The 'ollama' agent is the deliberative/reactive system: a fast deterministic executor (TaskManager
ticking Skill state-machines) orchestrated by a slow LLM planner over Ollama function-calling. See
docs/AGENT.md. The 'scripted' agent is the no-LLM reference baseline on the simple run() loop.
"""

import argparse

from genapi.client import GameClient


def run_scripted(args, client, view):
    from agent.base import run
    from agent.scripted import ScriptedAgent
    print("== running agent 'scripted' against {} ==".format(client.base))
    run(ScriptedAgent(), client, hz=args.hz, view=view, max_ticks=args.max_ticks)


def run_commander(args, client, view):
    """The always-on ALGORITHMIC CWC bot (no LLM). Plays + wins on its own; an LLM/human only patches
    the StrategyDirective file. See agent/commander/ and docs/COMMANDER_PLAN.md."""
    from agent.commander.commander import run_commander as _run
    _run(client, view=view, fast_hz=args.fast_hz)


def run_strategist(args, client, view):
    """The STRATEGIST (commander v2): a strong, dynamic, map-aware CWC bot — influence heat maps,
    coherent macro (never bankrupts, protects dozers, standing army), counter-composition from the
    scouted enemy, and an aggressive influence-driven army (scout/harass/defend/assault). No LLM.
    See agent/strategist/."""
    from agent.strategist.strategist import run_strategist as _run
    _run(client, view=view, fast_hz=args.fast_hz)


def run_ollama(args, client, view):
    from agent.journal import AgentNotes, EventJournal
    from agent.ollama_agent import OllamaPlanner
    from agent.ollama_client import OllamaChat
    from agent.orchestrator import orchestrate
    from agent.skills import build_default_registry
    from agent.tasks import TaskManager
    from genapi.threats import ThreatTracker

    chat = OllamaChat(host=args.ollama_host, model=args.model)
    print("== ollama planner: {} model={} (reachable={}) ==".format(chat.base, chat.model, chat.ping()))

    me = client.external_player()
    owner = me["index"] if me else None
    registry = build_default_registry()
    taskmgr = TaskManager()
    notes = AgentNotes()
    journal = EventJournal(client, owner) if owner is not None else None
    threats = ThreatTracker(client, owner) if owner is not None else None
    planner = OllamaPlanner(registry, chat, taskmgr, notes)

    print("== skills: {} ==".format(", ".join(registry.names())))
    orchestrate(client, planner, taskmgr, journal=journal, threats=threats, notes=notes,
                view=view, fast_hz=args.fast_hz, plan_period_s=args.plan_period)


AGENTS = {"scripted": run_scripted, "commander": run_commander,
          "strategist": run_strategist, "ollama": run_ollama}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", default="scripted", choices=sorted(AGENTS))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--view", default="self", help="fog view: 'self', 'none', or a player index")
    # scripted
    ap.add_argument("--hz", type=float, default=0.5, help="scripted: decisions per second")
    ap.add_argument("--max-ticks", type=int, default=None)
    # ollama
    ap.add_argument("--model", default=None, help="ollama model (default qwen3.5:9b / $GEN_OLLAMA_MODEL)")
    ap.add_argument("--ollama-host", default=None, help="host:port (default $GEN_OLLAMA_HOST)")
    ap.add_argument("--fast-hz", type=float, default=2.0, help="ollama: executor ticks per second")
    ap.add_argument("--plan-period", type=float, default=15.0, help="ollama: seconds between LLM plans")
    args = ap.parse_args()

    view = None if args.view == "none" else ("self" if args.view == "self" else int(args.view))
    client = GameClient(host=args.host, port=args.port)
    AGENTS[args.agent](args, client, view)


if __name__ == "__main__":
    raise SystemExit(main())
