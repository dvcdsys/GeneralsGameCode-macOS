#!/usr/bin/env python3
"""Offline CWC knowledge extractor.

Parses the Cold War Crisis mod data out of the BIGF archive (_469_CWC.gib) into a
set of committed JSON tables under tables/.  The runtime KnowledgeBase
(agent/cwc/knowledge_base.py) loads these once per match.

Why offline + committed:
  - The live engine /catalog gives cost/buildTime/power/prereqs/canCapture/abilities
    but NOT weapon damage, attack range, armor multipliers, vision range or HP.
  - Those numbers (the counter matrix!) live only in the mod INI files inside the
    .gib, and parsing 300+ files at match start would be slow and fragile.
  - So we extract once, commit the JSON, and the runtime just loads it.  Every
    lookup degrades gracefully, so a missing/edited table never breaks gameplay.

INI structure facts this parser relies on (verified against v469):
  - Top-level declarations (Object/Weapon/Armor/CommandSet/...) start in column 0
    and end with a column-0 `End`/`END`.  Nested blocks are indented and their
    closing `End` is indented to match their opener.
  - We do NOT attempt a full recursive INI parse (the engine's block grammar is
    huge and several keys like AliasConditionState/DeathTypes are one-line fields
    that would drift a naive depth counter).  Instead we use targeted,
    indent-bounded extraction of just the four sub-blocks we need
    (WeaponSet / ArmorSet / Body / Prerequisites) plus a whitelist of top-level
    scalar fields.

Usage:
  python3 extract_cwc.py [--archive PATH] [--out DIR]
  python3 extract_cwc.py --verify [--catalog catalog.json]   # report gaps
"""
import argparse
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_ARCHIVE = os.path.join(
    REPO,
    "original",
    "Command_and_Conquer_ZERO_HOUR_ORIGINAL",
    "Command and Conquer Generals Zero Hour",
    "GLM", "Cold War Crisis", "1.5", "_469_CWC.gib",
)
DEFAULT_OUT = os.path.join(HERE, "tables")
EXTRACTOR_VERSION = 1

# Top-level scalar Object fields we copy verbatim (first occurrence wins; these
# keys do not appear inside the sub-blocks we read, so first == the real one).
TOP_SCALARS = {
    "Side", "BuildCost", "BuildTime", "VisionRange", "ShroudClearingRange",
    "CommandSet", "TransportSlotCount", "EnergyProduction", "DisplayName",
    "BuildVariations",
}
NUM_FIELDS = {
    "BuildCost", "BuildTime", "VisionRange", "ShroudClearingRange",
    "TransportSlotCount", "EnergyProduction", "PrimaryDamage",
    "PrimaryDamageRadius", "SecondaryDamage", "SecondaryDamageRadius",
    "AttackRange", "MinimumAttackRange", "DelayBetweenShots", "ClipSize",
    "ClipReloadTime", "WeaponSpeed", "ScatterRadiusVsInfantry", "MaxHealth",
    "RadiusDamageAffects",
}


def _load_big_extract():
    spec = importlib.util.spec_from_file_location(
        "big_extract", os.path.join(REPO, "scripts", "big_extract.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _strip(line):
    """Drop trailing comment + whitespace.  Returns (indent, content)."""
    # Comments start at ';'.  (No '//' style in these INIs.)
    c = line.split(";", 1)[0].rstrip("\r\n")
    content = c.strip()
    indent = len(c) - len(c.lstrip(" \t"))
    return indent, content


def _num(v):
    """Best-effort numeric coercion: '17.0', '800', '100%' -> float/int."""
    if v is None:
        return None
    s = v.strip()
    m = re.match(r"^-?\d+(\.\d+)?%?$", s)
    if not m:
        # take first numeric token if present (e.g. 'ExperienceValue 800 1200 ...')
        toks = re.findall(r"-?\d+(?:\.\d+)?", s)
        return float(toks[0]) if toks else v
    s = s.rstrip("%")
    f = float(s)
    return int(f) if f.is_integer() else f


def iter_top_blocks(text):
    """Yield (header_tokens, body_lines) for every column-0 declaration block.

    A block opens at a column-0 non-blank, non-comment, non-'End' line and closes
    at the next column-0 'End'.  body_lines are the raw lines in between.
    """
    lines = text.splitlines()
    i, n = 0, len(lines)
    while i < n:
        indent, content = _strip(lines[i])
        if content and indent == 0 and content.lower() != "end":
            header = content.split()
            body = []
            i += 1
            while i < n:
                ind2, c2 = _strip(lines[i])
                if ind2 == 0 and c2.lower() == "end":
                    i += 1
                    break
                body.append(lines[i])
                i += 1
            yield header, body
        else:
            i += 1


def _all_subblocks(body, opener_pred):
    """Yield the indent-bounded lines of EVERY sub-block whose opening line matches
    opener_pred(content).  Each block runs until an 'End' at indentation <= the
    opener's indentation.  (Units often have several WeaponSet/ArmorSet blocks for
    different Conditions/rider stances — we must read all of them.)"""
    blocks = []
    i, n = 0, len(body)
    while i < n:
        ind, content = _strip(body[i])
        if content and opener_pred(content):
            open_indent = ind
            cur = []
            i += 1
            while i < n:
                ind2, c2 = _strip(body[i])
                if c2:
                    if c2.lower() == "end" and ind2 <= open_indent:
                        i += 1
                        break
                    cur.append((ind2, c2))
                i += 1
            blocks.append(cur)
        else:
            i += 1
    return blocks


def _subblock(body, opener_pred):
    """First matching sub-block (convenience)."""
    blocks = _all_subblocks(body, opener_pred)
    return blocks[0] if blocks else []


def _scalar_fields(body):
    """Top-level scalar fields: only lines whose key is whitelisted.  We take the
    first occurrence of each key (top-level fields precede the deep module blocks
    in these files)."""
    out = {}
    for raw in body:
        _, content = _strip(raw)
        if "=" not in content:
            continue
        k, v = content.split("=", 1)
        k = k.strip()
        if k in TOP_SCALARS and k not in out:
            v = v.strip()
            out[k] = _num(v) if k in NUM_FIELDS else v
    return out


# ---------------------------------------------------------------------------
# Weapon.ini / Armor.ini
# ---------------------------------------------------------------------------
def parse_weapons(text):
    weapons = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "Weapon" or len(header) < 2:
            continue
        name = header[1]
        w = {}
        anti = []
        for raw in body:
            _, content = _strip(raw)
            if "=" not in content:
                continue
            k, v = content.split("=", 1)
            k, v = k.strip(), v.strip()
            if k in NUM_FIELDS:
                w[k] = _num(v)
            elif k == "DamageType":
                w["DamageType"] = v.split()[0] if v else v
            elif k.startswith("Anti") and v.lower().startswith("yes"):
                anti.append(k)
        if anti:
            w["anti"] = anti
        # derived: damage-per-second (1 shot / DelayBetweenShots ms; clip ignored
        # as a coarse approximation good enough for ranking)
        dmg = w.get("PrimaryDamage") or 0
        delay = w.get("DelayBetweenShots") or 0
        clip = w.get("ClipSize") or 0
        reload_ms = w.get("ClipReloadTime") or 0
        if clip and reload_ms and delay:
            cycle = clip * delay + reload_ms
            w["dps"] = round(dmg * clip / (cycle / 1000.0), 2) if cycle else dmg
        elif delay:
            w["dps"] = round(dmg / (delay / 1000.0), 2)
        else:
            w["dps"] = float(dmg)
        weapons[name] = w
    return weapons


def parse_armors(text):
    armors = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "Armor" or len(header) < 2:
            continue
        name = header[1]
        mult = {}
        for raw in body:
            _, content = _strip(raw)
            if not content.startswith("Armor"):
                continue
            if "=" not in content:
                continue
            _, v = content.split("=", 1)
            toks = v.split()
            if len(toks) >= 2:
                dtype = toks[0]
                pct = _num(toks[1])
                mult[dtype] = (pct / 100.0) if isinstance(pct, (int, float)) else 1.0
        armors[name] = mult
    return armors


# ---------------------------------------------------------------------------
# Object/**.ini
# ---------------------------------------------------------------------------
def parse_objects(text):
    objs = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "Object" or len(header) < 2:
            continue
        name = header[1]
        o = _scalar_fields(body)
        o["template"] = name

        # KindOf (space-separated flags)
        for raw in body:
            _, content = _strip(raw)
            if content.startswith("KindOf") and "=" in content:
                o["kindOf"] = content.split("=", 1)[1].split()
                break

        # WeaponSet -> {slot: weaponName} from the first block (for display) PLUS
        # the union of ALL weapon names across every WeaponSet block (units carry
        # different weapons per Conditions/rider stance — e.g. an AT trooper's LAW
        # launcher lives in a later WEAPON_RIDER3 block than its rifle).
        ws = {}
        all_w = []
        for block in _all_subblocks(body, lambda c: c == "WeaponSet"):
            for ind, content in block:
                if content.startswith("Weapon") and "=" in content:
                    toks = content.split("=", 1)[1].split()
                    if len(toks) >= 2 and toks[1] not in ("None", "NONE"):
                        ws.setdefault(toks[0], toks[1])
                        if toks[1] not in all_w:
                            all_w.append(toks[1])
        if ws:
            o["weaponSet"] = ws
        if all_w:
            o["weaponsAll"] = all_w

        # ArmorSet -> first Armor name
        for ind, content in _subblock(body, lambda c: c == "ArmorSet"):
            if content.startswith("Armor") and "=" in content:
                toks = content.split("=", 1)[1].split()
                if toks:
                    o["armor"] = toks[0]
                    break

        # Body block -> MaxHealth
        for ind, content in _subblock(body, lambda c: c.startswith("Body")):
            if content.startswith("MaxHealth") and "=" in content:
                o["maxHealth"] = _num(content.split("=", 1)[1])
                break

        # Prerequisites -> objects[] + sciences[]
        pre_obj, pre_sci = [], []
        for ind, content in _subblock(body, lambda c: c == "Prerequisites"):
            if "=" not in content:
                continue
            k, v = content.split("=", 1)
            k = k.strip()
            if k == "Object":
                pre_obj += v.split()
            elif k == "Science":
                pre_sci += v.split()
        if pre_obj or pre_sci:
            o["prereq"] = {"object": pre_obj, "science": pre_sci}

        # Experience (veterancy thresholds), first numeric list
        for raw in body:
            _, content = _strip(raw)
            if content.startswith("ExperienceRequired") and "=" in content:
                o["expRequired"] = [int(float(x)) for x in
                                    re.findall(r"-?\d+(?:\.\d+)?",
                                               content.split("=", 1)[1])]
                break

        objs[name] = o
    return objs


# ---------------------------------------------------------------------------
# CommandSet.ini / CommandButton.ini -> production graph + abilities
# ---------------------------------------------------------------------------
def parse_command_buttons(text):
    """name -> {command, object}."""
    buttons = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "CommandButton" or len(header) < 2:
            continue
        b = {}
        for raw in body:
            _, content = _strip(raw)
            if "=" not in content:
                continue
            k, v = content.split("=", 1)
            k, v = k.strip(), v.strip()
            if k in ("Command", "Object", "SpecialPower", "Upgrade", "Science"):
                b[k] = v.split()[0] if v else v
        buttons[header[1]] = b
    return buttons


def parse_command_sets(text):
    """name -> [button names]."""
    sets = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "CommandSet" or len(header) < 2:
            continue
        btns = []
        for raw in body:
            _, content = _strip(raw)
            if "=" not in content:
                continue
            _, v = content.split("=", 1)
            v = v.strip()
            if v.startswith("Command_"):
                btns.append(v)
        sets[header[1]] = btns
    return sets


def parse_ranks(text):
    ranks = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "Rank" or len(header) < 2:
            continue
        r = {}
        for raw in body:
            _, content = _strip(raw)
            if "=" not in content:
                continue
            k, v = content.split("=", 1)
            k, v = k.strip(), v.strip()
            if k in ("SkillPointsNeeded", "SciencePurchasePointsGranted"):
                r[k] = _num(v)
        ranks[header[1]] = r
    return ranks


def parse_sciences(text):
    sci = {}
    for header, body in iter_top_blocks(text):
        if not header or header[0] != "Science" or len(header) < 2:
            continue
        s = {}
        for raw in body:
            _, content = _strip(raw)
            if "=" not in content:
                continue
            k, v = content.split("=", 1)
            k, v = k.strip(), v.strip()
            if k == "PrerequisiteSciences":
                s["prereq"] = v.split()
            elif k in ("SciencePurchasePointCost",):
                s["cost"] = _num(v)
        sci[header[1]] = s
    return sci


# ---------------------------------------------------------------------------
# Derivation: roles, abilities, effectiveness (counter matrix)
# ---------------------------------------------------------------------------
ANTI_INF_DTYPES = {"SMALL_ARMS", "FLAME", "SNIPER", "FLESHY_SNIPER",
                   "MOLOTOV_COCKTAIL", "GATTLING", "COMANCHE_VULCAN"}
ANTI_ARMOR_DTYPES = {"ARMOR_PIERCING", "JET_MISSILES", "STEALTHJET_MISSILES",
                     "INFANTRY_MISSILE", "LASER", "PARTICLE_BEAM"}


def derive_abilities(objs, command_sets, buttons):
    """template -> {builds:[...], canCapture, repair, heal, deploy}."""
    out = {}
    for name, o in objs.items():
        ab = {"builds": []}
        cs = o.get("CommandSet")
        if cs and cs in command_sets:
            for bn in command_sets[cs]:
                b = buttons.get(bn, {})
                cmd = b.get("Command", "")
                tgt = b.get("Object")
                if cmd in ("DOZER_CONSTRUCT", "UNIT_BUILD") and tgt:
                    ab["builds"].append(tgt)
                if "CAPTURE" in cmd:
                    ab["canCapture"] = True
                if cmd in ("UNIT_REPAIR", "COMBATDROP") or "REPAIR" in cmd:
                    ab["repair"] = True
                if "HEAL" in cmd:
                    ab["heal"] = True
                if cmd in ("DEPLOY", "TOGGLE_OVERCHARGE") or "DEPLOY" in cmd:
                    ab["deploy"] = True
        kindof = set(o.get("kindOf", []))
        if "PORTABLE_STRUCTURE" in kindof or "CAPTURE" in " ".join(kindof):
            ab.setdefault("canCapture", True)
        out[name] = ab
    return out


def _unit_weapons(o, weapons):
    """All resolved weapon records the unit can use (union across every WeaponSet
    block / rider stance, not just the first slot set)."""
    out = []
    names = o.get("weaponsAll") or list((o.get("weaponSet") or {}).values())
    for wn in names:
        w = weapons.get(wn)
        if w and (w.get("PrimaryDamage") or 0) > 0:
            out.append(w)
    return out


def _armor_kinds(objs):
    """armor_name -> aggregated KindOf set of the units that wear it.

    Lets us classify a target as infantry/vehicle/aircraft/structure without a
    second lookup, so roles can be derived from the real effectiveness matrix
    (essential in CWC where damage types are repurposed — a tank's LASER sabot
    does 0% to infantry, only its coax small-arms kills them)."""
    out = {}
    for o in objs.values():
        ar = o.get("armor")
        if not ar:
            continue
        out.setdefault(ar, set()).update(o.get("kindOf", []))
    return out


def build_effectiveness(objs, weapons, armors):
    """attacker_template -> {dps, range, weapons[], vsArmor{armor: best effective dps}}.

    vsArmor combines ALL of the attacker's weapons (max effective dps vs that
    armor), because in CWC a unit's real anti-X capability often lives in its
    secondary/coax weapon, not the primary.  The runtime maps a defender template
    -> its armor -> the multiplier here."""
    eff = {}
    for name, o in objs.items():
        wlist = _unit_weapons(o, weapons)
        if not wlist:
            continue
        rng = max((w.get("AttackRange", 0) or 0) for w in wlist)
        best_dps = max((w.get("dps", 0.0) or 0.0) for w in wlist)
        row = {}
        for armor_name, mult in armors.items():
            best = 0.0
            for w in wlist:
                dt = w.get("DamageType", "DEFAULT")
                m = mult.get(dt, mult.get("DEFAULT", 1.0))
                best = max(best, (w.get("dps", 0.0) or 0.0) * m)
            row[armor_name] = round(best, 2)
        eff[name] = {
            "dps": best_dps,
            "range": rng,
            "weapons": [{"damageType": w.get("DamageType"),
                         "dps": w.get("dps"),
                         "range": w.get("AttackRange"),
                         "anti": w.get("anti", [])} for w in wlist],
            "vsArmor": row,
        }
    return eff


def derive_roles(objs, weapons, abilities, effectiveness, armor_kinds):
    """template -> [roles], with combat roles read off the real effectiveness
    matrix (so CWC's repurposed damage types don't mislabel units)."""
    # representative best effective dps vs each target class
    def best_vs(eff_row, want, without=()):
        best = 0.0
        for armor_name, dps in eff_row["vsArmor"].items():
            kinds = armor_kinds.get(armor_name, set())
            if want in kinds and not (set(without) & kinds):
                best = max(best, dps)
        return best

    out = {}
    for name, o in objs.items():
        roles = []
        kindof = set(o.get("kindOf", []))
        ab = abilities.get(name, {})
        if "DOZER" in kindof:
            roles.append("dozer")
        if "STRUCTURE" in kindof:
            roles.append("structure")
        if "INFANTRY" in kindof:
            roles.append("infantry")
        if "VEHICLE" in kindof and "STRUCTURE" not in kindof:
            roles.append("vehicle")
        if "AIRCRAFT" in kindof:
            roles.append("aircraft")
        if "TRANSPORT" in kindof:
            roles.append("transport")
        er = effectiveness.get(name)
        if er:
            b_inf = best_vs(er, "INFANTRY")
            b_veh = best_vs(er, "VEHICLE", without=("STRUCTURE",))
            b_air = best_vs(er, "AIRCRAFT")
            peak = max(b_inf, b_veh, 1e-9)
            if b_inf > 0 and b_inf >= 0.5 * peak:
                roles.append("anti_inf")
            # anti_tank uses a LOWER bar: a tank's gun does solid damage to armor but its anti-infantry
            # splash often has higher raw dps, so a 0.5*peak test wrongly excludes real MBTs (T-72's
            # LASER ~60 vs its EXPLOSION coax ~188). 0.3*peak tags units that MEANINGFULLY hurt tanks
            # (MBTs, ATGMs) while pure rifle infantry (~0 vs armor) stay out.
            if b_veh > 0 and b_veh >= 0.3 * peak:
                roles.append("anti_tank")
            # AA strictly from an explicit anti-air weapon flag (CWC repurposes
            # damage types, so splash hitting aircraft armor is NOT a reliable
            # AA signal).
            if any("Airborne" in a
                   for w in er["weapons"] for a in w.get("anti", [])):
                roles.append("aa")
            # artillery = INDIRECT fire: very long range AND a large minimum range (can't shoot up
            # close). This distinguishes real howitzers/MLRS (2S1/BM21: range 1200-2000, minRange
            # 250-500) from MAIN BATTLE TANKS (T-72/T-80/M1A1: range ~400, minRange ~50) whose HEAT
            # round also has splash — the old "range>=300 & radius>=10" test wrongly tagged every MBT
            # as artillery, which excluded them from the tank quota's MBT preference.
            for w in _unit_weapons(o, weapons):
                if (w.get("AttackRange", 0) or 0) >= 800 and \
                        (w.get("MinimumAttackRange", 0) or 0) >= 150:
                    roles.append("artillery")
                    break
        if ab.get("canCapture"):
            roles.append("capturer")
        if ab.get("repair"):
            roles.append("repair")
        if ab.get("heal"):
            roles.append("heal")
        low = name.lower()
        if "engineer" in low:
            roles += ["engineer", "repair"]
        if "dozer" in low:
            roles.append("dozer")
        out[name] = sorted(set(roles))
    return out


def _common_prefix_len(a, b):
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def alias_missing_weapons(objs, effectiveness, roles, min_prefix=10):
    """CWC splits a buildable unit (a thin parent/container) from the sibling
    object that actually carries the weapons (e.g. CWCusInfAntiTank ->
    CWCusInfAntiTankWhite01, infantry rider variants, fort turret objects).  For
    any CAN_ATTACK unit with no resolved weapon, inherit the effectiveness + combat
    roles of the longest-name-prefix sibling that DOES have a weapon.  Heuristic,
    but it matches the variant/rider naming and is marked aliasedFrom for audit."""
    armed = [n for n in effectiveness]
    for name, o in objs.items():
        if name in effectiveness:
            continue
        if "CAN_ATTACK" not in o.get("kindOf", []):
            continue
        best, best_len = None, min_prefix
        for cand in armed:
            pl = _common_prefix_len(name, cand)
            if pl > best_len:
                best, best_len = cand, pl
        if best:
            effectiveness[name] = dict(effectiveness[best], aliasedFrom=best)
            # union combat roles from the alias
            combat = {r for r in roles.get(best, [])
                      if r in ("anti_inf", "anti_tank", "aa", "artillery")}
            roles[name] = sorted(set(roles.get(name, [])) | combat)


# ---------------------------------------------------------------------------
def extract(archive, out_dir):
    be = _load_big_extract()
    data, entries = be.read_archive(archive)

    def read(internal):
        needle = internal.lower().replace("/", "\\")
        for name, off, size in entries:
            if name.lower() == needle:
                return data[off:off + size].decode("latin-1")
        return ""

    weapons = parse_weapons(read("Data\\INI\\Weapon.ini"))
    armors = parse_armors(read("Data\\INI\\Armor.ini"))
    buttons = parse_command_buttons(read("Data\\INI\\CommandButton.ini"))
    command_sets = parse_command_sets(read("Data\\INI\\CommandSet.ini"))
    ranks = parse_ranks(read("Data\\INI\\Rank.ini"))
    sciences = parse_sciences(read("Data\\INI\\Science.ini"))

    # objects: every file under Object\Cold War Crisis
    objs = {}
    obj_entries = [(n, o, s) for n, o, s in entries
                   if n.startswith("Data\\INI\\Object\\Cold War Crisis")]
    for n, o, s in obj_entries:
        txt = data[o:o + s].decode("latin-1")
        objs.update(parse_objects(txt))

    abilities = derive_abilities(objs, command_sets, buttons)
    effectiveness = build_effectiveness(objs, weapons, armors)
    armor_kinds = _armor_kinds(objs)
    roles = derive_roles(objs, weapons, abilities, effectiveness, armor_kinds)
    alias_missing_weapons(objs, effectiveness, roles)

    # tech tree: object prereqs + science chains + rank gates
    tech = {"objects": {n: o.get("prereq", {}) for n, o in objs.items()
                        if o.get("prereq")},
            "sciences": sciences,
            "ranks": ranks}

    os.makedirs(out_dir, exist_ok=True)
    tables = {
        "units.json": objs,
        "weapons.json": weapons,
        "armor_matrix.json": armors,
        "abilities.json": abilities,
        "roles.json": roles,
        "effectiveness.json": effectiveness,
        "tech_tree.json": tech,
        "meta.json": {
            "archive": os.path.basename(archive),
            "archiveSize": os.path.getsize(archive),
            "extractorVersion": EXTRACTOR_VERSION,
            "counts": {
                "units": len(objs), "weapons": len(weapons),
                "armors": len(armors), "commandSets": len(command_sets),
                "buttons": len(buttons), "effectiveness": len(effectiveness),
            },
        },
    }
    for fn, obj in tables.items():
        with open(os.path.join(out_dir, fn), "w") as f:
            json.dump(obj, f, indent=1, sort_keys=True)
    return tables


def verify(out_dir, catalog_path=None):
    """Report unresolved weapon/armor refs and (optionally) catalog templates the
    tables miss."""
    def load(fn):
        p = os.path.join(out_dir, fn)
        return json.load(open(p)) if os.path.exists(p) else {}

    units = load("units.json")
    weapons = load("weapons.json")
    armors = load("armor_matrix.json")
    problems = []
    no_weapon = no_armor = no_health = 0
    bad_w, bad_a = set(), set()
    for name, o in units.items():
        ws = o.get("weaponSet", {})
        if ws:
            for slot, wn in ws.items():
                if wn not in weapons:
                    bad_w.add(wn)
        else:
            no_weapon += 1
        ar = o.get("armor")
        if ar:
            if ar not in armors:
                bad_a.add(ar)
        else:
            no_armor += 1
        if "maxHealth" not in o:
            no_health += 1
    print(f"units={len(units)} weapons={len(weapons)} armors={len(armors)}")
    print(f"  units w/o weaponSet: {no_weapon}")
    print(f"  units w/o armor:     {no_armor}")
    print(f"  units w/o maxHealth: {no_health}")
    if bad_w:
        print(f"  UNRESOLVED weapon refs ({len(bad_w)}): "
              f"{sorted(bad_w)[:15]}")
    if bad_a:
        print(f"  UNRESOLVED armor refs ({len(bad_a)}): {sorted(bad_a)[:15]}")
    if catalog_path and os.path.exists(catalog_path):
        cat = json.load(open(catalog_path))
        names = {c.get("name") for c in cat} if isinstance(cat, list) else set()
        missing = sorted(n for n in names if n and n not in units)
        print(f"  catalog templates NOT in units.json ({len(missing)}): "
              f"{missing[:20]}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--archive", default=DEFAULT_ARCHIVE)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--catalog", default=None,
                    help="path to a saved /catalog json for gap analysis")
    args = ap.parse_args()
    if args.verify:
        verify(args.out, args.catalog)
        return
    if not os.path.exists(args.archive):
        sys.exit(f"archive not found: {args.archive}")
    tables = extract(args.archive, args.out)
    meta = tables["meta.json"]
    print(f"extracted -> {args.out}")
    for k, v in meta["counts"].items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
