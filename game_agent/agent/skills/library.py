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
    description = ("Send a group to attack-move into an area, engaging anything on the way. Completes "
                   "when no enemies remain near the target. Optionally restrict to specific unit ids.")
    param_schema = {
        "type": "object",
        "properties": {
            "area": dict(_POINT, description="target area to assault"),
            "radius": {"type": "number", "default": 200},
            "ids": {"type": "array", "items": {"type": "integer"}},
        },
        "required": ["area"],
    }
    REISSUE = 150

    def tick(self, ctx):
        self._begin(ctx)
        ax, ay = resolve_point(ctx, self.params)
        radius = float(self.params.get("radius", 200))
        units = select_combat_units(ctx, ids=self.params.get("ids"))
        if not units:
            self.status, self.detail = FAILED, "no units to attack with"
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
        units = select_combat_units(ctx, ids=self.params.get("ids"))
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


ALL_SKILLS = [
    BuildStructureSkill,
    TrainUnitsSkill,
    AssembleGroupSkill,
    DefendSectorSkill,
    AttackAreaSkill,
    HoldPointSkill,
    ScoutSkill,
]
