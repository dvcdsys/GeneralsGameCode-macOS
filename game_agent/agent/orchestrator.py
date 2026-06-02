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
import threading
import time

from agent.brief import compose_brief, _enemy_base_guess
from agent.skills.base import SkillContext, select_combat_units, base_under_attack, my_buildings, my_units
from agent.skills.library import (AttackAreaSkill, BuildBaseSkill, MaintainArmySkill,
                                  CapturePointsSkill, DefendBaseSkill)
from genapi.world import WorldModel

STATE_PATH = "/tmp/gen_agent_state.json"
DIRECTIVE_PATH = "/tmp/gen_agent_directive.json"

# Autonomous-offense safety net: a small LLM sometimes turtles forever and never orders the attack
# even when it has a winning army. To actually BEAT the AI we guarantee offense — if the army is
# strong, the base is safe, the enemy location is known/estimable, and no attack is already running,
# we inject one toward the enemy base. The LLM is still the commander (its own attack_area dedupes
# this); this only fires when it has failed to push.
AUTO_ATTACK_ARMY = 14  # combat units before the safety-net attack triggers


def _seed_opening(taskmgr, frame, verbose=False):
    """Start the standing macros the INSTANT the match begins, without waiting for the first LLM
    plan. The first Ollama call pays a 30-70s model-load and the planner runs async, so without this
    the bot sits idle for the whole opening ('first steps very late'). The LLM still runs right after
    and can re-prioritise; its duplicate macro calls are deduped by the planner (singletons)."""
    have = {t["skill"] for t in taskmgr.active()}
    opening = [BuildBaseSkill, MaintainArmySkill, CapturePointsSkill, DefendBaseSkill]
    seeded = []
    for cls in opening:
        if cls.name not in have:
            taskmgr.add(cls({}), priority=5, frame=frame)
            seeded.append(cls.name)
    if verbose and seeded:
        print("[orch] seeded opening @f{}: {}".format(frame, ", ".join(seeded)), flush=True)


def _maybe_autonomous_attack(ctx, taskmgr, verbose=False):
    if base_under_attack(ctx, 700.0):
        return  # defend first; attack_area would keep a home guard anyway, but don't split under siege
    if any(t["skill"] == "attack_area" for t in taskmgr.active()):
        return  # an attack is already planned/running (LLM's or ours)
    army = select_combat_units(ctx)
    if len(army) < AUTO_ATTACK_ARMY:
        return
    guess = _enemy_base_guess(ctx.world, my_buildings(ctx), my_units(ctx))
    if not guess:
        return
    skill = AttackAreaSkill({"area": {"x": guess["x"], "y": guess["y"]}})
    taskmgr.add(skill, priority=4, frame=ctx.frame)
    if verbose:
        print("[orch] AUTO-ATTACK injected toward {} ({})".format(
            (guess["x"], guess["y"]), guess.get("source")), flush=True)


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

    # Warm the LLM (preload it into VRAM) on a background thread while the map loads, so the first
    # real plan doesn't eat the 30-70s cold-load. The deterministic opening seed plays meanwhile.
    if planner and getattr(planner, "chat", None):
        def _warm():
            try:
                planner.chat.chat([{"role": "user", "content": "ready? reply OK"}])
                if verbose:
                    print("[orch] LLM warmed", flush=True)
            except Exception:  # noqa: BLE001
                pass
        threading.Thread(target=_warm, name="llm-warmup", daemon=True).start()

    map_cache = None
    seeded = False
    last_dir_ts = None
    directive = ""
    # the planner runs on a background thread so the LLM's seconds of thinking never freeze the
    # executor — the box carries the latest plan result + the running thread between iterations.
    plan_box = {"result": None, "thread": None, "last": 0.0}

    while True:
        if not client.in_game():
            _atomic_write(state_path, {"inGame": False, "tasks": taskmgr.snapshot(),
                                       "notes": notes.lines() if notes else [], "directive": directive})
            map_cache = None
            seeded = False  # re-seed the opening when a new match begins
            if verbose:
                print("[orch] waiting for in-game ...")
            time.sleep(1.0)
            continue

        try:
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

            # --- instant opening (deterministic, before the slow first LLM plan) ---
            if not seeded:
                _seed_opening(taskmgr, frame, verbose=verbose)
                seeded = True

            # --- human directive (force a re-plan when it changes) -------------
            d_text, d_ts = _read_directive(directive_path)
            directive_changed = (d_ts is not None and d_ts != last_dir_ts)
            if directive_changed:
                directive = d_text
                last_dir_ts = d_ts

            # --- deliberative tier (slow, ASYNC) -------------------------------
            now = time.time()
            th = plan_box["thread"]
            due = (plan_box["result"] is None or directive_changed
                   or now - plan_box["last"] >= plan_period_s)
            if planner and due and (th is None or not th.is_alive()):
                brief = compose_brief(ctx, taskmgr, notes, directive)  # snapshot now (main thread)
                plan_box["last"] = now

                def _run(brief=brief, frame=frame):
                    t0 = time.time()
                    try:
                        r = planner.plan(brief, frame)  # slow LLM call(s); mutates taskmgr under its lock
                        plan_box["result"] = r
                        if verbose:
                            print("[plan f{} {:.1f}s] calls={} {}".format(
                                frame, time.time() - t0, r.get("calls"), r.get("error", "")), flush=True)
                    except Exception as e:  # noqa: BLE001
                        if verbose:
                            print("[plan] error: {}".format(e), flush=True)

                t = threading.Thread(target=_run, name="planner", daemon=True)
                t.start()
                plan_box["thread"] = t

            # --- autonomous offense safety net (guarantees the bot pushes to win) --
            _maybe_autonomous_attack(ctx, taskmgr, verbose=verbose)

            # --- reactive/executive tier (fast — never blocked by planning) ----
            taskmgr.tick(ctx)

            # --- persist state for the UI --------------------------------------
            _atomic_write(state_path, {
                "inGame": True,
                "frame": frame,
                "me": {"player": me["index"], "side": me.get("side"), "money": me.get("money"),
                       "power": (me.get("powerProduction", 0) or 0) - (me.get("powerConsumption", 0) or 0)},
                "directive": directive,
                "strategy": (notes.strategy if notes else None),
                "tasks": taskmgr.snapshot(),
                "notes": notes.lines() if notes else [],
                "events": journal.digest(16) if journal else [],
                "threats": threats.threats(frame) if threats else [],
                "lastPlan": plan_box["result"],
            })
        except Exception as e:  # noqa: BLE001 — a transient (API blip, bad snapshot) must not kill the bot
            if verbose:
                print("[orch] tick error: {}".format(e), flush=True)

        time.sleep(1.0 / fast_hz if fast_hz else 0.5)
