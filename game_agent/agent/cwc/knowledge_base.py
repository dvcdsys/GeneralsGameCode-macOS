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
        self._catalog_abilities = {}    # template -> [SpecialPowerTemplate names] from its command set

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
            ab = c.get("abilities")
            if ab:
                self._catalog_abilities[name] = [str(a) for a in ab]

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

    # Helicopter / ATGM name markers (mod has no explicit sniper/medic/officer/heli roles, so derive
    # the fine roles the combat micro needs from template names + the coarse KB roles).
    _HELI_KW = ("mi24", "mi-24", "mi8", "mi-8", "hind", "hokum", "havoc", "ka50", "ka-50",
                "apache", "ah6", "ah-6", "ah64", "blackhawk", "comanche", "kiowa", "heli", "chopper")
    # DEDICATED ATGM (guided tank-killers), by name — NOT every rifleman who happens to carry an RPG.
    _ATGM_KW = ("at5", "at-5", "at4", "at-4", "atgm", "antitank", "tow", "konkurs", "spandrel",
                "fagot", "metis", "milan", "javelin", "dragon", "saxhorn", "spigot", "antitankmissile")
    # REAL MBTs by name: several (T-80 family, late NATO armour) fire gun-launched ATGMs, so the
    # weapon-based ATGM test alone misread them as missile carriers ("гармата танка вважається
    # артилерією/ПТУРом") — pulling premium tanks out of the tank class everywhere.
    _TANK_KW = ("t55", "t62", "t64", "t72", "t80", "m1a", "m48", "m60", "leo2", "leopard",
                "abrams", "challenger", "chieftain")
    _AA_KW = ("antiair", "shilka", "tunguska", "gepard", "vulcan", "m163", "linebacker", "avenger",
              "stinger", "sa6", "sa9", "sa11", "sa13", "s300", "nsvt", "flak", "aagun")
    _SNIPER_KW = ("sniper", "antimaterial", "anti_material", "spetsnaz")
    # A guided ATGM is an ARMOR_PIERCING weapon that out-ranges tank guns (~400). 480 separates IFV ATGMs
    # (BMP-2 / Bradley M2A1 / AT-5 @ 494-534) from tank main guns (LASER/EXPLOSION @ <=400). So IFVs that
    # carry a TOW/Konkurs are detected as ATGM by their WEAPON, not just by name (user: "БМП та Bradley теж
    # ПТУРи мають і дуже сильно виносять техніку на дистанції").
    ATGM_MIN_RANGE = 480
    _ATGM_DAMAGE = ("ARMOR_PIERCING", "MISSILE")

    def _has_atgm_weapon(self, template):
        er = self.effectiveness.get(template) or {}
        for w in er.get("weapons", []):
            dt = (w.get("damageType") or "").upper()
            if (w.get("range") or 0) >= self.ATGM_MIN_RANGE and any(k in dt for k in self._ATGM_DAMAGE):
                return True
        return False

    def fine_role(self, template):
        """Single fine combat role for micro: heli / jet / atgm / aa / tank / light_veh / artillery /
        transport / sniper / medic / officer / engineer / mg_inf / infantry / dozer / structure / other.
        Derived from KB roles_of() + template-name markers (the mod tags none of these distinctly)."""
        t = (template or ""); tl = t.lower()
        roles = self.roles_of(template)
        if any(k in tl for k in self._SNIPER_KW): return "sniper"
        if "medic" in tl: return "medic"
        if "officer" in tl: return "officer"
        if "engineer" in roles or "engineer" in tl: return "engineer"
        if "aircraft" in roles or "air" in roles:
            return "heli" if any(k in tl for k in self._HELI_KW) else "jet"
        # AA before ATGM: an AA unit named e.g. ...AntiAir must not be mis-read as anti-tank
        if "aa" in roles or any(k in tl for k in self._AA_KW): return "aa"
        # MBT names beat the weapon-based ATGM test (gun-launched missiles ≠ an ATGM carrier)
        if "vehicle" in roles and any(k in tl for k in self._TANK_KW): return "tank"
        # ATGM = a name-marked launcher OR any unit whose WEAPON is a long-range armor-piercing missile
        # (catches IFVs like BMP-2 / Bradley that carry a TOW/Konkurs — they shred armour at range).
        if any(k in tl for k in self._ATGM_KW) or self._has_atgm_weapon(template): return "atgm"
        if "artillery" in roles: return "artillery"
        if "vehicle" in roles:
            if "anti_tank" in roles and "anti_inf" in roles and "transport" not in roles:
                return "tank"
            if "transport" in roles: return "transport"
            return "light_veh"
        if "dozer" in roles: return "dozer"
        if "infantry" in roles:
            return "mg_inf" if "anti_inf" in roles else "infantry"
        if "structure" in roles: return "structure"
        return "other"

    def abilities_of(self, template):
        a = dict(self.abilities.get(template, {}))
        if template in self._catalog_capture:
            a["canCapture"] = True
        return a

    def catalog_abilities(self, template):
        """SpecialPowerTemplate names from the unit's command set (live /catalog; empty offline).
        These are invocable via the special_power verb (e.g. CWC FakeRider stance toggles)."""
        return self._catalog_abilities.get(template, [])

    def is_armed(self, template):
        """Does this unit carry a real weapon? Production must not buy UNARMED units to satisfy a
        combat need (a $500 CH47 transport heli was bought as 'air' and just flew around). With an
        effectiveness row, dps decides; without one, transports are assumed unarmed, combat-role
        templates armed."""
        row = self.eff_row(template)
        if row is not None:
            if (row.get("dps") or 0) > 0:
                return True
            va = row.get("vsArmor")
            return isinstance(va, dict) and any((v or 0) > 0 for v in va.values())
        roles = self.roles_of(template)
        if any(r in roles for r in ("anti_inf", "anti_tank", "aa", "artillery")):
            return True
        return "transport" not in roles

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
