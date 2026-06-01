#!/usr/bin/env python3
"""Generate loose-override INI patch that adds Command_GuardFromPosition to every
CWC CommandSet that currently has Command_Guard at slot 13.

Input:  CWC's extracted CommandSet.ini (CRLF, Windows line endings)
Output: ZH-install-root/Data/INI/CommandSet.ini  and  Data/INI/CommandButton.ini

Reads:  /tmp/cwc_extract/CommandSet.ini
Writes: <install>/Data/INI/CommandSet.ini
        <install>/Data/INI/CommandButton.ini
"""
import os
import re
import sys


def parse_command_sets(text):
    """Returns ordered list of (name, lines[]) for every CommandSet block."""
    # Split on lines while preserving \r\n→\n. We'll re-emit CRLF on write.
    lines = text.replace("\r\n", "\n").split("\n")
    sets = []
    cur_name = None
    cur_lines = []
    set_re = re.compile(r"^\s*CommandSet\s+(\S+)\s*$")
    end_re = re.compile(r"^\s*End\s*$", re.IGNORECASE)
    for ln in lines:
        m = set_re.match(ln)
        if m and cur_name is None:
            cur_name = m.group(1)
            cur_lines = [ln]
            continue
        if cur_name is not None:
            cur_lines.append(ln)
            if end_re.match(ln):
                sets.append((cur_name, cur_lines))
                cur_name = None
                cur_lines = []
    return sets


# All guard-family button name patterns we want to detect. Matters because CWC
# has faction- and general-specific variants (CWCus, CWCru, SupW, Lazr…) and
# the original script only matched Command_Guard exactly, missing ~500 CWC sets.
GUARD_VARIANTS_RE = re.compile(
    r"^\s*\d+\s*=\s*Command_("
    r"Guard|"                          # vanilla Guard
    r"CWCusGuard|CWCruGuard|"          # CWC faction generals
    r"SupW_.*Guard|Lazr_.*Guard|"      # CWC sub-generals prefix
    r"GuardWithoutPursuit|"            # vanilla Guard Close
    r"CWCusGuardWithoutPursuit|CWCruGuardWithoutPursuit|"
    r"GuardFlyingUnitsOnly|"           # Guard Air
    r"CWCusGuardFlyingUnitsOnly|CWCruGuardFlyingUnitsOnly|"
    r"CWCusGuardWithoutPursuitFlyingUnitsOnly"
    r")\s*(;.*)?$"
)


def block_has_guard(lines):
    """True if any 'N = Command_*Guard*' (including CWC faction/general variants)
    appears in this CommandSet block. Wider than the original which only matched
    plain Command_Guard."""
    for ln in lines:
        if GUARD_VARIANTS_RE.match(ln):
            return True
    return False


def patched_block(name, lines):
    """Re-spec this CommandSet with Command_GuardFromPosition pinned to slot 10.

    Strategy: we always place GFP at slot 10 (rather than first-free-of-[12,10,...]).
    Two reasons:
    1. Many CWC CommandSets already have slot 12 occupied by a faction-specific Guard
       variant (e.g. Command_CWCusGuardWithoutPursuit). The original first-free strategy
       quietly fell through to a different slot per unit type, so the button position
       was inconsistent (visible on some units, hidden on others depending on which
       slot won the lottery).
    2. Slot 10 is empty in ~all CWC vehicle/infantry CommandSets we've inspected, so
       overwriting is rare. When it IS taken, the existing entry gets pushed to the
       lowest free slot in [12, 8, 6, 4, 2, 11, 9, 7, 5, 3, 1] so we don't lose
       functionality.
    """
    assign_re = re.compile(r"^\s*(\d+)\s*=\s*(\S+)")
    used = {}
    body = []
    for ln in lines:
        m = assign_re.match(ln)
        if m:
            n = int(m.group(1))
            used[n] = ln.rstrip()
        else:
            body.append(ln.rstrip())

    GFP_SLOT = 10
    if GFP_SLOT in used:
        # slot 10 was already taken — push displaced entry to a free spot
        displaced = used[GFP_SLOT]
        for s in [12, 8, 6, 4, 2, 11, 9, 7, 5, 3, 1]:
            if s not in used:
                # Re-emit the displaced line with the new slot number prefix
                m2 = assign_re.match(displaced)
                if m2:
                    used[s] = f"  {s:2d} = {m2.group(2)}"
                break

    used[GFP_SLOT] = f"  {GFP_SLOT:2d} = Command_GuardFromPosition"

    out = [f"CommandSet {name}"]
    for i in sorted(used.keys()):
        out.append(used[i])
    out.append("End")
    return out


CMD_BUTTON_INI = """\
;------------------------------------------------------------------------------
; Guard-From-Position command button.
; Added by macOS port (TheSuperHackers @feature). Two-click flow:
;   1) Click puts the unit's HOME position.
;   2) Second click sets the WATCH zone - unit attacks anything that enters it
;      and returns home when threat clears.
; Reuses Guard icon and Guard radius cursor for now.
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
        print("usage: cwc_guard_patch.py <cwc_extract_dir> <install_root>")
        print("  example: cwc_guard_patch.py /tmp/cwc_extract '/Users/.../Command and Conquer Generals Zero Hour/Command and Conquer Generals Zero Hour'")
        sys.exit(1)

    extract_dir = sys.argv[1]
    install_root = sys.argv[2]

    src = os.path.join(extract_dir, "CommandSet.ini")
    with open(src, "rb") as f:
        text = f.read().decode("latin-1")

    sets = parse_command_sets(text)
    print(f"Parsed {len(sets)} CommandSet blocks from CWC.", file=sys.stderr)

    patched = []
    for name, lines in sets:
        if not block_has_guard(lines):
            continue
        new = patched_block(name, lines)
        if new is None:
            print(f"  skip (all slots used): {name}", file=sys.stderr)
            continue
        patched.append(new)

    print(f"Patching {len(patched)} guard-bearing CommandSets.", file=sys.stderr)

    # Drop overrides into the engine-recognised CREATE_OVERRIDES dirs (added in
    # ControlBar::init), NOT the standard CommandSet/ subdir. The standard subdir
    # loads in OVERWRITE mode and parseCommandSetDefinition throws INI_INVALID_DATA on
    # duplicates. OverrideCommandSet/ loads in CREATE_OVERRIDES, which routes through
    # newCommandSetOverride() and quietly chains the override on top of the base entry.
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
        f.write("; Filename starts with '_zz_' so it sorts AFTER the base CommandSet entries\n")
        f.write("; in INI::loadDirectory (which loads alphabetically). Each block here re-spec's\n")
        f.write("; a guard-bearing CommandSet and adds Command_GuardFromPosition at slot 12.\n")
        f.write("; In release builds the engine silently overwrites the in-memory CommandSet.\n\n")
        for block in patched:
            f.write("\n".join(block))
            f.write("\n\n")
    print(f"wrote {set_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
