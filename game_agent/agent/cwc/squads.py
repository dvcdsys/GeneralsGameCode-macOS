"""squads — combined-arms SQUAD system for the offense (Stage 2 redo).

The army does NOT move as one blob. It is split into independent squads that each maneuver tactically:

  • ADVANCE  — march toward the objective in column: recon + infantry LEAD, AA mid, TANKS behind (kept safe)
  • CONTACT  — enemy in sight: spread and fight with role targeting (AA→air, inf/snipers→soft, tanks→armour)
  • ATGM     — enemy anti-tank missiles threaten:
                 - SOFT infantry ATGM: TANKS pull back (preserve them) while the cover (infantry/AA) HOLDS
                   to bait the ATGM forward and kill it; if >=2 tanks, ONE scouts ahead to reveal a hidden
                   launcher while the rest retreat.
                 - ARMOURED IFV ATGM (BMP/Bradley): only tanks/AT can kill it → they engage it (carefully).
  • SCOUT    — taking fire from OUTSIDE vision (a squad member loses hp with no visible enemy): push the
                recon unit toward the threat to reveal the shooter, the rest hold.

Squad SIZE adapts to phase (user): SCOUT small, MARCH big (concentrate the move), COMBAT standard. When we
attack the base the squads spread across the front (waves from different approach points). Squads are
re-partitioned each command from role pools, so losses are auto-replenished and incomplete squads refill
from whatever is nearby.
"""
import math

from agent.skills.base import is_building, is_combat_unit
from agent.cwc import combat_eval


class SquadSystem:
    # per-squad target composition by phase (tanks drive the count)
    SIZES = {
        "scout":  {"tank": 2, "aa": 1, "inf": 2, "recon": 1},   # probing the map — small & many
        "march":  {"tank": 5, "aa": 2, "inf": 3, "recon": 1},   # moving the army up — big & concentrated
        "combat": {"tank": 3, "aa": 1, "inf": 2, "recon": 1},   # in the fight — standard combined-arms
    }
    ENGAGE = 800.0        # see/fight enemies within this of a squad centroid
    ATGM_TRIGGER = 640.0  # an enemy ATGM within this of the squad triggers the ATGM tactic
    RETREAT_DIST = 200.0  # how far tanks pull back from a soft ATGM
    MARCH_STEP = 260.0    # advance step per order
    FRONT_SPREAD = 340.0  # lateral spacing between squads' approach points (waves across the front)

    def __init__(self, kb):
        self.kb = kb
        self._hp = {}         # unit id -> last-seen health (hidden-fire detection)
        self.detail = ""

    # -- role bucketing -------------------------------------------------------
    def _bucket(self, u):
        r = self.kb.fine_role(u.get("template")) if self.kb else "other"
        if r == "tank": return "tank"
        if r == "atgm": return "at"
        if r == "aa": return "aa"
        if r in ("mg_inf", "infantry", "sniper"): return "inf"
        if r in ("officer", "light_veh", "transport"): return "recon"
        if r == "artillery": return "arty"
        return "inf"

    def _is_inf_atgm(self, e):
        return "infantry" in self.kb.roles_of(e.get("template"))

    # -- order primitives -----------------------------------------------------
    def _amove(self, ctx, ids, x, y):
        if ids:
            ctx.client.command(ctx.player, list(ids), "attack_move", {"pos": {"x": x, "y": y, "z": 0.0}})

    def _attack(self, ctx, ids, tgt):
        if ids and tgt is not None:
            ctx.client.command(ctx.player, list(ids), "attack_target", {"targetId": tgt["id"]})

    # -- main entry -----------------------------------------------------------
    def command(self, ctx, force_ids, objective, units_by_id, phase, raze=None, aggressive=False,
                focus=None, terrain=None):
        kb = self.kb
        if not kb or not force_ids:
            self.detail = "no squads"
            return self.detail
        raze = [b for b in (raze or []) if "x" in b]
        self._ubid = units_by_id        # template lookups for matchup-aware targeting
        self._aggressive = aggressive   # committed assault → tanks PUSH, don't baby them
        self._terrain = terrain         # passability grid → reachable firing positions (no path-fail flood)
        # CONCENTRATION: in a committed assault every squad hammers the SAME focus building (the core /
        # production / rebuild source) instead of each razing a different structure → the base actually
        # falls before the enemy can rebuild it. None ⇒ fall back to per-squad nearest building.
        self._focus = focus if (focus and "x" in focus) else None
        pools = {"tank": [], "aa": [], "inf": [], "recon": [], "at": [], "arty": []}
        for i in force_ids:
            u = units_by_id.get(i)
            if u:
                pools[self._bucket(u)].append(i)
        size = self.SIZES.get(phase, self.SIZES["combat"])
        nsq = max(1, len(pools["tank"]) // max(1, size["tank"]))
        squads = [[] for _ in range(nsq)]
        for ids in pools.values():                 # round-robin each role pool across squads
            for k, uid in enumerate(ids):
                squads[k % nsq].append(uid)

        # visible enemy combat units, classified once. INCLUDE enemy DOZERS: they aren't "combat units"
        # (no weapon, so is_combat_unit excludes them) but they're the highest-value assault target — they
        # REBUILD every structure we raze, so the squad logic must be able to see and exterminate them.
        enemies = []
        for e in ctx.world.enemies():
            if is_building(e) or "x" not in e:
                continue
            r = kb.fine_role(e.get("template"))
            if is_combat_unit(e) or r == "dozer":
                enemies.append((r, e))

        # update hidden-fire hp tracking for all force units
        cur_hp = {i: units_by_id[i]["health"] for i in force_ids
                  if i in units_by_id and "health" in units_by_id[i]}

        ox, oy = objective
        states = []
        for si, members in enumerate(squads):
            ap = self._approach(squads, si, ox, oy, units_by_id)
            st = self._run_squad(ctx, members, units_by_id, ap, enemies, cur_hp, raze)
            if st:
                states.append(st)
        self._hp = cur_hp
        from collections import Counter
        c = Counter(states)
        self.detail = "{}sq/{} [{}]".format(nsq, phase, " ".join("{}{}".format(v, k) for k, v in c.items()))
        return self.detail

    # -- approach points: spread squads across the front --------------------
    def _approach(self, squads, si, ox, oy, ubid):
        nsq = len(squads)
        # army centroid -> objective axis, spread perpendicular
        pts = [(ubid[i]["x"], ubid[i]["y"]) for s in squads for i in s if i in ubid and "x" in ubid[i]]
        if not pts:
            return (ox, oy)
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        dx, dy = ox - cx, oy - cy
        d = math.hypot(dx, dy) or 1.0
        px, py = -dy / d, dx / d                   # perpendicular to the approach
        lateral = (si - (nsq - 1) / 2.0) * self.FRONT_SPREAD
        return (ox + px * lateral, oy + py * lateral)

    # -- per-squad tactics ----------------------------------------------------
    def _run_squad(self, ctx, members, ubid, approach, enemies, cur_hp, raze=None):
        if not members:
            return ""
        pts = [(ubid[i]["x"], ubid[i]["y"]) for i in members if i in ubid and "x" in ubid[i]]
        if not pts:
            return ""
        sx = sum(p[0] for p in pts) / len(pts)
        sy = sum(p[1] for p in pts) / len(pts)
        g = {"tank": [], "inf": [], "aa": [], "recon": [], "at": [], "arty": []}
        for i in members:
            u = ubid.get(i)
            if u:
                g[self._bucket(u)].append(i)

        def near(rng):
            return [(r, e) for (r, e) in enemies if (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2 <= rng * rng]

        def nrst(cands):
            return min(cands, key=lambda e: (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2) if cands else None

        foes = near(self.ENGAGE)
        atgms = [e for (r, e) in near(self.ATGM_TRIGGER) if r == "atgm"]
        taking_fire = any(i in self._hp and i in cur_hp and cur_hp[i] < self._hp[i] - 1 for i in members)

        nb = [b for b in (raze or []) if (b["x"] - sx) ** 2 + (b["y"] - sy) ** 2 <= self.ENGAGE ** 2]
        focus = getattr(self, "_focus", None)
        # CONCENTRATED ASSAULT: a shared focus building overrides everything — the whole army grinds the
        # SAME structure down (tanks+AT+arty on the building) while cheap cover screens the single most
        # dangerous defender. This is what makes the base fall instead of 10 squads poking 10 buildings.
        if getattr(self, "_aggressive", False) and focus is not None:
            return self._tactic_focus(ctx, g, sx, sy, focus, foes)
        # AGGRESSIVE but base not yet located: drive the WHOLE squad to the objective at full distance
        # (attack-move = auto-engage + no idling on path-fail). NOT centroid+step — otherwise units
        # spawning at home constantly drag the squad centroid back and the army never reaches the base.
        if getattr(self, "_aggressive", False):
            return self._tactic_push(ctx, g, sx, sy, approach, foes)
        if atgms:
            return self._tactic_atgm(ctx, g, sx, sy, atgms, [e for (r, e) in foes if r in ("heli", "jet")])
        # AGGRESSIVE assault: RAZE the base — tanks shoot the building, cover screens nearby defenders.
        # (Without this the squad fights the endless defenders forever and the base never falls.)
        if getattr(self, "_aggressive", False) and nb:
            return self._tactic_raze(ctx, g, sx, sy, nb, foes)
        if foes:
            return self._tactic_contact(ctx, g, sx, sy, foes)
        if nb:                                    # not aggressive but a building is in reach and no foes
            self._attack(ctx, members, min(nb, key=lambda b: (b["x"] - sx) ** 2 + (b["y"] - sy) ** 2))
            return "RAZE"
        if taking_fire:
            return self._tactic_scout(ctx, g, sx, sy, approach)
        return self._tactic_advance(ctx, g, sx, sy, approach)

    def _standoff(self, ctx, ids, building, sx, sy, dist=650.0):
        """Hold `ids` outside a garrisoned building's weapon envelope (grenadiers inside shred
        armor point-blank — walking tanks onto the doorstep was how they 'тупо вмирають')."""
        if not ids:
            return
        bx, by = building["x"], building["y"]
        dx, dy = sx - bx, sy - by
        d = math.hypot(dx, dy) or 1.0
        self._amove(ctx, ids, bx + dx / d * dist, by + dy / d * dist)

    def _raze_building(self, ctx, g, tgt, sx, sy):
        """Armor vs one building, garrison-aware: a GARRISONED structure is dug out by artillery
        from standoff range while the armor holds back out of the grenadiers' envelope; with no
        artillery on hand the tanks still engage (their gun slightly outranges the garrison) —
        stalling forever would be worse. Returns True when the garrison branch handled it."""
        if (tgt.get("contains") or 0) > 0 and g["arty"]:
            self._attack(ctx, g["arty"], tgt)
            self._standoff(ctx, g["tank"] + g["at"] + g["recon"], tgt, sx, sy)
            return True
        return False

    def _tactic_raze(self, ctx, g, sx, sy, buildings, foes):
        tgt = min(buildings, key=lambda b: (b["x"] - sx) ** 2 + (b["y"] - sy) ** 2)
        if not self._raze_building(ctx, g, tgt, sx, sy):
            self._attack(ctx, g["tank"] + g["at"] + g["arty"] + g["recon"], tgt)   # main force razes it
        if foes:                                                                # cover screens the defenders
            f = min((e for (_r, e) in foes), key=lambda e: (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2)
            self._attack(ctx, g["inf"] + g["aa"], f)
        else:
            self._attack(ctx, g["inf"] + g["aa"], tgt)
        return "RAZE!"

    BUILDING_FIRE_DIST = 420.0   # within this of the focus building → attack_target (focus-fire to raze)

    def _hit_building(self, ctx, ids, building, sx, sy):
        """Order `ids` to destroy `building`, HYBRID by distance:
          • FAR (and a passability grid is available): attack-MOVE to a REACHABLE firing position near the
            building. The approach goal is reachable, so the squad doesn't flood FindHierarchicalPath
            failures every frame trying to path onto an unreachable corner-base tile (that flood bogs the
            sim and crashes it in big fights). Attack-move clears defenders en route.
          • CLOSE (or no grid): attack_target the building — short path to firing range, and the unit
            FOCUSES the structure so it actually falls (plain firing-position attack-move regressed razing:
            units chased the defender swarm and never dropped the building)."""
        if not ids:
            return
        terr = getattr(self, "_terrain", None)
        d = math.hypot(building["x"] - sx, building["y"] - sy)
        if terr is not None and getattr(terr, "ok", False) and d > self.BUILDING_FIRE_DIST:
            fp = terr.firing_pos(building["x"], building["y"], sx, sy, weapon_range=300.0)
            self._amove(ctx, ids, fp[0], fp[1])
        else:
            self._attack(ctx, ids, building)

    def _tactic_focus(self, ctx, g, sx, sy, focus, foes):
        """CONCENTRATION: the whole squad attack_targets the SAME (sticky) focus building. attack_target
        lets the ENGINE path each unit to its own firing position and hold there — far fewer hierarchical
        path-failures than attack-moving a 70-unit blob onto one tile inside a cluttered base. The cheap
        screen (inf/AA/recon) peels onto the one thing our tanks can't trade with: ATGM > air > DOZER
        (the rebuilder — killing it is why the building we raze finally STAYS down)."""
        def nrst(cands):
            return min(cands, key=lambda e: (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2) if cands else None
        atgms = [e for (r, e) in foes if r == "atgm"]
        air = [e for (r, e) in foes if r in ("heli", "jet")]
        dozers = [e for (r, e) in foes if r == "dozer"]
        allf = [e for (_r, e) in foes]
        dz = nrst(dozers)
        if dz is not None:
            # KILL THE REBUILDERS while STILL RAZING. The enemy AI re-raises razed buildings with dozers,
            # so the dozers must die — but throwing the TANKS at them starved the building of DPS and it
            # never fell (FAC stuck). So tanks + arty keep grinding the building; the cheap recon + infantry
            # + AT (also good vs the dozer's light armour) hunt the dozer. Best of both.
            if not self._raze_building(ctx, g, focus, sx, sy):
                self._hit_building(ctx, g["tank"] + g["arty"], focus, sx, sy)
            self._attack(ctx, g["recon"] + g["inf"] + g["at"], dz)
            self._attack(ctx, g["aa"], nrst(air) or dz)
            return "DOZER!"
        if self._raze_building(ctx, g, focus, sx, sy):                  # garrisoned -> arty digs, armor stands off
            pass
        else:
            self._hit_building(ctx, g["tank"] + g["arty"], focus, sx, sy)   # mass razes from a reachable position
        # each screen role attacks its priority threat if present (units → reachable, no flood), else it
        # adds its fire to the building from a reachable firing position too. The infantry screen only
        # peels onto SOFT targets it can actually kill — never onto the defending armor (matchup rule):
        soft = [e for (r, e) in foes
                if r not in ("heli", "jet", "tank", "light_veh", "transport", "artillery", "aa", "atgm")]
        at_t, air_t, soft_t = nrst(atgms), nrst(air), nrst(soft)
        self._attack(ctx, g["at"], at_t) if at_t else self._hit_building(ctx, g["at"], focus, sx, sy)
        self._attack(ctx, g["aa"], air_t) if air_t else self._hit_building(ctx, g["aa"], focus, sx, sy)
        if soft_t:
            self._attack(ctx, g["inf"] + g["recon"], soft_t)
        else:
            self._hit_building(ctx, g["inf"] + g["recon"], focus, sx, sy)
        return "RAZE!"

    def _tactic_push(self, ctx, g, sx, sy, approach, foes):
        """Committed assault, enemy base not yet pinpointed. If anything is in sight → attack_target it
        (engine paths to firing range — few path-fails — and the contact drags us toward the base). If
        NOTHING is visible → attack-MOVE toward the objective across open ground to FIND the base. We only
        attack-move when blind, because attack-moving a blob ONTO a cluttered base tile path-fails en masse."""
        def nrst(cands):
            return min(cands, key=lambda e: (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2) if cands else None
        if foes:
            # fight by MATCHUP, not by proximity — charging the nearest foe fed MG infantry to
            # tanks and ordered ground units at helicopters they cannot hit (user feedback)
            self._engage_by_matchup(ctx, g, sx, sy, foes)
            return "PUSH*"
        ox, oy = approach
        terr = getattr(self, "_terrain", None)
        if terr is not None and getattr(terr, "ok", False):
            snapped = terr.nearest_clear(ox, oy)        # don't march the whole force at an unreachable tile
            if snapped:
                ox, oy = snapped
        d = math.hypot(ox - sx, oy - sy) or 1.0
        ax, ay = (ox - sx) / d, (oy - sy) / d
        self._amove(ctx, g["recon"] + g["inf"], ox + ax * 30, oy + ay * 30)   # screen leads the march
        self._amove(ctx, g["tank"] + g["at"] + g["arty"] + g["aa"], ox, oy)   # mass right behind
        return "PUSH"

    def _tactic_advance(self, ctx, g, sx, sy, approach):
        ox, oy = approach
        d = math.hypot(ox - sx, oy - sy) or 1.0
        ax, ay = (ox - sx) / d, (oy - sy) / d
        step = min(d, self.MARCH_STEP)
        bx, by = sx + ax * step, sy + ay * step
        self._amove(ctx, g["recon"], bx + ax * 40, by + ay * 40)   # recon scouts ahead
        self._amove(ctx, g["inf"], bx, by)                          # infantry lead
        self._amove(ctx, g["at"], bx - ax * 60, by - ay * 60)
        self._amove(ctx, g["aa"], bx - ax * 100, by - ay * 100)     # AA mid
        self._amove(ctx, g["tank"], bx - ax * 150, by - ay * 150)   # tanks behind (safe)
        self._amove(ctx, g["arty"], bx - ax * 210, by - ay * 210)
        return "ADV"

    # -- matchup-aware engagement ---------------------------------------------
    # The user's verdict on the old logic was exact: "юніти біжуть в тупу вперед" — every group
    # attack_target'ed the NEAREST foe, so MG infantry charged tanks they cannot scratch, ground
    # units were ordered at helicopters they cannot hit, and the enemy's counter-units ate us.
    # Now every role group picks the best target CLASS it actually HURTS (combat_eval counter
    # matrix), and a group with nothing it can hurt FALLS BACK behind the squad instead of feeding.
    def _engage_by_matchup(self, ctx, g, sx, sy, foes, building=None):
        kb = self.kb

        def nrst(cands):
            return min(cands, key=lambda e: (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2) if cands else None
        cls = {"air": [], "armor": [], "soft": []}
        for r, e in foes:
            if r in ("heli", "jet"):
                cls["air"].append(e)
            elif r in ("tank", "light_veh", "transport", "artillery", "aa", "atgm", "dozer"):
                cls["armor"].append(e)
            else:
                cls["soft"].append(e)

        def rep_template(ids):
            counts = {}
            for i in ids:
                u = self._ubid.get(i) if hasattr(self, "_ubid") else None
                t = u.get("template") if u else None
                if t:
                    counts[t] = counts.get(t, 0) + 1
            return max(counts, key=counts.get) if counts else None

        def pick(ids, prefer):
            t = rep_template(ids)
            # only trust the hurt-filter when this template HAS effectiveness data — coverage gaps
            # (130/769 rows) must degrade to class preference, not to "never fight anything"
            filt = bool(t and kb and kb.eff_row(t))
            for c in prefer:
                cands = cls[c]
                if not cands:
                    continue
                if filt:
                    cands = [e for e in cands
                             if (combat_eval.counter_score_strict(kb, t, e.get("template")) or 0.0) > 0.05]
                tgt = nrst(cands)
                if tgt is not None:
                    return tgt
            return None

        def fallback(ids):
            """Nothing this group can hurt is here, but something can hurt THEM -> kite behind the
            squad (away from the nearest foe), don't stand and feed the counter-unit."""
            if not ids:
                return
            f = nrst([e for lst in cls.values() for e in lst])
            if f is None:
                return
            ax, ay = sx - f["x"], sy - f["y"]
            d = math.hypot(ax, ay) or 1.0
            self._amove(ctx, ids, sx + ax / d * 240.0, sy + ay / d * 240.0)

        def engage(ids, prefer, may_hit_building=False):
            if not ids:
                return
            tgt = pick(ids, prefer)
            if tgt is not None:
                self._attack(ctx, ids, tgt)
            elif may_hit_building and building is not None:
                self._hit_building(ctx, ids, building, sx, sy)
            else:
                fallback(ids)

        engage(g["aa"], ("air", "armor", "soft"))
        engage(g["tank"], ("armor", "soft"), may_hit_building=True)
        engage(g["at"], ("armor",))                       # AT vs infantry is feeding — fall back instead
        engage(g["inf"] + g["recon"], ("soft",))          # rifles/MG never charge tanks they can't dent
        engage(g["arty"], ("soft", "armor"), may_hit_building=True)   # splash hurts everything

    def _tactic_contact(self, ctx, g, sx, sy, foes):
        self._engage_by_matchup(ctx, g, sx, sy, foes)
        return "FIGHT"

    def _tactic_atgm(self, ctx, g, sx, sy, atgms, heli):
        inf_atgm = [e for e in atgms if self._is_inf_atgm(e)]
        veh_atgm = [e for e in atgms if not self._is_inf_atgm(e)]

        def nrst(cands):
            return min(cands, key=lambda e: (e["x"] - sx) ** 2 + (e["y"] - sy) ** 2) if cands else None
        cover = g["inf"] + g["aa"] + g["recon"]
        # AGGRESSIVE (committed assault): don't baby the tanks — focus-fire the ATGM and push through it.
        if getattr(self, "_aggressive", False):
            tgt = nrst(veh_atgm) or nrst(inf_atgm)
            self._attack(ctx, g["tank"] + g["at"] + cover, tgt)
            return "ATGM!"
        if veh_atgm:
            # armoured launcher (BMP/Bradley): tanks+AT are the only counter — engage it; cover supports
            tgt = nrst(veh_atgm)
            self._attack(ctx, g["tank"] + g["at"], tgt)
            self._attack(ctx, cover, tgt)
            return "ATGMv"
        # soft infantry ATGM: cover HOLDS and kills it; tanks pull back (preserve), one scouts a hidden one
        tgt = nrst(inf_atgm)
        self._attack(ctx, cover, tgt)
        ax, ay = sx - tgt["x"], sy - tgt["y"]
        d = math.hypot(ax, ay) or 1.0
        rx, ry = sx + ax / d * self.RETREAT_DIST, sy + ay / d * self.RETREAT_DIST
        tanks = g["tank"]
        if len(tanks) >= 2:
            self._amove(ctx, [tanks[0]], tgt["x"], tgt["y"])   # one scouts/reveals + can finish it
            self._amove(ctx, tanks[1:], rx, ry)                # the rest fall back
        else:
            self._amove(ctx, tanks, rx, ry)
        self._amove(ctx, g["at"], rx, ry)
        return "ATGMi"

    def _tactic_scout(self, ctx, g, sx, sy, approach):
        ox, oy = approach
        scout = (g["recon"][:1] or g["tank"][:1])
        self._amove(ctx, scout, ox, oy)                        # reveal the hidden shooter
        hold = [i for i in (g["inf"] + g["aa"] + g["at"] + g["arty"] + g["tank"]) if i not in scout]
        self._amove(ctx, hold, sx, sy)                          # the rest hold position
        return "SCOUT"
