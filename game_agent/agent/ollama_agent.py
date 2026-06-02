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
from collections import deque

LLM_LOG = "/tmp/gen_agent_llm.jsonl"

# Rolling-memory ("infinity chat") settings: the planner is one continuous conversation. The last
# KEEP_ROUNDS rounds of the model's OWN reasoning (thinking + plan + actions) stay verbatim so it sees
# what it was thinking recently; everything older is folded into a bounded running summary so the chat
# can run forever without the context growing without bound.
KEEP_ROUNDS = 20
SUMMARY_CAP = 4000  # max chars of compacted older-round memory

# The LLM commands CONCRETELY: it picks specific unit ids and specific targets/locations. No
# high-level "do everything" macros (those hid too much and misbehaved) — the commander issues
# explicit orders and re-issues them as the battle changes.
LLM_SKILLS = {"build_structure", "train_units", "hold_point", "defend_sector", "attack_area", "scout",
              "pipeline"}
MAX_PIPELINES = 6  # cap on concurrent multi-step plans

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

SYSTEM_PROMPT = """You are the COMMANDER of your army in a Cold War Crisis (CWC) real-time strategy \
battle. You think at the STRATEGIC level: you read the battlefield, decide what to do, and issue \
high-level TASKS that a fast executor carries out tick-by-tick. You are called every few seconds, so \
form DURABLE intent and adjust it as the situation changes. There is no fixed script — YOU decide the \
strategy from what you see, your memory, and the human commander's directive.

CRITICAL — this is the CWC mod, NOT any stock game you may know. The unit and building names are \
mod-specific (e.g. CWCus... / CWCru...). NEVER invent a name or recall one from another game (there is \
no "power plant", "supply center" etc. unless the brief lists it). ONLY ever name templates that appear \
in the current brief — buildable.makeableNow (what you can build/train right now), myForces, \
myBuildings. If something you want is not in buildable.makeableNow, you CANNOT build it yet (missing \
prerequisite or money) — build a prerequisite or wait; do not guess names.

HOW THIS GAME WORKS (principles to reason from):
- ECONOMY funds everything. Money comes from supply/oil/cash points and from capturing fuel/economy \
buildings and flags. The more economy points you hold, the bigger army you can afford. Map control = \
economy.
- POWER: if powerMargin goes NEGATIVE, buildings shut down — fix it by building a power structure. \
But if powerMargin is 0 AND no power building appears in buildable.makeableNow, power is simply not \
tracked/needed in this setup — do NOT chase it or invent power buildings; focus on army and economy. \
Only build what buildable.makeableNow actually lists (use those EXACT names).
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

YOU COMMAND CONCRETELY — issue explicit orders to specific units and targets (no auto-pilot). Your tools:
- build_structure(structure, area={x,y}) — build ONE named structure (exact name from \
buildable.makeableNow) near a location (use area≈myBaseAt; a legal spot is found for you, a dozer is \
auto-assigned).
- train_units(unit, count) — train N of a unit (exact trainable name from buildable.makeableNow).
- hold_point(ids=[...], targetId=N) — send THESE units to CAPTURE point N (from `points`: oil/fuel/flag \
— use its id). Or hold_point(ids, pos={x,y}) to make them hold/guard a spot.
- defend_sector(ids=[...], area={x,y}) — send THESE units to defend an area (e.g. your base).
- attack_area(ids=[...], area={x,y}) — send THESE units to attack-move into an area (e.g. enemyBaseGuess).
- scout(ids=[...], area={x,y}) — send a unit to scout a location.
- pipeline(steps=[...], label) — an ORDERED PLAN where each step finishes before the next starts. Use \
it for dependent sequences, e.g. build a barracks, THEN train infantry once it exists, THEN build a war \
factory, THEN train tanks. steps (max 8) are objects: {do:"build",structure,area}, {do:"train",unit,count}, \
{do:"capture",targetId,ids}, {do:"attack",area,ids}, {do:"scout",area,ids}, {do:"wait",frames|until_building|until_units}. \
Example: pipeline(label="open", steps=[{do:"build",structure:"CWCusBarracks",area:myBaseAt}, \
{do:"wait",until_building:"CWCusBarracks"}, {do:"train",unit:"CWCusInfAntiTank",count:4}]). You may have \
up to 6 pipelines running. Prefer a pipeline when steps depend on each other; use the single tools above \
for independent one-off orders.
Pick the `ids` from myForces (each group lists its unit ids). Assign groups to jobs: some defend the \
base, a few capture nearby points, the rest attack when strong. Orders are durable — units keep doing \
their last order until you reassign them; re-issuing the SAME order is a harmless no-op. You manage the \
whole economy+army yourself: each round check counts and issue build_structure / train_units as needed.

ALWAYS pass a short `reason` with every order (e.g. "capture oil for income", "hold the east flank", \
"siege enemy base"). YOUR ORDER LEDGER: the brief's `tasks` lists every order you currently have out — \
the units it commands, its target, your recorded reason, and its status. THIS IS YOUR ACTION MEMORY: \
read it first each round to remember which units are already assigned and why, so you don't double-assign \
a unit or forget a job. Units NOT shown in any order are idle — give them something to do.

MEMORY: the brief carries your history — recentEvents (what just happened), threats (who's attacking \
whom), your own notes, and currentStrategy (your last strategy). Reason over this; learn within the \
game (e.g. if an attack failed, note why and adapt). Use note(text) to remember things the snapshot \
won't re-derive (enemy intent, what worked/failed, where you're expanding).

EACH ROUND:
1. Read the brief and the human directive.
2. set_strategy(situation, plan): your OWN one-line read of the situation and one-line plan right now.
3. Issue concrete tool calls (several at once). A typical early round: build_structure the next building \
you need; train_units some infantry; hold_point a couple of units onto the nearest capturable point id; \
defend_sector the rest at myBaseAt. Later: attack_area a strong group toward enemyBaseGuess. Only re-issue \
an order if you're changing it.

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
        self._tools = [t for t in self.registry.skill_tools()
                       if (t.get("function") or {}).get("name") in LLM_SKILLS]
        # Every order carries a short `reason` — the LLM's note of WHY it sent these units here. It is
        # stored on the task and replayed in the brief's order ledger, so the commander keeps the
        # context of its own actions (which units it assigned where and why).
        for t in self._tools:
            props = ((t.get("function") or {}).get("parameters") or {}).get("properties")
            if isinstance(props, dict):
                props["reason"] = {"type": "string",
                                   "description": "short WHY for this order (kept in your order ledger)"}
        self._tools += MANAGEMENT_TOOLS
        self.chat.think = True              # let it reason; thinking is kept in the rolling memory
        self.reasoning = deque()            # one entry per round: {"frame","text"} (kept verbatim)
        self.summary = ""                   # compacted memory of rounds older than KEEP_ROUNDS

    def _build_messages(self, brief):
        """Assemble the continuous ('infinity') conversation: system principles, a compacted memory of
        older rounds, the last KEEP_ROUNDS rounds of the model's own reasoning verbatim, then the fresh
        brief. The model thus sees its recent thinking and decisions and can build on them."""
        messages = [{"role": "system", "content": SYSTEM_PROMPT}]
        if self.summary:
            messages.append({"role": "user",
                             "content": "MEMORY of earlier rounds (compacted):\n" + self.summary})
        for r in self.reasoning:  # the model's own prior reasoning, kept verbatim (last KEEP_ROUNDS)
            messages.append({"role": "assistant", "content": r["text"]})
        messages.append({"role": "user", "content": json.dumps(brief, separators=(",", ":"))})
        return messages

    def _record_round(self, frame, thinking, rationale, applied):
        """Append this round's reasoning to the rolling window; fold anything beyond KEEP_ROUNDS into
        the bounded running summary (so the chat is effectively infinite)."""
        reason = (thinking or "").strip() or (rationale or "").strip()
        acts = []
        for a in applied or []:
            if a.get("created") is not None:
                acts.append("{}#{}".format(a.get("tool"), a.get("created")))
            elif a.get("tool") in ("set_strategy", "note", "cancel_task", "set_priority"):
                acts.append(a.get("tool"))
        text = "[f{}] {}".format(frame, reason[:700])
        if acts:
            text += "\nACTIONS: " + ", ".join(acts)
        self.reasoning.append({"frame": frame, "text": text})
        while len(self.reasoning) > KEEP_ROUNDS:
            old = self.reasoning.popleft()
            # compaction: keep the most recent SUMMARY_CAP chars of dropped reasoning one-liners
            first_line = old["text"].splitlines()[0] if old["text"] else ""
            self.summary = (self.summary + "\n" + first_line).strip()[-SUMMARY_CAP:]

    def plan(self, brief, frame=0, max_steps=2):
        """One planning round over the CONTINUOUS conversation: the model sees its recent reasoning +
        the fresh brief and emits its orders (usually all at once). max_steps is kept LOW — concrete
        orders are independent, so we don't need to feed tool results back across many slow thinking
        steps (that made each round ~38s); the model re-plans next cycle on a fresh brief instead."""
        system = SYSTEM_PROMPT
        messages = self._build_messages(brief)
        t0 = time.time()
        applied_all, total_calls, rationale, thinking, last_msg = [], 0, "", "", None
        for _step in range(max_steps):
            msg = self.chat.chat(messages, tools=self._tools)
            last_msg = msg
            if not msg or msg.get("error"):
                latency_ms = int((time.time() - t0) * 1000)
                self._log(frame, brief, msg or {}, applied_all, latency_ms, system)
                return {"error": (msg or {}).get("error", "no response"), "applied": applied_all,
                        "calls": total_calls, "latencyMs": latency_ms}
            if msg.get("content"):
                rationale = msg["content"].strip()
            if msg.get("thinking"):
                thinking = msg["thinking"].strip()
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
        # fold this round's reasoning into the rolling memory (infinity chat)
        self._record_round(frame, thinking, rationale, applied_all)
        result = {
            "rationale": rationale,
            "applied": applied_all,
            "calls": total_calls,
            "latencyMs": latency_ms,
            "memoryRounds": len(self.reasoning),
            "response": {"content": (last_msg or {}).get("content", ""),
                         "thinking": (last_msg or {}).get("thinking") or thinking,
                         "tool_calls": (last_msg or {}).get("tool_calls") or []},
        }
        self._log(frame, brief, last_msg or {}, applied_all, latency_ms, system)
        return result

    def _log(self, frame, brief, msg, applied, latency_ms, system=""):
        """Append the full LLM decision exchange (what we sent + what the model replied) to a JSONL
        log — the observable battlefield decision cycle. One line per planning round. The brief is
        passed in directly (in the rolling-memory conversation it is the LAST message, not messages[1],
        so re-parsing from the message list silently broke logging after round 1)."""
        if not self.log_path:
            return
        try:
            entry = {
                "t": time.time(),
                "frame": frame,
                "model": self.chat.model,
                "latencyMs": latency_ms,
                "request": {"system": system, "brief": brief, "tools": self.registry.names()},
                "response": {"content": msg.get("content", ""), "thinking": msg.get("thinking"),
                             "tool_calls": msg.get("tool_calls") or [], "error": msg.get("error")},
                "applied": applied,
            }
            with open(self.log_path, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except Exception:  # noqa: BLE001 — logging must never break planning
            pass

    @staticmethod
    def _signature(fn, params):
        """A normalized fingerprint of a concrete order. Re-issuing the SAME order (same skill, target,
        location bucket, unit ids) is treated as a no-op so the LLM can safely repeat its intent each
        round without piling up duplicate tasks; a DIFFERENT order (other ids/target/place) is new."""
        # build_structure dedups by the STRUCTURE alone (ignore the jittered area) so a small model
        # that re-orders the same building at slightly different coords doesn't spawn 3 barracks.
        if fn == "build_structure":
            return "build_structure|structure={}".format(params.get("structure"))
        if fn == "pipeline":   # dedup by label + the sequence of step verbs/targets
            steps = params.get("steps") or []
            seq = ";".join("{}:{}".format(s.get("do"), s.get("structure") or s.get("unit")
                                          or s.get("targetId") or "") for s in steps if isinstance(s, dict))
            return "pipeline|{}|{}".format(params.get("label", ""), seq)
        parts = [fn]
        for k in ("structure", "unit", "targetId"):
            if params.get(k) is not None:
                parts.append("{}={}".format(k, params[k]))
        for k in ("area", "pos"):
            p = params.get(k)
            if isinstance(p, dict) and "x" in p:
                parts.append("{}={},{}".format(k, round(p["x"] / 150), round(p["y"] / 150)))  # ~150u bucket
        ids = params.get("ids")
        if ids:
            parts.append("ids=" + ",".join(str(i) for i in sorted(ids)))
        return "|".join(parts)

    def _duplicate_of(self, fn, args):
        sig = self._signature(fn, args)
        for t in self.taskmgr.active():
            if t["skill"] == fn and self._signature(fn, t["params"]) == sig:
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
                if fn == "pipeline":  # cap concurrent multi-step plans
                    n = sum(1 for t in self.taskmgr.active() if t["skill"] == "pipeline")
                    if n >= MAX_PIPELINES:
                        return {"tool": fn, "skipped": "pipeline cap ({})".format(MAX_PIPELINES)}
                skill = self.registry.create(fn, args)
                tid = self.taskmgr.add(skill, priority=priority, frame=frame)
                if tid is None:
                    return {"tool": fn, "skipped": "task cap"}
                return {"tool": fn, "created": tid, "params": args}
            return {"tool": fn, "error": "unknown tool"}
        except Exception as e:  # noqa: BLE001
            return {"tool": fn, "error": str(e)}
