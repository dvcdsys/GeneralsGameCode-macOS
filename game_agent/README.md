# game_agent — in-game agent harness

The **harness** that plays C&C Generals Zero Hour as a first-class `PLAYER_EXTERNAL` opponent by
driving the game's external-control API. It will eventually run a small local LLM (Ollama, qwen/gemma
7B) as the agent, with a browser UI for human visualization + control.

**Boundary:** the API is part of the **game** (the engine modification — see
[`../docs/EXTERNAL_CONTROL_API.md`](../docs/EXTERNAL_CONTROL_API.md)). This folder is the **harness**,
a separate client layer. Pure Python standard library (no `pip install`).

## Quick start

```bash
cd game_agent
make build      # build the game binary (generalszh_api)
make run        # launch the stand (skirmish + API), wait until in-game
make agent      # run the STRATEGIST bot (the strong v2 CWC bot) — watch it play
make viewer     # interactive world-view → http://localhost:8088/map_live.html
make            # full target list
```

`make agent` runs **`strategist`** by default. `make agent AGENT=commander` runs the older bot,
`AGENT=scripted` the no-op baseline, `AGENT=ollama` the LLM planner.

## The Strategist (algorithmic CWC bot, no LLM)

`agent/strategist/` — a strong, dynamic, map-aware opponent that plays a full game on its own:

- **`influence.py`** — influence/heat maps (presence / threat / value) over the map, from a
  cost-primary per-unit military weight. Drives every spatial decision (where to defend, which
  enemy target to raid, how to flank an assault, where to expand).
- **`playbook.py` + `../cwc_data/playbook.json`** — mined per-faction doctrine (USA + Russia rosters,
  roles, costs, tech, build orders, army composition, counter matchups). Preference layer only —
  `/buildable` (canMake) is always the gating authority.
- **`macro.py`** — economy + construction + tech + counter-composed production. Captures **flags**
  (the only income in CWC; oil gives nothing), protects dozers, keeps a cash floor and a tank
  reserve, and composes the army to counter the **scouted** enemy.
- **`army.py`** — every combat unit gets a job each tick: scout / harass / defend (dynamic home
  guard) / mass / assault / retreat. Masses behind the frontline, then commits on a favourable (or
  economy-edge) engagement and grinds the enemy base via the combined-arms squad micro.
- **`personality.py`** — the bot's only randomness source: a seeded per-match "personality" draw
  (opening profile, attack/retreat thresholds, raid cadence and size, rally geometry, capturer
  appetite, premium-tank taste, territorial outpost appetite, army comfort cap) so the bot never
  plays the same script twice. Printed at match start as `[strat] personality: ...`.
- **`stance.py`** — CWC infantry doctrine: holding infantry goes **prone**, switches to the **AT
  weapon** when armor rolls in, stands up before moving (FakeRider stance powers from `/catalog`).
  Outposts also **garrison** neutral buildings at their site and evacuate when the post falls back.

Tune posture/aggression via the StrategyDirective file (`/tmp/gen_agent_directive.json`); no LLM
needed to play or win.

## What's here

- `genapi/` — client library for the game API (`GameClient`, `WorldModel`, WS `events`).
- `agent/` — the agent: `Agent` interface + driver loop, a scripted baseline (Ollama agent planned).
- `ui/` — the harness UI server + interactive map viewer (grows into human control of the agent).
- `tools/` — one-shot utilities (smoke/demo/events/session/map) as thin clients.
- `run_agent.py` — agent entrypoint. `Makefile` — quick-launch.

## Docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — **start here**: components, the observe→decide→act loop, the action/fog contracts, and the planned Ollama/Qwen agent design.
- [`docs/HARNESS.md`](docs/HARNESS.md) — usage: Makefile, layout, client-lib examples, run-log analysis.
- [`docs/AGENT.md`](docs/AGENT.md) — agent design detail (Ollama qwen/gemma 7B) + human-control UI.
- [`../docs/EXTERNAL_CONTROL_API.md`](../docs/EXTERNAL_CONTROL_API.md) — the **game's** API reference + how to extend the engine.
