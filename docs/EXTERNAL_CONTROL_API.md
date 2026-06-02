# External-Control API (the game side)

This documents the **game's** external-control API — the engine modification that lets an outside
process read state, issue orders, control tempo, and receive events. It is part of the **game**, not
the harness. The harness that consumes this API (Python client, agent, UI) lives in `game_agent/`
and is documented there (`game_agent/docs/`).

> Compiled in whenever `RTS_BUILD_EXTERNAL_CONTROL` is ON (default → `RTS_HAS_EXTERNAL_CONTROL`).
> Starts automatically on launch. REST on `127.0.0.1:3459`, WebSocket on `:3460`. No auth, localhost.

---

## 1. Boot / test stand (env vars)

The stand boots straight into a skirmish with an API-controlled player via the existing
`DebugAutoStartSkirmish` hook. Build a separately-named binary so tooling never disturbs a
manually-run game:

```bash
cmake --preset apple-arm64 -DRTS_BUILD_OUTPUT_SUFFIX=_api
cmake --build build/apple-arm64 --config Release --target z_generals
# -> build/apple-arm64/GeneralsMD/Release/generalszh_api
```

Launch from the game data dir (or just `make run` in `game_agent/`):

| Env | Effect |
|-----|--------|
| `GEN_AUTO_SKIRMISH=1` | boot straight into a skirmish |
| `GEN_AUTO_EXTERNAL=1` | make the opponent a `PLAYER_EXTERNAL` (API-driven) player |
| `GEN_AUTO_ALLY=1` | 3-player layout: human + External(API) ally + enemy AI (needs a 3+ player map) |
| `GEN_AUTO_MAP=maps\<name>\<name>.map` | skirmish map — **must be `[ SK | AI ]`** (see below) |
| `GEN_API_PORT=<n>` | REST port (default 3459); WS = port+1 |
| `GEN_API_WS_PORT=<n>` | WS port (default REST+1) |
| `GEN_API_OFF=1` | compile-in but don't start the server |
| `GEN_API_LOG=<path>` | bot-action log path (default `/tmp/gen_api_actions.jsonl`); `GEN_API_LOG_OFF=1` disables |

**Map constraint:** the skirmish map MUST be an AI-capable `[ SK | AI ]` map or the CWC mod
auto-ends the match ~20 s in. Verified-good: `maps\mp_dawn_of_war_day_weather\…` ("Dawn of War (Day)").

**Cleanup discipline:** only ever `pkill -f generalszh_api` — never `pkill -f generalszh` (that
substring also kills a manually-run `generalszh`).

---

## 2. Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/healthz` | GET | `{ok, frame, inGame, paused}` (works in menu / while paused) |
| `/players` | GET | per player: `index, controller (human/computer/external), name, side, money, power, relationToLocal` |
| `/state` | GET | `frame, paused, inGame, logicFramesPerSecond, players[]` |
| `/units?player=<i>&view=<j>` | GET | objects: `id, template, player, x/y/z, health, relationToLocal, category, tags[]`; `view=j` applies **synthesized fog-of-war** for player j via the `shroud` field — `clear` (in sight, live state), `cached` (building seen before, now out of sight: last-known snapshot), `undefined` (neutral landmark known from the map but never seen: position only, no state). Hidden objects (un-scouted enemies, units out of sight) are omitted. `player=i` filters by owner. |
| `/resources?player=<i>` | GET | `money, powerProduction, powerConsumption` |
| `/map?ds=<n>&zone=1` | GET | pathfinder grid: `cellSize, width, height`, base64 `type` (clear/water/cliff/rubble/obstacle/impassable), `heightField`, optional `zone` |
| `/control` | POST | `{action:"pause"|"resume"|"step"|"speed", value?}` |
| `/command` | POST | `{player, ids[], verb, params}` — verbs: `move, attack_move, attack_target, stop, guard_zone, retreat` |
| `/commands` | POST | array of the above |
| `/session` | GET/POST | GET: `seed, headless, replay{mode,playingBack}, outcome{localResult,decided,endFrame,players[]}`; POST `{seed}` (pre-start only, 409 once live) |
| `/events` | WS | `unit_died, unit_produced, structure_complete, combat` batched ~30 Hz with `seq`/`frame`; global; live-only; `dropped` overflow counter |

Discover the API player as the `/players` entry with `controller=="external"`. Address units by `id`.

---

## 3. Architecture invariants (don't break)

- **Threading:** HTTP/WS listener threads NEVER touch engine state — they push `PendingRequest`s onto
  a mutex-guarded queue and block on a CV. ALL engine reads/commands run on the **logic thread** in
  `serviceRequests()` (the drain), called from `GameEngine::update()` before the logic gate. The WS
  broadcaster thread only reads the mutex-guarded event ring.
- **Pause safety:** the drain runs even while paused (so `/control` + reads work); single-step via
  `consumePendingStep()`.
- **Allocator:** engine `operator new` → DMA pool guarded by `TheDmaCriticalSection`, so listener-thread
  allocations are safe.
- **`eventsActive()` gate** on event taps → near-zero cost in a normal game when no client is connected.
- Everything behind `RTS_HAS_EXTERNAL_CONTROL`, compiles out cleanly when off.

---

## 4. Where the engine code lives + how to extend it

| Path | What |
|------|------|
| `Core/GameEngine/Source/Common/ExternalControl/ExternalControlSystem.cpp` | **The server.** Threads, drain, all `build*` endpoint builders, `executeCommand`, event ring + taps, the action log. Most changes here. |
| `Core/GameEngine/Include/Common/ExternalControl/ExternalControlInterface.h` | Subsystem interface (`TheExternalControl`): `serviceRequests`, `consumePendingStep`, `eventsActive`, `eventX(...)`. |
| `cmake/external_control.cmake` | FetchContent: cpp-httplib + nlohmann/json + IXWebSocket (all httplib backends forced OFF — OpenSSL pulls MacTypes.h which clashes with engine types). |
| `GeneralsMD/.../Common/GameEngine.cpp` | registers `TheExternalControl`; calls `serviceRequests()`+`consumePendingStep()` before the logic gate. |
| `GeneralsMD/.../GameLogic/Object/Object.cpp` | event taps: `onDie`→`eventUnitDied`, `attemptDamage`→`eventCombatDamage`. |
| `GeneralsMD/.../Common/RTS/Player.cpp` | event taps: `onUnitCreated`→`eventUnitProduced`, `onStructureConstructionComplete`→`eventStructureComplete`; `PLAYER_EXTERNAL` `wbonus` row + `initFromDict` branch. |
| `Core/.../GameCommon.h`, `GeneralsMD/.../WellKnownKeys.h`, `GameNetwork/GameInfo.{h,cpp}`, `GameLogic.cpp`, `Menus/SkirmishGameOptionsMenu.cpp` | `PLAYER_EXTERNAL` type + `SLOT_EXTERNAL_AI` slot + menu + `DebugAutoStartSkirmish`. |

**Cookbook** (all edits in `ExternalControlSystem.cpp`, run on the logic thread; `make build` then restart):
- **New command verb** → add an `else if (verb=="...")` in `executeCommand()`; resolve objects via
  `findObjectByID`, issue on the `AIGroup` with `CMD_FROM_AI`; keep ownership checks. Auto-logged.
- **New read endpoint** → add a `RequestKind`, register the route in `serverThreadMain()`, add a
  `case` in `service()`, write `buildFoo()` returning json.
- **New event** → declare `eventXxx` in the interface header, implement (gate on `eventsActive()`,
  `pushEvent`), add the tap at the engine site guarded by `#ifdef RTS_HAS_EXTERNAL_CONTROL`.
- **Map data** → `buildMap()` (pathfinder grid via `TheAI->pathfinder()`, terrain via `TheTerrainLogic`).
- **`/units` fields** → `buildUnits()` + helpers `relationName`/`primaryCategory`/`objectTags`.
- **Planned query endpoints** → reuse `TheBuildAssistant->isLocationLegalToBuild(...)` (buildability)
  and `TheAI->pathfinder()->findPath/isLinePassable/...` (pathing) — don't reimplement geometry.

---

## 5. Roadmap / known gaps (game side)

- **`/catalog`** — static `ThingTemplate` stats per faction: cost, build time, prerequisites (tech
  tree), power, health, armor, weapons (damage vs armor type), vision, speed, footprint.
- **`/buildable?player=N`** — what's buildable now (`TheBuildAssistant::canMakeUnit/isPossibleToMakeUnit`).
- **`/query/can_build` + `/query/path`** — point-wise authoritative answers (see cookbook).
- Deferred: LAN/online slot encoding; replay-recording of external commands (direct AIGroup dispatch
  bypasses `TheRecorder` → a `.rep` of an API session desyncs); guard_zone aggression/fallback.

### Fog-of-war on `/units` — why it's synthesized, not engine shroud

Do **not** use `Object::getShroudedStatus(playerIndex)` as a bot's fog model. The SAGE engine
maintains true per-cell fog only for the **local/human** player; every other (AI-brain) player —
including `PLAYER_EXTERNAL` and the skirmish enemy AI — gets a **permanent full-map reveal** (the AI
"sees all"), so `getShroudedStatus(externalIndex)` returns `CLEAR` for every object on the map.
Verified live: with the human at real fog (`clear`/`fogged`/`partial`), `view=external` and
`view=enemyAI` both returned the entire map as `clear`.

So `buildUnits()` **synthesizes** fog from geometry instead: collect the view player's + allies' live
units as "lookers" (center = position, radius = `getShroudClearingRange()`), and an object is in
sight iff it lies inside any looker's radius. Own/allied objects are always live-visible (shared
vision); undetected stealth (`OBJECT_STATUS_STEALTHED && !DETECTED && !DISGUISED`) stays hidden.

For everything else the `shroud` field is one of three states, so a planner has stable knowledge
without free live intel:

- **`clear`** — in sight now; live state. A building seen here is snapshotted into `m_fogMemory`
  (per-view `objId -> {snapshot, everSeen}`, cleared on `reset()`).
- **`cached`** — a building seen before, now out of sight: we replay the **frozen snapshot** (its
  last-known health/owner/position), never the current engine values. So the bot can't tell whether
  it was since destroyed or captured until it re-scouts.
- **`undefined`** — a **neutral** building never yet seen: position is reported (static map landmark
  the bot must plan around — oil/supply, tech, capturable, garrisonable bunkers), but `health`/state
  is omitted. Un-scouted **enemy** buildings and all out-of-sight units remain hidden.

A cached/undefined building absent from the live object list (destroyed off-screen) keeps being
reported until the view player regains sight of its tile, at which point it's confirmed gone and
dropped from the cache. Honest, deterministic, independent of the engine's local-player-only shroud;
does not model partial-clear / ghost-snapshot nuances.

The harness (client lib, agent, UI) and its run instructions live in `game_agent/` — see
`game_agent/README.md`, `game_agent/docs/HARNESS.md`, and `game_agent/docs/AGENT.md`.
