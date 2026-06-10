"""playbook.py — curated CWC faction knowledge for the Strategist.

Loaded once from cwc_data/playbook.json (mined + cross-verified from the KB tables).
It is the PREFERENCE / DOCTRINE layer:
  - template -> tactical role (mbt, at_inf, aa_veh, heli, arty, ...) — cleaner than keyword guessing
  - template -> threat class (air / armor / infantry / arty) — for reactive composition
  - per-faction army-composition preferences (which templates to mass for each NEED:
    core / anti_armor / anti_air / anti_inf / siege / air / support)
  - per-faction build order + tech notes
  - counter doctrine (which target classes each of my roles should prioritise firing on)

It is NOT the gating authority: whether a unit can be built RIGHT NOW (tech/money/power) is
read live from /buildable (canMake). The playbook only says what is GOOD to build and what it
counters. Everything degrades to empty/None if the file is missing, so the bot still runs on the
KB's keyword roles alone.
"""
import json
import os

_PB_PATH = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "cwc_data", "playbook.json"))

# role -> coarse threat class (what kind of enemy is this, for reactive comp & AA/AT/anti-inf needs)
_ROLE_CLASS = {
    "heli": "air", "jet": "air",
    "mbt": "armor", "ifv": "armor", "light_at": "armor", "aa_veh": "armor",
    "recon": "armor", "transport": "armor",
    "arty": "arty",
    "at_inf": "infantry", "aa_inf": "infantry", "rifle_inf": "infantry",
    "mg_inf": "infantry", "sniper": "infantry", "engineer": "infantry",
    "medic": "infantry", "officer": "infantry",
}


class Playbook:
    def __init__(self, path=_PB_PATH):
        self.loaded = False
        self.factions = {}          # prefix -> faction dict
        self.role = {}              # template -> role
        self.need = {}              # template -> set(needs it serves)
        self.tier = {}              # template -> tech tier (1 early .. 3 late)
        self.air_kind = {}          # air template -> 'air_superiority' | 'ground_attack'
        self.counters = {}
        self._target_prio = {}      # my_role -> [enemy target classes]
        try:
            with open(path) as f:
                pb = json.load(f)
            for fac in pb.get("factions", []):
                pfx = fac.get("prefix")
                if not pfx:
                    continue
                self.factions[pfx] = fac
                for u in fac.get("combat_units", []):
                    t = u.get("template")
                    if not t:
                        continue
                    self.role[t] = u.get("role")
                    self.tier[t] = u.get("tier") or 1
                    if u.get("role") in ("jet", "heli"):
                        # air that's best vs aircraft = interceptor; everything else = CAS/ground attack
                        self.air_kind[t] = ("air_superiority" if u.get("best_vs") == "aircraft"
                                            else "ground_attack")
                for comp in fac.get("army_comp", []):
                    need = comp.get("need")
                    for t in comp.get("templates", []):
                        self.need.setdefault(t, set()).add(need)
            self.counters = pb.get("counters", {})
            for rp in self.counters.get("role_priority_vs", []):
                mr = rp.get("my_role")
                if mr:
                    self._target_prio[mr] = rp.get("prefers_targets", [])
            self.loaded = bool(self.factions)
        except Exception:  # noqa: BLE001 — missing/garbage file -> empty playbook, KB still works
            self.loaded = False

    # -- per-template -----------------------------------------------------------
    def role_of(self, template):
        return self.role.get(template)

    def tier_of(self, template):
        """Tech tier 1 (early) .. 3 (late). Used to INFER enemy rank from scouted units."""
        return self.tier.get(template, 1)

    def air_kind_of(self, template):
        """'air_superiority' (best vs aircraft) | 'ground_attack' (CAS/anti-tank) | None."""
        return self.air_kind.get(template)

    def threat_class(self, template, kb=None):
        """air / armor / infantry / arty / other — for deciding what counters the enemy fields."""
        r = self.role.get(template)
        if r:
            return _ROLE_CLASS.get(r, "other")
        if kb:
            fr = kb.fine_role(template)
            m = {"heli": "air", "jet": "air", "tank": "armor", "light_veh": "armor",
                 "atgm": "armor", "transport": "armor", "aa": "armor", "artillery": "arty",
                 "mg_inf": "infantry", "infantry": "infantry", "sniper": "infantry",
                 "officer": "infantry", "engineer": "infantry", "medic": "infantry"}
            return m.get(fr, "other")
        return "other"

    # -- per-faction composition ------------------------------------------------
    def faction(self, prefix):
        return self.factions.get(prefix)

    def need_templates(self, prefix, need):
        """Preferred templates (in doctrine order) for a composition NEED, for this faction."""
        fac = self.factions.get(prefix)
        if not fac:
            return []
        for comp in fac.get("army_comp", []):
            if comp.get("need") == need:
                return list(comp.get("templates", []))
        return []

    def build_order(self, prefix):
        fac = self.factions.get(prefix)
        return fac.get("build_order", []) if fac else []

    def needs_of(self, template):
        return self.need.get(template, set())

    # -- counter doctrine -------------------------------------------------------
    def target_priority(self, my_role):
        """Ordered enemy target-class keywords this role should prefer to shoot."""
        return self._target_prio.get(my_role, [])


_SINGLETON = None


def get_playbook():
    global _SINGLETON
    if _SINGLETON is None:
        _SINGLETON = Playbook()
    return _SINGLETON
