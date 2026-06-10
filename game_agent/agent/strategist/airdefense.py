"""airdefense.py — USSR-doctrine air-defence brain (the user's per-unit AA playbook).

Owns the AA units that are NOT already held by an outpost or committed in the assault column, and
assigns each by ARCHETYPE per the user's doctrine (reference_ussr_aa_doctrine):

  FIGHTER (MiG-29 / Su-27)  loiter over the base; SCRAMBLE to a friendly that is being hit by air
                            with no ground AA in reach (counter-air on call). Keep min ~4.
  SA-11    (Buk, long range) forward ZONE-DENIAL: scattered standoff points toward the enemy and
                            across the centre, to deny their aircraft the sky.
  SA-9     (mobile, fragile) BASE PERIMETER (2-3) + hit-and-hide: dart at an air threat near home,
                            then fall back. Dies fast, so it never holds a static forward spot.
  MANPADS  (InfAntiAir)     weak — point-defence pairs at the base (ideally garrisoned; see task #27).
  SHILKA   (mass gun-AA)    must never sit ALONE: a loose Shilka is routed to the nearest owned flag
                            to patrol/cover (the bulk ride with outposts + the assault column).

What this module deliberately does NOT touch: AA already inside an outpost detachment, or AA in the
active assault pool — the outpost logic and SquadSystem keep those with their groups. AirDefense only
claims the SURPLUS, so the three legs (posts / march / standing air-defence) all stay covered.
"""
import math


class AirDefense:
    FIGHTER_MIN = 4
    SA9_PERIMETER = 3
    MANPADS_HOME = 2
    REISSUE = 180
    BASE_RING = 520.0          # radius of the base air-defence ring
    AIR_NEAR = 1100.0          # an air threat within this of the base triggers SA-9 hit-and-hide
    SCRAMBLE_R = 2600.0        # fighters scramble to an air-hunted friendly within this of base

    def __init__(self, kb):
        self.kb = kb
        self._ordered = {}      # uid -> (intent_key, frame) — reissue only on change / staleness
        self.claimed = set()
        self.detail = ""

    # -- archetype ------------------------------------------------------------
    def _arch(self, template):
        t = (template or "").lower()
        if not self.kb:
            return None
        role = self.kb.fine_role(template)
        if role in ("jet", "heli") and self.kb.is_armed(template) and "aa" in self.kb.roles_of(template):
            return "fighter"                    # an air unit that can shoot air = interceptor
        if "sa11" in t or "sa-11" in t:
            return "sa11"
        if "sa9" in t or "sa-9" in t:
            return "sa9"
        if "shilka" in t:
            return "shilka"
        if role == "aa" and "infantry" in self.kb.roles_of(template):
            return "manpads"
        if role == "aa":
            return "sa9"                        # other mobile SAMs behave like SA-9 (mobile point AA)
        return None

    # -- helpers --------------------------------------------------------------
    def _cmd(self, ctx, uid, verb, params, key):
        """Issue once per (uid, intent) — re-issue only when the intent changes or goes stale."""
        prev = self._ordered.get(uid)
        if prev and prev[0] == key and ctx.frame - prev[1] < self.REISSUE:
            return
        self._ordered[uid] = (key, ctx.frame)
        ctx.client.command(ctx.player, [uid], verb, params)

    def _guard(self, ctx, uid, x, y, key):
        self._cmd(ctx, uid, "guard_zone",
                  {"anchor": {"x": x, "y": y}, "engage": {"x": x, "y": y}}, key)

    def _amove(self, ctx, uid, x, y, key):
        self._cmd(ctx, uid, "attack_move", {"pos": {"x": x, "y": y, "z": 0.0}}, key)

    def _air_threats(self, ctx):
        out = []
        for e in ctx.world.enemies():
            if "x" in e and self.kb and self.kb.fine_role(e.get("template")) in ("heli", "jet"):
                out.append(e)
        return out

    def _scramble_point(self, ctx, base):
        """A friendly being hit by AIR right now -> where the fighters are needed (counter-air)."""
        tt = getattr(ctx, "threats", None)
        if not tt:
            return None
        from agent.skills.base import my_units, my_buildings
        mine = {u.get("id"): u for u in my_units(ctx) + my_buildings(ctx) if "x" in u}
        enemies = {e.get("id"): e for e in ctx.world.enemies()}
        best, bestd = None, None
        try:
            events = tt.threats(ctx.frame)
        except Exception:  # noqa: BLE001
            return None
        for t in events:
            v = mine.get(t.get("victimId"))
            a = enemies.get(t.get("topAttacker"))
            if not v or not a:
                continue
            if self.kb and self.kb.fine_role(a.get("template")) in ("heli", "jet"):
                d = math.hypot(v["x"] - base[0], v["y"] - base[1]) if base else 0
                if d <= self.SCRAMBLE_R and (bestd is None or d < bestd):
                    best, bestd = (v["x"], v["y"]), d
        return best

    # -- main -----------------------------------------------------------------
    def assign(self, ctx, pool, assigned, base, objective, im):
        """Claim surplus AA from `pool` and command it per doctrine. Returns the claimed count;
        claimed ids are in self.claimed so the caller drops them from the offensive pool."""
        self.claimed = set()
        if not base or not self.kb:
            self.detail = ""
            return 0
        buckets = {"fighter": [], "sa11": [], "sa9": [], "manpads": [], "shilka": []}
        for u in pool:
            if u["id"] in assigned:
                continue
            a = self._arch(u.get("template"))
            if a in buckets:
                buckets[a].append(u)
        self._ordered = {k: v for k, v in self._ordered.items()
                         if ctx.frame - v[1] < self.REISSUE * 4}

        # FIGHTERS — loiter over base, scramble to an air-hunted friendly
        scramble = self._scramble_point(ctx, base)
        for u in buckets["fighter"]:
            if scramble:
                self._amove(ctx, u["id"], scramble[0], scramble[1], "scramble")
            else:
                self._guard(ctx, u["id"], base[0], base[1], "loiter")
            self.claimed.add(u["id"])

        # SA-11 — forward zone-denial: scatter at standoff toward the enemy (and centre)
        sa11 = buckets["sa11"]
        if sa11:
            tx, ty = objective or (base[0], base[1])
            dx, dy = tx - base[0], ty - base[1]
            d = math.hypot(dx, dy) or 1.0
            ux, uy = dx / d, dy / d
            px, py = -uy, ux
            for i, u in enumerate(sa11):
                frac = 0.45 + 0.12 * (i % 3)              # staggered depth toward the enemy
                lat = ((i % 5) - 2) * 360.0               # spread laterally
                sx = base[0] + dx * frac + px * lat
                sy = base[1] + dy * frac + py * lat
                if im is None or ctx.world.passable(sx, sy):
                    self._guard(ctx, u["id"], sx, sy, "sa11:{}".format(i))
                    self.claimed.add(u["id"])

        # SA-9 — base perimeter ring + hit-and-hide on a near air threat
        air = self._air_threats(ctx)
        near_air = [e for e in air
                    if (e["x"] - base[0]) ** 2 + (e["y"] - base[1]) ** 2 <= self.AIR_NEAR ** 2]
        sa9 = sorted(buckets["sa9"], key=lambda u: (u["x"] - base[0]) ** 2 + (u["y"] - base[1]) ** 2)
        perim = sa9[:self.SA9_PERIMETER]
        for i, u in enumerate(perim):
            if near_air:                                  # dart at the closest intruder, then fall back
                tgt = min(near_air, key=lambda e: (e["x"] - u["x"]) ** 2 + (e["y"] - u["y"]) ** 2)
                self._cmd(ctx, u["id"], "attack_target", {"targetId": tgt["id"]}, "sa9hit")
            else:
                ang = (i / max(1, len(perim))) * 2 * math.pi
                self._guard(ctx, u["id"], base[0] + math.cos(ang) * self.BASE_RING,
                            base[1] + math.sin(ang) * self.BASE_RING, "sa9ring:{}".format(i))
            self.claimed.add(u["id"])
        # surplus SA-9 spread the map as interceptors (toward owned flags / forward)
        for i, u in enumerate(sa9[self.SA9_PERIMETER:]):
            fx, fy = self._spread_point(ctx, base, objective, i)
            self._guard(ctx, u["id"], fx, fy, "sa9spread:{}".format(i))
            self.claimed.add(u["id"])

        # MANPADS — keep a weak point-defence pair at the base (garrison TODO, task #27)
        man = sorted(buckets["manpads"], key=lambda u: (u["x"] - base[0]) ** 2 + (u["y"] - base[1]) ** 2)
        for u in man[:self.MANPADS_HOME]:
            self._guard(ctx, u["id"], base[0], base[1], "manpads")
            self.claimed.add(u["id"])

        # SHILKA — never alone: route a LOOSE shilka (far from base and from the army) to the nearest
        # owned flag to patrol/cover. Shilkas with posts / the assault are left to those systems.
        flags = [u for u in ctx.world.units
                 if u.get("player") == ctx.player and "x" in u
                 and "flag" in (u.get("template") or "").lower()]
        army_pts = [(u["x"], u["y"]) for u in pool if u["id"] not in self.claimed and "x" in u]
        for u in buckets["shilka"]:
            if not flags:
                break
            near_group = any((u["x"] - ax) ** 2 + (u["y"] - ay) ** 2 <= 600.0 ** 2 for ax, ay in army_pts)
            if near_group:
                continue                                  # already with a group -> leave it
            f = min(flags, key=lambda fl: (fl["x"] - u["x"]) ** 2 + (fl["y"] - u["y"]) ** 2)
            self._guard(ctx, u["id"], f["x"], f["y"], "shilkaflag")
            self.claimed.add(u["id"])

        for uid in self.claimed:
            assigned.add(uid)
        c = {k: len(v) for k, v in buckets.items() if v}
        self.detail = " ".join("{}{}".format(v, k[:3]) for k, v in c.items())
        return len(self.claimed)

    def _spread_point(self, ctx, base, objective, i):
        W = (ctx.world.width or 0) * (ctx.world.cell or 10)
        H = (ctx.world.height or 0) * (ctx.world.cell or 10)
        if objective:
            mx = (base[0] + objective[0]) / 2.0
            my = (base[1] + objective[1]) / 2.0
        else:
            mx, my = W * 0.5, H * 0.5
        ang = (i * 2.399)                                 # golden-angle scatter around the midfield
        return (mx + math.cos(ang) * 700.0, my + math.sin(ang) * 700.0)
