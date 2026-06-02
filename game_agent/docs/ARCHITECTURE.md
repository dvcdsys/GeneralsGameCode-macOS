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
  tags[]` and — under a fog view — a `shroud` (see §4).

### `genapi.ws.stream_events` — event stream
Pure-stdlib RFC6455 client (`genapi/ws.py`): handshake + frame decode + ping/pong, yields decoded
`/events` payloads (`unit_died`, `unit_produced`, `structure_complete`, `combat`). Used for reactive
logic and run analysis; the decision loop itself is poll-based.

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

### `agent.ScriptedAgent` — the no-LLM baseline
`agent/scripted.py`: rallies idle units to the nearest economy point (else map centre). Its only job is
to prove the loop end-to-end and be the reference the LLM agent must beat. New agents subclass `Agent`
and register in `run_agent.py` (`AGENTS` dict → `--agent <name>`).

### `ui/` — viewer + (future) human control
`ui/server.py` serves `ui/map_live.html` over http (the page fetches the API cross-origin; the API
sends `Access-Control-Allow-Origin: *`). The page renders terrain + classified objects, with a **"see
as the bot (fog of war)" toggle (on by default)** that fetches `/units?view=<bot>` and dims
cached/undefined objects. This server is the seam where human-control endpoints (observe / approve /
override / pause-agent) will live — see `AGENT.md`.

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

## 5. Next: the Ollama / Qwen-7B agent

A new `agent/ollama_agent.py` implementing `Agent.decide()` by prompting a local model over Ollama
(`http://localhost:11434/api/chat`, e.g. `qwen2.5:7b`). **No new dependency** (plain HTTP via
`urllib`, like `GameClient`) and **no engine/loop change** — it slots into the existing pipeline:

```
WorldModel(view=self)
   │  compact()                      # 2000 raw objects -> a small structured brief (we write this)
   ▼
world brief (JSON, ~1–2 KB)
   │  prompt = system(role + rules + ACTION SCHEMA) + user(brief)
   ▼
Ollama /api/chat  (format:"json", low temp, qwen2.5:7b)
   │  parse + validate against schema
   ▼
actions [{group|unit refs, verb, params}]
   │  resolve refs -> real ObjectIDs (from the brief's id lists)
   ▼
return [{ids, verb, params}]  ──▶  run() dispatches via /command (already logged to the action log)
```

**Design points (to settle when we build it):**

1. **Compaction is the crux, not the model.** A 7B model can't read 2000 objects. `compact(world, me)`
   produces a brief: my economy (`/resources`: money, power margin), my forces grouped by template →
   `{type, count, centroid, ids}`, visible enemy contacts grouped by area, capture/economy points and
   bunkers with `clear|cached|undefined` status, plus `/buildable` (what's makeable now + the
   `builderId` to use) and `/catalog` (costs/prereqs). Keep it stable and small; this is where most of
   the engineering goes.
2. **Constrained output.** System prompt embeds the §3 action schema; request Ollama `format:"json"`
   and low temperature so the reply is a parseable action list. Reject/repair on schema mismatch
   (one retry, then fall back to the previous tick's intent or the scripted baseline).
3. **Reference indirection.** The model emits group/unit references that exist in the brief (e.g.
   `"group":"rocket_inf"` or explicit `ids`); the harness maps them to live ObjectIDs. The model never
   invents IDs.
4. **Authority stays on the game side.** The LLM only emits documented verbs; verb→engine mapping
   (AIGroup dispatch) is the game's job. Anything illegal is rejected by `/command` and logged.
5. **Cadence vs latency.** A 7B decision takes ~hundreds of ms–seconds; that fits `hz≈0.2–0.5`. The loop
   already tolerates this; long calls just lower the effective tick rate. Consider running the model
   call off the critical path later if needed.
6. **Determinism & eval (M4).** Fix RNG via `POST /session {seed}` pre-start, read `GET /session`
   outcome, and score from the action log + outcome. Same launch + seed ⇒ repeatable game for A/B-ing
   prompts/models. The action log (`/tmp/gen_api_actions.jsonl`) is the dataset for eval and later
   fine-tuning.

**Integration checklist for the next session:**
- [ ] `agent/ollama_agent.py`: `OllamaAgent(Agent)` with `compact()`, `prompt()`, `parse()`, `decide()`.
- [ ] Register in `run_agent.py` `AGENTS = {"scripted": ..., "ollama": OllamaAgent}`; flags for model name
      / endpoint / temperature.
- [ ] `make agent AGENT=ollama` works against the stand; verify accepted orders + sane behaviour.
- [ ] (Optional) overlay the agent's last brief + chosen actions on `map_live.html`.
- [ ] Game-side `/catalog` + `/buildable` and the full verb set (build/train/capture/abilities) are
      **already live** — the agent can use them immediately; no game-side blockers remain for M3.

---

## 6. Invariants

- Pure stdlib (the Ollama agent talks to a local HTTP server — still no pip package).
- All game I/O via `GameClient`; no engine assumptions beyond the documented contract.
- Strategic cadence (low `hz`); never busy-loop the engine.
- Harness owns policy/UI/state; the game owns capability/authority/determinism.
- Only ever launch/kill `generalszh_api` (never the user's `generalszh`); stand maps must be `[ SK | AI ]`.
