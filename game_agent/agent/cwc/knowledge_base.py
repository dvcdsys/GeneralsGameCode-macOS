"""KnowledgeBase — runtime loader for the committed CWC knowledge tables.

Loads cwc_data/tables/*.json once per match and exposes template-keyed lookups
(the same template names the engine uses in /units and /catalog).  Every accessor
degrades to None/empty so a missing table or template never breaks gameplay — the
Commander's existing keyword/role fallbacks (_ROLE_HINTS etc.) remain the floor.

The runtime /catalog is authoritative for cost/prereqs/canCapture *right now*; the
KB supplies the combat numbers the catalog lacks (weapon dps/range/damageType,
armor multipliers, vision, HP) and the precomputed counter matrix.
"""
import json
import os

_TABLES_DIR = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "cwc_data", "tables"))

_TABLE_FILES = {
    "units": "units.json",
    "weapons": "weapons.json",
    "armor": "armor_matrix.json",
    "abilities": "abilities.json",
    "roles": "roles.json",
    "effectiveness": "effectiveness.json",
    "tech": "tech_tree.json",
    "meta": "meta.json",
}


class KnowledgeBase:
    def __init__(self, tables_dir=_TABLES_DIR):
        self.dir = tables_dir
        self.units = {}
        self.weapons = {}
        self.armor = {}
        self.abilities = {}
        self.roles = {}
        self.effectiveness = {}
        self.tech = {}
        self.meta = {}
        self.loaded = False
        # template -> armor name, cached for effectiveness lookups
        self._armor_of = {}
        # catalog augmentation (canCapture/abilities resolved live)
        self._catalog_capture = set()

    # -- lifecycle ---------------------------------------------------------
    def load(self):
        for attr, fn in _TABLE_FILES.items():
            p = os.path.join(self.dir, fn)
            try:
                with open(p) as f:
                    setattr(self, attr, json.load(f))
            except Exception:  # noqa: BLE001 - missing/garbage table => empty
                setattr(self, attr, {})
        self._armor_of = {n: o.get("armor") for n, o in self.units.items()
                          if o.get("armor")}
        self.loaded = bool(self.units)
        return self.loaded

    def merge_catalog(self, catalog):
        """Fold authoritative live data from /catalog (list of template dicts).
        We trust the engine for canCapture (CWC capture is unit-specific)."""
        if not catalog:
            return
        for c in catalog:
            name = c.get("name")
            if not name:
                continue
            if c.get("canCapture"):
                self._catalog_capture.add(name)

    # -- per-template lookups (all degrade to None/empty) ------------------
    def stat(self, template):
        return self.units.get(template)

    def roles_of(self, template):
        r = set(self.roles.get(template, []))
        if template in self._catalog_capture:
            r.add("capturer")
        return r

    def has_role(self, template, role):
        return role in self.roles_of(template)

    def abilities_of(self, template):
        a = dict(self.abilities.get(template, {}))
        if template in self._catalog_capture:
            a["canCapture"] = True
        return a

    def _offline_capture_guess(self, template):
        # offline canCapture detection is noisy; trust it only for infantry.
        if not self.abilities.get(template, {}).get("canCapture"):
            return False
        return "INFANTRY" in (self.units.get(template, {}).get("kindOf", []))

    def can_capture(self, template):
        if self._catalog_capture:                 # catalog merged -> authoritative
            return template in self._catalog_capture
        return self._offline_capture_guess(template)

    def prereq(self, template):
        return self.tech.get("objects", {}).get(template, {})

    def vision(self, template):
        o = self.units.get(template, {})
        return o.get("ShroudClearingRange") or o.get("VisionRange") or 0

    def cost(self, template):
        return (self.units.get(template, {}) or {}).get("BuildCost")

    def max_health(self, template):
        return (self.units.get(template, {}) or {}).get("maxHealth")

    def transport_slots(self, template):
        return (self.units.get(template, {}) or {}).get("TransportSlotCount", 0)

    # -- counter matrix ----------------------------------------------------
    def eff_row(self, attacker):
        return self.effectiveness.get(attacker)

    def effective_dps(self, attacker, defender):
        """Best effective dps `attacker` deals to `defender` (combining all of
        attacker's weapons vs defender's armor).  None if unknown."""
        row = self.effectiveness.get(attacker)
        if not row:
            return None
        armor = self._armor_of.get(defender)
        if armor is None:
            # unknown defender armor -> fall back to raw dps estimate
            return row.get("dps")
        return row.get("vsArmor", {}).get(armor)

    def attack_range(self, attacker):
        row = self.effectiveness.get(attacker)
        return row.get("range") if row else None

    # -- side-filtered role helpers ---------------------------------------
    def _by_role(self, role, side=None):
        out = []
        for name, rs in self.roles.items():
            if role not in rs:
                continue
            if side and (self.units.get(name, {}).get("Side") != side):
                continue
            out.append(name)
        return out

    def aa_templates(self, side=None):
        return self._by_role("aa", side)

    def anti_tank_templates(self, side=None):
        return self._by_role("anti_tank", side)

    def anti_inf_templates(self, side=None):
        return self._by_role("anti_inf", side)

    def artillery_templates(self, side=None):
        return self._by_role("artillery", side)

    def repair_templates(self, side=None):
        return self._by_role("repair", side)

    def transports_with_slots(self, side=None):
        out = []
        for name, o in self.units.items():
            if (o.get("TransportSlotCount", 0) or 0) > 0:
                continue  # >0 means it OCCUPIES slots (a passenger), skip
            if "transport" in self.roles.get(name, []):
                if side and o.get("Side") != side:
                    continue
                out.append(name)
        return out

    def capturers(self, side=None):
        if self._catalog_capture:                 # catalog merged -> authoritative
            names = set(self._catalog_capture)
        else:                                     # offline: infantry-only guess
            names = {n for n in self.abilities
                     if self._offline_capture_guess(n)}
        if side:
            names = {n for n in names
                     if self.units.get(n, {}).get("Side") == side}
        return sorted(names)


_SINGLETON = None


def get_kb():
    """Process-wide cached KnowledgeBase (tables are immutable per match)."""
    global _SINGLETON
    if _SINGLETON is None:
        kb = KnowledgeBase()
        kb.load()
        _SINGLETON = kb
    return _SINGLETON
