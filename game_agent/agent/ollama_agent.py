"""OllamaPlanner — the slow, deliberative LLM tier.

It does NOT drive units directly. Each planning round it receives a compact brief (agent.brief) and
calls the model with the skill catalog + task-management ops as native tools. The model's tool calls
mutate the TaskManager (create/cancel/reprioritise tasks) and the notes scratchpad; the fast executor
then carries those tasks out tick-by-tick. This is the deliberative/reactive split the user asked for:
the LLM plans and orchestrates, deterministic skills execute in real time.

Authority stays game-side: the model only emits documented skills/verbs; anything illegal is rejected
by the skill or by /command and surfaces as a FAILED task, never a crash.
"""

import json
import time

LLM_LOG = "/tmp/gen_agent_llm.jsonl"

# Task-management tools the model can call alongside the skill tools.
MANAGEMENT_TOOLS = [
    {"type": "function", "function": {
        "name": "cancel_task",
        "description": "Cancel an active task by its id (from the brief's tasks list).",
        "parameters": {"type": "object",
                       "properties": {"task_id": {"type": "integer"}},
                       "required": ["task_id"]}}},
    {"type": "function", "function": {
        "name": "set_priority",
        "description": "Change an active task's priority (higher runs first; default 5).",
        "parameters": {"type": "object",
                       "properties": {"task_id": {"type": "integer"},
                                      "priority": {"type": "integer"}},
                       "required": ["task_id", "priority"]}}},
    {"type": "function", "function": {
        "name": "set_strategy",
        "description": ("Record/UPDATE your current strategy in plain text: a one-line read of the "
                        "SITUATION and your one-line PLAN. Call this FIRST every round and revise it "
                        "as the game changes — it is your persistent memory and is shown to the human."),
        "parameters": {"type": "object",
                       "properties": {"situation": {"type": "string"}, "plan": {"type": "string"}},
                       "required": ["situation", "plan"]}}},
    {"type": "function", "function": {
        "name": "note",
        "description": ("Record a short strategic note to your own memory (persists across planning "
                        "rounds). Use for observations the world snapshot won't re-derive: enemy "
                        "intent, where you are expanding, what failed."),
        "parameters": {"type": "object",
                       "properties": {"text": {"type": "string"}},
                       "required": ["text"]}}},
]

SYSTEM_PROMPT = """You are the COMMANDER of your army in a Command & Conquer: Generals Zero Hour \
skirmish. You think at the STRATEGIC level: you read the battlefield, decide what to do, and issue \
high-level TASKS that a fast executor carries out tick-by-tick. You are called every few seconds, so \
form DURABLE intent and adjust it as the situation changes. There is no fixed script — YOU decide the \
strategy from what you see, your memory, and the human commander's directive.

HOW THIS GAME WORKS (principles to reason from):
- ECONOMY funds everything. Money comes from supply/oil/cash points and from capturing fuel/economy \
buildings and flags. The more economy points you hold, the bigger army you can afford. Map control = \
economy.
- POWER: most buildings need power. If your powerMargin goes negative, buildings shut down (no \
production, no radar, defenses go offline). Keep powerMargin >= 0 — build power plants when low.
- BUILD ORDER logic: you need a builder (dozer/worker) to construct; power and production buildings \
(barracks = infantry, war factory = vehicles, airfield = aircraft) come before a big army; defensive \
structures protect your base. Build in a sensible order for your plan.
- ARMY: infantry, vehicles, aircraft — each counters different things. A dozer is a BUILDER and drones \
are RECON, neither are fighters. You must keep replacing losses.
- FOG OF WAR: you only see what your units/buildings can see. Scout to reveal the map and find the \
enemy. enemyContacts shows what you currently see (shroud: clear / cached=maybe-stale / undefined).
- MAP: you start in one corner; the enemy AI starts in another (usually the opposite one). myBaseAt \
is your base centre; enemyBaseGuess is the best estimate of the enemy base (their scouted buildings if \
seen, else the opposite corner).
- WINNING / LOSING: you win by destroying ALL enemy buildings; you lose if all of yours are destroyed. \
So defense and offense both matter — but a pure turtle never wins, and an over-commit that strips your \
defense gets your base destroyed while your army is away. Balance is the skill.

YOUR TOOLS: you are given a set of function tools (build/train/capture/scout/defend/attack and base/army \
macros). Each tool's description says what it does. Choose and combine them to execute YOUR strategy. \
Tasks are durable — once running they keep working; don't re-issue an identical active task (no-op). \
Cancel tasks that no longer fit your plan.

MEMORY: the brief carries your history — recentEvents (what just happened), threats (who's attacking \
whom), your own notes, and currentStrategy (your last strategy). Reason over this; learn within the \
game (e.g. if an attack failed, note why and adapt). Use note(text) to remember things the snapshot \
won't re-derive (enemy intent, what worked/failed, where you're expanding).

EACH ROUND:
1. Read the brief and the human directive.
2. set_strategy(situation, plan): your OWN one-line read of the situation and one-line plan right now. \
This is your evolving strategy and memory — revise it honestly as the battle develops.
3. Issue the tool calls that execute your plan (you can call several at once). If your current plan is \
working and nothing needs changing, call no tools.

The human commander's DIRECTIVE in the brief is your standing mission — it outranks your preferences. \
Pursue it. Within it, the strategy and the timing are YOURS to decide.

Brief fields: me (money, powerMargin, counts), myBaseAt, enemyBaseGuess, myForces/myBuildings (grouped \
by template with ids + location `at`), buildable.makeableNow (exact buildable/trainable names right now), \
enemyContacts, points (capturable economy/flags with fog status), threats, tasks (your active tasks + \
status), recentEvents, notes, currentStrategy, directive. Use EXACT template names from the brief."""


class OllamaPlanner:
    name = "ollama"

    def __init__(self, registry, chat, taskmgr, notes, log_path=LLM_LOG):
        self.registry = registry
        self.chat = chat
        self.taskmgr = taskmgr
        self.notes = notes
        self.log_path = log_path
        self._tools = self.registry.skill_tools() + MANAGEMENT_TOOLS

    def plan(self, brief, frame=0, max_steps=4):
        """One planning round = an agentic tool-use loop: the model calls tools, we apply them and
        feed the results back, and it can call MORE — up to max_steps — so it issues many actions per
        round and reacts to what happened, instead of one action per round."""
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": json.dumps(brief, separators=(",", ":"))},
        ]
        t0 = time.time()
        applied_all, total_calls, rationale, last_msg = [], 0, "", None
        for _step in range(max_steps):
            msg = self.chat.chat(messages, tools=self._tools)
            last_msg = msg
            if not msg or msg.get("error"):
                latency_ms = int((time.time() - t0) * 1000)
                self._log(frame, messages, msg or {}, applied_all, latency_ms)
                return {"error": (msg or {}).get("error", "no response"), "applied": applied_all,
                        "calls": total_calls, "latencyMs": latency_ms}
            if msg.get("content"):
                rationale = msg["content"].strip()
            calls = msg.get("tool_calls") or []
            if not calls:
                break
            total_calls += len(calls)
            messages.append({"role": "assistant", "content": msg.get("content", "") or "",
                             "tool_calls": calls})
            step_applied = [self._apply(c, frame) for c in calls]
            applied_all += step_applied
            for c, res in zip(calls, step_applied):  # feed results back so it can continue
                messages.append({"role": "tool",
                                 "tool_name": (c.get("function") or {}).get("name", ""),
                                 "content": json.dumps(res)})
        latency_ms = int((time.time() - t0) * 1000)
        result = {
            "rationale": rationale,
            "applied": applied_all,
            "calls": total_calls,
            "latencyMs": latency_ms,
            "response": {"content": (last_msg or {}).get("content", ""),
                         "thinking": (last_msg or {}).get("thinking"),
                         "tool_calls": (last_msg or {}).get("tool_calls") or []},
        }
        self._log(frame, messages, last_msg or {}, applied_all, latency_ms)
        return result

    def _log(self, frame, messages, msg, applied, latency_ms):
        """Append the full LLM decision exchange (what we sent + what the model replied) to a JSONL
        log — the observable battlefield decision cycle. One line per planning round."""
        if not self.log_path:
            return
        try:
            brief = json.loads(messages[1]["content"]) if len(messages) > 1 else None
            entry = {
                "t": time.time(),
                "frame": frame,
                "model": self.chat.model,
                "latencyMs": latency_ms,
                "request": {"system": messages[0]["content"], "brief": brief, "tools": self.registry.names()},
                "response": {"content": msg.get("content", ""), "thinking": msg.get("thinking"),
                             "tool_calls": msg.get("tool_calls") or [], "error": msg.get("error")},
                "applied": applied,
            }
            with open(self.log_path, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except Exception:  # noqa: BLE001 — logging must never break planning
            pass

    # Identifying param per skill — a new task whose identity matches an active one is a no-op
    # (stops the planner re-issuing the same build/train every plan round and draining resources).
    _IDENTITY = {"build_structure": "structure", "train_units": "unit",
                 "assemble_group": None, "hold_point": "targetId",
                 # singleton macros — only one of each makes sense at a time
                 "build_base": None, "maintain_army": None, "defend_base": None,
                 "capture_points": None, "attack_area": None}

    def _duplicate_of(self, fn, args):
        if fn not in self._IDENTITY:
            return None
        key = self._IDENTITY[fn]
        want = args.get(key) if key else True  # None key => one-of-this-skill is enough to dedupe
        for t in self.taskmgr.active():
            if t["skill"] != fn:
                continue
            have = t["params"].get(key) if key else True
            if have == want:
                return t["id"]
        return None

    def _apply(self, call, frame):
        fn = (call.get("function") or {}).get("name")
        args = (call.get("function") or {}).get("arguments")
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except Exception:  # noqa: BLE001
                args = {}
        args = dict(args or {})
        try:
            if fn == "cancel_task":
                ok = self.taskmgr.cancel(int(args.get("task_id")))
                return {"tool": fn, "task_id": args.get("task_id"), "ok": ok}
            if fn == "set_priority":
                ok = self.taskmgr.set_priority(int(args.get("task_id")), int(args.get("priority", 5)))
                return {"tool": fn, "task_id": args.get("task_id"), "ok": ok}
            if fn == "set_strategy":
                self.notes.set_strategy(args.get("situation", ""), args.get("plan", ""), frame)
                return {"tool": fn, "situation": args.get("situation", "")[:90],
                        "plan": args.get("plan", "")[:90]}
            if fn == "note":
                self.notes.add(args.get("text", ""), frame)
                return {"tool": fn, "text": args.get("text", "")[:80]}
            if self.registry.has(fn):
                priority = int(args.pop("priority", 5)) if "priority" in args else 5
                dup = self._duplicate_of(fn, args)
                if dup is not None:
                    return {"tool": fn, "skipped": "duplicate", "of": dup}
                skill = self.registry.create(fn, args)
                tid = self.taskmgr.add(skill, priority=priority, frame=frame)
                return {"tool": fn, "created": tid, "params": args}
            return {"tool": fn, "error": "unknown tool"}
        except Exception as e:  # noqa: BLE001
            return {"tool": fn, "error": str(e)}
