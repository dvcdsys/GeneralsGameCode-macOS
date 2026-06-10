"""stance.py — CWC infantry stance & weapon-mode doctrine (prone / stand / AT toggle).

CWC infantry change stance through FakeRider SpecialPowers exposed per unit in /catalog
abilities (SpecialAbilityCWC{ru,us}FakeRider_Inf_Prone / _Inf_Stand / _Inf_Stand_AT / ...).
A human player constantly uses them: prone infantry holding ground is far harder to kill,
and dual-weapon infantry swaps to the AT launcher when armor rolls in. The bot never doing
this both reads as scripted and costs real strength (the user's direct feedback).

Doctrine here, applied each tick from the army controller:
  HOLDERS (home guard, outpost garrisons, the massing main force) -> PRONE; if the unit has
  an AT mode and enemy ARMOR is near, the AT variant of the stance is preferred.
  MOVERS (retreaters, harass squads, the committed assault, scouts) -> STAND first, so they
  travel at full speed instead of crawling.

Engine mechanics: the special_power verb with no target self-toggles the group
(groupDoSpecialPower). Orders are batched per power name, issued only on a state CHANGE,
and rate-limited per unit so the doctrine never spams the engine.
"""

_PRONE, _STAND, _PRONE_AT, _STAND_AT = "prone", "stand", "prone_at", "stand_at"


class StanceDoctrine:
    TOGGLE_COOLDOWN = 150        # frames between stance orders for one unit
    ARMOR_NEAR = 700.0           # enemy armor within this of the unit -> prefer the AT mode

    def __init__(self, kb):
        self.kb = kb
        self._state = {}         # uid -> last stance we ordered (engine default = stand)
        self._last = {}          # uid -> frame of our last toggle order
        self._powers = {}        # template -> {stance_key: power name}

    def _powers_of(self, template):
        p = self._powers.get(template)
        if p is not None:
            return p
        p = {}
        for a in (self.kb.catalog_abilities(template) if self.kb else []) or []:
            if "FakeRider" not in a:
                continue
            al = a.lower()
            if al.endswith("_inf_prone"):
                p[_PRONE] = a
            elif al.endswith("_inf_stand"):
                p[_STAND] = a
            elif al.endswith("_inf_prone_at"):
                p[_PRONE_AT] = a
            elif al.endswith("_inf_stand_at"):
                p[_STAND_AT] = a
        self._powers[template] = p
        return p

    def _want_holding(self, powers, armor_near):
        # armor rolling in -> the AT weapon beats prone cover (rifles do nothing to tanks)
        if armor_near and _PRONE_AT in powers:
            return _PRONE_AT
        if armor_near and _STAND_AT in powers:
            return _STAND_AT
        if _PRONE in powers:
            return _PRONE
        return None

    def _want_moving(self, powers, cur):
        # only stand a unit up if WE put it down (or switched its weapon mode)
        if cur in (_PRONE, _PRONE_AT, _STAND_AT) and _STAND in powers:
            return _STAND
        return None

    def apply(self, ctx, holders, movers):
        """holders/movers: lists of unit dicts. Issues batched special_power toggles."""
        enemy_armor = []
        if holders and self.kb:
            for e in ctx.world.enemies():
                t = e.get("template")
                if t and "x" in e and self.kb.fine_role(t) in ("tank", "mbt", "light_veh"):
                    enemy_armor.append((e["x"], e["y"]))
        batches = {}

        def order(u, want):
            uid = u["id"]
            if want is None or self._state.get(uid, _STAND) == want:
                return
            if ctx.frame - self._last.get(uid, -10 ** 9) < self.TOGGLE_COOLDOWN:
                return
            powers = self._powers_of(u.get("template"))
            self._state[uid] = want
            self._last[uid] = ctx.frame
            batches.setdefault(powers[want], []).append(uid)

        for u in holders:
            powers = self._powers_of(u.get("template"))
            if not powers:
                continue
            armor_near = any((u.get("x", 0) - ax) ** 2 + (u.get("y", 0) - ay) ** 2
                             <= self.ARMOR_NEAR ** 2 for ax, ay in enemy_armor)
            order(u, self._want_holding(powers, armor_near))
        for u in movers:
            powers = self._powers_of(u.get("template"))
            if not powers:
                continue
            order(u, self._want_moving(powers, self._state.get(u["id"], _STAND)))

        for power, ids in batches.items():
            ctx.client.command(ctx.player, ids, "special_power", {"power": power})
        # forget dead units occasionally so the maps don't grow forever
        if len(self._state) > 400:
            live = {u["id"] for u in holders} | {u["id"] for u in movers}
            self._state = {k: v for k, v in self._state.items() if k in live}
            self._last = {k: v for k, v in self._last.items() if k in live}
        return sum(len(v) for v in batches.values())
