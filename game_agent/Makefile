# game_agent — quick-launch Makefile for the in-game agent harness
#
#   make            show this help
#   make build      build the generalszh_api binary (the game)
#   make run        launch the test stand (skirmish + API), wait until in-game
#   make agent      run the harness agent (scripted baseline) against the stand
#   make viewer     interactive browser world-view (serves on :8088)
#   make demo       read->pause->move->resume demo
#   make events     stream live game events (WS /events)
#   make map        render the agent's world map to a PNG
#   make session    print /session (seed / replay / outcome)
#   make log        tail the bot-action log
#   make stop       stop the API game + viewer (never touches your own generalszh)
#
# Paths derive from this Makefile's location, so `make -C game_agent run` works from anywhere.
# Override on the command line, e.g. `make run PORT=3460`.

PKG     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
REPO    := $(abspath $(PKG)/..)
TOOLS   := $(PKG)/tools
UI      := $(PKG)/ui
BIN     := $(REPO)/build/apple-arm64/GeneralsMD/Release/generalszh_api
BUILDDIR:= $(REPO)/build/apple-arm64
DATADIR ?= $(HOME)/Command and Conquer Generals Zero Hour/Command and Conquer Generals Zero Hour
MAP     := maps\mp_dawn_of_war_day_weather\mp_dawn_of_war_day_weather.map

PORT    ?= 3459
WEBPORT ?= 8088
LOG     ?= /tmp/gen_api_actions.jsonl
GAMELOG ?= /tmp/gen_api_stand.log
PY      ?= python3
AGENT   ?= strategist
OLLAMA_HOST ?= localhost:11434
MODEL   ?= gemma4:26b

# extra GEN_AUTO_* knobs; override to taste
RUNENV  ?= GEN_AUTO_SKIRMISH=1 GEN_AUTO_EXTERNAL=1 GEN_AUTO_ALLY=1
# RENDER-SKIP for the automated stand: GEN_NO_VIEWS=1 skips drawViews() (the 3D scene render).
# Mass battles (~54+ on-screen units) otherwise FREEZE the legacy D3D8->Metal renderer on macOS
# (profiled: shadow + sorting/particle + mesh draw calls saturate the main thread). The stand only
# needs logic + the API, so skipping the 3D draw keeps big-army matches running at full sim speed.
# Set VIEWS= (empty) to watch the 3D scene instead (will freeze in huge battles). `make play` never
# sets this — a human game renders normally (and the bot loses well before 54 units anyway).
VIEWS   ?= GEN_NO_VIEWS=1

.DEFAULT_GOAL := help
.PHONY: help build run play wait stop agent viewer demo events session smoke-read smoke-control map log status clean all

help:
	@echo "game_agent harness — targets:"
	@echo "  make build          build generalszh_api ($(BIN))"
	@echo "  make play           launch PLAYABLE game (normal menu, API on) — YOU vs the bot"
	@echo "  make run            launch AUTO test stand (skirmish+API, 3D render skipped for big-battle stability); VIEWS= to render"
	@echo "  make agent          run harness agent '$(AGENT)' (strategist = the strong v2 bot; AGENT=commander = old)"
	@echo "  make viewer         interactive browser world-view  (http://localhost:$(WEBPORT)/map_live.html)"
	@echo "  make map            render world PNG -> /tmp/gen_world.png"
	@echo "  make demo           read->pause->move->resume DoD loop"
	@echo "  make events         live WS event stream"
	@echo "  make threats        live attacks-on-my-units view (ThreatTracker)"
	@echo "  make session        print /session (seed/replay/outcome)"
	@echo "  make smoke-read     live state+units table"
	@echo "  make smoke-control  pause/step/resume tempo test"
	@echo "  make log            tail the bot-action log ($(LOG))"
	@echo "  make llmlog         tail the LLM decision cycle (brief in / tool-calls out)"
	@echo "  make status         quick /healthz + /players"
	@echo "  make stop           stop API game + viewer (NOT your own generalszh)"
	@echo "  make clean          remove generated PNGs"
	@echo ""
	@echo "  vars: PORT=$(PORT) WEBPORT=$(WEBPORT) AGENT=$(AGENT) LOG=$(LOG)"

build:
	cmake --build "$(BUILDDIR)" --config Release --target z_generals

# Launch the stand in the background, then block until the match is live.
run: stop
	@echo "launching stand on :$(PORT) (map: Dawn of War) ..."
	@cd "$(DATADIR)" && env GEN_API_PORT=$(PORT) GEN_API_LOG=$(LOG) $(VIEWS) $(RUNENV) \
		GEN_AUTO_MAP='$(MAP)' "$(BIN)" > "$(GAMELOG)" 2>&1 & \
		echo "  pid $$! (game log: $(GAMELOG))"
	@$(MAKE) --no-print-directory wait

# Launch the game NORMALLY (full menu) with the API on, so YOU play AGAINST the bot.
# In the Skirmish menu: pick your faction, set ONE opponent slot to "ExternalAI"
# (last dropdown entry; its label is blank / "MISSING: 'GUI:ExternalAI'"), Start.
# Then in another terminal:  make agent AGENT=commander   (attaches the bot brain).
# Runs in the FOREGROUND — the game window opens; Ctrl-C (or quit in-game) stops it.
play: stop
	@echo "launching PLAYABLE game on :$(PORT) — set an opponent slot to 'ExternalAI', Start, then: make agent AGENT=commander"
	@cd "$(DATADIR)" && exec env GEN_API_PORT=$(PORT) GEN_API_LOG=$(LOG) "$(BIN)"

wait:
	@echo "waiting for in-game on :$(PORT) ..."
	@for i in $$(seq 1 50); do \
		if curl -s --max-time 3 http://127.0.0.1:$(PORT)/healthz 2>/dev/null | grep -q '"inGame":true'; then \
			echo "  IN GAME -> http://127.0.0.1:$(PORT)"; \
			curl -s --max-time 3 -X POST http://127.0.0.1:$(PORT)/control \
				-H 'Content-Type: application/json' -d '{"action":"pause"}' >/dev/null 2>&1; \
			echo "  PAUSED until the agent attaches (fair start — the enemy AI was getting a ~1min head start)"; \
			exit 0; fi; \
		sleep 3; done; \
	echo "  timeout (check $(GAMELOG))"; exit 1

stop:
	-@pkill -f generalszh_api 2>/dev/null; pkill -f "ui/server.py" 2>/dev/null; pkill -f "run_agent.py" 2>/dev/null; sleep 1; \
	echo "stopped api game + agent + viewer (your own generalszh is untouched)"

# Run the agent from the package root so `genapi`/`agent` import cleanly.
# `make agent`              -> scripted baseline (no LLM)
# `make agent AGENT=ollama` -> LLM planner + skill executor (gemma4:26b on $OLLAMA_HOST)
agent:
	@cd "$(PKG)" && GEN_API_PORT=$(PORT) GEN_OLLAMA_HOST=$(OLLAMA_HOST) GEN_OLLAMA_MODEL=$(MODEL) \
		$(PY) run_agent.py --agent $(AGENT)

viewer:
	@echo "serving interactive world-view at http://localhost:$(WEBPORT)/map_live.html (Ctrl-C to stop)"
	@$(PY) "$(UI)/server.py" --port $(WEBPORT)

demo:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/demo.py" --dx 800

events:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/events_listen.py"

threats:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/threats_watch.py"

session:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/session.py"

smoke-read:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/smoke_read.py"

smoke-control:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/smoke_control.py"

map:
	@GEN_API_PORT=$(PORT) $(PY) "$(TOOLS)/map_view.py" --out /tmp/gen_world.png --scale 4 --armies-only

log:
	@touch "$(LOG)"; echo "tailing $(LOG) (Ctrl-C to stop)"; tail -f "$(LOG)"

# Live view of the LLM decision cycle: what the brief sent + the model's tool-call reply, per round.
LLMLOG ?= /tmp/gen_agent_llm.jsonl
llmlog:
	@touch "$(LLMLOG)"; echo "tailing LLM decisions $(LLMLOG) (Ctrl-C to stop)"; \
	tail -f "$(LLMLOG)" | $(PY) -c 'import sys,json;\
[print("\n── f{} {}ms {} ──\nDIRECTIVE: {}\nRESP: {}\nCALLS: {}".format(d.get("frame"),d.get("latencyMs"),d.get("model"),(d.get("request",{}).get("brief") or {}).get("directive",""),(d.get("response",{}).get("content") or d.get("response",{}).get("thinking") or "")[:300],[ (c.get("function") or {}).get("name") for c in d.get("response",{}).get("tool_calls") or [] ])) for d in (json.loads(l) for l in sys.stdin if l.strip())]'

status:
	@echo "healthz:"; curl -s --max-time 4 http://127.0.0.1:$(PORT)/healthz; echo; \
	echo "players:"; curl -s --max-time 4 http://127.0.0.1:$(PORT)/players | $(PY) -m json.tool 2>/dev/null | head -60

clean:
	-@rm -f /tmp/gen_world.png /tmp/gen_map.png /tmp/gen_map_armies.png
	@echo "removed generated PNGs (kept $(LOG))"

all: build run
