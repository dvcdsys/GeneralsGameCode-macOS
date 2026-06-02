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
make agent      # run the harness agent (scripted baseline) — watch units move
make viewer     # interactive world-view → http://localhost:8088/map_live.html
make            # full target list
```

## What's here

- `genapi/` — client library for the game API (`GameClient`, `WorldModel`, WS `events`).
- `agent/` — the agent: `Agent` interface + driver loop, a scripted baseline (Ollama agent planned).
- `ui/` — the harness UI server + interactive map viewer (grows into human control of the agent).
- `tools/` — one-shot utilities (smoke/demo/events/session/map) as thin clients.
- `run_agent.py` — agent entrypoint. `Makefile` — quick-launch.

## Docs

- [`docs/HARNESS.md`](docs/HARNESS.md) — harness architecture, client-lib usage, the agent loop, run-log analysis.
- [`docs/AGENT.md`](docs/AGENT.md) — LLM agent design (Ollama qwen/gemma 7B) + human-control UI.
- [`../docs/EXTERNAL_CONTROL_API.md`](../docs/EXTERNAL_CONTROL_API.md) — the **game's** API reference + how to extend the engine.
