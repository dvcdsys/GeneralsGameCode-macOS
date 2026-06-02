# game_agent — harness architecture

Authoritative architecture reference for the harness. Companion docs:
[`HARNESS.md`](HARNESS.md) (usage / Makefile / layout), [`AGENT.md`](AGENT.md) (agent + human-control
design), and the **game side** [`../../docs/EXTERNAL_CONTROL_API.md`](../../docs/EXTERNAL_CONTROL_API.md)
(the API this harness consumes).

---

## 1. What the harness is (and isn't)

The **harness** is a standalone Python project that plays C&C Generals Zero Hour as a first-class
`PLAYER_EXTERNAL` opponent by driving the game's external-control API **as a client**. It owns: the
API client, the world model, the agent(s) that decide what to do, the run loop, the browser viewer,
and the one-shot tools.

It is **not** the API. The external-control API (REST `:3459` / WS `:3460`, the action log) is part of
the **game** — an engine modification compiled into `generalszh_api`. That boundary is deliberate and
locked: the game exposes capability; the harness exposes *policy*. The harness never links engine code
and makes zero assumptions beyond the documented HTTP contract.

```
                          ┌──────────────────────────  HARNESS (this project, pure-stdlib Python)
  human ──▶ browser UI ──▶│  ui/server.py ──┐
                          │  agent/ (policy) ┼─▶ genapi.GameClient ─┐
                          │  tools/ (probes) ┘                       │   HTTP/JSON + WS
                          └──────────────────────────────────────────┼──────────────────────────────
                                                                      ▼
                                              GAME: external-control API  (generalszh_api)
                                              REST :3459  ·  WS :3460  ·  /tmp/gen_api_actions.jsonl
```

Single rule for all harness code: **everything game-facing goes through `genapi.GameClient`.** No tool,
agent, or page re-implements HTTP. That keeps the API surface in one place and lets us evolve transport
(ret, batching, auth) without touching policy.

---

## 2. Components

### `genapi.GameClient` — the only door to the game
Thin REST+WS wrapper (`genapi/client.py`). Resolves host/port from args or `GEN_API_PORT` /
`GEN_API_WS_PORT` (WS defaults to REST+1).

- Low level: `get/post(path[,body]) -> (status, json)` — never raises; network/HTTP errors come back as
  `(None, {"error": ...})` or `(code, json)`. Typed helpers below unwrap to the body (or `[]`/`None`).
- Reads: `healthz() players() state() units(player=,view=) resources(p) session() map(ds=,zone=)`.
- Tempo: `pause() resume() step(n) speed(fps)` (thin over `control(action,value)`).
- Orders: `command(player,ids,verb,params) commands([...])`.
- Setup/determinism: `set_seed(seed)`.
- Convenience: `external_player()` (the agent's `/players` row, `controller=="external"`),
  `in_game()`, and `events(duration=)` → generator over WS `/events` (delegates to `genapi.ws`).

### `genapi.WorldModel` — what the agent "sees"
In-memory model built from one `/map` + one `/units` snapshot (`genapi/world.py`).
`WorldModel.from_api(client, view=<idx>)` is the normal constructor — **`view` is the fog lens**.

- Terrain: decodes the base64 pathfinder grid → `cell_type/cell_type_name`, `passable(x,y)` (clear|
  rubble), `buildable(x,y)` (clear; coarse until the game ships `/query/can_build`), `ground_height`.
- Objects: `objects(category=,relation=,owner=,tag=)`, plus shortcuts `my_units(owner)`, `enemies()`,
  `economy_points()` (oil/supply capture targets), `garrisonable()` (bunkers). Geometry helpers
  `centroid(objs)`, `nearest(objs,x,y)`.
- Each object carries `id, template, player, x/y/z, health, maxHealth, relationToLocal, category,
  tags[]`, dynamic state when non-default (`veterancy`, `experience`, `visionRange`, `contains`), and
  — under a fog view — a `shroud` (see §4). Static per-template stats come from `/catalog`.

### `genapi.ws.stream_events` — event stream
Pure-stdlib RFC6455 client (`genapi/ws.py`): handshake + frame decode + ping/pong, yields decoded
`/events` payloads (`unit_died`, `unit_produced`, `structure_complete`, `combat`). Used for reactive
logic and run analysis; the decision loop itself is poll-based.

### `genapi.threats.ThreatTracker` — reactive layer
A daemon thread over the `combat` event stream (`genapi/threats.py`). "My unit is under attack" needs a
faster reaction than the low-Hz `decide()` tick, so this aggregates `combat` events for a given player
into a live, cheap-to-read threat picture — per victim: `topAttacker`/`attackers`, cumulative `damage`,
`hits`, `lastFrame` — with stale entries expiring after a window. `decide()` (or a human panel) reads
`tt.threats(now_frame)` without blocking on the socket. Combat events are ground truth, so a fog-aware
agent should cross-check `topAttacker` against its `view=N` units before treating it as a target.

### `agent.Agent` + `agent.run` — the decision loop
`agent/base.py` defines the contract and the driver:

```python
class Agent:
    name = "agent"
    def on_start(self, client): ...                 # one-time setup (e.g. fetch /catalog)
    def decide(self, world, me, client) -> [ {ids, verb, params}, ... ]   # player filled in by loop

def run(agent, client, hz=0.5, view="self", max_ticks=None): ...
```

`run()` is the observe→decide→act heartbeat (§3). `view="self"` resolves to the external player's index
so the agent sees the game through its own fog; `view=None` is omniscient (debug); an int forces a
specific player. **`hz` is strategic cadence — keep it low** (default 0.5/s); this is not micro.

The **LLM agent does not use `run()`** — it uses the two-cadence `agent.orchestrator.orchestrate`
(fast skill executor + slow LLM planner). See §5 and `AGENT.md`.

### `agent.ScriptedAgent` — the no-LLM baseline
`agent/scripted.py`: rallies idle units to the nearest economy point (else map centre). Its only job is
to prove the loop end-to-end and be the reference the LLM agent must beat. New agents subclass `Agent`
and register in `run_agent.py` (`AGENTS` dict → `--agent <name>`).

### `ui/` — viewer + (future) human control
`ui/server.py` serves `ui/map_live.html` over http (the page fetches the API cross-origin; the API
sends `Access-Control-Allow-Origin: *`). The page renders terrain + classified objects, with a **"see
as the bot (fog of war)" toggle (on by default)** that fetches `/units?view=<bot>` and dims
cached/undefined objects. It also serves the **Agent panel** and the human-control endpoints that are
now live: `GET /agent/state` (tasks/notes/events/last-plan, from `/tmp/gen_agent_state.json`) and
`POST /agent/directive` (the Commander's-intent box → `/tmp/gen_agent_directive.json` → immediate
re-plan). Future approve/override/pause-agent modes extend the same seam — see `AGENT.md`.

### `tools/` — one-shot probes
`smoke_read, smoke_control, demo, events_listen, session, map_view` — thin `GameClient` users for
manual verification; each is a "see it working" proof, not part of the agent runtime.

---

## 3. The tick: observe → decide → act

```
run(agent, client, hz, view):
  on_start(client)
  loop:
    wait until in_game() and external_player() exists
    me    = external_player()                       # {index, side, money, power, ...}
    world = WorldModel.from_api(client, view=me.index)   # OBSERVE  (1×/map + 1×/units, fog-applied)
    cmds  = agent.decide(world, me, client)              # DECIDE   (policy: scripted today, LLM next)
    for c in cmds: client.command(player=me.index, **c)  # ACT      (verb table below)
    sleep(1/hz)
```

- **Frame-coherence:** each `/units`/`/map` read is drained on the engine's logic thread, so a snapshot
  is internally consistent. Reads work while the game is paused, so an agent (or human) may
  `pause → inspect → command → resume` for deliberate turns.
- **Idempotent intent:** commands express intent ("attack-move group to X"); re-issuing a similar order
  next tick is fine. The agent need not track in-flight execution at micro resolution.
- **Cadence:** 0.5–1 Hz suits a 7B model and the strategic layer. The engine keeps simulating between
  decisions; the agent corrects course on the next tick.

### Action schema (the harness↔game contract)
`decide()` returns a list of `{ids: [ObjectID...], verb, params}`; the loop fills `player`. The verb
vocabulary is the full set of actions a player can take, organised by intent. **✓ = live in
`generalszh_api` today; ◻ = planned (game-side roadmap).** When a planned verb lands it appears here and
gains an entry in the LLM schema (§5) with **no loop change** — the dispatch is entirely game-side.

**Movement**
| verb | params | meaning | |
|------|--------|---------|---|
| `move` | `pos:{x,y,z}` | move group to a point | ✓ |
| `stop` | — | halt the group (`groupIdle`) | ✓ |
| `retreat` | `pos:{x,y,z}` | fall back (currently mapped to `move`) | ✓ |

**Combat (offense)**
| verb | params | meaning | |
|------|--------|---------|---|
| `attack_move` | `pos:{x,y,z}` | advance to a point, engaging anything on the way | ✓ |
| `attack_target` | `targetId:ObjectID` | focus-fire one object | ✓ |

**Defense**
| verb | params | meaning | |
|------|--------|---------|---|
| `guard_zone` | `anchor:{x,y}`, `engage:{x,y}`, `aggression?`, `fallback_if?` | hold/return-to an area, watching a zone (aggression coarse, `fallback_if` accepted-but-ignored) | ✓ |

**Unit actions**
| verb | params | meaning | |
|------|--------|---------|---|
| `capture` | `targetId` (neutral/enemy building) | send units to take it (`groupEnter`) | ✓ |
| `garrison` / `ungarrison` | `targetId` (building) | enter a building as a bunker / leave it (`ungarrison` with no target = evacuate) | ✓ |
| `repair` | `targetId` | dozers repair the target | ✓ |
| `sell` | — | sell the building(s) in `ids[]` (refund) | ✓ |
| `special_power` | `power`, `targetId?`/`pos?` | general's power / superweapon / power-based unit ability | ✓ |
| `ability` | `button`, `targetId?`/`pos?` | generic command-button ability (deploy, weapon toggle, upgrade, hack…) | ✓ |

**Production / construction** (use `/catalog` for stats, `/buildable?player=N` for what's makeable now + the `builderId` to use)
| verb | params | meaning | |
|------|--------|---------|---|
| `build_structure` | `ids[0]`=dozer, `template`, `pos:{x,y}`, `angle?` | place a building (validates location; returns new `objectId`) | ✓ |
| `train_unit` | `ids[0]`=factory, `template`, `count?` | queue unit production at a factory | ✓ |
| `set_rally` | `ids[0]`=building, `pos:{x,y}` | set a building's rally point | ✓ |

The agent now has the **full action vocabulary** — scout, manoeuvre, attack, defend, capture/garrison,
build, train, repair, sell, and trigger powers/abilities. Remaining game-side polish (see API doc §5):
combat stats in `/catalog` (health/armor/weapons/vision/speed), and `cancel`/queue-management verbs.

---

## 4. Fog-of-war model (recap; full rationale in the game doc §5)

The engine grants non-local AI players a permanent full-map reveal, so the harness must **not** trust raw
shroud. The API synthesizes fog from the view player's + allies' unit vision; the harness receives a
per-object `shroud`:

- **`clear`** — in sight now, live state.
- **`cached`** — building seen before, now out of sight → last-known snapshot (frozen HP/owner). The
  agent must treat it as *possibly stale* (could be dead/captured) until re-scouted.
- **`undefined`** — neutral landmark known from the map (oil/supply, tech, capturable, garrisonable),
  never yet seen → position only, no state.
- Un-scouted enemies and out-of-sight units are simply absent.

Planning implication for the LLM: economy/capture/bunker geography is always available (plan around it);
enemy composition must be *discovered* (reward scouting); never assume a `cached` building still stands.

---

## 5. The LLM agent — two tiers (built; full design in [`AGENT.md`](AGENT.md))

The LLM agent is **not** a single `decide()` — an LLM can't drive an RTS in real time. It is a slow
**planner** orchestrating a fast deterministic **executor**, with the planner's tools being the skill
library (so the model issues *tasks*, not coordinates):

```
        PLANNER (agent.ollama_agent)                     EXECUTOR (agent.tasks.TaskManager)
   compact brief ─▶ Ollama /api/chat with               every ~0.5 s: tick each active Skill
   tools = skill catalog + {cancel,priority,note}  ──▶   (build %, production counts, threat
   tool calls mutate the task queue + notes              reactions); retire done/failed
        (~every 15-30 s, or on directive change)         (agent.orchestrator drives both cadences)
```

- **Skills** (`agent/skills/`) — parameterised stateful routines; each is one native function-calling
  tool. `build_structure / train_units / assemble_group / defend_sector / attack_area / hold_point /
  scout`. Add one by subclassing `Skill` + registering it; it appears to the model automatically.
- **Planner** (`agent/ollama_agent.OllamaPlanner`) — builds the brief (`agent.brief`), calls Ollama
  (`qwen3.5:9b`, tools, thinking off, stdlib HTTP via `agent.ollama_client`), applies tool calls with
  **dedup** so re-planning can't recreate equivalent active tasks.
- **Memory** (`agent/journal.py`) — `EventJournal` (digest + exact event counts) and `AgentNotes`
  (planner scratchpad); folded into the brief alongside the task ledger and the human directive.
- **Orchestrator** (`agent/orchestrator.py`) — the two-cadence driver. Persists agent state to
  `/tmp/gen_agent_state.json` and reads the human directive from `/tmp/gen_agent_directive.json`
  (file-based control channel ⇄ the UI server).

Authority stays game-side (the LLM only triggers documented skills/verbs); compaction + the skill layer
are where the engineering lives. Determinism & eval (M4) reuse `POST /session {seed}` + the action log.

---

## 6. Invariants

- Pure stdlib (the Ollama agent talks to a local HTTP server — still no pip package).
- All game I/O via `GameClient`; no engine assumptions beyond the documented contract.
- Strategic cadence (low `hz`); never busy-loop the engine.
- Harness owns policy/UI/state; the game owns capability/authority/determinism.
- Only ever launch/kill `generalszh_api` (never the user's `generalszh`); stand maps must be `[ SK | AI ]`.
