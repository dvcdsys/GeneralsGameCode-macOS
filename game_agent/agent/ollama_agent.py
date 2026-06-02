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

# Only these HIGH-LEVEL skills are exposed to the LLM. The low-level primitives (build_structure,
# train_units, assemble_group, hold_point, defend_sector) are used INTERNALLY by the macros and the
# orchestrator — a small model misuses them badly (it placed a hallucinated building forward at the
# enemy base and re-commanded the lone dozer every tick, so nothing ever finished). The commander
# orchestrates macros; the macros handle construction/training correctly.
LLM_SKILLS = {"build_base", "maintain_army", "capture_points", "defend_base", "attack_area", "scout"}

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
        self._tools = [t for t in self.registry.skill_tools()
                       if (t.get("function") or {}).get("name") in LLM_SKILLS] + MANAGEMENT_TOOLS
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

    def plan(self, brief, frame=0, max_steps=4):
        """One planning round = an agentic tool-use loop over the CONTINUOUS conversation: the model
        sees its recent reasoning + the fresh brief, calls tools, we apply them and feed results back,
        and it can call MORE — up to max_steps. After the round we fold its reasoning into memory."""
        messages = self._build_messages(brief)
        t0 = time.time()
        applied_all, total_calls, rationale, thinking, last_msg = [], 0, "", "", None
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
