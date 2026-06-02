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
DATADIR := /Users/dvcdsys/Command and Conquer Generals Zero Hour/Command and Conquer Generals Zero Hour
MAP     := maps\mp_dawn_of_war_day_weather\mp_dawn_of_war_day_weather.map

PORT    ?= 3459
WEBPORT ?= 8088
LOG     ?= /tmp/gen_api_actions.jsonl
GAMELOG ?= /tmp/gen_api_stand.log
PY      ?= python3
AGENT   ?= scripted
OLLAMA_HOST ?= 192.168.1.168:11434
MODEL   ?= qwen3:8b

# extra GEN_AUTO_* knobs; override to taste
RUNENV  ?= GEN_AUTO_SKIRMISH=1 GEN_AUTO_EXTERNAL=1 GEN_AUTO_ALLY=1

.DEFAULT_GOAL := help
.PHONY: help build run wait stop agent viewer demo events session smoke-read smoke-control map log status clean all

help:
	@echo "game_agent harness — targets:"
	@echo "  make build          build generalszh_api ($(BIN))"
	@echo "  make run            launch stand (skirmish+API) and wait for in-game"
	@echo "  make agent          run harness agent '$(AGENT)' (use AGENT=ollama for the LLM planner)"
	@echo "  make viewer         interactive browser world-view  (http://localhost:$(WEBPORT)/map_live.html)"
	@echo "  make map            render world PNG -> /tmp/gen_world.png"
	@echo "  make demo           read->pause->move->resume DoD loop"
	@echo "  make events         live WS event stream"
	@echo "  make threats        live attacks-on-my-units view (ThreatTracker)"
	@echo "  make session        print /session (seed/replay/outcome)"
	@echo "  make smoke-read     live state+units table"
	@echo "  make smoke-control  pause/step/resume tempo test"
	@echo "  make log            tail the bot-action log ($(LOG))"
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
	@cd "$(DATADIR)" && env GEN_API_PORT=$(PORT) GEN_API_LOG=$(LOG) $(RUNENV) \
		GEN_AUTO_MAP='$(MAP)' "$(BIN)" > "$(GAMELOG)" 2>&1 & \
		echo "  pid $$! (game log: $(GAMELOG))"
	@$(MAKE) --no-print-directory wait

wait:
	@echo "waiting for in-game on :$(PORT) ..."
	@for i in $$(seq 1 50); do \
		if curl -s --max-time 3 http://127.0.0.1:$(PORT)/healthz 2>/dev/null | grep -q '"inGame":true'; then \
			echo "  IN GAME -> http://127.0.0.1:$(PORT)"; exit 0; fi; \
		sleep 3; done; \
	echo "  timeout (check $(GAMELOG))"; exit 1

stop:
	-@pkill -f generalszh_api 2>/dev/null; pkill -f "ui/server.py" 2>/dev/null; sleep 1; \
	echo "stopped api game + viewer (your own generalszh is untouched)"

# Run the agent from the package root so `genapi`/`agent` import cleanly.
# `make agent`              -> scripted baseline (no LLM)
# `make agent AGENT=ollama` -> LLM planner + skill executor (qwen3:8b on $OLLAMA_HOST)
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

status:
	@echo "healthz:"; curl -s --max-time 4 http://127.0.0.1:$(PORT)/healthz; echo; \
	echo "players:"; curl -s --max-time 4 http://127.0.0.1:$(PORT)/players | $(PY) -m json.tool 2>/dev/null | head -60

clean:
	-@rm -f /tmp/gen_world.png /tmp/gen_map.png /tmp/gen_map_armies.png
	@echo "removed generated PNGs (kept $(LOG))"

all: build run
