"""Commander — the always-on algorithmic CWC bot, and its standalone runner.

The Commander orchestrates the proven macro skills (build_base / maintain_army / capture_points /
defend_base) as STANDING ORDERS, in priority order, and adds the piece the M3 LLM loop never closed:
**continuous autonomous offense** — a strike force that masses past a home guard and assaults the
enemy base until it is razed. No LLM is required to play or win; a StrategyDirective only re-weights
the doctrine (army size, home guard, strike threshold, build order, posture).

run_commander() is a self-contained observe→act loop (modelled on agent.orchestrator.orchestrate but
deterministic, no planner): cache the terrain once, classify capture-capable units from /catalog once,
then each tick rebuild the fog-aware world, build a SkillContext, and step the Commander.
"""

import math
import time

from agent.brief import _enemy_base_guess
from agent.knowledge import capture_capable_templates
from agent.skills import base as _base  # read CAPTURE_TEMPLATES live (set once per match)
from agent.skills.base import (
    SkillContext, set_capture_templates, my_buildings, my_units, is_building,
    select_combat_units, is_combat_unit, find_dozers, find_build_spot, find_buildable_by_role,
    find_trainable, find_trainable_combat, buildable_now, capture_capable_units, capturable_points, obj_pos, alive_ids,
    _ROLE_HINTS, DONE, FAILED,
)
from agent.skills.library import (
    BuildBaseSkill, MaintainArmySkill, DefendBaseSkill, CapturePointsSkill,
)
from agent.cwc.knowledge_base import get_kb
from agent.cwc import uistate, combat_eval
from agent.cwc.intel import BattlefieldIntel
from agent.cwc.opening import OpeningScript
from agent.cwc.sectors import SectorModel


class _Strike:
    """Lightweight standing-order handle for the offense — exposes name='attack_area' + params['_force']
    so the macro skills' sibling-coordination (defend/capture) leave the strike force alone."""
    name = "attack_area"

    def __init__(self):
        self.params = {"_force": []}
        self.detail = "idle"

    def status_line(self):
        return self.detail
from agent.strategy import resolve_directive, load_directive, DIRECTIVE_PATH
from genapi.world import WorldModel


class _TaskShim:
    """Minimal taskmgr stand-in so the macro skills' sibling-coordination helpers
    (force_claimed_by_siblings) can see each other's reserved unit ids — this is what keeps the
    strike force, the capture force, and the home guard from fighting over the same units."""

    def __init__(self, get_skills):
        self._get = get_skills

    def active(self):
        return [{"skill": s.name, "params": s.params} for s in self._get()]


class Commander:
    def __init__(self, owner, directive_path=DIRECTIVE_PATH):
        self.owner = owner
        self.directive_path = directive_path
        self.directive = resolve_directive()
        self._dir_mtime = None
        # CWC knowledge base (counter matrix, roles, stats) — loaded once, shared.
        # intel/sectors are populated in later phases; None here is harmless.
        self.kb = get_kb()
        self.intel = BattlefieldIntel(self.kb, owner)
        self.sectors = None
        self.opening = OpeningScript(self.kb)
        # standing orders — proven doctrine from skills/library.py
        self.build = BuildBaseSkill({})
        self.army = MaintainArmySkill({})
        self.capture = CapturePointsSkill({})
        self.defend = DefendBaseSkill({})
        self.strike = _Strike()        # persistent offense strike force
        self._committed = False        # once an assault launches, stay committed until wiped/won
        self._last_attack = -10 ** 9
        self._last_est = None          # last engagement estimate (for UI/debug)
        self._raze_target = None       # id of the enemy production building we're locked onto razing
        self._shim = _TaskShim(self._siblings)
        self.last_detail = {}
        # Capture is bonus income (lone capturers die to the roaming AI army), so commit modestly and
        # keep a real home guard; the main economy comes from fuel-depot trickle + a steady army.
        self.capture.HOME_GUARD = 4
        self.capture.MAX_OUT = 8
        self.capture.RETRY = 350
        # custom move-then-capture state (the engine's capture power stops short of the building, so we
        # walk the capturer ONTO the point first, then trigger the power when adjacent)
        self._cap_cmd = {}       # unit_id -> (point_id, frame_issued)
        self._cap_assign = {}    # unit_id -> point_id (STICKY: a capturer keeps its point until taken)
        self._cap_detail = "idle"
        # produce army fast so a dominant economy becomes a dominant army (default 75f was far too slow
        # — the enemy AI out-trained us 97-vs-63 while our capture income sat idle)
        self.army.PERIOD = 12
        self.build.DOZER_TARGET = 4   # more dozers → parallel construction + survive losing some
        self._army_detail = ""
        self._prod_k = 0
        self._last_expand = -10 ** 9
        self._expand_attempt = 0
        self._last_cap_train = -10 ** 9
        # tank quota (user feedback #1) — global per-tick reservation set by _produce_tank
        self._tank_reserve = 0
        self._tank_detail = ""
        self._last_tank_train = -10 ** 9
        # siege quota — artillery built only while COMMITTED (base-crack demolition DPS)
        self._siege_reserve = 0
        self._siege_detail = ""
        self._last_siege_train = -10 ** 9

    def _produce_army(self, ctx, target):
        """Train combat units at EVERY ready factory each tick (not one-at-a-time) so a big capture
        economy becomes a big army fast. find_trainable_combat returns only affordable+ready builders,
        so busy factories are skipped automatically. Rotates unit types for a combined-arms mix."""
        army_n = len(select_combat_units(ctx))
        if army_n >= target:
            self._army_detail = "army {}/{} (full)".format(army_n, target)
            return
        trainable = find_trainable_combat(ctx)
        if not trainable:
            self._army_detail = "army {}/{} (no factory ready)".format(army_n, target)
            return
        money = ctx.me.get("money") or 0
        base = ctx.world.centroid(my_buildings(ctx))
        # COUNTER-AWARE production: order this tick's picks by how well they counter
        # what the enemy actually fields (combat_eval over the KB matrix), preserving
        # a combined-arms mix.  Falls back to the old cheapest-rotation when the KB
        # has no data for the trainable set (faction-agnostic safety).
        # The TANK (vehicle quota) is bought separately at the TOP of step() under a GLOBAL reserve
        # (_produce_tank); here we build only the non-tank mix and must leave self._tank_reserve
        # unspent so the reserved cash survives to the war factory.
        profile = self.intel.enemy_profile() if self.intel else {}
        ordered = self._counter_order(trainable, profile)
        used, made, picks = set(), 0, []
        for tmpl, builder, cost, _e in ordered:
            if not builder or builder in used or money < cost:
                continue
            if (money - cost) < (self._tank_reserve + self._siege_reserve):
                continue                           # keep money saved for the reserved tank/siege
            ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
            if base:
                ctx.client.command(ctx.player, [builder], "set_rally", {"pos": {"x": base[0], "y": base[1]}})
            used.add(builder); money -= cost; made += 1; picks.append(tmpl)
        self._prod_k += 1
        tag = "counter" if profile else "blind"
        shortp = [p[5:] if p.startswith("CWC") else p for p in picks]  # drop CWCxx prefix
        self._army_detail = "army {}/{} (+{}@{}fac {}:{}){}".format(
            army_n, target, made, len(used), tag,
            ",".join(sorted(set(shortp))[:3]) if shortp else "-",
            self._tank_detail + self._siege_detail)

    def _counter_order(self, trainable, profile):
        """Order trainable (template,builder,cost,entry) by counter value vs the
        enemy profile, rotating among the top picks for combined arms.  Pure KB
        reasoning; if the KB scores everything 0 (unknown templates) keep the
        original cheapest-first rotation so nothing regresses."""
        if not self.kb or not self.kb.loaded:
            rot = self._prod_k % len(trainable)
            return trainable[rot:] + trainable[:rot]
        ranked = combat_eval.best_counters(self.kb, profile, trainable)
        if not ranked or ranked[0][1] <= 0:
            rot = self._prod_k % len(trainable)
            return trainable[rot:] + trainable[:rot]
        tuples = [t for t, _ in ranked]
        # rotate the top-3 to the front each tick so we don't build 100% of one
        topn = min(3, len(tuples))
        rot = self._prod_k % topn
        head = tuples[:topn]
        head = head[rot:] + head[:rot]
        return head + tuples[topn:]

    _SUPPORT = ("ural", "radar", "supply", "ambul", "scout", "drone",
                "transport", "cruisemissile")

    def _is_combat_veh(self, t):
        """A real fighting GROUND vehicle for the tank quota: excludes aircraft, structures, dozers
        and support trucks (Ural/radar/supply/transport). Must carry an anti-tank or anti-infantry
        weapon. KB-driven; returns False when the KB has no data (keyword path stays the fallback)."""
        if not (self.kb and self.kb.loaded):
            return False
        r = self.kb.roles_of(t)
        if "vehicle" not in r or "structure" in r or "dozer" in r or "aircraft" in r:
            return False
        if "anti_tank" not in r and "anti_inf" not in r:
            return False           # must actually fight (skip Ural/radar/supply trucks)
        return not any(k in t.lower() for k in self._SUPPORT)

    def _is_quota_tank(self, t):
        """A real GENERALIST main battle tank for the tank quota: a tracked gun platform that kills both
        infantry AND armor (anti_inf + anti_tank), not AA/artillery, not a troop-carrying IFV (transport).
        = T-72/T-64 (USSR), M60A3/M1A1 (USA). Excludes the light AT/recon vehicles (BRDM-2, AT-5, BMP/BTR,
        Shilka) that were filling the vehicle quota so no real tank ever got built."""
        if not (self.kb and self.kb.loaded):
            return False
        r = self.kb.roles_of(t)
        return ("vehicle" in r and "anti_tank" in r and "anti_inf" in r
                and "aa" not in r and "artillery" not in r and "transport" not in r)

    def _pick_tank(self, ctx):
        """When BELOW the vehicle quota, choose the tank to buy. Prefer an MBT (anti-tank GROUND
        generalist — not AA/artillery) and, among qualifiers, the CHEAPEST: a reachable reserve
        (T-72 $800) fields armor far sooner than a priciest-MBT target (T-80UK $1700) the money
        never reaches — the precise bug that kept the army all-infantry. Sourced from PER-BUILDER
        /buildable options incl. canMake=='no_money' so an unaffordable tank is still visible to
        reserve for (find_trainable_combat hides unaffordable units). Returns (tmpl, builder, cost)
        or None when at/above quota, no KB, or no buildable vehicle (e.g. no war factory yet)."""
        if not (self.kb and self.kb.loaded):
            return None
        combat = select_combat_units(ctx)
        # Count ONLY real generalist tanks toward the quota (not light AT/IFV/arty). Otherwise BRDM-2 /
        # BMP / BTR / Shilka / 2S1 fill the 30% "vehicle" quota and a real T-72 is never forced — the
        # verified "9 BRDM-2, 0 T-72" bug. _is_quota_tank = the generalist MBT tier (T-72/T-64, M60A3/M1A1).
        tanks = sum(1 for u in combat if self._is_quota_tank(u.get("template", "")))
        frac = (tanks / len(combat)) if combat else 0.0
        if frac >= self.TANK_FRACTION:
            return None
        cands = []  # (template, builderId, cost)
        for blder in (buildable_now(ctx).get("builders") or []):
            for o in (blder.get("options") or []):
                if o.get("how") == "train" and o.get("canMake") in ("ok", "no_money"):
                    t = o.get("template")
                    if t and self._is_combat_veh(t):
                        cands.append((t, blder.get("id"), o.get("cost", 0) or 0))
        if not cands:
            return None
        def _rank(c):
            t, _b, cost = c
            r = self.kb.roles_of(t)
            is_mbt = ("anti_tank" in r and "aa" not in r and "artillery" not in r)
            # A TRUE tank is a tracked gun platform, not a troop-carrying IFV/Humvee. The role-tagger
            # over-tags MG/grenade Humvees (M998_M2/Mk19) as anti_tank, and they ALL carry 'transport';
            # real MBTs (M60A3/M1A1, T-72/T-80) do not. Excluding transport drops the jeeps.
            is_true_tank = is_mbt and "transport" not in r
            # A real MBT is a GENERALIST gun platform — it kills BOTH infantry (HE/coax) AND armor
            # (main gun). Pure tank-DESTROYERS (AT-5 Spandrel, M998_TOW: anti_tank ONLY) are fragile
            # wheeled ATGM carriers, not base-crackers; requiring anti_inf too picks T-72 over AT-5 and
            # M60A3 over the TOW Humvee. Tiered so we still fall back to any tank if no generalist sells.
            is_generalist = is_true_tank and "anti_inf" in r
            return (1 if is_generalist else 0, 1 if is_true_tank else 0,
                    1 if is_mbt else 0, -cost)
        cands.sort(key=_rank, reverse=True)
        return cands[0]

    TANK_TRAIN_PERIOD = 150   # min frames between tank orders (don't queue a stack in one war factory)
    TANK_ARMY_FLOOR = 8       # don't reserve for a tank until a small army exists — else the opening
                              # capture-rush is starved before the economy is up

    def _produce_tank(self, ctx):
        """Buy the quota tank at the TOP of step(), BEFORE capturers/expand/opening spend, and publish
        self._tank_reserve so those earlier spenders leave the tank's cost unspent. THE FIX for 'builds
        tank factories but no tanks' (user feedback #1): money oscillated $75-1130, drained every tick
        before _produce_army ran, so a reserve local to that loop never protected savings. Now the
        reserve is global to the tick and the tank buys the instant it's affordable. Self-gates: no war-
        factory vehicle option → _pick_tank returns None → no reserve; needs a small army first so the
        opening capture-rush isn't starved."""
        self._tank_reserve = 0
        self._tank_detail = ""
        if len(select_combat_units(ctx)) < self.TANK_ARMY_FLOOR:
            return
        cand = self._pick_tank(ctx)
        if not cand:
            return
        tmpl, builder, cost = cand
        self._tank_reserve = cost
        short = tmpl[5:] if tmpl.startswith("CWC") else tmpl
        money = ctx.me.get("money") or 0
        if builder is None:
            self._tank_detail = " |tank:{} no-builder".format(short)
            return
        if money < cost:
            self._tank_detail = " |tank:{} save ${}/{}".format(short, money, cost)
            return
        if ctx.frame - self._last_tank_train < self.TANK_TRAIN_PERIOD:
            self._tank_detail = " |tank:{} cooldown".format(short)
            return
        ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
        base = ctx.world.centroid(my_buildings(ctx))
        if base:
            ctx.client.command(ctx.player, [builder], "set_rally", {"pos": {"x": base[0], "y": base[1]}})
        self._last_tank_train = ctx.frame
        self._tank_reserve = 0          # bought this tick — release the reservation
        self._tank_detail = " |tank:{} BUILT ${}".format(short, money)

    SIEGE_TARGET = 3        # artillery pieces to maintain during an assault
    SIEGE_PERIOD = 200      # min frames between artillery orders

    def _produce_siege(self, ctx):
        """During a COMMITTED assault, field ARTILLERY (role 'artillery' = indirect-fire 2S1/BM21/M109/
        MLRS). It is the only unit class with the anti-STRUCTURE damage + standoff range to crack a base
        quickly: the counter-production builds an anti-UNIT force (anti-tank/anti-air infantry) that barely
        scratches 1000-2000 HP buildings, so without siege the bot razes too slowly and the enemy out-
        rebuilds (verified: AirField chipped 1500→1001 over minutes). Reserve+build like _produce_tank;
        only while self._committed so we don't divert the economy before the army even forms. The committed
        tank+infantry force escorts the fragile artillery."""
        self._siege_reserve = 0
        self._siege_detail = ""
        if not self._committed or not (self.kb and self.kb.loaded):
            return
        arty = [u for u in select_combat_units(ctx)
                if "artillery" in self.kb.roles_of(u.get("template", ""))]
        if len(arty) >= self.SIEGE_TARGET:
            return
        cands = []  # (template, builderId, cost)
        for blder in (buildable_now(ctx).get("builders") or []):
            for o in (blder.get("options") or []):
                if o.get("how") == "train" and o.get("canMake") in ("ok", "no_money"):
                    t = o.get("template")
                    if t and "artillery" in self.kb.roles_of(t):
                        cands.append((t, blder.get("id"), o.get("cost", 0) or 0))
        if not cands:
            return
        cands.sort(key=lambda c: c[2])      # cheapest artillery piece
        tmpl, builder, cost = cands[0]
        self._siege_reserve = cost
        short = tmpl[5:] if tmpl.startswith("CWC") else tmpl
        money = ctx.me.get("money") or 0
        if builder is None:
            self._siege_detail = " |siege:{} no-builder".format(short); return
        if money < cost:
            self._siege_detail = " |siege:{} save ${}/{}".format(short, money, cost); return
        if ctx.frame - self._last_siege_train < self.SIEGE_PERIOD:
            self._siege_detail = " |siege:{} cd".format(short); return
        ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
        base = ctx.world.centroid(my_buildings(ctx))
        if base:
            ctx.client.command(ctx.player, [builder], "set_rally", {"pos": {"x": base[0], "y": base[1]}})
        self._last_siege_train = ctx.frame
        self._siege_reserve = 0
        self._siege_detail = " |siege:{} BUILT".format(short)

    # how many of my buildings serve a given role (keyword match, faction-agnostic)
    TANK_FRACTION = 0.30   # aim ~30% of the army as vehicles/tanks (durable base-crackers)
    EXPAND_CAPS = {"power": 2, "warfactory": 4, "barracks": 5, "defense": 6}
    EXPAND_ORDER = ["power", "warfactory", "barracks", "defense"]  # fuel depot (power) is the TECH GATE
                   # for the war factory; then MANY factories so capture income becomes a big army
    EXPAND_FLOOR = 700     # build factories with modest cash — they're the throughput that wins
    EXPAND_PERIOD = 130    # build factories faster
    BUILDING_TARGET = 6    # a lean base (CC + fuel + 2 barracks + warfactory + defense); income is CAPTURE,
                           #   not buildings, so don't sink the opening cash into structures
    MIN_DEFENSE = 4        # tiny home defense, then everything into capturers + capturing
    FACTORY_TARGET = 5     # build out to ~this many production buildings before flooding army (so the
                           # dominant capture economy actually OUT-PRODUCES the enemy, not just matches)
    CAPTURER_TARGET = 6    # enough capturers for strong income; fewer frees cash for FACTORIES (the
                           # throughput that converts the economy into a winning army)
    CAP_TRAIN_PERIOD = 55  # pump capturers fast early
    CAP_MAX_OUT = 8        # capturers committed to grabbing points at once (rest stay as army)
    CAP_REISSUE = 700      # only RE-issue capture if this long passed (i.e. it failed) — the capture
                           # power approaches + channels on its own, and re-issuing mid-channel RESTARTS
                           # it, so it must NOT be spammed (that's why oil never rose before)

    def _ensure_capturers(self, ctx):
        """Deliberately produce cheap capture-capable infantry (CWC: Officer/Assault) so the
        capture-economy actually scales — without this the army is all AntiTank/AA/Sniper and NOTHING
        can take an oil point, so income never grows. Data-driven from the engine's canCapture set."""
        if ctx.frame - self._last_cap_train < self.CAP_TRAIN_PERIOD:
            return
        if len(capture_capable_units(ctx)) >= self.CAPTURER_TARGET:
            return
        cap_set = {c.lower() for c in (_base.CAPTURE_TEMPLATES or set())}
        cands = find_trainable(ctx, lambda tl, e: e.get("how") == "train" and tl in cap_set)
        if not cands:
            return
        tmpl, builder, cost, _e = sorted(cands, key=lambda x: x[2])[0]  # cheapest capturer (Assault)
        money = ctx.me.get("money") or 0
        if builder and money >= cost and (money - cost) >= (self._tank_reserve + self._siege_reserve):
            ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
            base = ctx.world.centroid(my_buildings(ctx))
            if base:
                ctx.client.command(ctx.player, [builder], "set_rally", {"pos": {"x": base[0], "y": base[1]}})
            self._last_cap_train = ctx.frame

    def _capture(self, ctx):
        """Capture economy: STICKY-assign capturers to neutral civ points and issue the capture power
        ONCE per assignment. The fixed engine verb now triggers the unit's own capture power, which
        approaches + channels on its own; we must NOT re-issue (that restarts the channel) and must NOT
        re-shuffle assignments (that yanks a channelling capturer off its point). A capturer keeps its
        point until it's ours (then it's freed for the next). Reserved in _capture_force so the
        defend/offense managers leave them be."""
        caps = {u["id"]: u for u in capture_capable_units(ctx)}
        pts = {u["id"]: u for u in capturable_points(ctx)}   # neutral/enemy, capturable, not yet mine
        # drop assignments whose unit died or whose point is captured/gone (→ free that capturer)
        self._cap_assign = {uid: pid for uid, pid in self._cap_assign.items()
                            if uid in caps and pid in pts}
        if not caps or not pts:
            self.capture.params["_capture_force"] = list(self._cap_assign)
            self._cap_detail = "no capturers" if not caps else "no points in sight"
            return
        base = ctx.world.centroid(my_buildings(ctx)) or obj_pos(next(iter(caps.values())))
        # assign FREE capturers to the nearest-to-home unassigned points (closest = safest), up to cap
        taken_pts = set(self._cap_assign.values())
        free = [u for uid, u in caps.items() if uid not in self._cap_assign]
        open_pts = sorted((p for pid, p in pts.items() if pid not in taken_pts),
                          key=lambda p: math.hypot(p.get("x", 0) - base[0], p.get("y", 0) - base[1]))
        for p in open_pts:
            if len(self._cap_assign) >= self.CAP_MAX_OUT or not free:
                break
            c = min(free, key=lambda u: math.hypot(u.get("x", 0) - p["x"], u.get("y", 0) - p["y"]))
            free.remove(c)
            self._cap_assign[c["id"]] = p["id"]
        # execute: issue the capture power ONCE per (unit,point); only re-issue if long-stale (failed)
        for uid, pid in self._cap_assign.items():
            last_pid, last_f = self._cap_cmd.get(uid, (None, -10 ** 9))
            if last_pid != pid or ctx.frame - last_f >= self.CAP_REISSUE:
                ctx.client.command(ctx.player, [uid], "capture", {"targetId": pid})
                self._cap_cmd[uid] = (pid, ctx.frame)
        self.capture.params["_capture_force"] = list(self._cap_assign)
        self._cap_detail = "capturing {} pts (sticky)".format(len(self._cap_assign))

    def _count_role(self, ctx, role):
        hints = _ROLE_HINTS.get(role, ())
        return sum(1 for u in my_buildings(ctx)
                   if any(h in (u.get("template") or "").lower() for h in hints))

    # skills whose reserved-unit params the coordination helpers must see
    def _siblings(self):
        return [self.capture, self.strike]

    def _reload_directive(self):
        import os
        try:
            m = os.path.getmtime(self.directive_path)
        except OSError:
            return
        if m == self._dir_mtime:
            return
        self.directive, _ = load_directive(self.directive_path)
        self._dir_mtime = m

    def _apply_directive(self):
        d = self.directive
        self.army.params["target"] = int(d["army"]["target"])
        roles = d.get("build_priority")
        if roles:
            self.build.DEFAULT_ROLES = list(roles)

    def step(self, ctx):
        self._reload_directive()
        self._apply_directive()
        ctx.taskmgr = self._shim
        # expose CWC brains to skills + observe the enemy FIRST (pure read)
        ctx.kb = self.kb
        ctx.intel = self.intel
        ctx.sectors = self.sectors
        if self.intel is not None:
            try:
                self.intel.observe(ctx)
            except Exception:  # noqa: BLE001 - intel is best-effort, never break the tick
                pass
        d = self.directive

        # TANK QUOTA (user feedback #1: "you build tank factories but no tanks"). Compute the reserve
        # and buy the tank FIRST, before the capturer/expand/opening spend below — money oscillated
        # $75-1130 and was drained every tick before _produce_army ran, so the tank never fielded.
        # _produce_tank self-gates (no war-factory vehicle option / army still tiny → no reserve), so
        # this never starves the opening economy.
        self._produce_tank(ctx)
        # SIEGE: while committed, field artillery (anti-structure DPS to actually raze the base fast).
        self._produce_siege(ctx)

        # CWC is ECONOMY-FIRST: income is capture-driven, so a wide economy (many capturers holding many
        # oil/flag points + extra production buildings) out-scales an army flooded from one base. The
        # economy therefore gets FIRST claim on cash; the army is funded from what's left and scales WITH
        # the economy. This is the fix for the army-first plateau (bot stuck at 5 bldgs while the AI
        # snowballed to 11).
        # 0) OPENING overlay (additive): shapes the build order and fires the dictated
        # early production (capturer burst, MG+AT Humvee, engineers-into-transports).
        # It reuses build.tick for placement and hands back once vehicles flow.
        if not self.opening.done and d.get("opening", {}).get("enabled", True):
            try:
                self.opening.tick(self, ctx)
            except Exception:  # noqa: BLE001 - opening is best-effort
                pass
        # 1) base plan, then keep scaling buildings, then build capturers, then capture oil
        self.build.tick(ctx)
        # CAPTURE-RUSH economy: income = capturing neutral civ oil/gas/flag points (the enemy AI grabs
        # ~7 early). So PUMP cheap capturers and commit them to nearby points BEFORE sinking cash into
        # extra buildings — capturing is the income engine; built fuel depots barely pay.
        self._ensure_capturers(ctx)
        if d["economy"].get("capture", True):
            self._capture(ctx)
        self._expand(ctx)
        # ARMY — funded by capture income; scales with buildings. Hold army spend while we still need a
        # bit more economy (so cash goes to capturers first), once a small defense exists.
        # Convert the capture economy into ARMY: scale the target with captured points (= income),
        # effectively uncapped (income limits real size). A dominant economy must become a dominant army.
        captured = len([u for u in ctx.world.units if u.get("player") == ctx.player
                        and (u.get("template") or "").startswith("CWCciv")])
        # Scale the army with captured income, but CAP it: a combined-arms ~ARMY_HARD_CAP force (incl.
        # tanks) already overwhelms the easy AI, and beyond that the ENGINE's hierarchical pathfinder
        # chokes when 100+ units all attack-move to the distant enemy base at once (FindHierarchicalPath
        # spam → the game HANGS / API goes unresponsive before the kill). Fewer, better units > a horde.
        target = min(self.ARMY_HARD_CAP, max(int(d["army"]["target"]), 30 + 6 * captured))
        # Reserve cash for the $3000 fuel depot that UNLOCKS the war factory (tanks): build a basic
        # infantry defense first, then SAVE — otherwise cheap infantry keeps draining cash below $3000,
        # the fuel depot never gets built, and the bot is stuck with a weak infantry-only army.
        # Build out PRODUCTION before flooding army: with only 2 factories the dominant economy can't
        # out-produce the enemy (unlimited factories), so the army only matches and can't break the core.
        # Reserve cash for the fuel depot (tank tech) AND ~5 factories; keep a basic defense (12) while
        # saving. _expand spends the reserved cash on factories (placement now correct).
        n_fac = self._count_role(ctx, "barracks") + self._count_role(ctx, "warfactory")
        have_wf = self._count_role(ctx, "warfactory") > 0
        money = ctx.me.get("money") or 0
        if len(select_combat_units(ctx)) >= 12 and money < 4000 and ((not have_wf) or n_fac < self.FACTORY_TARGET):
            self._army_detail = "saving ${} for production ({}/{} factories)".format(money, n_fac, self.FACTORY_TARGET)
        else:
            self._produce_army(ctx, target)
        # 3) DEFENSE — commands ONLY the HOME GUARD. Exclude the committed strike force and the capture
        # force, otherwise defend's guard_zone(base) and offense's attack_target(enemy) alternate on the
        # SAME units every ~120 frames: the units oscillate between "come home" and "go attack" and just
        # cluster at base, never doing either (the "units pile up at home / orders re-link on the same
        # units" symptom). With this, the strike force obeys offense and only the reserve guards home.
        reserved = set(self.strike.params.get("_force", [])) | set(self.capture.params.get("_capture_force", []))
        self.defend.params["ids"] = [u["id"] for u in select_combat_units(ctx) if u["id"] not in reserved]
        self.defend.tick(ctx)
        # 4) OFFENSE — continuous assault on the enemy base once a surplus has massed
        if d["offense"].get("engage", True):
            self._offense(ctx)

        self.last_detail = {
            "build": self.build.status_line(),
            "army": self._army_detail,
            "capture": self._cap_detail,
            "defend": self.defend.status_line(),
            "attack": self.strike.status_line(),
            "opening": ("done" if self.opening.done else self.opening.detail),
            "tank": self._tank_detail.strip(" |") or "—",
        }

    COMMIT_HOME_GUARD = 6  # while committed, keep only this many units home — commit the rest as one
                           # concentrated wave (a dribble of 6-9 just dies at the defended base)
    ARMY_HARD_CAP = 64     # cap total army size — past this the engine pathfinder chokes on mass
                           # attack-moves (FindHierarchicalPath spam → game hang). Tunable; ~48 commit.
    ATTACK_ARMY_MIN = 18   # FLOOR: never commit fewer than this (don't feed dribs to defenses)
    ATTACK_ARMY_CAP = 48   # CEILING: commit regardless of the estimate once this big (don't turtle on a
                           # pessimistic estimate — an overwhelming mass beats unmodeled base defenses)
    ATTACK_REISSUE = 120   # frames between re-issuing the attack order
    COMMIT_WIN_PROB = 0.55 # engagement_estimate edge required to commit: a real (not just even) edge so we
                           # don't all-in into the defended core, but low enough that a dominant economy
                           # still pushes instead of turtling to death
    # ECONOMIC-DOMINANCE GRIND COMMIT: the engagement estimate is a single-clash snapshot — it ignores
    # REINFORCEMENT. When the bot out-economies the enemy (many captured income points + factories), it
    # replaces losses faster than the enemy can, so a committed + auto-reinforcing combined-arms force
    # (now incl. M60 tanks that absorb base-defense fire) GRINDS a roughly-even fight down instead of
    # turtling to a draw while the easy AI snowballs buildings. Gated by a healthy army + strong income,
    # with a wp>=floor so we never feed into a clearly losing matchup.
    GRIND_ARMY_MIN = 26    # a solid combined-arms force (incl. tanks) before grinding
    GRIND_OIL = 12         # captured income points = reinforcement edge (proxy: we out-produce the enemy)
    GRIND_WIN_PROB = 0.40  # floor: below this the clash is genuinely losing — keep massing/countering

    def _commit_decision(self, ctx, army_ids):
        """Decide whether to launch the assault using the KB engagement estimate
        instead of a blind unit count.  Commit when our strike-eligible force would
        BEAT the enemy's current army with margin (so we don't all-in into the
        defended core kill-zone), with a floor (never trickle) and a ceiling (an
        overwhelming mass commits regardless of a pessimistic estimate)."""
        n = len(army_ids)
        if n < self.ATTACK_ARMY_MIN:
            return False, "massing ({}/{} floor)".format(n, self.ATTACK_ARMY_MIN)
        if n >= self.ATTACK_ARMY_CAP:
            return True, "overwhelming mass ({})".format(n)
        kb = self.kb
        if not (kb and kb.loaded):
            # no KB → fall back to the old fixed threshold
            return (n >= 30), "massing ({}/30)".format(n)
        # my strike force composition
        ids = set(army_ids)
        my_force = {}
        for u in select_combat_units(ctx):
            if u["id"] in ids:
                t = u.get("template")
                if t:
                    my_force[t] = my_force.get(t, 0) + 1
        # enemy force = currently-visible enemy combat units (what we'd actually
        # fight), falling back to the intel histogram if nothing is in sight
        enemy_force = {}
        for u in ctx.world.enemies():
            if is_building(u):
                continue
            t = u.get("template")
            if t and is_combat_unit(u):
                enemy_force[t] = enemy_force.get(t, 0) + 1
        if not enemy_force and self.intel:
            enemy_force = dict(self.intel.enemy_profile())
        if not enemy_force:
            # enemy army not yet scouted — push once we have a solid force
            return (n >= 24), "no enemy seen ({}/24)".format(n)
        est = combat_eval.engagement_estimate(kb, my_force, enemy_force)
        wp = est["win_prob"]
        thresh = float(self.directive.get("offense", {}).get("min_win_prob",
                                                             self.COMMIT_WIN_PROB))
        self._last_est = est
        if wp >= thresh:
            return True, "edge wp={:.2f} dps×{} (n={})".format(
                wp, est.get("dps_ratio"), n)
        # economic-dominance grind commit (see GRIND_* constants): out-reinforce a roughly-even fight
        captured = len([u for u in ctx.world.units if u.get("player") == ctx.player
                        and (u.get("template") or "").startswith("CWCciv")])
        if n >= self.GRIND_ARMY_MIN and captured >= self.GRIND_OIL and wp >= self.GRIND_WIN_PROB:
            return True, "GRIND commit wp={:.2f} oil={} (n={})".format(wp, captured, n)
        return False, "massing wp={:.2f}<{:.2f} (n={}) oil={} — out-massing/countering".format(
            wp, thresh, n, captured)

    def _offense(self, ctx):
        """Guaranteed offense: once the army is big enough, commit everything beyond a FIXED home guard
        to a persistent strike force and attack-move it into the enemy base, reinforcing each wave. This
        replaces AttackAreaSkill, whose keep-home inflated with every bit of harassment so the strike
        force was perpetually 0 and the bot never actually attacked."""
        d = self.directive
        guess = _enemy_base_guess(ctx.world, my_buildings(ctx), my_units(ctx))
        if not guess:
            self.strike.detail = "no enemy-base estimate"
            return
        cap_force = set(self.capture.params.get("_capture_force", []))
        army_ids = [u["id"] for u in select_combat_units(ctx) if u["id"] not in cap_force]
        # CONCENTRATE FORCE once committed: keep only a SMALL fixed home guard and throw the BULK at the
        # base. With the full keep_home (~12) and an attrited army (~21) the strike force shrank to ~6-9
        # and got fed piecemeal to its death without ever massing enough to crack a defended base
        # (verified: 6-unit strikes died en route, 0 reached the target). A concentrated wave + the
        # stay-committed reinforcement is what actually razes.
        keep = int(d["army"]["keep_home"])
        if self._committed:
            keep = min(keep, self.COMMIT_HOME_GUARD)
        # Commit once the army reaches the threshold, then STAY committed: keep assaulting with everything
        # beyond the home guard (auto-reinforced as units train) until the strike force is wiped. Without
        # this the bot crushes the enemy army, drops below threshold, RETREATS to re-mass, and never
        # finishes razing the core (the enemy just rebuilds its army).
        if not self._committed:
            ok, why = self._commit_decision(ctx, army_ids)
            if not ok:
                self.strike.params["_force"] = []
                self.strike.detail = why
                return
            self._committed = True
            self.strike.detail = "COMMIT: " + why
        force = army_ids[keep:]   # everything beyond the home guard assaults (auto-reinforced each tick)
        if not force:
            self._committed = False
            self.strike.params["_force"] = []
            self.strike.detail = "strike force wiped — re-massing"
            return
        self.strike.params["_force"] = force
        if ctx.frame - self._last_attack < self.ATTACK_REISSUE:
            return
        self._last_attack = ctx.frame
        # BASE-CRACK targeting (perimeter → inward). The old logic locked the DEEPEST production building
        # and drove the whole force onto it — straight past the enemy's base defenses into their kill-zone,
        # where the army melted before razing anything (verified: 30+ units lost, 0 buildings down). Instead
        # raze the enemy structure NEAREST the strike force: defenses + outer buildings fall first, and as
        # each is destroyed (ghost-prune drops it from memory) the lock advances one ring deeper — the force
        # always fights at the edge it can actually win, chewing the base apart from outside in. PRODUCTION
        # buildings (the win condition) get a mild distance bonus so we finish a game-ender when it's near.
        # Hold the lock until that building is gone (don't chase a flickering fog centroid).
        units_by_id = {u["id"]: u for u in select_combat_units(ctx)}
        fpos = [(units_by_id[i]["x"], units_by_id[i]["y"]) for i in force
                if i in units_by_id and "x" in units_by_id[i]]
        fcx = sum(x for x, _ in fpos) / len(fpos) if fpos else None
        fcy = sum(y for _, y in fpos) / len(fpos) if fpos else None
        intel = self.intel
        known = intel.all_enemy_buildings() if intel else []
        known = [b for b in known if "x" in b and "y" in b]
        prod_ids = {b["id"] for b in (intel.production_targets() if intel else [])}
        known_ids = {b["id"] for b in known}
        # relock if our target was razed (dropped from memory by the ghost-prune)
        locked = getattr(self, "_raze_target", None)
        if locked is not None and locked not in known_ids:
            locked = None
        tx = ty = None
        src = "?"
        if known and fcx is not None:
            if locked is None:
                PROD_BONUS = 200.0   # prefer a production building within ~200u of the nearest target
                def _score(b):
                    d = math.hypot(b["x"] - fcx, b["y"] - fcy)
                    return d - (PROD_BONUS if b["id"] in prod_ids else 0.0)
                locked = min(known, key=_score)["id"]
            tb = next((b for b in known if b["id"] == locked), None)
            if tb:
                kind = "RAZE" if tb["id"] in prod_ids else "CRACK"
                tx, ty = tb["x"], tb["y"]
                src = kind + " " + tb["template"].replace("CWCus", "").replace("CWCru", "")
        self._raze_target = locked
        if tx is None:
            # No production scouted yet: push to the DEEPEST known enemy building (drives the force
            # into the base to scout the production core), not the centroid (which stops it short).
            home0 = ctx.world.centroid([u for u in my_buildings(ctx)
                                        if not (u.get("template") or "").startswith("CWCciv")])
            deep = intel.deepest_building(home0[0], home0[1]) if (intel and home0) else None
            axis = intel.threat_axis() if intel else None
            if deep:
                tx, ty, src = deep["x"], deep["y"], "DRIVE " + deep["template"].replace("CWCus", "").replace("CWCru", "")
            elif guess and guess.get("source") == "scouted":
                tx, ty, src = guess["x"], guess["y"], "scouted"
            elif axis:
                tx, ty, src = axis[0], axis[1], "enemy-sightings"
            else:
                core = [u for u in my_buildings(ctx) if not (u.get("template") or "").startswith("CWCciv")]
                home = ctx.world.centroid(core) or ctx.world.centroid(my_units(ctx))
                W = (ctx.world.width or 0) * (ctx.world.cell or 0)
                H = (ctx.world.height or 0) * (ctx.world.cell or 0)
                tx, ty = (round(W - home[0]), round(H - home[1])) if (home and W and H) else (guess["x"], guess["y"])
                src = "geometric"
        # ISSUE THE ORDER. Critical base-crack fix: when we have a locked enemy building, ATTACK_TARGET
        # its id — units path into weapon range and actually SHOOT the structure. The old attack_move to
        # the building's COORDINATE made the force idle ~150-200u away at the perimeter, never engaging
        # (verified: 81 units within 200u of an AirField, 0 within attack range, building at FULL hp the
        # whole time). attack_move is kept only for the scout/geometric fallback (no known building id).
        if locked is not None:
            ctx.client.command(ctx.player, force, "attack_target", {"targetId": locked})
        else:
            ctx.client.command(ctx.player, force, "attack_move", {"pos": {"x": tx, "y": ty, "z": 0.0}})
        self.strike.detail = "{} @{:.0f},{:.0f} w/{}".format(src, tx, ty, len(force))

    def _expand(self, ctx):
        """Build extra economy/production/defense with surplus cash so the bot scales like the AI
        (which reaches ~12 buildings). Throttled; uses a free dozer; placement validated game-side."""
        if ((ctx.me.get("money") or 0) - self._tank_reserve - self._siege_reserve) < self.EXPAND_FLOOR:
            return                                  # keep the reserved tank/siege cash unspent
        if ctx.frame - self._last_expand < self.EXPAND_PERIOD:
            return
        # Exclude dozers that build.tick ALREADY assigned to a sub-build THIS TICK: ctx.world is a single
        # snapshot, so a dozer build.tick just tasked still reads `busy:false` here — without this, expand
        # picks the SAME dozer and its build_structure cancels build.tick's construct order, abandoning
        # that structure at 0% (the verified "stuck at 0%, no dozer building it" stall).
        build_claimed = {s["sub"].params.get("_dozer") for s in getattr(self.build, "_subs", [])}
        dozers = [d for d in find_dozers(ctx) if d["id"] not in build_claimed]
        if not dozers:
            return
        # Don't place buildings faster than dozers can raise them — else foundations pile up at 1hp,
        # tying up nothing and wasting the cash already spent. Wait until current builds finish.
        # WIP = buildings ACTUALLY under construction. Do NOT count merely-damaged buildings (hp<max):
        # the base is usually under attack, so counting damage made wip>=2 permanently → expansion was
        # blocked forever → factories stuck at 2 and the dominant economy never scaled.
        wip = [u for u in my_buildings(ctx) if u.get("constructing")]
        if len(wip) >= 3:
            return
        # Place around our CORE base (CC/barracks/warfactory/fuel), NOT the scattered captured CWCciv
        # econ points — counting those drags the centroid to mid-map, so every spot came back "illegal
        # build location" and factories never got built (cash sat idle). This is the real placement fix.
        core = [u for u in my_buildings(ctx) if not (u.get("template") or "").startswith("CWCciv")]
        base = ctx.world.centroid(core) or ctx.world.centroid(my_units(ctx))
        if not base:
            return
        # BALANCED expansion: build the most-needed role (smallest count relative to its early weight),
        # so defenses (forts) come up DURING the economy phase, not only after 11 buildings. Weight =
        # how many of each we want early; we build whichever is furthest below its weight, then its cap.
        weight = {"power": 1, "warfactory": 4, "barracks": 4, "defense": 2}
        ranked = []
        for i, role in enumerate(self.EXPAND_ORDER):
            cnt = self._count_role(ctx, role)
            if cnt >= self.EXPAND_CAPS.get(role, 0):
                continue
            deficit = weight.get(role, 1) - cnt   # >0 = below desired early count → highest priority
            ranked.append((-deficit, cnt, i, role))   # most-deficient, then fewest, then order
        ranked.sort()
        for _d, _c, _i, role in ranked:
            tmpl = find_buildable_by_role(ctx, role)
            if not tmpl:
                continue
            spot = find_build_spot(ctx, base[0], base[1], attempt=self._expand_attempt,
                                   max_radius=1300.0, step=70.0, clearance=160.0)
            self._expand_attempt += 1
            if spot is None:
                return                       # no clear spot — skip rather than stack on the base
            sx, sy = spot
            res = ctx.client.command(ctx.player, [dozers[0]["id"]], "build_structure",
                                     {"template": tmpl, "pos": {"x": sx, "y": sy}})
            if res and res.get("accepted"):
                self._last_expand = ctx.frame
            return


# ------------------------------------------------------------------------------
# Standalone runner
# ------------------------------------------------------------------------------
def _heartbeat(ctx, cmdr, world):
    me = ctx.me
    army = len(select_combat_units(ctx))
    blds = len(my_buildings(ctx))
    enemy_blds = len([u for u in world.enemies() if is_building(u)])
    captured = len([u for u in ctx.world.units if u.get("player") == ctx.player
                    and (u.get("template") or "").startswith("CWCciv")])
    a = cmdr.last_detail
    print("[cmdr f{}] ${} units={} bldgs={} army={} oilCaptured={} | enemyBldgsSeen={} | "
          "TANK[{}] | army:{} | build:{} cap:{} def:{} atk:{}".format(
              ctx.frame, me.get("money"), len(my_units(ctx)), blds, army, captured, enemy_blds,
              a.get("tank", ""), a.get("army", ""), a.get("build", ""), a.get("capture", ""),
              a.get("defend", ""), a.get("attack", "")),
          flush=True)


def run_commander(client, view="self", fast_hz=1.5, directive_path=DIRECTIVE_PATH,
                  heartbeat_s=10.0, verbose=True):
    from agent.journal import EventJournal
    from genapi.threats import ThreatTracker

    print("== commander (algorithmic CWC bot, no LLM required) on {} ==".format(client.base), flush=True)
    cmdr = None
    threats = journal = None
    owner = None
    map_cache = None
    catalog_loaded = False
    was_in_game = False
    last_hb = 0.0

    while True:
        if not client.in_game():
            if was_in_game:
                sess = client.session() or {}
                print("== MATCH ENDED == outcome={}".format(sess.get("outcome")), flush=True)
                uistate.atomic_write(uistate.STATE_PATH,
                                     {"inGame": False, "outcome": sess.get("outcome")})
            was_in_game = False
            map_cache = None
            catalog_loaded = False
            cmdr = None
            time.sleep(1.5)
            continue

        try:
            me = client.external_player()
            if not me:
                time.sleep(1.0)
                continue
            if cmdr is None:
                owner = me["index"]
                cmdr = Commander(owner, directive_path)
                threats = ThreatTracker(client, owner)
                journal = EventJournal(client, owner)
                threats.start()
                journal.start()
                was_in_game = True
                print("[cmdr] match start: external player idx={} side={}".format(
                    owner, me.get("side")), flush=True)
                # FASTER TESTS: bump the sim logic-fps (env GEN_SIM_SPEED, e.g. 50) so matches finish
                # quicker in wall-clock. Frame-based commander cadence scales with it; default = unchanged.
                import os as _os
                _spd = _os.getenv("GEN_SIM_SPEED")
                if _spd:
                    try:
                        client.speed(int(_spd))
                        print("[cmdr] sim speed set to {} logic-fps".format(int(_spd)), flush=True)
                    except Exception:  # noqa: BLE001
                        pass

            v = me["index"] if view == "self" else view
            if map_cache is None:
                map_cache = client.map(ds=1)
            world = WorldModel(map_cache, client.units(view=v), client.players(), owner=owner)
            if cmdr.sectors is None:
                try:
                    cmdr.sectors = SectorModel(world, grid=4)
                except Exception:  # noqa: BLE001
                    cmdr.sectors = None
            frame = (client.healthz() or {}).get("frame", 0)
            ctx = SkillContext(world, me, client, threats=threats, journal=journal, frame=frame,
                               taskmgr=None)

            if not catalog_loaded:
                cat = client.catalog() or []
                if cat:
                    cap = capture_capable_templates(cat)
                    set_capture_templates(cap)
                    cmdr.kb.merge_catalog(cat)          # authoritative canCapture
                    uistate.atomic_write(uistate.STATIC_PATH,
                                         uistate.build_static(cmdr.kb))
                    # FAIR TECH (no free grants — the engine owns all gating): the bot PURCHASES general's
                    # sciences with the rank/skill points it EARNS in combat, exactly like the skirmish AI
                    # (Player::attemptToPurchaseScience). Build a prioritized wishlist ONCE; the loop calls
                    # purchase_science periodically and the engine buys whatever is affordable + prereq-met
                    # now, leaving the rest pending until the bot ranks up. Order: RANK tiers first (climb
                    # the rank tree to unlock capacity), then unit-prereq tech (tanks!), then powers.
                    sl = (me.get("side") or "").lower()
                    pfx = "SCIENCE_CWCru" if sl.startswith("rus") else \
                          ("SCIENCE_CWCus" if (sl.startswith("us") or "america" in sl) else None)
                    unit_pre = sorted({s for pre in cmdr.kb.tech.get("objects", {}).values()
                                       for s in (pre.get("science") or [])})
                    side_sci = [s for s in cmdr.kb.tech.get("sciences", {}) if pfx and s.startswith(pfx)]
                    ranks = sorted(s for s in side_sci if "Rank" in s)
                    others = sorted(s for s in side_sci if "Rank" not in s and s not in unit_pre)
                    seen, wishlist = set(), []
                    for s in ranks + unit_pre + others:
                        if s not in seen:
                            seen.add(s); wishlist.append(s)
                    cmdr._sci_wishlist = wishlist
                    print("[cmdr] science wishlist: {} items (PURCHASED with earned rank points, not granted)"
                          .format(len(wishlist)), flush=True)
                    catalog_loaded = True
                    print("[cmdr] catalog: {} entries, canCapture={}; kb units={} eff={}".format(
                        len(cat), sorted(cap)[:8], len(cmdr.kb.units),
                        len(cmdr.kb.effectiveness)), flush=True)

            cmdr.step(ctx)

            # FAIR TECH: periodically try to BUY pending sciences with the rank points earned in combat.
            # The engine purchases only what's affordable + prereq-met now (attemptToPurchaseScience); the
            # rest stay queued until the bot ranks up — no free grants.
            wl = getattr(cmdr, "_sci_wishlist", None)
            if wl and frame - getattr(cmdr, "_last_sci", -10 ** 9) > 150:
                cmdr._last_sci = frame
                res = client.command(owner, [], "purchase_science", {"sciences": wl}) or {}
                bought = set(res.get("purchased") or [])
                if bought:
                    cmdr._sci_wishlist = [s for s in wl if s not in bought]
                    print("[cmdr] bought {} sciences (rank {}, {} pts left): {}".format(
                        len(bought), res.get("rankLevel"), res.get("sciencePurchasePoints"),
                        sorted(b.replace("SCIENCE_", "") for b in bought)), flush=True)

            # publish live state for the viewer (the commander never did this before)
            try:
                uistate.atomic_write(uistate.STATE_PATH,
                                     uistate.build_state(ctx, cmdr, world))
            except Exception:  # noqa: BLE001 — UI publish must never break the bot
                pass

            now = time.time()
            if verbose and now - last_hb >= heartbeat_s:
                _heartbeat(ctx, cmdr, world)
                last_hb = now
        except Exception as e:  # noqa: BLE001 — a transient API blip must not kill the bot
            if verbose:
                print("[cmdr] tick error: {}".format(e), flush=True)

        time.sleep(1.0 / fast_hz if fast_hz else 0.75)
