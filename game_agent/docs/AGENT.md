# Agent design — LLM player + human control

How the harness turns a small local LLM into a `PLAYER_EXTERNAL` player, and how a human supervises
it. This is the design/roadmap; today only the scripted baseline (`agent/scripted.py`) exists.

## Interface

Every agent implements `agent.base.Agent`:

```python
class Agent:
    def on_start(self, client): ...
    def decide(self, world, me, client) -> list[dict]:   # [{ids, verb, params}, ...]
```

`agent.base.run()` drives it: connect → wait for match → build `WorldModel` (fog-aware) → `decide()`
→ dispatch commands. Register new agents in `run_agent.py` (`--agent <name>`).

## LLM agent (Ollama, qwen/gemma 7B) — planned `agent/ollama_agent.py`

Local model via **Ollama** (`http://localhost:11434/api/chat`), e.g. `qwen2.5:7b` or `gemma2`. No
Python dependency — plain HTTP. The agent is **strategic, low-cadence** (a decision every few
seconds, not per-frame micro), which suits a 7B model.

Pipeline per decision:

1. **Observe** — `WorldModel.from_api(client, view=me.index)` (fog-aware: the API synthesizes the
   bot's fog from its + allies' unit vision — see `../../docs/EXTERNAL_CONTROL_API.md` §5).
2. **Compact** — the model cannot read 2000 raw objects. Summarize into a small structured brief:
   my forces (grouped by type + count + centroid), visible enemy contacts (by area), economy/capture
   points (`world.economy_points()`), garrisonable bunkers, my economy (`/resources`), and — once the
   what I can build now (`/buildable`, with the `builderId` to use) and costs/prereqs from `/catalog`.
3. **Prompt** — system prompt = role + rules + the **action schema** (the `/command` verbs:
   move/combat/defense/capture/garrison/repair/sell/build_structure/train_unit/set_rally/special_power/ability); user
   message = the compact brief. Ask for a JSON list of actions (constrain with Ollama's `format:json`).
4. **Parse → act** — validate the JSON against the schema, map unit references to real ObjectIDs, and
   return the command dicts; `run()` dispatches them via `/command`/`/commands`.

Keep the verb→engine mapping authoritative on the game side; the LLM only emits the documented schema.
Every emitted action is captured in the bot-action log (`/tmp/gen_api_actions.jsonl`) for analysis and
for building eval/fine-tune datasets later.

## Human control

The human supervises the agent through the browser UI, mediated by the **harness server**
(`ui/server.py`) — which is part of the harness, distinct from the game's API:

```
browser (map_live.html)  ⇄  harness server (ui/server.py)  ⇄  agent loop
                                         │
                                         └─▶ game API (:3459 / :3460)
```

Planned control modes (harness server holds agent state + exposes control endpoints; the UI grows
panels for them):

- **Observe** — agent runs autonomously; UI shows its current world brief + the actions it just issued
  (overlaid on the map: target arrows, group selections).
- **Approve** — agent *proposes* actions; they wait in the UI until the human confirms/edits/rejects.
- **Override** — human issues manual orders directly (click units → click destination), which the
  harness forwards as `/command`s; agent paused or constrained.
- **Pause agent** — stop the decision loop without pausing the game (distinct from `/control pause`).

The map viewer expands to render: the agent's fog-limited view (`/units?view=N`), its decision
overlay, and the control panels. Because human orders and agent orders both flow through the same
`/command` path, they're uniformly recorded in the action log.

## Determinism & evaluation (later, M4)

For reproducible matches and an optimizer loop: fix the RNG via `POST /session {seed}` (pre-start),
read the outcome via `GET /session` (`outcome.localResult/decided/endFrame`), and score runs from the
action log + outcome. Same launch path + seed → repeatable game for A/B-ing prompts/agents.

## Dependencies (game side — see ../../docs/EXTERNAL_CONTROL_API.md §5)

- `/catalog` (unit/building stats + tech tree + footprint) — needed for build/train decisions and
  matchup reasoning.
- `/buildable` — what's constructible now.
- `/query/can_build` + `/query/path` — authoritative placement/pathing checks.

Fog-of-war is **done**: `view=N` already gives the agent a realistic limited picture (vision-range
based, with scouted-structure memory), independent of the engine's local-player-only shroud.
