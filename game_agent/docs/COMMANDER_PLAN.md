# Algorithmic Commander + LLM Strategist — architecture & implementation plan

Status: **PLAN (not yet built)**. Supersedes the M3 "LLM-calls-skills" model for how the bot is driven.
Companion docs: [`ARCHITECTURE.md`](ARCHITECTURE.md) (current harness), [`AGENT.md`](AGENT.md) (M3 agent),
game side [`../../docs/EXTERNAL_CONTROL_API.md`](../../docs/EXTERNAL_CONTROL_API.md).

Locked decisions (this turn):
- **Brain location = Python harness + thin engine `/query` endpoints** (option A). Keeps the locked
  boundary *engine = capability, harness = policy*. We **port the patterns** of the engine's
  `AISkirmishPlayer` into Python and **call the engine** for geometry/pathfinding/legality.
- **LLM seam = declarative `StrategyDirective`** (option B-decl). The LLM sets *strategy parameters*,
  not unit commands. The M3 skill library is refactored into autonomous Commander managers; the LLM no
  longer calls per-task skills.

> **TARGET GAME = the CWC mod (Cold War Crisis), NOT stock Zero Hour.** Its mechanics differ
> fundamentally (capture-driven fuel economy, power not tracked, infantry-dominant combined arms,
> asymmetric factions, win-by-raze). The Commander must be **excellent specifically in CWC**. See
> **§8 — CWC specialization (critical)**; it governs how every manager and default behaves.

---

## 1. The core idea — invert M3

The shipped game already contains a strong algorithmic bot (`AIPlayer`/`AISkirmishPlayer`) split into:
- **per-unit autonomy** (`AIUpdate` + `AIStateMachine`): pathfind, attack-move auto-engage, hunt,
  guard+retaliate, target-acquire (`getNextMoodTarget`, `AttackPriority`), formations, pursuit — *micro
  is already solved by the engine*; and
- **player-level macro** (`AISkirmishPlayer`): `processBaseBuilding` (from a **BuildList**),
  `doTeamBuilding`/`selectTeamToBuild` (from **TeamPrototypes**), `buildAIBaseDefense` (front/flank
  angle math), `acquireEnemy` (nearest enemy + load-balancing + grudge), `doUpgradesAndSkills`,
  `computeSuperweaponTarget`, supply guarding — **driven by static map data (BuildList / TeamPrototypes
  / AIData.ini) and map Scripts (`SKIRMISH_CENTER/FLANK/BACKDOOR`, `AI_TEAM_ATTACK_AREA`).**

So the game's own architecture is **strong algorithmic core + thin static strategy layer**. We keep the
core idea but make the strategy layer **dynamic and LLM-correctable**.

M3 today has the LLM as a *micromanager* (it calls `build_structure`, `attack_area`, …). If the LLM is
slow/silent/wrong the bot barely acts (the scripted baseline only rallies idle units). We invert this:

```
M3:    LLM ── issues concrete tasks ──▶ executor ticks those tasks
NEW:   LLM ── sets STRATEGY (params) ──▶ always-on algorithmic Commander plays a full game itself
```

The LLM becomes a **commander that corrects strategy once per round**; the Commander plays a competent
game even with an empty/stale directive.

---

## 2. Three layers

```
L0 ENGINE (capability, exists)  per-unit AIUpdate/AIStateMachine: pathfind, attack-move, hunt,
                                guard, retaliate, target-acquire, formations  + new read-only /query
        ▲ API verbs: move / attack_move / attack_target / guard_zone / capture / build_structure / train_unit / …
L1 ALGORITHMIC COMMANDER (policy, "smart bot, no LLM")  always-on, deterministic, ~2–4 Hz.
   Managers over one world-model: Economy · Base · Production · Defense · Recon · Engagement · Powers.
   Reads StrategyDirective as commander's-intent. SANE DEFAULTS → plays a full game with no LLM.
        ▲ StrategyDirective (small declarative struct), refreshed ~every 20–30 s
L2 LLM STRATEGIST (corrector)   reads a compact strategic brief, emits/patches StrategyDirective.
                                NEVER issues unit commands.
```

L1 leans entirely on L0 for micro: an `attack_move` along an axis auto-engages everything on the way; a
`guard_zone` retaliates and returns. That is why L1 stays "macro" and a few Hz is enough.

---

## 3. `StrategyDirective` — the L1↔L2 seam

This is the dynamic replacement for the game's static BuildList/TeamPrototypes/Scripts. **Every field
has a default; the LLM only overrides.** Lives in `game_agent/agent/strategy.py` (schema + defaults +
`validate()` + `merge(base, patch)`). Maps directly onto the user's brief ("attack points, approaches,
routes, what to build in what order, correct strategy each round").

```jsonc
{
  "posture": "expand",              // turtle | defend | expand | pressure | all_in   (default: expand)
  "economy": { "expand": true, "harvester_target": 6, "cash_floor": 800 },

  // WHAT TO BUILD IN WHAT ORDER — ordered ROLES, faction-agnostic, resolved via
  // find_buildable_by_role() against /buildable (already in skills/base.py):
  "build_priority": ["power","barracks","war_factory","tech","defense_front","superweapon"],

  "army":   { "weights": {"anti_inf":0.3,"anti_armor":0.4,"aa":0.2,"siege":0.1},
              "target_value": 8000, "keep_home": 4 },

  "defense":{ "emphasis": "front", "static": true },   // where to thicken defense

  // ATTACK POINTS / APPROACHES / ROUTES:
  "offense":{ "engage": false, "target_enemy": null,           // null => Commander auto-acquires nearest
              "objective": {"type":"base", "pos": null, "targetId": null},
              "axis": "center",                                // center | flank_left | flank_right | backdoor
              "staging": null,                                 // muster point before the assault
              "route": [],                                     // optional approach waypoints
              "commit_ratio": 1.3 },                           // attack only if local force ratio >= this

  "recon":  { "scout": true, "areas": [] },
  "powers": [],                                                // [{power, intent:"offensive|defensive|economy", hint}]
  "rationale": ""                                              // human-readable, for UI + llm log
}
```

Contract: the Commander reads the directive each tick as intent. **Empty/stale ⇒ play on defaults**
(turtle → economy → army → push nearest enemy). The LLM "corrects each round" = re-emits/patches the
directive every ~20–30 s based on what it scouted and how the game evolved. Authority stays game-side:
the directive only re-weights what the Commander already does via documented API verbs.

---

## 4. The Commander — managers (porting `AISkirmishPlayer` patterns)

`game_agent/agent/commander/` (new package). Each manager: deterministic, idempotent, defaulted; many
are a refactor of today's `skills/library.py` into always-on loops. The Commander driver ticks managers
in priority order each fast tick, sharing one `WorldModel` + `ThreatTracker` snapshot.

| Manager (`commander/`) | Algorithmic job | Engine pattern reused | Reuses today |
|---|---|---|---|
| `economy.py` | keep N harvesters; expand to supply/oil if `economy.expand` & source safe | `queueSupplyTruck`, `isSupplySourceSafe`, `findSupplyCenter` | `capture_points`, world `economy_points()` |
| `base.py` | build next structure by `build_priority`; force power when underpowered; rebuild; place legally | `processBaseBuilding` | `build_base`, `find_buildable_by_role`, `find_build_spot` |
| `production.py` | train to `army.weights` up to `target_value`; reinforce losses | `doTeamBuilding`/`selectTeamToBuild` | `maintain_army`, `train_units` |
| `defense.py` | static defense on `defense.emphasis` flank (port front/flank angle math); pull army home on `under_attack` | `buildAIBaseDefense` | `defend_base`, `ThreatTracker` |
| `recon.py` | send a cheap unit to `recon.areas` / toward suspected enemy base when intel is stale | *(engine doesn't scout — it cheats with full reveal; this is new)* | `scout`, fog `cached/undefined` |
| `engagement.py` | assemble strike force (surplus beyond `keep_home`); attack-move `staging→route→objective` only if force-ratio ≥ `commit_ratio`; retreat low-HP units; focus-fire priority targets | `acquireEnemy` + script attack + per-unit attack-move/hunt | `attack_area`, `assemble_group`, `hold_point` |
| `powers.py` | spend skill points; fire superweapon / general's powers by `intent` | `doUpgradesAndSkills`, `computeSuperweaponTarget` | `special_power`, `ability` verbs |

Default behaviour (no directive) is a coherent turtle→build→army→push game so the bot is competitive
*on its own*. The LLM only nudges weights, axis, posture, targets.

---

## 5. Engine `/query` endpoints (game-side, read-only, P3)

So the Python brain reuses the engine's real rules instead of re-deriving them. Added to
`Core/.../ExternalControl/ExternalControlSystem.cpp`, documented in `docs/EXTERNAL_CONTROL_API.md`.

- **`/query/can_build`** `?player=&template=&x=&y=[&angle=]` → `TheBuildAssistant->isLocationLegalToBuild`.
  Replaces the empirical `min_radius=200` placement hack in `find_build_spot`. (Already on the API roadmap.)
- **`/query/path`** `?from=&to=` (or `isLinePassable`) → `TheAI->pathfinder()->findPath` / `isLinePassable`.
  Lets the Commander validate an `offense.axis`/`route` and lets the LLM plan real approach corridors.
- **`/query/defense_spots`** (optional) `?player=` → port `computeCenterAndRadiusOfBase` + front/flank
  angle logic so `defense.py` places defenses exactly like the shipped AI without re-deriving geometry.

These are pure reads on the logic thread (same drain seam as `/units`), gated by `eventsActive`-style
cheapness; no new authority.

---

## 6. Implementation phases

Each phase is self-contained and live-tested on an `[ SK | AI ]` map with a separate `generalszh_api`
(`-DRTS_BUILD_OUTPUT_SUFFIX=_api`; never touch the user's `generalszh`).

- **P0 — Seam.** `agent/strategy.py`: `StrategyDirective` schema + defaults + `validate()` + `merge()`.
  Keep the file control channel (`/tmp/gen_agent_directive.json`); UI shows the active directive.
- **P1 — Commander v1 (no LLM).** `agent/commander/` with Economy/Base/Production/Defense managers
  reading the directive; defaults play a full turtle→army game. Refactor the matching `skills/` logic
  into managers. `run_agent.py --agent commander`. Benchmark vs the shipped enemy AI.
- **P2 — Engagement + Recon.** `engagement.py` (strike force, `commit_ratio`, retreat, focus-fire) +
  `recon.py`. Bot now takes map ground and lands attacks, not just defends.
- **P3 — Engine `/query` endpoints.** `/query/can_build` + `/query/path` (+ optional `defense_spots`).
  Commander switches from heuristics to engine truth.
- **P4 — LLM Strategist.** Repurpose `agent/ollama_agent.py`: one `set_strategy` tool whose schema **is**
  the `StrategyDirective`; the planner emits/patches it each round (reuse `brief.py`, the llm log, the
  directive channel). LLM "corrects each round". `--agent commander+llm`.
- **P5 — Powers + tuning + eval.** `powers.py`; A/B (no-LLM vs +LLM vs shipped AI) via `POST /session
  {seed}` + the action log (M4 optimizer). Tune defaults & directive weighting.

---

## 7. Invariants (unchanged)

- Pure-stdlib Python harness; all game I/O via `genapi.GameClient`.
- Strategic cadence (Commander ~2–4 Hz; LLM ~20–30 s). Micro is the engine's job — never busy-loop.
- Engine owns capability/authority/determinism; harness owns policy/UI/state.
- The Commander must be playable with the LLM fully disabled (that is the whole point).

---

## 8. CWC specialization (critical)

The bot must be **super competent in the CWC mod specifically**. CWC (Cold War Crisis, total
conversion, v469, 80s setting) differs from stock ZH in ways that change strategy at the root. The
design principle that makes us strong here *and* mod-robust:

> **Classify by CAPABILITY, not by name.** At game start the Commander fetches `/catalog` **once** and
> builds a **Capability Table**: for every template, derive role/flags from KINDOF `tags[]` + weapon
> vs-armor + speed + vision + cost (`/units` already returns `tags[]`/`category`/veterancy; `/catalog`
> adds stats). Names (`CWCus…`, `…DeathRider`, `…White01`) are only *hints*, never the source of truth.
> A small curated **CWC profile** (`commander/cwc_profile.py`) supplies role keyword-hints, the counter
> matrix, faction tilt, and tuning — layered on top of the capability table. This is why the bot is
> "super crazy good at CWC" (it learns CWC's real stats) and still survives mod updates / new variants.

What is fundamentally different in CWC, and how each manager specializes:

1. **Economy = CAPTURE & HOLD (not harvesters).** Income comes from capturing and holding scattered
   neutral `CWCciv` fuel/oil/gas/refinery + flag points → passive cash. **Map control IS the economy.**
   `economy.py` becomes a **Control manager**: rank econ points by value × proximity × safety (they're
   visible as `undefined` landmarks even un-scouted), send **engineers** (capability: *capturer*) to take
   the nearest safe ones, expand control outward, **defend** captured points, recapture losses. Also
   build own fuel-depot econ structures when buildable. *No harvester loop exists.*

2. **Power is (usually) not tracked.** If no `power`-role building is buildable and `powerMargin ≥ 0`,
   CWC simply doesn't use power → `base.py` must **never** chase power plants. Build only from
   `buildable.makeableNow`.

3. **Infantry-dominant combined arms + hard counters.** Infantry is far deadlier than in ZH and has
   rich roles: AntiTank, AntiAir, Assault/HeavyAssault, Sniper, Engineer (capture/repair), **Officer**
   (command buff), **Medic** (sustain), plus tanks (M60A3 / T72), APCs that **ferry infantry**
   (M113 / BTR80), and gunships (Mi24). `production.py` uses the **CWC counter matrix** against scouted
   enemy comp: enemy armor → AntiTank inf + AT vehicles; enemy air (Mi24) → AntiAir inf + AA tank
   (M60A3_AAGun); enemy infantry → Snipers + HeavyAssault + crush with vehicles. Always fold in
   Officer + Medic with infantry balls; use APCs for mobility/protection. Keep **veterans** alive
   (retreat-to-Medic) — XP is a real force multiplier (patches tune it).

4. **Asymmetric factions — play to strength.** **USSR = tanks + artillery**; **USA = aircraft +
   high-tech**. The CWC profile carries a per-faction tilt for `army.weights` defaults and build order
   (as USSR, mass armor + artillery siege; as USA, lean air + tech). The external player's faction is
   **random per game** — resolve everything per-faction from `/buildable` (never hardcode a side).

5. **Reinforcement mechanics.** US **Dropzone** paradrop and Soviet **Mi26 supply drop** deliver units
   to the front/staging — `production.py`/`engagement.py` use them to reinforce forward, not just at base.

6. **Win condition = raze ALL enemy buildings (lose if all yours fall).** No economic/king-of-hill win.
   `engagement.py` must eventually **commit a decisive combined-arms force to destroy the enemy base**
   while `defense.py` holds `keep_home`. A pure turtle never wins; an over-commit that strips home loses
   the base. Balance (the `commit_ratio` + `keep_home` gate) is the core skill.

**CWC tech tree (role order for `base.py` / `build_priority` defaults):** CommandCenter (trains the
Dozer builder) → Barracks (early infantry for capture + defense) → econ (capture points + fuel depot)
→ WarFactory (vehicles) → AirField/Helipad (aircraft) → defense Forts on the threatened flank. Resolve
each role to a real template per-faction via `find_buildable_by_role`.

These specializations are **defaults baked into the algorithmic Commander** (so it plays CWC well with
no LLM); the LLM only re-weights them via the `StrategyDirective`.

## 9. Observed CWC roster (reference, mined from live games)

Source of truth at runtime is `/catalog` + `/buildable`; this is a captured snapshot for design only.

- **Neutral economy (`CWCciv`, capturable income):** `Fuel_{Large,Medium,Small}_{OilDepot,OilRefinery,
  OilStorageTank,OilTank,GasStation,ConsumerDrone}`, `Flag_{Large,Small}`, plus civ props (Church,
  FishHut). These are the economy — capture & hold.
- **USA (`CWCus`):** structures CommandCenter, Barracks, WarFactory, AirField, Helipad, Dropzone,
  SmallFuelDepot, FortM2 (defense); builder Dozer; infantry AntiAir/AntiTank/Assault/HeavyAssault/
  Engineer/Medic/Officer/Sniper/M2Man (+ LAW-AT, White/Black & DeathRider variants); vehicles M60A3
  (tank), M60A3_AAGun (AA), M113 (APC), M2A1.
- **USSR (`CWCru`):** structures CommandCenter, Barracks, SmallFuelDepot; builder Dozer; infantry same
  role set (+ DeathRider variants); vehicles T72 (+MachineGun), BTR80 (APC), BRDM2 (recon/AT), AT5
  (AT missile); aircraft Mi24 (Hind gunship), Mi26 (heavy transport / supply drop).
- **Notes:** `DeathRider`/`White0x`/`Black0x` are unit variants → classify by capability, not name.
  `…SupplyDropDZ` / `Dropzone` = reinforcement delivery, not normal production.
