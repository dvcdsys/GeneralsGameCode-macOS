"""BattlefieldIntel — the bot's model of the enemy.

Ticked first in the Commander loop.  Pure observation: it issues no commands.  It
turns the fog-aware /units stream + the WS event journal + the threat tracker into:
  - enemy_unit_histogram   (max count seen per template + produced count)
  - last_seen[template]    (centroid position + frame) and movement vectors
  - battlefield coefficients {air, infantry, vehicle, artillery} mass fractions
  - enemy_profile()        (weighted bag for combat_eval.best_counters)

It degrades gracefully: with no KB it still tracks raw histograms; with no journal
it relies on current sightings.  snapshot() feeds the viewer's Intel panel.
"""
from agent.skills.base import is_combat_unit, is_building


# coarse class buckets for the dominance coefficients
def _class_of(kb, template):
    roles = kb.roles_of(template) if kb else set()
    if "aircraft" in roles:
        return "air"
    if "artillery" in roles:
        return "artillery"
    if "vehicle" in roles:
        return "vehicle"
    if "infantry" in roles:
        return "infantry"
    # fall back to template hints
    low = (template or "").lower()
    if "inf" in low:
        return "infantry"
    return "vehicle"


class BattlefieldIntel:
    def __init__(self, kb, owner):
        self.kb = kb
        self.owner = owner
        self.histogram = {}        # template -> max simultaneously-seen count
        self.produced = {}         # template -> cumulative produced (from journal)
        self.last_seen = {}        # template -> {"x","y","frame"}
        self.vectors = {}          # template -> (dx,dy) since previous sighting
        self.enemy_side = None
        self._frame = 0
        # PERSISTENT memory of enemy STRUCTURES ever seen: id -> {template,x,y,frame,prod}.
        # Buildings don't move, so once scouted we remember them even after fog re-covers them —
        # this is what lets the offense lock onto a production building to RAZE instead of chasing a
        # flickering fog-view centroid.
        self.enemy_buildings = {}

    # -- per-tick update ---------------------------------------------------
    _PROD_KW = ("command", "barrack", "warfact", "war_fact", "factory",
                "airfield", "helipad", "dropzone")

    def observe(self, ctx):
        self._frame = ctx.frame
        # persistent enemy-structure memory (buildings don't move; remember them through fog).
        # Drop a remembered building only if we can currently SEE its tile and it's gone (razed).
        seen_now = {}
        for b in ctx.world.enemies():
            if not is_building(b) or "x" not in b:
                continue
            bid = b.get("id")
            if bid is None:
                continue
            tmpl = (b.get("template") or "")
            # Only remember real FACTION structures (CWCus/CWCru…), not neutral/civilian
            # buildings (BarnShed, QuonsetHut, captured civ huts) — those pollute the base
            # estimate and drag the assault short of the actual production core.
            if not tmpl.startswith("CWC") or tmpl.startswith("CWCciv"):
                continue
            seen_now[bid] = True
            self.enemy_buildings[bid] = {
                "template": tmpl, "x": b.get("x", 0), "y": b.get("y", 0),
                "frame": ctx.frame,
                "prod": any(k in tmpl.lower() for k in self._PROD_KW),
            }
        # PRUNE razed buildings (the comment above, finally implemented): if one of OUR units is
        # close enough to a remembered building's tile that the tile is in our vision, but we did NOT
        # see the building this frame, it has been destroyed → forget it. Without this, a razed target
        # lingers in memory forever and the assault locks onto a GHOST on empty ground, milling there
        # (force attrited to nothing) while the real enemy base stands untouched elsewhere.
        my_pos = [(u.get("x"), u.get("y")) for u in ctx.world.units
                  if u.get("player") == ctx.player and "x" in u and "y" in u]
        VIS2 = 220.0 * 220.0
        for bid in list(self.enemy_buildings):
            if bid in seen_now:
                continue
            b = self.enemy_buildings[bid]
            bx, by = b.get("x", 0), b.get("y", 0)
            if any((px - bx) ** 2 + (py - by) ** 2 < VIS2 for px, py in my_pos):
                del self.enemy_buildings[bid]
        enemies = [u for u in ctx.world.enemies()
                   if not is_building(u) and is_combat_unit(u)]
        # current visible counts + positions per template
        cur = {}
        pos = {}
        for u in enemies:
            t = u.get("template")
            if not t:
                continue
            cur[t] = cur.get(t, 0) + 1
            pos.setdefault(t, []).append((u.get("x", 0), u.get("y", 0)))
            if self.enemy_side is None:
                st = self.kb.stat(t) if self.kb else None
                if st and st.get("Side"):
                    self.enemy_side = st.get("Side")
        for t, c in cur.items():
            self.histogram[t] = max(self.histogram.get(t, 0), c)
            xs = [p[0] for p in pos[t]]
            ys = [p[1] for p in pos[t]]
            cx, cy = sum(xs) / len(xs), sum(ys) / len(ys)
            prev = self.last_seen.get(t)
            if prev:
                self.vectors[t] = (round(cx - prev["x"], 1),
                                   round(cy - prev["y"], 1))
            self.last_seen[t] = {"x": round(cx, 1), "y": round(cy, 1),
                                 "frame": ctx.frame}
        # per-sector stats (if a sector model is attached): where enemies/my units/
        # capture points are, for the recon/expansion goals + UI overlay
        sec = getattr(ctx, "sectors", None)
        if sec is not None:
            try:
                sec.reset_stats()
                for u in enemies:
                    sec.bump(sec.sector_of(u.get("x", 0), u.get("y", 0)), "enemy")
                from agent.skills.base import my_units as _mine, capturable_points as _pts
                for u in _mine(ctx):
                    sec.bump(sec.sector_of(u.get("x", 0), u.get("y", 0)), "mine")
                for p in _pts(ctx):
                    sec.bump(sec.sector_of(p.get("x", 0), p.get("y", 0)), "points")
            except Exception:  # noqa: BLE001
                pass

        # journal: cumulative enemy production (ground truth even out of sight)
        j = getattr(ctx, "journal", None)
        if j is not None:
            try:
                for t in list(self.histogram) + self._enemy_catalog():
                    n = j.count("unit_produced", template=t) if t else 0
                    if n:
                        self.produced[t] = n
                        self.histogram[t] = max(self.histogram.get(t, 0), n)
            except Exception:  # noqa: BLE001 - journal API variance must not break tick
                pass

    # -- queries -----------------------------------------------------------
    def _enemy_catalog(self):
        if not (self.kb and self.enemy_side):
            return []
        return [n for n, o in self.kb.units.items()
                if o.get("Side") == self.enemy_side and "CAN_ATTACK" in o.get("kindOf", [])]

    def enemy_profile(self):
        """{template: weight} over enemy COMBAT units, for best_counters."""
        return {t: c for t, c in self.histogram.items() if c > 0}

    def dominance(self):
        """Mass fraction per class {air, infantry, vehicle, artillery}."""
        agg = {"air": 0, "infantry": 0, "vehicle": 0, "artillery": 0}
        for t, c in self.histogram.items():
            agg[_class_of(self.kb, t)] = agg.get(_class_of(self.kb, t), 0) + c
        return agg

    def dominant(self):
        agg = self.dominance()
        if not any(agg.values()):
            return None
        return max(agg, key=agg.get)

    def threat_axis(self):
        """Average position of recently-seen enemy units (where pressure is)."""
        pts = [(v["x"], v["y"]) for v in self.last_seen.values()
               if self._frame - v["frame"] < 600]
        if not pts:
            return None
        return (sum(p[0] for p in pts) / len(pts),
                sum(p[1] for p in pts) / len(pts))

    def production_targets(self):
        """Remembered enemy PRODUCTION buildings (command/barracks/warfactory/…),
        most-recently-seen first.  Each: {id,template,x,y,frame}."""
        out = [dict(v, id=k) for k, v in self.enemy_buildings.items() if v.get("prod")]
        out.sort(key=lambda b: b["frame"], reverse=True)
        return out

    def all_enemy_buildings(self):
        return [dict(v, id=k) for k, v in self.enemy_buildings.items()]

    def enemy_base_estimate(self):
        """Centroid of remembered enemy buildings (prefer production), or None."""
        prod = self.production_targets()
        pool = prod if prod else self.all_enemy_buildings()
        if not pool:
            return None
        return (sum(b["x"] for b in pool) / len(pool),
                sum(b["y"] for b in pool) / len(pool))

    def nearest_production(self, x, y):
        import math
        prod = self.production_targets()
        if not prod:
            return None
        return min(prod, key=lambda b: math.hypot(b["x"] - x, b["y"] - y))

    def deepest_building(self, from_x, from_y):
        """The remembered enemy building FARTHEST from (from_x,from_y) — i.e. deepest
        in enemy territory.  Pushing the assault here drives it INTO the base (where
        it scouts the production core) instead of stopping at a polluted centroid."""
        import math
        pool = self.production_targets() or self.all_enemy_buildings()
        if not pool:
            return None
        return max(pool, key=lambda b: math.hypot(b["x"] - from_x, b["y"] - from_y))

    def never_used(self, limit=12):
        seen = set(self.histogram)
        return [t for t in self._enemy_catalog() if t not in seen][:limit]

    # -- UI ----------------------------------------------------------------
    def snapshot(self):
        return {
            "histogram": dict(self.histogram),
            "dominance": self.dominance(),
            "dominant": self.dominant(),
            "neverUsed": self.never_used(),
            "lastSeen": len(self.last_seen),
            "enemySide": self.enemy_side,
            "vectors": {t: v for t, v in self.vectors.items() if v != (0.0, 0.0)},
            "threatAxis": self.threat_axis(),
        }
