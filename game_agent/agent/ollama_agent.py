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
        "name": "note",
        "description": ("Record a short strategic note to your own memory (persists across planning "
                        "rounds). Use for observations the world snapshot won't re-derive: enemy "
                        "intent, where you are expanding, what failed."),
        "parameters": {"type": "object",
                       "properties": {"text": {"type": "string"}},
                       "required": ["text"]}}},
]

SYSTEM_PROMPT = """You are the COMMANDER of the external player in a Command & Conquer: Generals \
Zero Hour skirmish. Your goal is to WIN: build an economy, raise an army, defend, then destroy the \
enemy. You play at the STRATEGIC level — you set high-level TASKS; a fast deterministic executor \
carries them out over many ticks. You are called only every several seconds, so set DURABLE intent \
and check progress next round.

PREFER THE MACRO SKILLS — they encode good play so you don't have to micromanage:
- build_base    : builds an economy-first base IN ORDER, one structure at a time (trains a dozer first \
if needed, and auto-builds power whenever you run low). Call it with NO arguments — its default opening \
(power, barracks, defense, war factory, more power/defense) is strong; do NOT pass your own 'plan'. \
Use this ONCE — not many separate build_structure calls.
- maintain_army  : continuously trains & reinforces a standing army to a target size and rallies it \
home. Start it EARLY so you always have a force.
- capture_points : sends units to capture ALL oil/supply/tech/flag points (economy + map control). \
This is how you out-economy the enemy — START IT EARLY and keep it running.
- defend_base    : keeps your whole army guarding your base and counters attackers. Standing.
- attack_area    : sends the army to assault a location; it WAITS until you have enough units, so it \
never suicides a lone unit. Use it to finish the enemy once your army is strong.

WINNING SEQUENCE (do this):
1. FIRST round: start build_base AND maintain_army (target ~12) AND capture_points AND defend_base — \
all of them. You CAN and SHOULD call several tools in one turn. This sets up economy, army production, \
economy-point capture, static defenses, and base defense at once. Capturing oil/supply points early is \
critical — it funds everything.
2. Then each round just MONITOR the tasks list. Don't re-issue tasks that already exist and are \
running/blocked (it does nothing). A 'blocked' build/army task usually means low money/power — be \
patient, don't pile on duplicates.
3. Scout ONCE or twice to locate the enemy base (scout) — do NOT scout every round. The enemyContacts \
in the brief already show where enemies are.
4. ATTACK to win — turtling loses, but do NOT all-in. Once your army reaches ~16+, launch ONE \
attack_area toward the enemy (use the `at` of the biggest enemyContacts group, or scout toward the \
unexplored corner to find their base). attack_area automatically sends only a strike force and keeps a \
home guard, so your base stays defended. Keep maintain_army running to replace losses; the enemy base \
is usually in the opposite corner of the map — push toward it in waves, scouting as you advance. You \
win by destroying their buildings.
5. Keep power non-negative; if buildings are being lost, you are too passive — push out and attack.

Each round you get a JSON brief:
- me: money, powerMargin (keep >= 0), unit/building counts.
- myForces / myBuildings: your stuff grouped by template (ids + rough location `at`). A dozer is a \
builder, not a fighter; drones are recon, not fighters.
- buildable.makeableNow: what you can build/train RIGHT NOW (exact template names).
- enemyContacts: visible enemies; shroud = clear/cached(maybe stale)/undefined(scout it).
- points, threats, tasks (your ACTIVE tasks + status), recentEvents, notes.
- directive: the human commander's STANDING INTENT — it OUTRANKS your preferences. Obey it.

Rules: prefer macros over primitives; don't duplicate active tasks; cancel stuck/obsolete ones; use \
exact template names; keep text brief and respond by CALLING TOOLS. If nothing needs changing, call \
no tools."""


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
