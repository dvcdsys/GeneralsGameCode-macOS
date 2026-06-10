"""macro.py — the Strategist's economy / construction / production brain.

A clean, priority-ordered spend layer that fixes the baseline commander's death spiral
(bankrupt -> no army -> dozers die -> unrecoverable). Each tick, in this order:

  1. POWER emergency (build power if the margin goes negative).
  2. DOZER FLOOR — never drop below a safe dozer count; if we have none and one is
     trainable, train it FIRST (the baseline lost every dozer and could never rebuild).
  3. BASE PLAN — drive the proven BuildBaseSkill to raise the core buildings in order
     (barracks -> war factory -> defence -> tech), faction-resolved from /buildable.
  4. ECONOMY — pump cheap capturers and STICKY-capture the safest nearby income points
     (flags). Income is capture-driven, so this funds everything; do it early and keep a
     cash floor so we never bankrupt.
  5. STANDING ARMY — counter-composed combat units to a dynamic target, built at every
     idle factory. A defensive floor is ALWAYS funded (the baseline fielded 2 units).
  6. EXPANSION — extra production/economy/defence structures once income supports it.
  7. SUPPORT — medics / engineers / AA to round out the formation.

Construction uses the proven primitives (BuildBaseSkill / BuildStructureSkill: native
dozer construction, parallel builds, legal-spot placement). Composition uses the curated
playbook + the live combat_eval counter matrix over the SCOUTED enemy. Gating is always
read from /buildable (canMake), never assumed.
"""
import math

from agent.skills.base import (
    my_units, my_buildings, select_combat_units, is_combat_unit, is_building,
    find_trainable, find_trainable_combat, find_buildable_by_role, find_dozers,
    find_all_dozers, find_trainable_dozer, buildable_now, capture_capable_units,
    capturable_points, find_build_spot, power_margin, have_role, _ROLE_HINTS,
    my_flag_count,
)
from agent.skills.library import BuildBaseSkill, BuildStructureSkill
from agent.cwc import combat_eval


def faction_prefix(my_buildings_list):
    """CWCus / CWCru / ... from my own structures (most common CWC prefix)."""
    counts = {}
    for u in my_buildings_list:
        t = u.get("template") or ""
        if t.startswith("CWC") and len(t) >= 5:
            p = t[:5]
            counts[p] = counts.get(p, 0) + 1
    return max(counts, key=counts.get) if counts else None


# my-unit role -> composition NEED bucket. NB: 'core' is ONLY real tanks (mbt) — never let
# officers/engineers/medics/unknowns fall into 'core' or they make the core (armour) need look
# satisfied and the bot never builds tanks.
def _need_of(role):
    if role in ("aa_inf", "aa_veh", "aa"):
        return "anti_air"
    if role in ("at_inf", "light_at", "atgm"):
        return "anti_armor"
    if role in ("arty", "artillery"):
        return "siege"
    if role in ("heli", "jet"):
        return "air"
    if role in ("mbt", "tank"):
        return "core"
    return "anti_inf"        # rifle/mg/sniper/ifv/recon/officer/engineer/medic/unknown -> light infantry


class Macro:
    # --- tunables (a StrategyDirective may override via Strategist) ---
    DOZER_FLOOR = 2          # keep at least this many dozers alive when affordable (protect the rebuild ability)
    DOZER_CAP = 3
    CASH_FLOOR = 250         # BASE cash buffer; the live floor is adaptive (self.cash_floor) — lowered by
                             # each captured point so a strong economy doesn't sit on idle cash
    ARMY_FLOOR = 8           # always fund at least this many combat units (defense) before luxuries
    ARMY_CAP = 72            # SAFETY ceiling only (runaway/perf guard). The real limiter is the
                             # DOMINANCE THROTTLE in Strategist._army_target: the bot stops growing the
                             # army once it recognises it's winning. A StrategyDirective army.target
                             # sets a hard cap instead (e.g. for a smooth watchable 3D game).
    CAPTURER_TARGET = 7      # cheap capturers committed to income — WIN THE FLAG RACE early (flags are
                             # the only income, so out-flagging the AI = earlier tanks/air + starves it).
                             # _ensure_capturers bumps this +3 early and trains several in PARALLEL.
    CAP_MAX_OUT = 9
    CAP_TRAIN_PERIOD = 20    # tighter so the per-tick gate never dominates the flag race
    CAP_REISSUE = 700        # capture power channels itself; only re-issue if long-stale (it failed)
    EXPAND_PERIOD = 90       # early production capacity is the multiplier on a flag economy
    EXPAND_FLOOR = 850       # expand on a modest surplus (a faster/cheating AI out-builds a cautious bot)
    SUPPORT_PERIOD = 110
    PROD_PERIOD = 6          # frames between army-production sweeps — keep idle factories filled

    # base build order (resolved per-faction from /buildable; unbuildable roles are skipped).
    # POWER (fuel depot) comes BEFORE the war factory: in CWC the war factory is prereq-gated behind
    # the fuel depot, so building power first unlocks vehicles instead of wasting a dozer on the
    # late/expensive airfield. economy income is CAPTURE, so keep the core lean and scale via EXPANSION.
    BASE_ROLES = ["barracks", "power", "warfactory", "defense", "airfield"]
    # airfield role matches BOTH airfield + helipad (so expansion can raise one of each -> jets AND helis)
    EXPAND_CAPS = {"barracks": 3, "warfactory": 4, "power": 2, "defense": 6, "airfield": 2}
    EXPAND_WEIGHT = {"warfactory": 4, "barracks": 3, "defense": 2, "power": 1, "airfield": 1}

    def __init__(self, owner, kb, playbook, personality=None):
        self.owner = owner
        self.kb = kb
        self.pb = playbook
        self.pers = personality
        self.prefix = None
        self.cash_floor = self.CASH_FLOOR    # adaptive each tick; safe default before the first tick
        self._captured = 0
        self._flags = 0
        # PERSONALITY: per-match opening profile + economy appetite (the per-match RNG draw —
        # without it the build order/capturer count were identical every game and human-readable)
        self._roles_ground = list(self.BASE_ROLES)
        self._roles_air = ["barracks", "power", "airfield", "warfactory", "defense"]
        if personality:
            self.CAPTURER_TARGET = max(4, self.CAPTURER_TARGET + personality.capturer_bias)
            self.CAP_MAX_OUT = max(self.CAPTURER_TARGET, self.CAP_MAX_OUT + personality.capturer_bias)
            self.EXPAND_FLOOR = personality.expand_floor
            if personality.opening == "fast_air":
                self._roles_ground = list(self._roles_air)
            elif personality.opening == "eco_greed":
                self.CAPTURER_TARGET += 2
                self.CAP_MAX_OUT += 2
                self.EXPAND_FLOOR = max(600, self.EXPAND_FLOOR - 150)
            elif personality.opening == "pressure":
                self._roles_ground = ["barracks", "power", "warfactory", "airfield", "defense"]
        self.build = BuildBaseSkill({})
        self.build.DEFAULT_ROLES = list(self._roles_ground)
        self._cap_assign = {}     # capturer id -> point id (sticky)
        self._cap_cmd = {}        # capturer id -> (point id, frame)
        self._cap_danger = {}     # point id -> decaying death count (capturers killed going there)
        self._last_cap_train = -10 ** 9
        self._last_prod = -10 ** 9
        self._last_support = -10 ** 9
        self._last_expand = -10 ** 9
        self._expand_attempt = 0
        self._prod_k = 0
        self.detail = {}

    # ----------------------------------------------------------------- main ---
    def tick(self, ctx, im, intel, army_target=None, want_siege=False):
        if self.prefix is None:
            self.prefix = faction_prefix(my_buildings(ctx))
        # strategic context (map size / time / enemy tier) — computed once, shared by all sub-systems
        self._sc = self._strategic_context(ctx, intel)
        captured = len([u for u in ctx.world.units if u.get("player") == ctx.player
                        and (u.get("template") or "").startswith("CWCciv")])
        self._captured = captured
        self._flags = my_flag_count(ctx)
        # ADAPTIVE cash floor: a strong economy needs less idle buffer; each captured FLAG (the only
        # income) frees cash. Recomputed from the BASE constant — the old `self.cash_floor - ...`
        # compounded every tick and collapsed the buffer to the 120 minimum within seconds.
        self.cash_floor = max(120, self.CASH_FLOOR - self._flags * 12)
        # MAP-SIZE build order: on big maps bring the airfield/helipad forward (early air = reach the
        # spread-out flags + harass), on small maps keep the personality's ground order.
        if self._sc["map"] == "large":
            self.build.DEFAULT_ROLES = list(self._roles_air)
        else:
            self.build.DEFAULT_ROLES = list(self._roles_ground)
        money = ctx.me.get("money") or 0
        d = {}

        # 1) DOZER FLOOR + base construction. Size the dozer demand from the work plan, but never let
        #    the live count fall below DOZER_FLOOR while affordable — losing all dozers is fatal.
        self._plan_dozers(ctx)
        self.build.tick(ctx)
        d["build"] = self.build.status_line()

        # 2) ECONOMY — cheap capturers + sticky capture of the safest nearby income points.
        self._ensure_capturers(ctx, money)
        self._capture(ctx, im)
        d["cap"] = self._cap_detail

        # 3) STANDING ARMY — counter-composed, funded above a defensive floor.
        tgt = army_target if army_target is not None else self.ARMY_FLOOR
        tgt = max(self.ARMY_FLOOR, min(self.ARMY_CAP, tgt))
        d["army"] = self._produce_army(ctx, im, intel, tgt, money, want_siege)

        # 4) EXPANSION — scale production/defence with surplus cash.
        self._expand(ctx, im)

        # 5) SUPPORT — medics/engineers/AA to round out the formation.
        self._produce_support(ctx, money)

        self.detail = d
        return d

    # ------------------------------------------------------------- dozers -----
    def _plan_dozers(self, ctx):
        spawned = len(find_all_dozers(ctx))
        inflight = int(getattr(self.build, "_dz_inflight", 0))
        live = spawned + inflight
        # demand = base-plan jobs waiting; clamp to [FLOOR, CAP]. The FLOOR guarantees we keep the
        # ability to (re)build even after losses.
        pending = self.build._jobs_pending_count(ctx) if hasattr(self.build, "_jobs_pending_count") else 0
        desired = max(self.DOZER_FLOOR if live < self.DOZER_FLOOR else 1,
                      min(self.DOZER_CAP, pending + 1))
        desired = max(desired, min(self.DOZER_FLOOR, self.DOZER_CAP))
        self.build.DOZER_TARGET = desired

    # ------------------------------------------------------------ economy -----
    def _map_bonus(self):
        return {"large": 3, "small": -1}.get((getattr(self, "_sc", {}) or {}).get("map"), 0)

    def _ensure_capturers(self, ctx, money):
        if ctx.frame - self._last_cap_train < self.CAP_TRAIN_PERIOD:
            return
        # WIN THE FLAG RACE: grab flags HARD early — the flag economy is everything. Bump the target
        # while young / income-less, and train SEVERAL capturers in PARALLEL across idle barracks.
        target = max(3, self.CAPTURER_TARGET + self._map_bonus())
        if ctx.frame < 3000 or self._captured == 0:
            target += 3
        have = len(capture_capable_units(ctx))
        if have >= target:
            return
        from agent.skills import base as _b
        cap_set = {c.lower() for c in (_b.CAPTURE_TEMPLATES or set())}
        if not cap_set and self.kb:
            cap_set = {c.lower() for c in self.kb.capturers()}
        cands = find_trainable(ctx, lambda tl, e: e.get("how") == "train" and tl in cap_set)
        if not cands:
            return
        cands.sort(key=lambda x: x[2])                       # cheapest capturer first
        base = ctx.world.centroid(my_buildings(ctx))
        # relaxed floor while we have NO income yet (bootstrap the economy past the cash gate ONCE)
        floor = 100 if have == 0 else self.cash_floor
        budget = money
        used = set()
        trained = 0
        for tmpl, builder, cost, _e in cands:
            if have + trained >= target:
                break
            if not builder or builder in used or budget < cost + floor:
                continue
            ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
            if base:
                ctx.client.command(ctx.player, [builder], "set_rally", {"pos": {"x": base[0], "y": base[1]}})
            budget -= cost
            used.add(builder)
            trained += 1
            floor = self.cash_floor                          # only the FIRST is bootstrap-relaxed
        if trained:
            self._last_cap_train = ctx.frame

    def _capture(self, ctx, im):
        """STICKY capture of the SAFEST nearby income points (lowest enemy influence first), one
        capture-power issue per assignment (re-issuing restarts the channel). A capturer keeps its
        point until taken; dead capturers / taken points are dropped."""
        caps = {u["id"]: u for u in capture_capable_units(ctx)}
        pts = {u["id"]: u for u in capturable_points(ctx)}
        # DEATH MEMORY: a capturer that vanished while its point is still open almost certainly died
        # on the way (a camper / defended flag). Remember per-point danger so the bot stops feeding a
        # single-file conveyor of capturers into the same ambush (decays, so it retries eventually).
        for uid, pid in self._cap_assign.items():
            if uid not in caps and pid in pts:
                self._cap_danger[pid] = self._cap_danger.get(pid, 0.0) + 1.0
        self._cap_danger = {pid: v * 0.9985 for pid, v in self._cap_danger.items() if v > 0.2}
        self._cap_assign = {uid: pid for uid, pid in self._cap_assign.items()
                            if uid in caps and pid in pts}
        if not caps or not pts:
            self._cap_detail = "no capturers" if not caps else "no points"
            self._capture_force = list(self._cap_assign)
            return
        base = ctx.world.centroid(my_buildings(ctx)) or (0, 0)
        taken = set(self._cap_assign.values())
        free = [u for uid, u in caps.items() if uid not in self._cap_assign]
        # FLAGS are the ONLY income in CWC (oil/fuel points give NO money — same tags, so distinguish
        # by template). Prioritise flags hard, then safe+near oil for secondary map control / AI denial.
        # Per-point danger pushes repeated-ambush points down WITHIN the flag tier; personality noise
        # de-scripts the capture order across matches (assignments stay sticky within one).
        def pt_cost(p):
            cost = im.threat_at(p["x"], p["y"]) * 600.0 + math.hypot(p["x"] - base[0], p["y"] - base[1])
            cost += self._cap_danger.get(p["id"], 0.0) * 1200.0
            if self.pers:
                cost += self.pers.rng.uniform(0.0, 280.0)
            if "flag" in (p.get("template") or "").lower():
                cost -= 1_000_000.0          # flags first, always (income)
            return cost
        open_pts = sorted((p for pid, p in pts.items() if pid not in taken), key=pt_cost)
        max_out = max(4, self.CAP_MAX_OUT + self._map_bonus())
        for p in open_pts:
            if len(self._cap_assign) >= max_out or not free:
                break
            if self._cap_danger.get(p["id"], 0.0) >= 4.0 and len(open_pts) > 1:
                continue                     # proven death trap — back off until the danger decays
            c = min(free, key=lambda u: math.hypot(u.get("x", 0) - p["x"], u.get("y", 0) - p["y"]))
            free.remove(c)
            self._cap_assign[c["id"]] = p["id"]
        for uid, pid in self._cap_assign.items():
            last_pid, last_f = self._cap_cmd.get(uid, (None, -10 ** 9))
            if last_pid != pid or ctx.frame - last_f >= self.CAP_REISSUE:
                ctx.client.command(ctx.player, [uid], "capture", {"targetId": pid})
                self._cap_cmd[uid] = (pid, ctx.frame)
        self._capture_force = list(self._cap_assign)
        self._cap_detail = "capturing {} pts".format(len(self._cap_assign))

    def capture_force(self):
        return set(getattr(self, "_capture_force", []) or [])

    # -------------------------------------------------------- adaptation -------
    def _strategic_context(self, ctx, intel):
        """Read the situation the bot must adapt to BEYOND money: map size (territory logistics),
        elapsed time (the AI ranks up -> expect stronger units), and the enemy's scouted tier
        (air or high-tier units = an already-promoted opponent)."""
        w = ctx.world
        Wm = (w.width or 0) * (w.cell or 10)
        Hm = (w.height or 0) * (w.cell or 10)
        diag = math.hypot(Wm, Hm) or 1.0
        map_class = "large" if diag > 5200 else ("small" if diag < 3200 else "medium")
        time_tier = ctx.frame / 6000.0                 # ~1 enemy rank tier per ~6000 frames (heuristic)
        prof = intel.enemy_profile() if intel else {}
        cls = {"air": 0, "armor": 0, "infantry": 0, "arty": 0}
        scouted_tier, has_air, tot = 0, False, 0
        for t, c in prof.items():
            k = self.pb.threat_class(t, self.kb) if self.pb else "other"
            if k in cls:
                cls[k] += c
            if k == "air":
                has_air = True
            tot += c
            if self.pb:
                scouted_tier = max(scouted_tier, self.pb.tier_of(t))
        # enemy rank inferred indirectly: elapsed time, scouted unit tiers, and air-in-play (a high-rank sign)
        enemy_tier = max(time_tier, float(scouted_tier), 2.0 if has_air else 0.0)
        frac = {k: (cls[k] / tot if tot else 0.0) for k in cls}
        return {"map": map_class, "diag": diag, "enemy_tier": enemy_tier,
                "frac": frac, "has_air": has_air, "scouted": tot > 0}

    def desired_comp(self, ctx, intel):
        """Target composition fractions, ADAPTED to the strategic context — not just money:
          • PRECISE COUNTERS vs the scouted enemy: armor -> ATGM + CAS air; infantry -> snipers + siege;
            aircraft -> AA (+ interceptors).
          • TIME / ENEMY RANK: the longer the game (or the higher the scouted tier), the more AA + air
            we keep, anticipating the AI's promoted, air-capable units.
          • MAP SIZE: big maps reward air mobility (reach distant flags, harass, redeploy); small maps
            are ground brawls where air is wasted.
        """
        sc = getattr(self, "_sc", None) or self._strategic_context(ctx, intel)
        f = sc["frac"]
        frac = {"core": 0.32, "anti_armor": 0.20, "anti_inf": 0.24, "anti_air": 0.12,
                "air": 0.07, "siege": 0.05}
        if sc["scouted"]:
            if f["air"] > 0.04:                              # enemy aircraft -> hard AA. A heli rush must
                # be answerable up to nearly half the army (the old 0.32 ceiling lost a base to it).
                frac["anti_air"] = max(frac["anti_air"], min(0.45, 0.10 + f["air"] * 1.2))
            if f["armor"] > 0.25:                            # enemy armour -> ATGM AND CAS air (air kills tanks)
                frac["anti_armor"] = max(frac["anti_armor"], min(0.40, f["armor"] * 0.55))
                frac["air"] = max(frac["air"], 0.10)
            if f["infantry"] > 0.40:                         # enemy infantry -> snipers + a touch of siege
                frac["anti_inf"] = max(frac["anti_inf"], min(0.38, f["infantry"] * 0.5))
                frac["siege"] = max(frac["siege"], 0.06)
        if sc["enemy_tier"] >= 2.0:                          # promoted / air-capable opponent expected
            frac["anti_air"] = max(frac["anti_air"], 0.16)
            frac["air"] = max(frac["air"], 0.09)
        if sc["map"] == "large":                             # mobility matters on big maps -> more air
            frac["air"] = max(frac["air"], 0.11)
        elif sc["map"] == "small":
            frac["air"] = min(frac["air"], 0.04)
        s = sum(frac.values()) or 1.0
        out = {k: v / s for k, v in frac.items()}
        # HARD AA FLOOR (user doctrine: "завжди будувати ПВО"): never let the post-normalisation
        # share fall below this, so the bot ALWAYS fields air-defence — it must stock AA before the
        # enemy's helis arrive (posts + march + a home reserve all draw from this), not react late.
        if out.get("anti_air", 0) < 0.18:
            out["anti_air"] = 0.18                      # real AA demand -> pulls war-factory slots for
            s2 = sum(out.values())                      # vehicle AA, not just cheap barracks InfAntiAir
            out = {k: v / s2 for k, v in out.items()}
        self._want_air = out.get("air", 0) >= 0.06     # expansion bumps the airfield when true
        return out

    def _unit_need(self, template):
        role = (self.pb.role_of(template) if self.pb else None) or (self.kb.fine_role(template) if self.kb else "")
        return _need_of(role)

    def _produce_army(self, ctx, im, intel, target, money, want_siege):
        # the FIGHTING army excludes capturers (they're economy units out grabbing flags; counting
        # them filled the army cap with officers and starved real combat production) AND cripples
        # (units under the retreat threshold never rejoin a fight — counting them made production
        # report "army full" while the effective force rotted away to chip damage)
        cap_force = self.capture_force()
        army = [u for u in select_combat_units(ctx)
                if u["id"] not in cap_force
                and not (u.get("maxHealth") and u.get("health") is not None
                         and u["health"] < u["maxHealth"] * 0.45)]
        n = len(army)
        if n >= target:
            return "army {}/{} full".format(n, target)
        if ctx.frame - self._last_prod < self.PROD_PERIOD:
            return "army {}/{} (cooldown)".format(n, target)
        # ONE /buildable snapshot per tick: each idle factory + the combat units it can train now.
        bd = buildable_now(ctx)
        builders = []
        for b in (bd.get("builders") or []):
            opts = [(o.get("template"), o.get("cost", 0) or 0)
                    for o in (b.get("options") or [])
                    if o.get("how") == "train" and o.get("canMake") == "ok" and o.get("template")
                    and is_combat_unit({"category": "unit", "template": o.get("template")})]
            if opts:
                builders.append((b.get("id"), opts))
        if not builders:
            return "army {}/{} (no factory)".format(n, target)

        # current composition counts
        have = {"core": 0, "anti_armor": 0, "anti_inf": 0, "anti_air": 0, "air": 0, "siege": 0}
        for u in army:
            need = self._unit_need(u.get("template"))
            have[need] = have.get(need, 0) + 1
        comp = self.desired_comp(ctx, intel)
        if not want_siege:
            comp["siege"] = 0.0

        # TANK RESERVE: when armour (core) is under target and a tank exists (buildable, maybe not yet
        # affordable), hold back its cost so the cheap-infantry trickle can't consume all income — the
        # only way the bot accumulates enough to actually field tanks in a tight flag economy.
        # AIR RESERVE: same mechanism for aircraft — without it the $875-2400 heli/jet was NEVER
        # affordable by the time the spend loop reached it, so the bot simply had no air, ever.
        def _need_reserve(needk):
            if comp.get(needk, 0) <= 0 or have.get(needk, 0) >= comp[needk] * target:
                return 0
            costs = [o.get("cost", 0) or 0
                     for b in (bd.get("builders") or [])
                     for o in (b.get("options") or [])
                     if o.get("how") == "train" and o.get("canMake") in ("ok", "no_money")
                     and self._unit_need(o.get("template")) == needk]
            return min(costs) if costs else 0
        core_reserve = _need_reserve("core")
        air_reserve = _need_reserve("air")
        # how many of each template we already field — the novelty weight that keeps the roster
        # varied (user: "не будує ні брдм, ні шилки, ні гелікоптерів — тільки танки і піхота")
        own_tmpl = {}
        for u in army:
            t = u.get("template")
            if t:
                own_tmpl[t] = own_tmpl.get(t, 0) + 1

        made = 0
        used = set()
        picks = []
        budget = money
        have_run = {k: have.get(k, 0)
                    for k in ("core", "anti_armor", "anti_inf", "anti_air", "air", "siege")}
        rally = ctx.world.centroid(my_buildings(ctx))
        # VEHICLE-AA FLOOR (user doctrine: real AA must actually get built). Heavy AA (Shilka/SA-9/
        # SA-11) is a WAR-FACTORY unit and always lost the slot to tanks, while a couple of cheap
        # InfAntiAir "filled" the AA share — so the bot fielded ~3 InfAntiAir and zero vehicle AA.
        # This forces vehicle AA to a floor scaled by army size (more vs an air-capable enemy),
        # built FIRST at any builder that offers it, before the normal need race.
        veh_aa_have = sum(c for t, c in own_tmpl.items()
                          if self._unit_need(t) == "anti_air" and self._aa_archetype(t) != "manpads")
        sc_air = (getattr(self, "_sc", {}) or {}).get("has_air")
        veh_aa_floor = max(2 if any("warfact" in (b.get("template") or "").lower()
                                    for b in my_buildings(ctx)) else 0,
                           target // (5 if sc_air else 8))
        veh_aa_made = 0
        for builder, opts in builders:
            if n + made >= target:
                break
            # forced vehicle-AA build: cheapest Shilka/SA-9/SA-11 this builder offers, if under floor
            if veh_aa_have + veh_aa_made < veh_aa_floor:
                vcands = [(t, c) for (t, c) in opts
                          if self._unit_need(t) == "anti_air" and self._aa_archetype(t) != "manpads"
                          and c <= budget - self.cash_floor]
                if vcands:
                    tmpl, cost = min(vcands, key=lambda x: x[1])
                    ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
                    if rally:
                        ctx.client.command(ctx.player, [builder], "set_rally",
                                           {"pos": {"x": rally[0], "y": rally[1]}})
                    budget -= cost
                    made += 1
                    veh_aa_made += 1
                    used.add(builder)
                    picks.append((tmpl, "anti_air"))
                    have_run["anti_air"] += 1
                    own_tmpl[tmpl] = own_tmpl.get(tmpl, 0) + 1
                    continue
            # ONLY build needs still BELOW their target share. Never overbuild a satisfied need — that
            # was filling the whole army cap with early infantry (esp. AA), leaving no room or cash for
            # the CORE tanks that only unlock once the war factory is up. An unfillable need (core with
            # no war factory yet, or no affordable tank) simply leaves the factory idle and the cash to
            # accumulate, so the army paces itself and transitions to armour instead of mono-infantry.
            under = [k for k in have_run if comp.get(k, 0) > 0 and have_run[k] < comp[k] * target]
            if not under:
                break
            under.sort(key=lambda k: have_run[k] - comp[k] * target)   # most-deficient first
            chosen = chosen_need = None
            for need in under:
                # non-core builds may not dip into the tank/air reserves OR the cash floor (else a
                # barracks spends the surplus on infantry just before the war factory's turn and the
                # tank/aircraft can never clear cost+floor); core gets the full budget, air gets
                # everything above the floor+tank reserve.
                if need == "core":
                    b = budget
                elif need == "air":
                    b = max(0, budget - core_reserve - self.cash_floor)
                else:
                    b = max(0, budget - core_reserve - air_reserve - self.cash_floor)
                c = self._pick_for_need(need, opts, intel, b, own=own_tmpl)
                if c:
                    chosen, chosen_need = c, need
                    break
            if not chosen:
                continue                                # can't (afford to) make any under-target need here
            tmpl, cost = chosen
            # cash-floor post-check for NON-core only: a core (tank) pick is deliberately allowed to
            # spend through the floor (the reserve logic exists exactly to fund it) — gating it here
            # silently delayed every armour transition by a production window.
            if chosen_need != "core" and budget - cost < self.cash_floor:
                continue
            ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
            if rally:
                ctx.client.command(ctx.player, [builder], "set_rally", {"pos": {"x": rally[0], "y": rally[1]}})
            budget -= cost
            made += 1
            used.add(builder)
            picks.append((tmpl, chosen_need))
            have_run[chosen_need] += 1
            own_tmpl[tmpl] = own_tmpl.get(tmpl, 0) + 1  # novelty weighting sees this tick's picks too
            if chosen_need == "core":
                core_reserve = 0                        # got our tank this tick — release the reserve
            elif chosen_need == "air":
                air_reserve = 0
        if made:
            self._last_prod = ctx.frame
        self._prod_k += 1
        short = sorted({t[5:] if t.startswith("CWC") else t for t, _ in picks})
        return "army {}/{} (+{}@{}fac {})".format(n, target, made, len(used), ",".join(short[:4]) or "-")

    def _pick_for_need(self, need, opts, intel, budget, own=None):
        """Best (template,cost) among `opts` for composition `need`. Candidates are filtered to
        templates that ACTUALLY serve that need (same _unit_need classification used to COUNT my
        army — otherwise picking an off-role unit never satisfies the count and the bot mono-builds
        it forever). Within the need: a WEIGHTED pick by counter-value-per-cost × novelty — the old
        doctrine-first/cheapest-first always resolved to the same cheap barracks template, so the
        bot fielded ~8 of 28 templates and never built Shilka/BRDM/aircraft (user feedback)."""
        affordable = [(t, c) for (t, c) in opts if c <= budget]
        if not affordable:
            return None
        if need is not None:
            # UNARMED templates never satisfy a combat need (a weaponless CH47 'air' pick just flew
            # around); transports get their own plays later, not a slot in the fighting comp.
            cands = [(t, c) for (t, c) in affordable
                     if self._unit_need(t) == need
                     and (not self.kb or not self.kb.loaded or self.kb.is_armed(t))]
            if need == "core":
                # CHEAPEST tank first while poor (M60A3 $700 / T-72 $800) — armour on the field NOW
                # beats saving forever. But once the bank clears the personality's premium taste
                # (a multiple of the cheap tank), buy the BEST affordable tank instead: the army
                # gets its T-80U/M1A1 late-game arc rather than fielding bottom-tier MBTs forever.
                if not cands:
                    return None
                cands.sort(key=lambda x: x[1])
                taste = self.pers.premium_taste if self.pers else 2.5
                if len(cands) > 1 and budget >= cands[0][1] * taste:
                    return cands[-1]
                return cands[0]
            if need == "air":
                # pick the RIGHT kind of plane: interceptors (air-superiority) when the enemy flies,
                # CAS / ground-attack (kills tanks + infantry) otherwise — then variety of that kind.
                if not cands:
                    return None
                sc = getattr(self, "_sc", {}) or {}
                want_sup = sc.get("has_air") or sc.get("frac", {}).get("air", 0) > 0.18
                matched = [tc for tc in cands
                           if ((self.pb.air_kind_of(tc[0]) if self.pb else None) == "air_superiority")
                           == bool(want_sup)]
                return self._weighted_pick(matched or cands, intel, own)
            if need == "anti_air":
                # NO weighted fallback here: if the doctrine returns None (manpads capped and only
                # InfAntiAir is offered at this builder, e.g. a barracks), build NOTHING for AA so the
                # demand waits for a WAR FACTORY to make the real vehicle AA (Shilka/SA-9/SA-11) —
                # otherwise the fallback just spams the weak InfAntiAir the cap was meant to limit.
                return self._pick_anti_air(cands, own)
            return self._weighted_pick(cands, intel, own)   # None when nothing serves -> cascade
        # need is None -> counter matrix vs the scouted enemy, else strongest affordable
        if self.kb and self.kb.loaded:
            prof = (intel.enemy_profile() if intel else {}) or {}
            ranked = combat_eval.best_counters(self.kb, prof,
                                               [(t, None, c, None) for (t, c) in affordable])
            if ranked and ranked[0][1] > 0:
                tup = ranked[0][0]
                return (tup[0], tup[2])
        affordable.sort(key=lambda x: -x[1])
        return affordable[0]

    # AA archetype targets (share of the anti_air units we field). The user's doctrine: InfAntiAir is
    # weak -> a small CAP only; Shilka is the mass; SA-9 several; SA-11 the heavy zone-denial layer.
    _AA_TARGET = {"shilka": 0.42, "sa9": 0.30, "sa11": 0.18, "manpads": 0.10}
    _AA_MANPADS_CAP = 2        # one garrison pair of the weak InfAntiAir — the rest is vehicle AA

    def _aa_archetype(self, template):
        t = (template or "").lower()
        if "shilka" in t:
            return "shilka"
        if "sa11" in t or "sa-11" in t or "s300" in t:
            return "sa11"            # heavy long-range SAM layer
        if "sa9" in t or "sa-9" in t or "sa6" in t:
            return "sa9"
        roles = self.kb.roles_of(template) if self.kb else set()
        if "infantry" in roles:
            return "manpads"
        return "sa9"                 # any other mobile SAM behaves like the SA-9 layer

    def _pick_anti_air(self, cands, own):
        """Doctrine quota over AA archetypes: build the archetype most BELOW its target share that
        has an affordable candidate, hard-capping the weak InfAntiAir. Returns (template,cost) or
        None (nothing in-doctrine affordable -> caller falls back to the generic weighted pick)."""
        if not cands:
            return None
        by_arch = {}
        for t, c in cands:
            by_arch.setdefault(self._aa_archetype(t), []).append((t, c))
        have = {"shilka": 0, "sa9": 0, "sa11": 0, "manpads": 0}
        total = 0
        for tmpl, cnt in (own or {}).items():
            if self._unit_need(tmpl) == "anti_air":
                have[self._aa_archetype(tmpl)] = have.get(self._aa_archetype(tmpl), 0) + cnt
                total += cnt
        # deficit vs target share; manpads disabled once at the cap
        best, best_def = None, None
        for arch, tgt in self._AA_TARGET.items():
            if arch not in by_arch:
                continue
            if arch == "manpads" and have["manpads"] >= self._AA_MANPADS_CAP:
                continue
            deficit = tgt - (have.get(arch, 0) / total if total else 0.0)
            if best is None or deficit > best_def:
                best, best_def = arch, deficit
        if best is None:
            return None
        # cheapest within the chosen archetype (mass it up; premium SA-11 still gets built via its share)
        return min(by_arch[best], key=lambda x: x[1])

    def _weighted_pick(self, cands, intel, own):
        """Personality-weighted pick over (template,cost) candidates serving one need:
        weight = counter-value-per-cost vs the scouted enemy × NOVELTY (templates we already
        mass get progressively less likely). Deterministic argmax killed roster variety; this
        keeps the army mixed (Shilka next to AA infantry, BRDM next to snipers) and different
        between matches. Falls back to the strongest candidate without a personality RNG."""
        if not cands:
            return None
        prof = (intel.enemy_profile() if intel else {}) or {}
        weights = []
        for t, c in cands:
            val = 1.0
            if self.kb and self.kb.loaded:
                val = max(0.25, combat_eval._candidate_value(self.kb, t, prof)) ** 0.5
            nov = 1.0 / (1.0 + (own.get(t, 0) if own else 0))   # strong: 5 owned -> 1/6 weight
            weights.append(val * nov)
        if self.pers:
            return self.pers.rng.choices(cands, weights=weights, k=1)[0]
        return max(zip(cands, weights), key=lambda p: p[1])[0]

    # ------------------------------------------------------------ expansion ---
    def _expand(self, ctx, im):
        money = ctx.me.get("money") or 0
        # EMERGENCY REBUILD: a razed core production building is RECOVERY, not expansion — the
        # floor/period gates must not apply, or the bot can never re-arm after losing its factories
        # (the live HARD loss: war factory razed, $40-760 on hand, expansion floor $850+ -> dead).
        emergency = [r for r in ("barracks", "warfactory")
                     if self._count_role(ctx, r) == 0 and find_buildable_by_role(ctx, r)]
        if not emergency:
            if money < self.EXPAND_FLOOR or ctx.frame - self._last_expand < self.EXPAND_PERIOD:
                return
        wip = [u for u in my_buildings(ctx) if u.get("constructing")]
        if len(wip) >= 3:
            return
        build_claimed = {s["sub"].params.get("_dozer") for s in getattr(self.build, "_subs", [])}
        dozers = [d for d in find_dozers(ctx) if d["id"] not in build_claimed]
        if not dozers:
            return
        core = [u for u in my_buildings(ctx) if not (u.get("template") or "").startswith("CWCciv")]
        base = ctx.world.centroid(core)
        if not base:
            return
        ranked = []
        for role in ("warfactory", "barracks", "power", "defense", "airfield"):
            cnt = self._count_role(ctx, role)
            if cnt >= self.EXPAND_CAPS.get(role, 0):
                continue
            if not find_buildable_by_role(ctx, role):
                continue
            deficit = self.EXPAND_WEIGHT.get(role, 1) - cnt
            # the composition WANTS aircraft but there's nowhere to build them -> the airfield is
            # no longer the lowest priority (the bot literally never had air without this)
            if role == "airfield" and cnt == 0 and getattr(self, "_want_air", False):
                deficit = max(deficit, 3)
            ranked.append((-deficit, cnt, role))
        ranked.sort()
        if emergency:                                   # razed production first, whatever the weights say
            ranked = [(-99, 0, r) for r in emergency] + [t for t in ranked if t[2] not in emergency]
        for _d, _c, role in ranked:
            tmpl = find_buildable_by_role(ctx, role)
            if not tmpl:
                continue
            # place on the SAFE side of the base (away from enemy pressure)
            spot = self._safe_build_spot(ctx, im, base)
            if spot is None:
                return
            res = ctx.client.command(ctx.player, [dozers[0]["id"]], "build_structure",
                                     {"template": tmpl, "pos": {"x": spot[0], "y": spot[1]}})
            if res and res.get("accepted"):
                self._last_expand = ctx.frame
            return

    def _safe_build_spot(self, ctx, im, base):
        spot = find_build_spot(ctx, base[0], base[1], attempt=self._expand_attempt,
                               max_radius=1300.0, step=70.0, clearance=160.0)
        self._expand_attempt += 1
        return spot

    def _count_role(self, ctx, role):
        hints = _ROLE_HINTS.get(role, ())
        return sum(1 for u in my_buildings(ctx)
                   if any(h in (u.get("template") or "").lower() for h in hints))

    # -------------------------------------------------------------- support ---
    def _produce_support(self, ctx, money):
        if ctx.frame - self._last_support < self.SUPPORT_PERIOD or not self.kb:
            return
        have = {"medic": 0, "engineer": 0, "aa": 0, "inf": 0, "tank": 0, "sniper": 0}
        for u in my_units(ctx):
            r = self.kb.fine_role(u.get("template"))
            if r in have:
                have[r] += 1
            elif r in ("mg_inf", "infantry"):
                have["inf"] += 1
        want = {"medic": max(1, have["inf"] // 6) + (1 if have["sniper"] >= 2 else 0),
                "engineer": have["tank"] // 3}
        deficits = sorted(((want[r] - have[r], r) for r in want if want[r] > have[r]), reverse=True)
        if not deficits:
            return
        role = deficits[0][1]
        names = {"medic": ("medic",), "engineer": ("engineer",)}[role]
        cands = [c for c in find_trainable(ctx, lambda tl, e: any(k in tl for k in names))
                 if self.kb.fine_role(c[0]) == role]
        if not cands:
            return
        cands.sort(key=lambda c: c[2])
        tmpl, builder, cost, _e = cands[0]
        if builder and money - cost >= self.cash_floor:
            ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
            self._last_support = ctx.frame
