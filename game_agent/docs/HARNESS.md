# game_agent — harness usage

> Architecture overview (components, data flow, contracts, the Ollama agent design) lives in
> [`ARCHITECTURE.md`](ARCHITECTURE.md). This doc is the practical usage reference.


`game_agent/` is the **harness**: a Python project that drives a `PLAYER_EXTERNAL` player inside the
game through the game's external-control API. The API is part of the **game** (engine modification —
see `../../docs/EXTERNAL_CONTROL_API.md`); the harness is a separate layer that talks to it as a
client. Eventually the harness runs a small local LLM (Ollama, qwen/gemma 7B) as the agent, with a
browser UI for human visualization + control (see `AGENT.md`).

```
browser UI ──▶ harness server (ui/server.py) ─┐
agent (agent/) ──── genapi.GameClient ─────────┼──▶  GAME external-control API  (:3459 REST / :3460 WS)
tools (tools/) ──── genapi.GameClient ─────────┘
```

---

## Quick start (Makefile)

```bash
cd game_agent

make build      # build the game (generalszh_api)        [game side]
make run        # launch the stand, wait until in-game    [game side]
make agent      # run the harness agent (scripted baseline)
make viewer     # interactive browser world-view → http://localhost:8088/map_live.html
make demo       # read→pause→move→resume DoD loop
make events     # live WS event stream
make threats    # live "my units under attack" view (ThreatTracker over combat events)
make map        # render the world to /tmp/gen_world.png
make session    # seed / replay / outcome
make log        # tail the bot-action log
make stop       # stop the API game + viewer (never your own generalszh)
```

Override vars: `make run PORT=3460`, `make agent AGENT=scripted`, `make viewer WEBPORT=9000`.

**Iron rules** (baked into the Makefile): only ever touch `generalszh_api` (never `pkill -f
generalszh`); the stand map must be `[ SK | AI ]`; don't launch while the user's own game runs.

---

## Layout

```
game_agent/
  Makefile            quick-launch targets
  run_agent.py        agent entrypoint (run from this dir)
  genapi/             client library for the game API
    client.py         GameClient — REST + WS wrapper (the single HTTP path)
    ws.py             minimal RFC6455 WS client (stream_events generator)
    world.py          WorldModel — decodes /map + classifies /units into agent state
    threats.py        ThreatTracker — background WS listener; aggregates 'combat' events into a
                      live "my units under attack" picture (reactive layer for the agent)
  agent/
    base.py           Agent interface (decide) + run() driver loop (scripted path)
    scripted.py       NO-LLM baseline (rally to nearest capture point)
    orchestrator.py   two-cadence driver: fast skill executor + slow LLM planner (LLM path)
    ollama_agent.py   OllamaPlanner — Ollama function-calling planner over the skill catalog
    ollama_client.py  minimal Ollama /api/chat wrapper (stdlib; default qwen3.5:9b)
    tasks.py          TaskManager — the executor's queue of Skill state-machines + history
    brief.py          compose_brief — WorldModel + memory -> compact LLM brief (~1-3 KB)
    journal.py        EventJournal (event digest/counts) + AgentNotes (planner scratchpad)
    skills/           the extensible automation tool-library (see AGENT.md)
      base.py         Skill base + SkillContext + shared world/queries helpers
      library.py      build_structure / train_units / assemble_group / defend_sector /
                      attack_area / hold_point / scout  (add a skill -> new LLM tool)
      registry.py     SkillRegistry — maps names to classes + emits the LLM tool catalog
  ui/
    server.py         harness UI server: serves the viewer + GET /agent/state, POST /agent/directive
    map_live.html     interactive canvas (live poll, zoom/pan/hover, layer toggles,
                      "see as the bot (fog of war)" toggle — ON by default; off = ground truth)
                      + Agent panel: task history w/ statuses, last plan, notes, directive box
  tools/              one-shot utilities, thin clients over genapi
    smoke_read.py smoke_control.py demo.py events_listen.py session.py map_view.py
  docs/               HARNESS.md (this), AGENT.md
```

## Using the client library

```python
from genapi.client import GameClient
from genapi.world import WorldModel

c = GameClient()                          # 127.0.0.1:3459 (env GEN_API_PORT)
me = c.external_player()                   # the PLAYER_EXTERNAL slot
world = WorldModel.from_api(c, view=me["index"])   # fog-aware world state

c.pause()
c.command(me["index"], [u["id"] for u in world.my_units(me["index"])],
          "attack_move", {"pos": {"x": 1200, "y": 1800}})
c.resume()

for ev in c.events(duration=10):           # WS /events
    print(ev)
```

`WorldModel` helpers: `passable(x,y)`, `buildable(x,y)`, `ground_height(x,y)`, `cell_type_name(x,y)`,
`objects(category=, relation=, tag=)`, `my_units(owner)`, `enemies()`, `economy_points()`,
`garrisonable()`, `centroid(objs)`, `nearest(objs,x,y)`.

## The agent loop

`agent/base.run(agent, client, hz, view)` connects, waits for the match, builds a `WorldModel` each
tick (fog-aware), calls `agent.decide(world, me, client)`, and dispatches the returned command dicts.
Keep `hz` low — this is strategic cadence, not micro. `agent/scripted.ScriptedAgent` is the reference
baseline. Add a new agent by subclassing `Agent` and registering it in `run_agent.py`.

## Analyzing runs (bot-action log)

Every mutating API call is recorded by the **game** as JSONL at `/tmp/gen_api_actions.jsonl`
(`GEN_API_LOG`), one object per line: `{t, frame, type, status, request, result}` + `boot`/`reset`
markers. This is the primary artifact for iterating on agents:

```bash
make log                                                          # live tail
jq 'select(.type=="command") | {frame, verb:.request.verb, ok:.result.accepted}' /tmp/gen_api_actions.jsonl
jq -s 'group_by(.type) | map({(.[0].type): length}) | add' /tmp/gen_api_actions.jsonl   # action histogram
```

## Notes

- Tools insert the package root on `sys.path`, so `python3 tools/x.py` works directly; `run_agent.py`
  is run from the `game_agent/` root (the Makefile does this).
- No third-party Python deps (stdlib only) — except the future Ollama agent, which will talk to a
  local Ollama HTTP server (no Python package required either). Tkinter is intentionally unused
  (absent in the Homebrew python here) — the UI is browser-based.
