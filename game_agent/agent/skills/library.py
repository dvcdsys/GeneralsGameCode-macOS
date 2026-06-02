"""Concrete skills — the starter library the LLM planner orchestrates.

Each class is exposed to the model as one function-calling tool (name + description + param_schema).
Add a new capability by writing a `Skill` subclass here and registering it in `registry.py`; it then
appears in the LLM tool list automatically — no planner/loop change. Keep `description` LLM-facing:
it is the only thing the model reads to decide when to use the tool.
"""

import math

from agent.skills.base import (
    Skill, PENDING, RUNNING, DONE, FAILED, BLOCKED,
    my_units, my_buildings, find_object, find_dozers, find_producer,
    select_combat_units, resolve_point, find_build_spot, obj_pos,
    is_combat_unit, find_trainable_combat, find_trainable_dozer, is_dozerish,
    capturable_points, power_margin, find_power_buildable,
    find_buildable_by_role, have_role,
    enemy_units_near, base_under_attack, alive_ids, force_claimed_by_siblings,
)

_POINT = {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
          "required": ["x", "y"]}


# ------------------------------------------------------------------------------
# Production / construction
# ------------------------------------------------------------------------------
class BuildStructureSkill(Skill):
    name = "build_structure"
    description = ("Construct a building. Provide the structure template name and roughly WHERE "
                   "(area={x,y}); a dozer is chosen and a legal nearby cell is found automatically. "
                   "Use for power plants, barracks, war factories, defenses, tech, etc.")
    param_schema = {
        "type": "object",
        "properties": {
            "structure": {"type": "string", "description": "template name, e.g. AmericaPowerPlant"},
            "area": dict(_POINT, description="approximate build location (world coords)"),
        },
        "required": ["structure"],
    }
    MAX_ATTEMPTS = 12

    def tick(self, ctx):
        self._begin(ctx)
        structure = self.params.get("structure")
        if not structure:
            self.status, self.detail = FAILED, "no structure given"
            return
        if self.status in (PENDING, BLOCKED):
            dozers = find_dozers(ctx)
            if not dozers:
                self.status, self.detail = BLOCKED, "no dozer available"
                return
            # avoid double-booking a dozer that a sibling build task already claimed
            claimed = set()
            if ctx.taskmgr:
                for t in ctx.taskmgr.active():
                    d = t["params"].get("_dozer")
                    if d is not None:
                        claimed.add(d)
            free = [d for d in dozers if d["id"] not in claimed] or dozers
            dozer = free[0]
            self.params["_dozer"] = dozer["id"]
            cx, cy = resolve_point(ctx, self.params)
            sx, sy = find_build_spot(ctx, cx, cy, attempt=self._attempts)
            res = ctx.client.command(ctx.player, [dozer["id"]], "build_structure",
                                     {"template": structure, "pos": {"x": sx, "y": sy}})
            if res and res.get("accepted"):
                self._oid = res.get("objectId")
                self._spot = (sx, sy)
                self.status, self.detail = RUNNING, "placing {} @ {:.0f},{:.0f}".format(structure, sx, sy)
            else:
                self._attempts += 1
                self.detail = "build rejected ({}/{})".format(self._attempts, self.MAX_ATTEMPTS)
                if self._attempts >= self.MAX_ATTEMPTS:
                    self.status = FAILED
            return
        if self.status == RUNNING:
            obj = find_object(ctx.world, getattr(self, "_oid", None))
            if obj is None:
                # not yet visible, or fell out of sight / destroyed before completing
                if self._elapsed(ctx) > 1200:
                    self.status, self.detail = FAILED, "structure never completed"
                return
            hp, mx = obj.get("health", 0), obj.get("maxHealth", 0) or 1
            if hp >= mx * 0.99:
                self.status, self.detail = DONE, "{} complete".format(structure)
            else:
                self.detail = "{} building {:.0f}%".format(structure, 100.0 * hp / mx)


class TrainUnitsSkill(Skill):
    name = "train_units"
    description = ("Queue production of mobile units at an appropriate factory (chosen automatically "
                   "from what can be built now). Give the unit template and a count.")
    param_schema = {
        "type": "object",
        "properties": {
            "unit": {"type": "string", "description": "unit template, e.g. AmericaInfantryRanger"},
            "count": {"type": "integer", "minimum": 1, "default": 1},
        },
        "required": ["unit"],
    }

    def tick(self, ctx):
        self._begin(ctx)
        unit = self.params.get("unit")
        count = int(self.params.get("count", 1) or 1)
        if not unit:
            self.status, self.detail = FAILED, "no unit given"
            return
        if self.status in (PENDING, BLOCKED):
            builder, _ = find_producer(ctx, unit)
            if not builder:
                self.status, self.detail = BLOCKED, "cannot train {} now".format(unit)
                return
            res = ctx.client.command(ctx.player, [builder], "train_unit",
                                     {"template": unit, "count": count})
            if res and res.get("accepted"):
                self._base_frame = ctx.frame
                self.status, self.detail = RUNNING, "queued {}x {}".format(count, unit)
            else:
                self.status, self.detail = FAILED, "train rejected"
            return
        if self.status == RUNNING:
            made = 0
            if ctx.journal:
                made = ctx.journal.count("unit_produced", template=unit, player=ctx.player,
                                         since=getattr(self, "_base_frame", 0))
            self.detail = "{} / {} produced".format(made, count)
            if made >= count:
                self.status = DONE
            elif self._elapsed(ctx) > 1800:
                self.status, self.detail = (DONE if made > 0 else FAILED), \
                    "timeout ({} / {})".format(made, count)


class AssembleGroupSkill(Skill):
    name = "assemble_group"
    description = ("Build a mixed force and gather it at a muster point. composition is a list of "
                   "{unit, count}. Sets factory rally points to the muster location and trains each "
                   "type; completes when the whole group has been produced.")
    param_schema = {
        "type": "object",
        "properties": {
            "composition": {
                "type": "array",
                "items": {"type": "object",
                          "properties": {"unit": {"type": "string"},
                                         "count": {"type": "integer", "minimum": 1}},
                          "required": ["unit", "count"]},
            },
            "rally": dict(_POINT, description="muster point for produced units"),
        },
        "required": ["composition"],
    }

    def tick(self, ctx):
        self._begin(ctx)
        comp = self.params.get("composition") or []
        if not comp:
            self.status, self.detail = FAILED, "empty composition"
            return
        if self.status in (PENDING, BLOCKED):
            self._subs = [TrainUnitsSkill({"unit": c.get("unit"), "count": c.get("count", 1)})
                          for c in comp if c.get("unit")]
            rally = resolve_point(ctx, {"pos": self.params.get("rally")}) if self.params.get("rally") else None
            if rally:
                for c in comp:
                    builder, _ = find_producer(ctx, c.get("unit", ""))
                    if builder:
                        ctx.client.command(ctx.player, [builder], "set_rally",
                                           {"pos": {"x": rally[0], "y": rally[1]}})
            self.status = RUNNING
        if self.status == RUNNING:
            done = 0
            for s in self._subs:
                s.tick(ctx)
                if s.status == DONE:
                    done += 1
            self.detail = "{} / {} unit-types ready".format(done, len(self._subs))
            if done >= len(self._subs):
                self.status = DONE


# ------------------------------------------------------------------------------
# Defense / control
# ------------------------------------------------------------------------------
class DefendSectorSkill(Skill):
    name = "defend_sector"
    description = ("Hold an area: keep combat units guarding around a point and counter-attack visible "
                   "attackers there. Standing order — runs until cancelled. Optionally restrict to "
                   "specific unit ids.")
    param_schema = {
        "type": "object",
        "properties": {
            "area": dict(_POINT, description="centre of the sector to defend"),
            "radius": {"type": "number", "default": 250},
            "ids": {"type": "array", "items": {"type": "integer"},
                    "description": "optional: specific unit ids to assign"},
        },
        "required": ["area"],
    }
    REISSUE = 120  # frames between re-issuing the guard order

    def tick(self, ctx):
        self._begin(ctx)
        ax, ay = resolve_point(ctx, self.params)
        radius = float(self.params.get("radius", 250))
        units = select_combat_units(ctx, ids=self.params.get("ids"))
        if not units:
            self.status, self.detail = BLOCKED, "no units to defend with"
            return
        ids = [u["id"] for u in units]
        self.status = RUNNING

        # reactive: counter a visible attacker hitting a unit inside the sector
        countered = None
        if ctx.threats:
            for t in ctx.threats.threats(ctx.frame):
                victim = find_object(ctx.world, t.get("victimId"))
                attacker = find_object(ctx.world, t.get("topAttacker"))
                if victim and attacker:
                    vx, vy = obj_pos(victim)
                    if math.hypot(vx - ax, vy - ay) <= radius * 1.5:
                        ctx.client.command(ctx.player, ids, "attack_target",
                                           {"targetId": attacker["id"]})
                        countered = attacker["id"]
                        break
        if countered is not None:
            self.detail = "countering attacker {}".format(countered)
            self._last = ctx.frame
            return

        if ctx.frame - getattr(self, "_last", -10 ** 9) >= self.REISSUE:
            ctx.client.command(ctx.player, ids, "guard_zone",
                               {"anchor": {"x": ax, "y": ay}, "engage": {"x": ax, "y": ay}})
            self._last = ctx.frame
        self.detail = "guarding {:.0f},{:.0f} with {} units".format(ax, ay, len(ids))


class AttackAreaSkill(Skill):
    name = "attack_area"
    description = ("Send a STRIKE FORCE to attack-move into an area, engaging on the way. Leaves a home "
                   "guard for defense (keep_home) and WAITS (blocked) until enough units are free — "
                   "never all-ins or sends a lone unit. Completes when no enemies remain near the "
                   "target. Only one attack runs at a time; re-target after it finishes.")
    param_schema = {
        "type": "object",
        "properties": {
            "area": dict(_POINT, description="target area to assault"),
            "radius": {"type": "number", "default": 200},
            "min_units": {"type": "integer", "default": 8,
                          "description": "don't attack until the strike force has at least this many"},
            "keep_home": {"type": "integer", "default": 8,
                          "description": "combat units to leave behind defending the base"},
            "ids": {"type": "array", "items": {"type": "integer"}},
        },
        "required": ["area"],
    }
    REISSUE = 150

    def tick(self, ctx):
        self._begin(ctx)
        ax, ay = resolve_point(ctx, self.params)
        radius = float(self.params.get("radius", 200))
        min_units = int(self.params.get("min_units", 8))
        keep_home = int(self.params.get("keep_home", 8))
        if self.params.get("ids"):
            units = select_combat_units(ctx, ids=self.params.get("ids"))
        else:
            # commit only the surplus beyond the home guard; lock the strike force so defend_base
            # leaves them alone (avoids defend/attack whipsawing the same units)
            all_army = select_combat_units(ctx)
            force_ids = set(self.params.get("_force", []))
            alive = [u for u in all_army if u.get("id") in force_ids]
            if len(alive) < min_units and len(all_army) - keep_home >= min_units:
                # (re)form the strike force from the units farthest from base sense — just take surplus
                surplus = all_army[keep_home:]
                self.params["_force"] = [u["id"] for u in surplus]
                alive = surplus
            units = alive
        if len(units) < min_units:
            self.status = BLOCKED
            self.detail = "waiting for strike force ({}/{}, keep {} home)".format(
                len(units), min_units, keep_home)
            return
        ids = [u["id"] for u in units]
        self.status = RUNNING
        near_enemies = [e for e in ctx.world.enemies()
                        if math.hypot(e.get("x", 0) - ax, e.get("y", 0) - ay) <= radius]
        if not near_enemies and self._elapsed(ctx) > 60:
            self.status, self.detail = DONE, "area clear"
            return
        if ctx.frame - getattr(self, "_last", -10 ** 9) >= self.REISSUE:
            ctx.client.command(ctx.player, ids, "attack_move", {"pos": {"x": ax, "y": ay, "z": 0.0}})
            self._last = ctx.frame
        self.detail = "assaulting {:.0f},{:.0f} ({} enemies near)".format(ax, ay, len(near_enemies))


class HoldPointSkill(Skill):
    name = "hold_point"
    description = ("Take and hold a location or a capturable structure: move a group there, capture it "
                   "if it's a capturable building (targetId), and guard the spot. Standing order.")
    param_schema = {
        "type": "object",
        "properties": {
            "targetId": {"type": "integer", "description": "capturable structure to take (optional)"},
            "pos": dict(_POINT, description="point to hold (optional if targetId given)"),
            "ids": {"type": "array", "items": {"type": "integer"}},
        },
        "required": [],
    }
    REISSUE = 150

    def tick(self, ctx):
        self._begin(ctx)
        units = select_combat_units(ctx, ids=self.params.get("ids"))
        if not units:
            self.status, self.detail = BLOCKED, "no units to hold with"
            return
        ids = [u["id"] for u in units]
        self.status = RUNNING
        tid = self.params.get("targetId")
        target = find_object(ctx.world, tid) if tid else None
        if target is not None and not getattr(self, "_captured", False):
            ctx.client.command(ctx.player, ids, "capture", {"targetId": tid})
            self._captured = True
            self.detail = "capturing {}".format(tid)
            self._last = ctx.frame
            return
        px, py = resolve_point(ctx, self.params, default=(obj_pos(target) if target else None))
        if ctx.frame - getattr(self, "_last", -10 ** 9) >= self.REISSUE:
            ctx.client.command(ctx.player, ids, "guard_zone",
                               {"anchor": {"x": px, "y": py}, "engage": {"x": px, "y": py}})
            self._last = ctx.frame
        self.detail = "holding {:.0f},{:.0f}".format(px, py)


class ScoutSkill(Skill):
    name = "scout"
    description = ("Reveal fog: send a unit to an area to scout it. Completes when one of my units "
                   "reaches the area. Prefers a cheap/fast unit if no ids are given.")
    param_schema = {
        "type": "object",
        "properties": {
            "area": dict(_POINT, description="area to scout"),
            "ids": {"type": "array", "items": {"type": "integer"}},
        },
        "required": ["area"],
    }
    ARRIVE = 90.0

    def tick(self, ctx):
        self._begin(ctx)
        ax, ay = resolve_point(ctx, self.params)
        ids = self.params.get("ids")
        if ids:
            idset = set(ids)
            units = [u for u in my_units(ctx) if u.get("id") in idset]
        else:
            # any mobile non-builder unit can scout; prefer a recon drone if present
            units = [u for u in my_units(ctx) if not is_dozerish(u)]
            drones = [u for u in units if "drone" in (u.get("template") or "").lower()]
            units = drones or units
        if not units:
            self.status, self.detail = FAILED, "no unit to scout with"
            return
        # arrived?
        for u in units:
            if math.hypot(u.get("x", 0) - ax, u.get("y", 0) - ay) <= self.ARRIVE:
                self.status, self.detail = DONE, "scouted {:.0f},{:.0f}".format(ax, ay)
                return
        scout = self.params.get("ids") or [units[0]["id"]]  # one unit unless told otherwise
        if isinstance(scout, list) and scout and isinstance(scout[0], dict):
            scout = [scout[0]["id"]]
        if self.status in (PENDING,) or ctx.frame - getattr(self, "_last", -10 ** 9) >= 150:
            ctx.client.command(ctx.player, list(scout), "move", {"pos": {"x": ax, "y": ay, "z": 0.0}})
            self._last = ctx.frame
        self.status = RUNNING
        self.detail = "scouting {:.0f},{:.0f}".format(ax, ay)


# ------------------------------------------------------------------------------
# Macro skills — encode RTS doctrine so the planner just sequences a few high-level orders
# ------------------------------------------------------------------------------
class BuildBaseSkill(Skill):
    name = "build_base"
    description = ("Build up your base in a sensible ORDER, ONE structure at a time, skipping roles you "
                   "already have. Trains a dozer first if needed and auto-builds power when low. "
                   "Faction-agnostic (works as any side). Call with NO arguments — it picks the right "
                   "structures from what you can build. Use this instead of many build_structure calls.")
    param_schema = {"type": "object", "properties": {}, "required": []}
    # role order (resolved per-faction from /buildable): power -> infantry -> defense -> vehicles
    DEFAULT_ROLES = ["power", "barracks", "defense", "warfactory", "defense"]
    DOZER_RETRAIN = 300
    ROLE_WAIT = 1200  # frames to wait for an unbuildable role before skipping it

    def tick(self, ctx):
        self._begin(ctx)
        roles = self.DEFAULT_ROLES
        if not hasattr(self, "_i"):
            self._i, self._sub, self._dz_frame, self._power_insert, self._wait = 0, None, None, False, None
        # 1) need a dozer to build at all
        if not find_dozers(ctx):
            dz = find_trainable_dozer(ctx)
            if dz and ctx.frame - (self._dz_frame or -10 ** 9) > self.DOZER_RETRAIN:
                ctx.client.command(ctx.player, [dz[1]], "train_unit", {"template": dz[0], "count": 1})
                self._dz_frame = ctx.frame
            self.status = RUNNING if dz else BLOCKED
            self.detail = "training a dozer first" if dz else "no dozer and none trainable"
            return
        # 2) skip roles already satisfied
        while self._i < len(roles) and self._sub is None and have_role(ctx, roles[self._i]):
            self._i += 1
            self._wait = None
        if self._i >= len(roles):
            self.status, self.detail = DONE, "base plan complete"
            return
        role = roles[self._i]
        # 3) power emergency: inject a power plant if out of power (without consuming a role)
        if self._sub is None and power_margin(ctx) <= 0:
            pwr = find_power_buildable(ctx)
            if pwr:
                self._sub = BuildStructureSkill({"structure": pwr})
                self._power_insert = True
        # 4) resolve the current role to a concrete buildable template
        if self._sub is None:
            tmpl = find_buildable_by_role(ctx, role)
            if not tmpl:
                if self._wait is None:
                    self._wait = ctx.frame
                if ctx.frame - self._wait > self.ROLE_WAIT:    # give up on this role, move on
                    self._i += 1
                    self._wait = None
                    self.status, self.detail = RUNNING, "skip {} (not buildable)".format(role)
                else:
                    self.status, self.detail = BLOCKED, "waiting to build {} (prereq/money)".format(role)
                return
            self._sub = BuildStructureSkill({"structure": tmpl})
            self._power_insert = False
            self._wait = None
        # 5) drive the sub-build
        self._sub.tick(ctx)
        self.status = RUNNING
        label = "power!" if self._power_insert else "[{}/{} {}]".format(self._i + 1, len(roles), role)
        self.detail = "{} {}".format(label, self._sub.status_line())
        if self._sub.status in (DONE, FAILED):
            if not self._power_insert:
                self._i += 1
            self._sub = None
            self._power_insert = False


class MaintainArmySkill(Skill):
    name = "maintain_army"
    description = ("Continuously build and reinforce a standing army up to a target size, training "
                   "whatever combat units your factories can make now (rotating types), and rallying "
                   "them to your base. Standing order — runs until cancelled. Start this early so you "
                   "always have a force.")
    param_schema = {
        "type": "object",
        "properties": {
            "target": {"type": "integer", "default": 8, "description": "desired number of combat units"},
        },
        "required": [],
    }
    PERIOD = 75

    def tick(self, ctx):
        self._begin(ctx)
        self.status = RUNNING
        target = int(self.params.get("target", 8))
        army = [u for u in my_units(ctx) if is_combat_unit(u)]
        if len(army) >= target:
            self.detail = "army {}/{} (full)".format(len(army), target)
            return
        trainable = find_trainable_combat(ctx)
        if not trainable:
            self.detail = "army {}/{} (no factory/units yet)".format(len(army), target)
            return
        if ctx.frame - getattr(self, "_last", -10 ** 9) >= self.PERIOD:
            k = getattr(self, "_k", 0)
            tmpl, builder, _cost, _e = trainable[k % len(trainable)]
            self._k = k + 1
            if builder:
                ctx.client.command(ctx.player, [builder], "train_unit", {"template": tmpl, "count": 1})
                base = ctx.world.centroid(my_buildings(ctx))
                if base:
                    ctx.client.command(ctx.player, [builder], "set_rally",
                                       {"pos": {"x": base[0], "y": base[1]}})
            self._last = ctx.frame
        self.detail = "army {}/{} (training {})".format(len(army), target, trainable[0][0])


class DefendBaseSkill(Skill):
    name = "defend_base"
    description = ("Keep your whole army guarding your base and counter-attack anything that attacks "
                   "you there. Standing order — runs until cancelled. Pair with maintain_army.")
    param_schema = {
        "type": "object",
        "properties": {"radius": {"type": "number", "default": 350}},
        "required": [],
    }
    REISSUE = 120

    def tick(self, ctx):
        self._begin(ctx)
        self.status = RUNNING
        base = ctx.world.centroid(my_buildings(ctx)) or ctx.world.centroid(my_units(ctx))
        if not base:
            self.detail = "no base to defend"
            return
        ax, ay = base
        under_attack = bool(enemy_units_near(ctx, base, 700.0))
        # The dedicated strike force (attack_area) is always off-limits. When the base is UNDER
        # ATTACK we recall everyone else — including units out capturing — and mass on the threat.
        # When calm, capture units stay out (we exclude them) so we don't yank them off-objective.
        off_limits = force_claimed_by_siblings(ctx, {"attack_area"})
        if not under_attack:
            off_limits |= force_claimed_by_siblings(ctx, {"capture_points"})
        units = [u for u in select_combat_units(ctx) if u.get("id") not in off_limits]
        if not units:
            self.detail = "no home-guard units (all committed elsewhere)"
            return
        ids = [u["id"] for u in units]
        if under_attack:
            # Focus-fire the nearest enemy to the base; mass the whole home army on it.
            foes = sorted(enemy_units_near(ctx, base, 1200.0),
                          key=lambda e: math.hypot(e.get("x", 0) - ax, e.get("y", 0) - ay))
            target = None
            if ctx.threats:  # prefer something actively shooting us, if known
                for t in ctx.threats.threats(ctx.frame):
                    atk = find_object(ctx.world, t.get("topAttacker"))
                    if atk and not (atk.get("relationToLocal") in (None, "self", "ally")):
                        target = atk
                        break
            target = target or (foes[0] if foes else None)
            if target is not None:
                ctx.client.command(ctx.player, ids, "attack_target", {"targetId": target["id"]})
                self._last = ctx.frame
                self.detail = "UNDER ATTACK — {} units massing on enemy {}".format(len(ids), target["id"])
                return
        if ctx.frame - getattr(self, "_last", -10 ** 9) >= self.REISSUE:
            ctx.client.command(ctx.player, ids, "guard_zone",
                               {"anchor": {"x": ax, "y": ay}, "engage": {"x": ax, "y": ay}})
            self._last = ctx.frame
        self.detail = "guarding base with {} units".format(len(ids))


class CapturePointsSkill(Skill):
    name = "capture_points"
    description = ("Capture all nearby oil/supply/tech/flag points for economy and map control — sends "
                   "units to take neutral/enemy capturable points one by one (nearest first). Standing "
                   "order — keeps grabbing points as they're discovered. Start this EARLY; economy "
                   "points fund your army.")
    param_schema = {
        "type": "object",
        "properties": {
            "units_per": {"type": "integer", "default": 1, "description": "units to send per point"},
            "home_guard": {"type": "integer", "default": 6,
                           "description": "combat units kept home (never sent capturing)"},
            "max_out": {"type": "integer", "default": 4,
                        "description": "max units committed to capturing at once"},
        },
        "required": [],
    }
    RETRY = 500  # frames before re-sending to a point we already dispatched to

    def tick(self, ctx):
        self._begin(ctx)
        self.status = RUNNING
        if not hasattr(self, "_sent"):
            self._sent = {}
        # Keep our committed-units list (params["_capture_force"]) pruned to live units so defend_base
        # can see exactly which units we own — this is what stops the per-tick defend/capture tug-of-war.
        force = alive_ids(ctx, self.params.get("_capture_force", []))
        self.params["_capture_force"] = force

        # If the base is under attack, capturing is suicide and a distraction: release everyone so
        # defend_base masses the whole army at home.
        if base_under_attack(ctx, 700.0):
            self.params["_capture_force"] = []
            self.detail = "base under attack — yielding capture units to defense"
            return

        army = select_combat_units(ctx)
        if not army:
            self.detail = "no units to capture with yet"
            return
        caps = capturable_points(ctx)
        if not caps:
            self.detail = "no capturable points in sight (scout to find them)"
            return

        home_guard = max(0, int(self.params.get("home_guard", 6)))
        max_out = max(1, int(self.params.get("max_out", 4)))
        # Only commit the SURPLUS beyond the home guard, capped — never strip the defending army.
        budget = min(max_out, max(0, len(army) - home_guard))
        if len(force) >= budget:
            self.detail = "capturing with {}/{} units (home guard {})".format(len(force), budget, home_guard)
            return

        # Recruit free units (not already capturing, not in any other force) up to budget.
        reserved = set(force) | force_claimed_by_siblings(ctx, {"attack_area"}, exclude=None)
        free = [u for u in army if u.get("id") not in reserved]
        if not free:
            self.detail = "no free units to expand capture"
            return
        base = ctx.world.centroid(my_buildings(ctx)) or obj_pos(army[0])
        caps.sort(key=lambda u: math.hypot(u["x"] - base[0], u["y"] - base[1]))
        per = max(1, int(self.params.get("units_per", 1)))
        for tgt in caps:
            if ctx.frame - self._sent.get(tgt["id"], -10 ** 9) < self.RETRY:
                continue
            free.sort(key=lambda u: math.hypot(u.get("x", 0) - tgt["x"], u.get("y", 0) - tgt["y"]))
            take = free[:per]
            if not take:
                break
            grp = [u["id"] for u in take]
            ctx.client.command(ctx.player, grp, "capture", {"targetId": tgt["id"]})
            self._sent[tgt["id"]] = ctx.frame
            self.params["_capture_force"] = force + grp
            self.detail = "capturing point {} with {} ({} pts known)".format(tgt["id"], len(grp), len(caps))
            return
        self.detail = "capture force {}/{} committed; awaiting reachable points".format(len(force), budget)


ALL_SKILLS = [
    # macros (preferred — encode doctrine)
    BuildBaseSkill,
    MaintainArmySkill,
    DefendBaseSkill,
    CapturePointsSkill,
    # primitives
    BuildStructureSkill,
    TrainUnitsSkill,
    AssembleGroupSkill,
    DefendSectorSkill,
    AttackAreaSkill,
    HoldPointSkill,
    ScoutSkill,
]
