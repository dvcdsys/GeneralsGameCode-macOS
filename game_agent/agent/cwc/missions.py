"""missions — strategic force-allocation layer (the doctrine above the squad tactics).

The army is NOT one force pointed at the enemy base. It is split into MISSIONS, each with its own
destination, dispatched through the SquadSystem (which does the per-group tactics). Doctrine by phase:

  EXPLORE (enemy base unknown):
    • SCOUT  — small squads, one per UNEXPLORED sector, fan out to FIND the enemy base (no clumping)
    • PICKET — medium squads hold forward strategic points (approaches / chokepoints)
    • RESERVE— a medium squad waits at base for quick reaction
  CONTAIN (base found, not yet all-in):
    • SIEGE  — large squads ring the enemy base to block its exits ("seal" it)
    • PICKET + RESERVE keep holding
  ASSAULT (strong enough to win):
    • MAIN   — the bulk razes the base; a small RESERVE guards home

Assignment is STICKY (a unit keeps its mission until it dies or the mission is gone), so the force does
not thrash back into one blob. Missions are re-filled from whatever is nearby — losses self-replenish.

NOTE (v1): "strategic points" are sector-based (forward approach sectors); true chokepoint/height
detection from /map is a planned refinement.
"""
import math

from agent.brief import _enemy_base_guess
from agent.skills.base import select_combat_units, my_buildings, my_units, is_building


class MissionSystem:
    SCOUT_SIZE = 3
    PICKET_SIZE = 5
    RESERVE_SIZE = 6
    SIEGE_SIZE = 10
    MAX_SCOUTS = 4
    MAX_PICKETS = 3
    MAX_SIEGE = 2
    SIEGE_RING = 520.0     # how far the containment squads hold from the enemy base centre — OUTSIDE base
                           # defence range (towers/bunkers): a holding line that masses pressure, not a charge
    DISPATCH_PERIOD = 45   # frames between RE-ISSUING squad orders (avoid per-frame command spam)

    def __init__(self, kb, squads):
        self.kb = kb
        self.squads = squads
        self.assign = {}        # unit id -> mission key (sticky)
        self.explored = set()   # sector ids we have had eyes on
        self.detail = ""
        self._last_dispatch = -10 ** 9

    # -- helpers --------------------------------------------------------------
    def _core_base(self, ctx, world):
        core = [u for u in my_buildings(ctx) if not (u.get("template") or "").startswith("CWCciv")]
        return world.centroid(core) or world.centroid([u for u in my_buildings(ctx)])

    def _enemy_base(self, commander):
        intel = commander.intel
        blds = [b for b in (intel.all_enemy_buildings() if intel else []) if "x" in b]
        if not blds:
            return None, []
        cx = sum(b["x"] for b in blds) / len(blds)
        cy = sum(b["y"] for b in blds) / len(blds)
        return (cx, cy), blds

    # building-priority keywords for the shared assault focus
    _CORE_KW = ("command", "construct", "conyard", "headquarters", "palace")  # core + rebuild source
    _PROD_KW = ("warfact", "war_fact", "barrack", "factory", "airfield", "helipad", "dropzone")
    _POWER_KW = ("power", "reactor")
    FOCUS_TIMEOUT = 2400   # frames to grind ONE building before shelving it (it's too tanky / dozer-repaired
                           # / unreachable). A building we can actually kill is GONE long before this.
    FOCUS_SKIP_DUR = 2600  # frames to avoid a shelved building before retrying it (come back once the base
                           # is weakened — its defenders/repair-dozers dead)

    def _focus_target(self, commander, fx, fy, skip=None):
        """The single building the whole assault should grind down right now. PRODUCTION first (the
        reinforcement source, and softer than the core), then power (defences/radar), then the command/
        construction core LAST — it's the tankiest + dozer-repaired, so leaving it for when the base is
        already gutted avoids stalling the whole army on one un-killable building. Distance-discounted, and
        skipping any building shelved by the no-progress timeout."""
        intel = commander.intel
        skip = skip or {}
        blds = [b for b in (intel.all_enemy_buildings() if intel else [])
                if "x" in b and b.get("id") not in skip]
        if not blds:
            return None
        fx = fx if fx is not None else blds[0]["x"]
        fy = fy if fy is not None else blds[0]["y"]

        def score(b):
            t = (b.get("template") or "").lower()
            d = math.hypot(b["x"] - fx, b["y"] - fy)
            if b.get("prod") or any(k in t for k in self._PROD_KW):
                bonus = 500.0           # army production — softer than the core AND stops reinforcement
            elif any(k in t for k in self._POWER_KW):
                bonus = 250.0           # power → drops defences/radar
            elif any(k in t for k in self._CORE_KW):
                bonus = 120.0           # CC/construction yard — tanky+repaired, raze it LAST
            else:
                bonus = 0.0
            return d - bonus            # lower = razed first (near + high value)

        return min(blds, key=score)

    # -- main -----------------------------------------------------------------
    def command(self, ctx, commander):
        world = ctx.world
        sectors = commander.sectors
        if not sectors:
            self.detail = "no sectors"
            return
        cap_force = set(commander.capture.params.get("_capture_force", []))
        avail = [u for u in select_combat_units(ctx) if u["id"] not in cap_force and "x" in u]
        ubid = {u["id"]: u for u in avail}
        alive = set(ubid)
        self.assign = {k: v for k, v in self.assign.items() if k in alive}
        for u in avail:                       # everything we stand on is explored
            self.explored.add(sectors.sector_of(u["x"], u["y"]))

        base = self._core_base(ctx, world)
        if not base:
            self.detail = "no base"
            return
        enemy_base, enemy_blds = self._enemy_base(commander)
        g = _enemy_base_guess(world, my_buildings(ctx), my_units(ctx))
        guess = (g["x"], g["y"]) if g else None

        # COMMIT TO ATTACK. Normally we only commit once the enemy's REAL (faction) base is FOUND — a
        # premature commit at a heuristic GUESS marches the army into empty/civilian ground where it
        # withers without ever fighting the base (observed: army 32→14, never found the base). The
        # exception is an OVERWHELMING force (>= ATTACK_ARMY_CAP): then push the guess to flush a turtle.
        strong = len(avail) >= getattr(commander, "ATTACK_ARMY_CAP", 48)
        if not commander._committed:
            ok, _why = commander._commit_decision(ctx, [u["id"] for u in avail])
            if ok and (enemy_base is not None or strong):
                commander._committed = True
        if commander._committed and len(avail) < 6:        # force wiped → fall back and re-mass
            commander._committed = False

        if commander._committed and enemy_base is not None:
            phase, target = "assault", enemy_base          # base found → grind it down
        elif commander._committed and guess is not None:
            phase, target = "assault", guess               # committed via overwhelming force → flush guess
        elif enemy_base is not None:
            phase, target = "contain", enemy_base
        else:
            phase, target = "explore", None

        missions = self._slots(ctx, sectors, base, target, phase, guess)
        self._assign_units(avail, ubid, missions, base, phase)
        # CONCENTRATION + STICKY: ONE shared focus building for the whole main force. STICKY = keep
        # hammering the SAME building until it's actually razed (gone from intel), THEN pick the next.
        # Without stickiness the "nearest high-value" recompute flips the target as the army shuffles, so
        # fire never sustains on one structure and nothing falls. Buildings have a lot of HP — commit.
        focus = None
        if phase == "assault":
            blds = {b["id"]: b for b in (commander.intel.all_enemy_buildings()
                                         if commander.intel else []) if "x" in b and "id" in b}
            self._focus_skip = {k: v for k, v in getattr(self, "_focus_skip", {}).items() if v > ctx.frame}
            cur = getattr(self, "_focus_id", None)
            # NO-PROGRESS TIMEOUT: if we've hammered the same building too long and it still stands, it's
            # too tanky / being dozer-repaired / unreachable → shelve it and raze something we CAN kill, so
            # the army keeps making progress instead of grinding the command center forever while the enemy
            # rebuilds everything else.
            if cur in blds and ctx.frame - getattr(self, "_focus_since", 0) > self.FOCUS_TIMEOUT:
                self._focus_skip[cur] = ctx.frame + self.FOCUS_SKIP_DUR
                cur = None
                self._focus_id = None
            if cur in blds:
                focus = blds[cur]                       # still standing & within budget → keep grinding it
            else:
                main_ids = next((m["ids"] for m in missions if m["kind"] == "main"), [])
                fpts = [(ubid[i]["x"], ubid[i]["y"]) for i in main_ids if i in ubid and "x" in ubid[i]]
                fx = sum(p[0] for p in fpts) / len(fpts) if fpts else None
                fy = sum(p[1] for p in fpts) / len(fpts) if fpts else None
                focus = self._focus_target(commander, fx, fy, skip=self._focus_skip)
                self._focus_id = focus["id"] if focus else None
                self._focus_since = ctx.frame
        # re-issue orders only periodically (units keep their last orders in between → no per-frame spam)
        if ctx.frame - self._last_dispatch >= self.DISPATCH_PERIOD:
            self._last_dispatch = ctx.frame
            seg = {}
            for m in missions:
                if m["ids"]:
                    # ONLY the committed MAIN assault is aggressive (tanks push + RAZE). SIEGE holds a
                    # CONTAINMENT line at a safe distance and fights defensively — making it aggressive
                    # fed small squads into the base defenses where they bled out (army 21→9) without a
                    # full commit, so the commit threshold could never be reached. Contain = mass, don't suicide.
                    agg = m["kind"] == "main"
                    rz = enemy_blds if agg else None
                    fc = focus if m["kind"] == "main" else None
                    d = self.squads.command(ctx, m["ids"], m["dest"], ubid, m["sq"],
                                            raze=rz, aggressive=agg, focus=fc,
                                            terrain=getattr(commander, "terrain", None))
                    seg[m["kind"]] = d            # per-mission squad state (not just the LAST dispatch)
            self._seg = seg
        counts = {}
        for m in missions:
            if m["ids"]:
                counts[m["kind"]] = counts.get(m["kind"], 0) + 1
        ftxt = ""
        if focus is not None:
            ftxt = " >>{}".format((focus.get("template") or "?").replace("CWC", "")[:10])
        segtxt = " ".join("{}={}".format(k, v) for k, v in (getattr(self, "_seg", {}) or {}).items())
        self.detail = "{} [{}]{} {}".format(
            phase, " ".join("{}x{}".format(v, k) for k, v in counts.items()),
            ftxt, segtxt)

    # -- mission slots per phase ---------------------------------------------
    def _slots(self, ctx, sectors, base, enemy_base, phase, guess=None):
        bx, by = base
        ms = []
        if phase == "explore":
            # SCOUTS to unexplored sectors. Bias the fan-out toward the GUESS (likely base corner) when we
            # have one, so we FIND the faction base fast instead of wandering the whole map; otherwise just
            # sweep nearest-first from home.
            ax, ay = (guess if guess else (bx, by))
            unexplored = [s for s in sectors.all_sectors() if s not in self.explored]
            unexplored.sort(key=lambda s: (lambda c: (c[0] - ax) ** 2 + (c[1] - ay) ** 2)(sectors.centroid(s)))
            dests = [sectors.centroid(s) for s in unexplored[:self.MAX_SCOUTS]]
            if guess is not None:                      # a dedicated probe straight at the guess
                dests = [guess] + dests[:self.MAX_SCOUTS - 1]
            for i, dst in enumerate(dests):
                ms.append({"key": "scout:%d" % i, "kind": "scout", "dest": dst,
                           "target": self.SCOUT_SIZE, "sq": "scout"})
            # PICKETS on forward strategic sectors (toward map centre)
            for i, pt in enumerate(self._strategic_points(sectors, base)):
                ms.append({"key": "picket:%d" % i, "kind": "picket", "dest": pt,
                           "target": self.PICKET_SIZE, "sq": "combat"})
            ms.append({"key": "reserve", "kind": "reserve", "dest": base,
                       "target": self.RESERVE_SIZE, "sq": "combat"})
        elif phase == "contain":
            for i, pt in enumerate(self._siege_points(base, enemy_base)):
                ms.append({"key": "siege:%d" % i, "kind": "siege", "dest": pt,
                           "target": self.SIEGE_SIZE, "sq": "combat"})
            for i, pt in enumerate(self._strategic_points(sectors, base)):
                ms.append({"key": "picket:%d" % i, "kind": "picket", "dest": pt,
                           "target": self.PICKET_SIZE, "sq": "combat"})
            ms.append({"key": "reserve", "kind": "reserve", "dest": base,
                       "target": self.RESERVE_SIZE, "sq": "combat"})
        else:  # assault
            # "march" sizing = bigger squads ⇒ FEWER separate groups ⇒ the assault stays concentrated
            # (combined with the shared focus target, the army grinds the base down as one fist).
            ms.append({"key": "main", "kind": "main", "dest": enemy_base,
                       "target": 9999, "sq": "march"})
            # HOME GARRISON: keep a real defense at base (not 4) — the whole army marching out left home
            # undefended and the enemy counter-razed it (bot wiped: army 0, bldgs 0). 12 holds the line.
            ms.append({"key": "reserve", "kind": "reserve", "dest": base,
                       "target": 12, "sq": "combat"})
        for m in ms:
            m["ids"] = []
        return ms

    def _strategic_points(self, sectors, base):
        """Forward approach sectors between my base and the map centre — held as a defensive line. v1
        heuristic for chokepoints/heights (true terrain analysis from /map is a refinement)."""
        bx, by = base
        cx, cy = sectors.W / 2.0, sectors.H / 2.0
        dx, dy = cx - bx, cy - by
        d = math.hypot(dx, dy) or 1.0
        ax, ay = dx / d, dy / d
        cand = []
        for s in sectors.all_sectors():
            sx, sy = sectors.centroid(s)
            rel = (sx - bx) * ax + (sy - by) * ay        # how far FORWARD (toward centre)
            dist = math.hypot(sx - bx, sy - by)
            if rel > 0.2 * d and dist < 0.75 * sectors.W:   # forward, not too deep
                cand.append((rel, (sx, sy)))
        cand.sort()
        # pick MAX_PICKETS spread along the forward band
        pts = [p for _, p in cand[:self.MAX_PICKETS]]
        return pts

    def _siege_points(self, base, enemy_base):
        """Ring positions around the enemy base to block its exits. Spread on the side facing the map."""
        ex, ey = enemy_base
        bx, by = base
        dx, dy = bx - ex, by - ey                         # direction enemy->my base (their main exit)
        d = math.hypot(dx, dy) or 1.0
        ax, ay = dx / d, dy / d
        px, py = -ay, ax
        out = []
        for k in range(self.MAX_SIEGE):
            side = -1 if k % 2 == 0 else 1
            ang = side * 0.6
            ox = ax * math.cos(ang) - ay * math.sin(ang)
            oy = ax * math.sin(ang) + ay * math.cos(ang)
            out.append((ex + ox * self.SIEGE_RING, ey + oy * self.SIEGE_RING))
        return out

    # -- sticky assignment ----------------------------------------------------
    def _assign_units(self, avail, ubid, missions, base, phase):
        by_key = {m["key"]: m for m in missions}
        # keep existing assignments that still have a mission; drop the rest
        self.assign = {uid: k for uid, k in self.assign.items() if k in by_key}
        for uid, k in self.assign.items():
            by_key[k]["ids"].append(uid)
        unassigned = [u for u in avail if u["id"] not in self.assign]

        # fill order by phase priority
        order = {"explore": ["scout", "reserve", "picket"],
                 "contain": ["siege", "picket", "reserve"],
                 "assault": ["main", "reserve"]}[phase]

        def nearest_to(dest, pool):
            dx, dy = dest
            return min(pool, key=lambda u: (u["x"] - dx) ** 2 + (u["y"] - dy) ** 2)

        for kind in order:
            for m in missions:
                if m["kind"] != kind:
                    continue
                while len(m["ids"]) < m["target"] and unassigned:
                    u = nearest_to(m["dest"], unassigned)
                    unassigned.remove(u)
                    self.assign[u["id"]] = m["key"]
                    m["ids"].append(u["id"])
        # leftovers -> the catch-all (reserve, or main in assault)
        catch = next((m for m in missions if m["kind"] == ("main" if phase == "assault" else "reserve")), None)
        if catch is not None:
            for u in unassigned:
                self.assign[u["id"]] = catch["key"]
                catch["ids"].append(u["id"])
