# Agent design — LLM planner + skill executor + human control

How the harness turns a small local LLM into a `PLAYER_EXTERNAL` commander, and how a human supervises
it. **This is implemented** (`agent/ollama_agent.py` + `agent/skills/` + `agent/tasks.py` +
`agent/orchestrator.py`); the no-LLM `agent/scripted.py` remains as the baseline.

## The core idea: two tiers — slow planner, fast executor

An LLM cannot drive an RTS in real time (a planning call is ~1 s warm, longer cold). So the agent is
split into two cadences:

```
            (slow, ~every 15-30 s, or on directive change)         (fast, ~2 Hz, deterministic)
   ┌──────────────────────────────────────────┐        ┌────────────────────────────────────────┐
   │  PLANNER  (agent.ollama_agent.OllamaPlanner)│        │  EXECUTOR (agent.tasks.TaskManager)      │
   │  • gets a compact brief (agent.brief)       │ tasks  │  • ticks every active Skill state-machine│
   │  • calls Ollama with the SKILL CATALOG as   │──────▶ │  • each Skill issues low-level /command's │
   │    native tools + task-management ops        │        │  • advances build %, counts production,  │
   │  • tool calls MUTATE the task queue + notes  │        │    reacts to threats, retires done/failed│
   └──────────────────────────────────────────┘        └────────────────────────────────────────┘
              ▲  brief: world + memory + tasks                         │  reads WorldModel(view=self) each tick
              └────────────────────────────────────────────────────────┘
```

The LLM **plans and orchestrates**; deterministic Python **executes in real time**. A single tool call
("build a War Factory in the north", "assemble 4 rockets at the ridge") becomes many ticks of orders
the model never has to micromanage.

## Skills — the extensible tool library (`agent/skills/`)

A **Skill** is a parameterised, stateful routine. `tick(ctx)` is called every fast tick; it advances
its own state machine, issues commands via `ctx.client`, and reports a status (`pending` → `running` →
`done`/`failed`/`blocked`). Each skill is exposed to the model as **one native function-calling tool**
(name + description + JSON-schema params), so the model issues *tasks*, not coordinates.

Starter library (`agent/skills/library.py`):

| skill (tool) | intent | how it executes |
|---|---|---|
| `build_structure` | place a building near an area | finds a free dozer (avoids double-booking), spirals to a legal cell, tracks build % to completion |
| `train_units` | queue N units | finds the factory that can make it now (`/buildable`), counts `unit_produced` events to done |
| `assemble_group` | build a mixed force at a muster point | sets factory rally points, trains each type, done when all produced |
| `defend_sector` | hold an area + counter attackers | standing `guard_zone`; cross-checks `ThreatTracker` and focus-fires visible attackers |
| `attack_area` | assault an area | `attack_move`; done when no enemies remain near the target |
| `hold_point` | take & hold a point / capturable | `capture` then `guard_zone` |
| `scout` | reveal fog | sends one unit; done when a unit reaches the area |

**Add a capability** = write a `Skill` subclass + register it in `agent/skills/registry.py`. It appears
in the LLM tool list automatically — no planner/loop change. Teach the model to use it via the tool
`description` and (if needed) the system prompt. The model can still emit raw verbs indirectly through
these skills; authority stays game-side (illegal orders are rejected by the skill or `/command` and
surface as a `failed` task, never a crash).

## Planner (`agent/ollama_agent.py`)

Each planning round: build a brief (`agent.brief.compose_brief`) → call Ollama `/api/chat` with
`tools = skill catalog + {cancel_task, set_priority, note}` → apply each tool call. Skill tool calls
`add` a task (with **dedup**: a task whose identity matches an active one is skipped, so re-planning
can't drain resources); management calls mutate the queue / write a note. No new Python dependency
(stdlib HTTP, like `GameClient`).

- **Model:** `qwen3.5:9b` by default (tools + thinking; thinking disabled for latency). Override with
  `GEN_OLLAMA_HOST` / `GEN_OLLAMA_MODEL` or `--ollama-host` / `--model`. Warm planning ≈ 1 s; the first
  call pays a one-time model-load (~tens of s).
- **System prompt:** role = strategic commander; explains the two-tier control, the brief fields, fog
  semantics (clear/cached/undefined), and that the human **directive outranks** its own preferences.
- **Observability:** every planning round is logged to `/tmp/gen_agent_llm.jsonl` — the full decision
  cycle (`request:{system,brief,tools}` + `response:{content,thinking,tool_calls}` + `applied` +
  `latencyMs`). `make llmlog` tails it; the Agent panel shows the latest reply. This is how you see
  *why* the agent acted.

## Memory under a finite context (`agent/journal.py`)

The model never sees the raw firehose. Two bounded structures bridge it:

- **EventJournal** — daemon over WS `/events`; keeps a ring of raw events (exact counts like "produced
  since frame F") and a short rolling **digest** of notable lines (my structure finished, my unit died,
  enemy unit appeared).
- **AgentNotes** — a small scratchpad the planner writes via the `note` tool and reads back next round
  (its own long-horizon memory: enemy intent, where it's expanding, what failed). Capped.

Plus the **task ledger** itself is memory (what's been ordered + status), and the human **directive**
is standing intent. `compose_brief` packs all of this — economy, forces by type, enemy contacts (with
fog status), always-known economy/capture geography, `/buildable` make-now list, threats, tasks,
digest, notes, directive — into a terse (~1–3 KB) JSON brief.

## Human control (`ui/server.py` + `ui/map_live.html`)

Decoupled via two files in `/tmp` (the project's idiom, like the action log) so the agent process and
the UI server never block each other:

```
browser (map_live.html)  ⇄  harness server (ui/server.py)  ⇄  files in /tmp  ⇄  orchestrator
   directive box  ──POST /agent/directive──▶  /tmp/gen_agent_directive.json ──▶ re-plan now
   task panel     ──GET  /agent/state    ◀──  /tmp/gen_agent_state.json     ◀── every fast tick
```

The **Agent panel** in the viewer shows: live tasks with status pills (running/blocked/done/failed),
task history, the planner's last rationale + tool-call count, agent notes, recent events — and a
**Commander's intent** textbox. Typing a directive ("defend the north, hold the central oil") and
hitting *send* writes the directive file; the orchestrator picks it up and **re-plans immediately**,
folding it into the system prompt as intent the model must obey. This is the human steering channel the
design calls for: set a global behaviour/goal, watch the task list, correct course.

Future control modes (same seam): **approve** (agent proposes, human confirms), **override** (manual
orders forwarded as `/command`s), **pause-agent** (stop planning without pausing the game).

## Running it

```bash
make run                                   # launch the stand (external player, [SK|AI] map)
make agent AGENT=ollama                    # planner + executor (qwen3.5:9b on $GEN_OLLAMA_HOST)
make viewer                                # browser UI with the Agent panel (directive + tasks)
# direct:
GEN_OLLAMA_HOST=192.168.1.168:11434 python3 run_agent.py --agent ollama --plan-period 20 --fast-hz 2
```

## Known limitations / next refinements

- **Build placement:** the engine rejects `illegal build location` for spots too close to the base even
  on clear terrain (empirically a structure must sit ~200+ world-units from existing buildings).
  `find_build_spot` now starts at `min_radius=200` and varies per attempt; a proper game-side
  `/query/can_build` would remove the guessing. Also: you need a dozer to build — the planner trains
  one (from the Command Center) when it has none.
- **Dozer contention:** with one dozer, a second `build_structure` correctly goes `blocked` until the
  dozer frees; a stalled foundation isn't auto-resumed (no resume-construction verb yet).
- **Strategy quality** is prompt/skill-tuning, not framework: the model can over-commit while low on
  cash. Tune the system prompt, add economy-gating skills, or a cheaper "what-should-I-prioritise"
  pre-pass.
- **Planning is synchronous** — the executor pauses ~1 s per plan. Fine at strategic cadence; a worker
  thread + mutation queue would remove even that if needed.
- More skills (expand-to-oil, tech-up, base-wall, superweapon-watch), `/catalog` combat stats in the
  brief, and reflex skills wired directly to `ThreatTracker`.

## Determinism & evaluation (later, M4)

Reproducible matches + optimizer loop: fix RNG via `POST /session {seed}` (pre-start), read outcome via
`GET /session`, score runs from the action log + outcome. Same launch + seed ⇒ repeatable game for
A/B-ing prompts, models, and skills.
