#!/usr/bin/env python3
"""Generate the CWC Guard-From-Position loose-override INI.

Goal (per design): the Guard-From-Position ("double guard") command must appear
on EVERY Cold War Crisis combat VEHICLE and AIRCRAFT that can shoot — and on
NOTHING else. Specifically:
  * INCLUDE: Objects whose KindOf has VEHICLE or AIRCRAFT *and* can attack
             (CAN_ATTACK in KindOf, or a real PRIMARY weapon).
  * EXCLUDE: all INFANTRY (people/foot soldiers), unarmed support vehicles
             (dozers, ambulances, supply trucks), structures, projectiles,
             civilian props, etc.

Why classify by Object KindOf instead of "CommandSet already has a Guard
button" (the old heuristic): infantry ALSO have Command_Guard, so a
guard-button filter can't tell a rifleman from a tank. The authoritative
unit-type signal is the Object's KindOf line + its WeaponSet, so we parse the
Object definitions and map the qualifying ones to their CommandSet(s).

Pipeline:
  1. Read the CWC archive (.gib/.big) directly — no pre-extraction needed.
  2. Concatenate every Data\\INI\\Object\\... file + the top-level CommandSet.ini.
  3. Parse Object blocks: top-level KindOf, has-real-weapon, and ALL CommandSet
     references (primary `CommandSet =` plus any `CommandSet =` inside a
     `Behavior = CommandSetUpgrade` / veterancy module — vehicles swap sets on
     upgrade, e.g. CWCru2S1 -> CWCru2S1BarrageFireCommandSet).
  4. Select qualifying Objects, collect the union of their CommandSet names.
  5. For each of those CommandSets in CommandSet.ini, add
     Command_GuardFromPosition at the lowest FREE visible slot (1..14),
     never overwriting an existing command. Skip if already present or full.
  6. Emit loose overrides into the engine's CREATE_OVERRIDES dirs:
       <install>/Data/INI/OverrideCommandButton/_zz_GuardFromPosition.ini
       <install>/Data/INI/OverrideCommandSet/_zz_GuardFromPosition.ini
     (OverrideCommandSet/ loads in INI_LOAD_CREATE_OVERRIDES, which chains the
     override on top of the base entry — the standard CommandSet/ subdir loads
     OVERWRITE and throws on duplicates.)

Usage:
  cwc_guard_patch.py <cwc_archive.gib> <install_root>
  example:
    cwc_guard_patch.py \\
      "/Users/me/.../GLM/Cold War Crisis/1.5/_469_CWC.gib" \\
      "/Users/me/Command and Conquer Generals Zero Hour/Command and Conquer Generals Zero Hour"
"""
import os
import re
import struct
import sys


# UI shows slots 1..14 (MAX_COMMANDS_PER_SET is 18 but 15..18 are script-only).
MAX_VISIBLE_SLOT = 14

# CommandSets we must NOT patch even if a qualifying Object references them:
#  * Generic / StopOnly* are SHARED fallback sets used by many objects
#    (including non-combat ones) — patching them leaks the button everywhere.
#  * Civilian* are mission props (car bomb, nuke truck, limo) weaponised only
#    by a detonate ability — not "vehicles that shoot" in the user's sense.
EXCLUDE_EXACT  = {"GenericCommandSet", "StopOnlyGenericCommandSet"}
EXCLUDE_PREFIX = ("Civilian",)


def is_excluded_set(name):
    return name in EXCLUDE_EXACT or name.startswith(EXCLUDE_PREFIX)

# ---------------------------------------------------------------------------
# BIGF / .gib archive reader (matches StdBIGFileSystem.cpp; same as big_extract.py)
# ---------------------------------------------------------------------------
def read_archive(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"BIGF":
        raise SystemExit(f"{path}: not a BIGF archive (magic={data[:4]!r})")
    (num_files,) = struct.unpack(">I", data[8:12])
    pos = 0x10
    entries = []
    for _ in range(num_files):
        offset, size = struct.unpack(">II", data[pos:pos + 8])
        pos += 8
        end = data.index(b"\x00", pos)
        name = data[pos:end].decode("latin-1")
        pos = end + 1
        entries.append((name, offset, size))
    return data, entries


def read_member(data, entries, name_substr_lower):
    """Return decoded text of the first member whose path contains the substring."""
    for name, off, size in entries:
        if name_substr_lower in name.lower():
            return data[off:off + size].decode("latin-1")
    return None


def read_all_object_inis(data, entries):
    """Concatenate every Data\\INI\\Object\\... member into one text blob."""
    chunks = []
    for name, off, size in entries:
        low = name.lower()
        if "\\ini\\object\\" in low and low.endswith(".ini"):
            chunks.append(data[off:off + size].decode("latin-1"))
    return "\n".join(chunks)


# ---------------------------------------------------------------------------
# Object parsing / classification
# ---------------------------------------------------------------------------
KINDOF_RE   = re.compile(r"^\s*KindOf\s*=\s*(.+)$", re.IGNORECASE)
CMDSET_RE   = re.compile(r"^\s*CommandSet\s*=\s*(\S+)", re.IGNORECASE)
WEAPON_RE   = re.compile(r"^\s*Weapon\s*=\s*PRIMARY\s+(\S+)", re.IGNORECASE)
OBJECT_RE   = re.compile(r"^Object\s+(\S+)", re.IGNORECASE)

TYPE_TOKENS = {"INFANTRY", "VEHICLE", "AIRCRAFT", "STRUCTURE", "PROJECTILE",
               "DOZER", "HORDE_VEHICLE"}


def _strip_comment(s):
    i = s.find(";")
    return (s[:i] if i >= 0 else s).strip()


def split_objects(text):
    """Yield (object_name, [lines]) for each `Object ... ` block.

    We split purely on `^Object <name>` boundaries: a block runs to the next
    Object line (or EOF). That intentionally includes the object's nested
    modules, which is what we want — CommandSetUpgrade sub-modules carry extra
    `CommandSet =` lines we must capture.
    """
    lines = text.replace("\r\n", "\n").split("\n")
    cur_name = None
    cur = []
    for ln in lines:
        m = OBJECT_RE.match(ln)
        if m:
            if cur_name is not None:
                yield cur_name, cur
            cur_name = m.group(1)
            cur = [ln]
        elif cur_name is not None:
            cur.append(ln)
    if cur_name is not None:
        yield cur_name, cur


def classify_object(lines):
    """Return (qualifies: bool, command_sets: set[str]).

    Qualifies = (VEHICLE or AIRCRAFT) and (CAN_ATTACK or a real PRIMARY weapon)
                and NOT INFANTRY.
    """
    top_kindof = None       # first KindOf line that names a real unit type
    has_weapon = False
    command_sets = set()

    for ln in lines:
        mk = KINDOF_RE.match(ln)
        if mk and top_kindof is None:
            val = _strip_comment(mk.group(1)).upper()
            toks = set(val.split())
            if toks & TYPE_TOKENS or "CAN_ATTACK" in toks:
                top_kindof = toks
            # else: comment-only / horde-count KindOf — ignore, keep looking
        mw = WEAPON_RE.match(ln)
        if mw:
            wname = mw.group(1).strip()
            if wname and wname.lower() != "none":
                has_weapon = True
        mc = CMDSET_RE.match(ln)
        if mc:
            command_sets.add(mc.group(1).strip())

    if top_kindof is None:
        return False, command_sets

    if "INFANTRY" in top_kindof:
        return False, command_sets            # people/foot soldiers: excluded
    is_vehicle_or_air = ("VEHICLE" in top_kindof) or ("AIRCRAFT" in top_kindof)
    can_shoot = ("CAN_ATTACK" in top_kindof) or has_weapon
    return (is_vehicle_or_air and can_shoot), command_sets


# ---------------------------------------------------------------------------
# CommandSet parsing / patching
# ---------------------------------------------------------------------------
SET_OPEN_RE = re.compile(r"^\s*CommandSet\s+(\S+)\s*$")
SET_END_RE  = re.compile(r"^\s*End\s*$", re.IGNORECASE)
SLOT_RE     = re.compile(r"^\s*(\d+)\s*=\s*(\S+)")


def parse_command_sets(text):
    """Return ordered list of (name, {slot:int -> command:str})."""
    lines = text.replace("\r\n", "\n").split("\n")
    sets = []
    name = None
    slots = {}
    for ln in lines:
        if name is None:
            m = SET_OPEN_RE.match(ln)
            if m:
                name = m.group(1)
                slots = {}
            continue
        if SET_END_RE.match(ln):
            sets.append((name, slots))
            name = None
            slots = {}
            continue
        ms = SLOT_RE.match(ln)
        if ms:
            slots[int(ms.group(1))] = ms.group(2).strip()
    return sets


GFP = "Command_GuardFromPosition"


def patched_block(name, slots):
    """Return list[str] for an overridden CommandSet adding GFP at lowest free
    visible slot, or None if it can't / shouldn't be patched."""
    if GFP in slots.values():
        return None                            # already has it
    free = next((s for s in range(1, MAX_VISIBLE_SLOT + 1) if s not in slots), None)
    if free is None:
        return None                            # all 14 visible slots taken
    slots = dict(slots)
    slots[free] = GFP
    out = [f"CommandSet {name}"]
    for s in sorted(slots.keys()):
        out.append(f"  {s:2d} = {slots[s]}")
    out.append("End")
    return out


CMD_BUTTON_INI = """\
;------------------------------------------------------------------------------
; Guard-From-Position command button (TheSuperHackers @feature, macOS port).
; Two-click flow:
;   1) first click sets the unit's HOME position;
;   2) second click sets the WATCH zone - the unit attacks anything that enters
;      it and returns home when the threat clears.
; Applied to all CWC combat vehicles + aircraft (NOT infantry) by
; scripts/cwc_guard_patch.py. Reuses the vanilla Guard icon + radius cursor.
;------------------------------------------------------------------------------

CommandButton Command_GuardFromPosition
  Command           = GUARD_FROM_POSITION
  Options           = NEED_TARGET_POS OK_FOR_MULTI_SELECT
  TextLabel         = CONTROLBAR:CommandGuardFromPosition
  DescriptLabel     = CONTROLBAR:ToolTipCommandGuardFromPosition
  ButtonImage       = SSGuard
  CursorName        = FireBomb
  InvalidCursorName = GenericInvalid
  RadiusCursorType  = GUARD_AREA
  ButtonBorderType  = ACTION
End
"""


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    archive = sys.argv[1]
    install_root = sys.argv[2]

    data, entries = read_archive(archive)

    obj_text = read_all_object_inis(data, entries)
    if not obj_text:
        raise SystemExit("No Data\\INI\\Object\\... members found in archive.")
    cmdset_text = read_member(data, entries, "\\ini\\commandset.ini")
    if not cmdset_text:
        raise SystemExit("CommandSet.ini not found in archive.")

    # 1) Classify objects -> target command-set names.
    target_sets = set()
    n_objects = 0
    n_qualify = 0
    for oname, lines in split_objects(obj_text):
        n_objects += 1
        ok, sets = classify_object(lines)
        if ok:
            n_qualify += 1
            target_sets |= sets
    print(f"Parsed {n_objects} Objects; {n_qualify} qualify "
          f"(vehicle/aircraft + can-shoot, no infantry).", file=sys.stderr)
    print(f"-> {len(target_sets)} distinct target CommandSet names.", file=sys.stderr)

    # 2) Patch those command sets.
    all_sets = parse_command_sets(cmdset_text)
    by_name = {name: slots for name, slots in all_sets}
    patched = []
    missing = []
    skipped = []
    excluded = sorted(s for s in target_sets if is_excluded_set(s))
    for set_name in sorted(target_sets):
        if is_excluded_set(set_name):
            continue
        if set_name not in by_name:
            missing.append(set_name)
            continue
        block = patched_block(set_name, by_name[set_name])
        if block is None:
            skipped.append(set_name)
            continue
        patched.append(block)

    print(f"Patched {len(patched)} CommandSets; "
          f"{len(skipped)} skipped (already have it / full); "
          f"{len(excluded)} excluded (generic/civilian shared sets); "
          f"{len(missing)} target names absent from CommandSet.ini.",
          file=sys.stderr)
    if excluded:
        print("  (excluded: " + ", ".join(excluded) + ")", file=sys.stderr)
    if missing:
        print("  (absent: likely upgrade sets defined elsewhere or typos: "
              + ", ".join(missing[:8]) + (" ..." if len(missing) > 8 else ""),
              file=sys.stderr)

    # 3) Write overrides.
    btn_dir = os.path.join(install_root, "Data", "INI", "OverrideCommandButton")
    set_dir = os.path.join(install_root, "Data", "INI", "OverrideCommandSet")
    os.makedirs(btn_dir, exist_ok=True)
    os.makedirs(set_dir, exist_ok=True)

    btn_path = os.path.join(btn_dir, "_zz_GuardFromPosition.ini")
    with open(btn_path, "w", encoding="latin-1", newline="\r\n") as f:
        f.write(CMD_BUTTON_INI)
    print(f"wrote {btn_path}", file=sys.stderr)

    set_path = os.path.join(set_dir, "_zz_GuardFromPosition.ini")
    with open(set_path, "w", encoding="latin-1", newline="\r\n") as f:
        f.write("; Loose override generated by scripts/cwc_guard_patch.py\n")
        f.write("; Adds Command_GuardFromPosition to every CWC combat vehicle +\n")
        f.write("; aircraft CommandSet (NOT infantry). Filename '_zz_' sorts AFTER\n")
        f.write("; base entries so loadDirectory chains these overrides on top.\n")
        f.write(f"; {len(patched)} CommandSets patched.\n\n")
        for block in patched:
            f.write("\n".join(block))
            f.write("\n\n")
    print(f"wrote {set_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
