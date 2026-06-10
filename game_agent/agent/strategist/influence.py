"""influence.py — the Strategist's spatial heat maps.

Each tick we lay a coarse grid over the map and stamp military *influence* from both
sides plus economic *value*, then answer the spatial questions the macro brain and the
army controller ask:

  threat(x,y)        enemy military influence  (how dangerous a spot is for me)
  presence(x,y)      my own military influence
  control(x,y)       presence - threat         (>0 mine, <0 theirs, ~0 = frontline)
  value(x,y)         economic / strategic worth (capture points + enemy production)

  most_threatened(objs)      -> the friendly building under the most enemy pressure (go defend it)
  best_raid_target(objs)     -> a high-value enemy target sitting in the LOWEST local enemy
                                influence (an undefended back-line econ/structure to harass)
  approach_point(frm,to,..)  -> a staging point near `to` on the side with less enemy influence
                                (flank instead of charging the kill-zone)
  frontline_point(frm,to)    -> where control crosses zero along the my->enemy axis
  safe_value_spot(cands)     -> the candidate maximising value while minimising threat

Pure model: reads the WorldModel + KnowledgeBase, issues no commands, and degrades to
zero (neutral) influence wherever data is missing so callers always get a sane answer.

The military weight of a unit/building is derived from the KB (effective dps + hp +
weapon reach), cached per template. A bare rifleman ~ 0.5, a main battle tank ~ 2-3,
a base defence tower projects threat over its whole firing radius.
"""
import math

from agent.skills.base import is_building, is_combat_unit, is_junk

# tile size in world units — ~ one mid engagement range. Smaller = sharper but costlier.
TILE = 160.0
MAX_STAMP_TILES = 9          # cap a single object's stamp radius (keep the per-tick cost bounded)
DEFAULT_REACH = 150.0        # world units, when the KB has no range for a template
HOME_AURA = 240.0            # soft military aura every building projects (so a base reads as "mine")

# --- per-template military weight (cached) -----------------------------------
_POWER_CACHE = {}


_DEFENSE_KW = ("fort", "turret", "bunker", "tower", "sam", "patriot", "gun", "pillbox",
               "defens", "stinger", "flak", "shilka", "vulcan", "aagun")


def _default_cost(roles, tl):
    """Build-cost fallback when the KB lacks BuildCost — a stable strength backbone."""
    if "structure" in roles:
        return 800 if any(k in tl for k in _DEFENSE_KW) else 0
    if "aircraft" in roles or "air" in roles:
        return 1000
    if "artillery" in roles:
        return 800
    if "vehicle" in roles:
        return 500
    if "infantry" in roles:
        return 130
    return 200


def mil_power(kb, template):
    """Static military weight + weapon reach of one `template`.

    COST-primary: the engine prices units by combat value, so cost is a stable, sensible
    backbone (a $800 tank > a $100 rifleman) — far steadier than the noisy per-template
    effective-dps field, which we reserve for the per-matchup counter logic (combat_eval).
    Returns (power, reach). Live hp scaling is applied by the caller.
    """
    if not template:
        return 0.0, DEFAULT_REACH
    cached = _POWER_CACHE.get(template)
    if cached is not None:
        return cached
    roles = kb.roles_of(template) if kb else set()
    tl = template.lower()
    is_struct = "structure" in roles or kb is None and False
    # reach: prefer the KB weapon range
    reach = None
    has_weapon = False
    if kb:
        row = kb.eff_row(template)
        if row:
            reach = row.get("range")
            has_weapon = (row.get("dps") or 0) > 0 or bool(row.get("vsArmor"))
    reach = (reach or 0) or (kb.attack_range(template) if kb else None) or DEFAULT_REACH
    reach = float(max(60.0, min(reach, 650.0)))

    cost = (kb.cost(template) if kb else None)
    if cost is None:
        cost = _default_cost(roles, tl)
    # a non-defensive structure projects no threat (it does not shoot) — value-only
    if is_struct and not (has_weapon or any(k in tl for k in _DEFENSE_KW)):
        out = (0.0, reach)
        _POWER_CACHE[template] = out
        return out
    # sqrt(cost) compresses the range sensibly: rifle$100->0.9, AT$180->1.2, tank$800->2.6,
    # arty$900->2.7, heli$1200->3.2; clamp so nothing dominates the field.
    power = math.sqrt(max(cost, 40) / 120.0)
    if "aircraft" in roles or "air" in roles:
        power *= 1.1
    power = max(0.3, min(power, 6.0))
    out = (float(power), reach)
    _POWER_CACHE[template] = out
    return out


class InfluenceMap:
    def __init__(self, world, kb, owner, extra_enemy_buildings=None):
        self.world = world
        self.kb = kb
        self.owner = owner
        self.cell = world.cell or 10
        self.Wm = (world.width or 0) * self.cell or 1.0
        self.Hm = (world.height or 0) * self.cell or 1.0
        self.nx = max(1, int(math.ceil(self.Wm / TILE)))
        self.ny = max(1, int(math.ceil(self.Hm / TILE)))
        n = self.nx * self.ny
        self.presence = [0.0] * n      # my military influence
        self.threat = [0.0] * n        # enemy military influence
        self.value = [0.0] * n         # econ / strategic worth (positive = worth taking/raiding)
        self._build(extra_enemy_buildings or [])

    # -- geometry --------------------------------------------------------------
    def _ti(self, x, y):
        ix = min(self.nx - 1, max(0, int(x / TILE)))
        iy = min(self.ny - 1, max(0, int(y / TILE)))
        return ix, iy

    def _center(self, ix, iy):
        return (ix + 0.5) * TILE, (iy + 0.5) * TILE

    def _stamp(self, layer, ox, oy, p, reach):
        if p <= 0 or reach <= 0:
            return
        R = min(reach, MAX_STAMP_TILES * TILE)
        ix0, iy0 = self._ti(ox - R, oy - R)
        ix1, iy1 = self._ti(ox + R, oy + R)
        R2 = R * R
        for iy in range(iy0, iy1 + 1):
            base = iy * self.nx
            cy = (iy + 0.5) * TILE
            for ix in range(ix0, ix1 + 1):
                cx = (ix + 0.5) * TILE
                d2 = (cx - ox) ** 2 + (cy - oy) ** 2
                if d2 <= R2:
                    layer[base + ix] += p * (1.0 - math.sqrt(d2) / R)

    def _build(self, extra_enemy_buildings):
        kb = self.kb
        seen_enemy_bld = set()
        for u in self.world.units:
            if is_junk(u) or "x" not in u:
                continue
            x, y = u["x"], u["y"]
            tmpl = u.get("template") or ""
            mine = u.get("player") == self.owner
            bld = is_building(u)
            p, reach = mil_power(kb, tmpl)
            # live hp scaling for mobile units (a near-dead unit projects little)
            hp, mx = u.get("health"), u.get("maxHealth")
            if mx and hp is not None and not bld:
                p *= max(0.15, min(1.0, hp / mx))
            if mine:
                if bld:
                    self._stamp(self.presence, x, y, max(p, 0.6), max(reach, HOME_AURA))
                else:
                    self._stamp(self.presence, x, y, p, reach + TILE)
            elif u.get("relationToLocal") == "enemy" and u.get("player") != self.owner:
                if bld:
                    seen_enemy_bld.add(u.get("id"))
                    self._stamp(self.threat, x, y, max(p, 0.4), max(reach, HOME_AURA))
                    self._enemy_building_value(u, x, y)
                else:
                    self._stamp(self.threat, x, y, p, reach + TILE)
            else:
                # neutral: capturable econ/tech points are opportunity value
                self._neutral_value(u, x, y)
        # remembered enemy buildings still in fog (so raids/attacks have targets + threat persists)
        for b in extra_enemy_buildings:
            if b.get("id") in seen_enemy_bld or "x" not in b:
                continue
            self._stamp(self.threat, b["x"], b["y"], 0.6, HOME_AURA)
            self._enemy_building_value(b, b["x"], b["y"])

    def _enemy_building_value(self, u, x, y):
        tmpl = (u.get("template") or "").lower()
        if any(k in tmpl for k in ("warfact", "war_fact", "barrack", "factory", "airfield",
                                   "helipad", "dropzone")):
            v = 4.0                                  # production = the reinforcement source
        elif any(k in tmpl for k in ("command", "construct", "conyard", "palace", "headquarters")):
            v = 3.0                                  # the core / rebuild source
        elif any(k in tmpl for k in ("power", "reactor", "fuel")):
            v = 2.5                                  # power -> drops defences
        else:
            v = 1.0
        self._stamp(self.value, x, y, v, TILE * 1.5)

    def _neutral_value(self, u, x, y):
        cat = u.get("category")
        tags = [str(t).lower() for t in u.get("tags", [])]
        if cat == "economy" or any(t in tags for t in ("supply_source", "cash_generator",
                                                        "capturable", "tech")):
            self._stamp(self.value, x, y, 2.0, TILE * 1.5)

    # -- sampling --------------------------------------------------------------
    def _sample(self, layer, x, y):
        # bilinear over tile centres
        gx = x / TILE - 0.5
        gy = y / TILE - 0.5
        ix = int(math.floor(gx))
        iy = int(math.floor(gy))
        fx = gx - ix
        fy = gy - iy

        def at(i, j):
            if 0 <= i < self.nx and 0 <= j < self.ny:
                return layer[j * self.nx + i]
            return 0.0
        a = at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx
        b = at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx
        return a * (1 - fy) + b * fy

    def threat_at(self, x, y):
        return self._sample(self.threat, x, y)

    def presence_at(self, x, y):
        return self._sample(self.presence, x, y)

    def control_at(self, x, y):
        return self._sample(self.presence, x, y) - self._sample(self.threat, x, y)

    def value_at(self, x, y):
        return self._sample(self.value, x, y)

    # -- queries ---------------------------------------------------------------
    def most_threatened(self, objs):
        """Friendly object under the most enemy pressure (where to send the defense)."""
        best, bt = None, 0.0
        for u in objs:
            if "x" not in u:
                continue
            t = self.threat_at(u["x"], u["y"])
            if t > bt:
                best, bt = u, t
        return best, bt

    def raid_scores(self, objs):
        """[(obj, score)] for every candidate raid target: high value sitting in low local
        enemy influence scores best. Callers pick argmax (best_raid_target) or a weighted
        top-k (personality) so the raid target isn't a readable constant."""
        out = []
        for u in objs:
            if "x" not in u:
                continue
            x, y = u["x"], u["y"]
            v = max(self.value_at(x, y), 0.5)
            t = self.threat_at(x, y)
            out.append((u, v / (1.0 + t)))   # high value, low defence
        return out

    def best_raid_target(self, objs):
        """High-value enemy object sitting in the lowest local enemy influence — a soft
        back-line target a small harass group can hit and run. Returns (obj, score)."""
        scored = self.raid_scores(objs)
        if not scored:
            return None, None
        return max(scored, key=lambda t: t[1])

    def approach_point(self, frm, to, standoff=0.0, samples=5, spread=420.0):
        """A staging point near `to`, offset laterally toward the side with LESS enemy
        influence so the army flanks the defended axis instead of walking the kill-zone.
        `standoff` pulls the point back from `to` along the approach by that many units."""
        fx, fy = frm
        tx, ty = to
        dx, dy = tx - fx, ty - fy
        d = math.hypot(dx, dy) or 1.0
        ux, uy = dx / d, dy / d
        # base point pulled back from the target by standoff
        bx, by = tx - ux * standoff, ty - uy * standoff
        px, py = -uy, ux                    # perpendicular
        best, bestcost = (bx, by), None
        half = (samples - 1) / 2.0
        for k in range(samples):
            off = (k - half) / max(half, 1.0) * spread
            sx, sy = bx + px * off, by + py * off
            if not self.world.passable(sx, sy):
                continue
            # cost = enemy influence at the staging point + along the last leg to the target
            cost = self.threat_at(sx, sy) * 1.5
            for t in (0.33, 0.66):
                cost += self.threat_at(sx + (tx - sx) * t, sy + (ty - sy) * t)
            if bestcost is None or cost < bestcost:
                best, bestcost = (sx, sy), cost
        return best

    def frontline_point(self, frm, to):
        """Walk frm->to and return the first point where ENEMY influence takes over: the
        natural place to hold/contain/harass from. Strictly negative control only —
        neutral/unexplored ground (control == 0) is NOT enemy territory; treating it as
        such made the army mass at the edge of its own base aura and concede the whole
        mid-map. No enemy influence on the path -> stage at the midpoint."""
        fx, fy = frm
        tx, ty = to
        d = math.hypot(tx - fx, ty - fy) or 1.0
        steps = max(4, int(d / TILE))
        for k in range(1, steps + 1):
            t = k / steps
            x, y = fx + (tx - fx) * t, fy + (ty - fy) * t
            if self.control_at(x, y) < -0.05:
                return (x, y)
        return ((fx + tx) / 2.0, (fy + ty) / 2.0)

    def safe_value_spot(self, cands):
        """Of candidate points/objs, the one maximising value while minimising threat."""
        best, bs = None, None
        for u in cands:
            x, y = (u["x"], u["y"]) if isinstance(u, dict) else u
            score = self.value_at(x, y) + 1.0 - self.threat_at(x, y)
            if bs is None or score > bs:
                best, bs = u, score
        return best

    # -- viewer overlay --------------------------------------------------------
    def overlay(self, ds=1):
        """Compact grid snapshot for the live map view: control & threat per tile.
        ds downsamples for bandwidth. Values rounded; empty tiles dropped."""
        out = []
        for iy in range(0, self.ny, ds):
            for ix in range(0, self.nx, ds):
                i = iy * self.nx + ix
                pr, th, va = self.presence[i], self.threat[i], self.value[i]
                if pr < 0.05 and th < 0.05 and va < 0.05:
                    continue
                cx, cy = self._center(ix, iy)
                out.append({"x": round(cx), "y": round(cy),
                            "c": round(pr - th, 2), "t": round(th, 2), "v": round(va, 2)})
        return {"tile": TILE, "nx": self.nx, "ny": self.ny, "cells": out}
