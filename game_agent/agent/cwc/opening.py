"""OpeningScript — the dictated CWC opening, as an additive, low-risk overlay.

The user specified a precise opening: dozer -> fuel depot (the war-factory tech
gate) -> barracks -> drop zone -> 3 capturer infantry -> war factory -> a
machine-gun Humvee + an AT Humvee + engineers, with engineers loaded into every
transport with free slots so they repair the vehicles; then mass AA near fuel/flag
points to deny captures.

Design choice (see COMMANDER_PLAN.md): this does NOT micro-manage dozers (that
caused contention bugs before).  It REUSES the proven BuildBaseSkill for placement
and only:
  - shapes the build ROLE ORDER to the dictated sequence,
  - bursts the 3 capturers as soon as the barracks is up,
  - on the war factory, ensures an MG Humvee + AT Humvee + engineer are queued,
  - garrisons idle engineers into friendly transports/vehicles (auto-repair) — a
    standing behaviour that keeps running after the opening,
then hands back to the standing orders (which are now counter-aware).  AA denial
lives in the defense goal (P3).

Everything is guarded on world state, not timers, and degrades to no-op without a
KnowledgeBase, so it never stalls or fights the main loop.
"""
from agent.skills.base import (
    my_units, my_buildings, select_combat_units, capture_capable_units,
    find_trainable, find_producer, is_building,
)

# build order the user dictated: fuel(power) first as the war-factory gate, then
# barracks, war factory, drop zone (airfield-class), then defenses.
OPENING_ROLES = ["power", "barracks", "warfactory", "airfield", "defense"]


def _is_engineer(kb, u):
    t = (u.get("template") or "")
    if "engineer" in t.lower():
        return True
    return bool(kb and "repair" in kb.roles_of(t) and "INFANTRY"
                in (kb.stat(t) or {}).get("kindOf", []))


def _is_transport(kb, u):
    """A friendly vehicle that carries passengers (slots), not a passenger itself."""
    t = (u.get("template") or "")
    if not kb:
        return "transport" in (u.get("tags") or [])
    st = kb.stat(t) or {}
    if (st.get("TransportSlotCount", 0) or 0) > 0:
        return False                      # >0 means it OCCUPIES slots (a passenger)
    return "transport" in kb.roles_of(t) and "dozer" not in kb.roles_of(t)


class OpeningScript:
    GARRISON_PERIOD = 60      # frames between engineer-loading sweeps
    TRANSPORT_CAP = 4         # assume room until this many passengers

    def __init__(self, kb):
        self.kb = kb
        self.done = False
        self.detail = "init"
        self._roles_set = False
        self._cap_burst = False
        self._vehicles_ordered = False
        self._last_garrison = -10 ** 9

    # -- helpers -----------------------------------------------------------
    def _have_role(self, cmdr, ctx, role):
        return cmdr._count_role(ctx, role) > 0

    def _wheeled(self, ctx, want_role):
        """A trainable wheeled/light vehicle of the wanted combat role (MG=anti_inf,
        AT=anti_tank), cheapest first.  Faction-agnostic via KB roles."""
        kb = self.kb
        def pred(tl, e):
            if e.get("how") != "train":
                return False
            roles = kb.roles_of(tl) if kb else set()
            return ("vehicle" in roles and want_role in roles
                    and "structure" not in roles)
        cands = find_trainable(ctx, pred)
        cands.sort(key=lambda x: x[2])
        return cands[0] if cands else None

    # -- main tick ---------------------------------------------------------
    def tick(self, cmdr, ctx):
        """Run the opening overlay.  Returns True while the opening still owns the
        early shaping (caller still runs the normal loop; we only ADD orders)."""
        if not self._roles_set:
            cmdr.build.DEFAULT_ROLES = list(OPENING_ROLES)
            self._roles_set = True

        # engineers -> transports (auto-repair); standing, also runs post-opening
        self._garrison_engineers(ctx)

        have_rax = self._have_role(cmdr, ctx, "barracks")
        have_wf = self._have_role(cmdr, ctx, "warfactory")

        # burst the 3 capturers the moment the barracks is up (the user's step 5)
        if have_rax and not self._cap_burst:
            self._burst_capturers(ctx, n=3)
            self._cap_burst = True

        # on the war factory: ensure an MG Humvee + AT Humvee + engineer (step 8/9)
        if have_wf and not self._vehicles_ordered:
            self._order_opening_vehicles(ctx)
            self._vehicles_ordered = True

        if have_wf and self._vehicles_ordered:
            # hand back to the standing (counter-aware) production once vehicles flow
            self.done = True
            self.detail = "complete -> standing orders"
            return False
        self.detail = "rax={} wf={} capBurst={}".format(
            int(have_rax), int(have_wf), int(self._cap_burst))
        return True

    # -- behaviours --------------------------------------------------------
    def _burst_capturers(self, ctx, n=3):
        cap_set = set()
        if self.kb:
            cap_set = {c.lower() for c in self.kb.capturers()}
        from agent.skills import base as _b
        if not cap_set:
            cap_set = {c.lower() for c in (_b.CAPTURE_TEMPLATES or set())}
        cands = find_trainable(ctx, lambda tl, e: e.get("how") == "train"
                               and tl.lower() in cap_set)
        if not cands:
            return
        tmpl, builder, cost, _e = sorted(cands, key=lambda x: x[2])[0]
        money = ctx.me.get("money") or 0
        made = 0
        for _ in range(n):
            if money < cost or not builder:
                break
            ctx.client.command(ctx.player, [builder], "train_unit",
                                {"template": tmpl, "count": 1})
            money -= cost
            made += 1

    def _order_opening_vehicles(self, ctx):
        money = ctx.me.get("money") or 0
        wants = [self._wheeled(ctx, "anti_inf"), self._wheeled(ctx, "anti_tank")]
        # engineer too (rides the Humvee for repair)
        eng = find_trainable(ctx, lambda tl, e: e.get("how") == "train"
                             and "engineer" in tl.lower())
        if eng:
            wants.append(sorted(eng, key=lambda x: x[2])[0])
        for w in wants:
            if not w:
                continue
            tmpl, builder, cost, _e = w
            if builder and money >= cost:
                ctx.client.command(ctx.player, [builder], "train_unit",
                                    {"template": tmpl, "count": 1})
                money -= cost

    def _garrison_engineers(self, ctx):
        """Load idle engineers into friendly transports/vehicles with free slots so
        they continuously repair the vehicle (the user's explicit doctrine)."""
        if ctx.frame - self._last_garrison < self.GARRISON_PERIOD:
            return
        kb = self.kb
        units = my_units(ctx)
        engineers = [u for u in units if _is_engineer(kb, u)
                     and not u.get("contains")           # not already inside
                     and (u.get("contains") is None)]
        # engineers that are passengers won't appear free; only ground ones do
        free_eng = [u for u in engineers]
        transports = [u for u in units if _is_transport(kb, u)
                      and (u.get("contains") or 0) < self.TRANSPORT_CAP]
        if not free_eng or not transports:
            return
        self._last_garrison = ctx.frame
        # pair nearest engineer to each transport with room
        import math
        used = set()
        for tr in transports:
            cand = [e for e in free_eng if e["id"] not in used]
            if not cand:
                break
            e = min(cand, key=lambda u: math.hypot(
                (u.get("x", 0) - tr.get("x", 0)), (u.get("y", 0) - tr.get("y", 0))))
            used.add(e["id"])
            ctx.client.command(ctx.player, [e["id"]], "garrison",
                               {"targetId": tr["id"]})
