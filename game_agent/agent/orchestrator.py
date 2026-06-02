"""orchestrate — the two-tier driver: fast deterministic executor + slow LLM planner.

This replaces the single-cadence `agent.base.run` for the LLM agent. Each fast tick (~2 Hz) it rebuilds
the world, ticks the TaskManager (executing every active skill), and persists agent state to a file the
UI reads. On a slower cadence (or when the human directive changes) it composes a brief and calls the
planner, whose tool calls mutate the task queue. Memory threads (EventJournal, ThreatTracker) run
independently in the background.

State/control are file-based (the project's idiom, like /tmp/gen_api_actions.jsonl) so the agent process
and the UI server stay decoupled and crash-safe:
  - writes  /tmp/gen_agent_state.json      (tasks + statuses, notes, events, threats, last plan)
  - reads   /tmp/gen_agent_directive.json  ({text, ts}) — the human's standing intent

NOTE: planning is synchronous, so the executor pauses for the ~1-5 s of an LLM call. That is acceptable
at strategic cadence (planning is infrequent); a future version can move planning to a worker thread
with a mutation queue if responsiveness during planning ever matters.
"""

import json
import os
import time

from agent.brief import compose_brief
from agent.skills.base import SkillContext
from genapi.world import WorldModel

STATE_PATH = "/tmp/gen_agent_state.json"
DIRECTIVE_PATH = "/tmp/gen_agent_directive.json"


def _atomic_write(path, obj):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:  # noqa: BLE001
        pass


def _read_directive(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return (d.get("text", "") or "").strip(), d.get("ts")
    except Exception:  # noqa: BLE001
        return "", None


def orchestrate(client, planner, taskmgr, journal=None, threats=None, notes=None,
                view="self", fast_hz=2.0, plan_period_s=20.0,
                state_path=STATE_PATH, directive_path=DIRECTIVE_PATH, verbose=True):
    if journal:
        journal.start()
    if threats:
        threats.start()

    map_cache = None
    last_plan = 0.0
    last_dir_ts = None
    directive = ""
    last_result = None
    last_brief = None

    while True:
        if not client.in_game():
            _atomic_write(state_path, {"inGame": False, "tasks": taskmgr.snapshot(),
                                       "notes": notes.lines() if notes else [], "directive": directive})
            map_cache = None
            if verbose:
                print("[orch] waiting for in-game ...")
            time.sleep(1.0)
            continue

        me = client.external_player()
        if not me:
            time.sleep(1.0)
            continue

        v = me["index"] if view == "self" else view
        if map_cache is None:
            map_cache = client.map(ds=1)  # terrain is static for the match — fetch once
        world = WorldModel(map_cache, client.units(view=v), client.players())
        frame = (client.healthz() or {}).get("frame", 0)
        ctx = SkillContext(world, me, client, threats=threats, journal=journal, frame=frame,
                           taskmgr=taskmgr)

        # --- human directive (force a re-plan when it changes) -----------------
        d_text, d_ts = _read_directive(directive_path)
        directive_changed = (d_ts is not None and d_ts != last_dir_ts)
        if directive_changed:
            directive = d_text
            last_dir_ts = d_ts

        # --- deliberative tier (slow) ------------------------------------------
        now = time.time()
        if planner and (last_result is None or directive_changed or now - last_plan >= plan_period_s):
            last_brief = compose_brief(ctx, taskmgr, notes, directive)
            t0 = time.time()
            last_result = planner.plan(last_brief, frame)
            last_plan = time.time()
            if verbose:
                print("[plan f{} {:.1f}s] calls={} {}".format(
                    frame, last_plan - t0, last_result.get("calls"), last_result.get("error", "")),
                    flush=True)

        # --- reactive/executive tier (fast) ------------------------------------
        taskmgr.tick(ctx)

        # --- persist state for the UI ------------------------------------------
        _atomic_write(state_path, {
            "inGame": True,
            "frame": frame,
            "me": {"player": me["index"], "side": me.get("side"), "money": me.get("money"),
                   "power": (me.get("powerProduction", 0) or 0) - (me.get("powerConsumption", 0) or 0)},
            "directive": directive,
            "tasks": taskmgr.snapshot(),
            "notes": notes.lines() if notes else [],
            "events": journal.digest(16) if journal else [],
            "threats": threats.threats(frame) if threats else [],
            "lastPlan": last_result,
        })

        time.sleep(1.0 / fast_hz if fast_hz else 0.5)
