"""uistate — serialize Commander + KnowledgeBase + intel into the /tmp JSON files
the browser viewer (ui/map_live.html) polls.

Two channels, same file idiom as the rest of the harness:
  /tmp/gen_agent_state.json   -- live, written every tick (state + intel)
  /tmp/gen_agent_static.json  -- written once per match (the knowledge tables)

The commander agent never wrote the live state file before (only the LLM
orchestrator did), so the viewer's right panel was empty under --agent commander.
build_state() fixes that and adds an "intel" block for the new debug panels.

Kept dependency-free and defensive: any missing piece just yields a partial dict;
the front-end renders "—" for absent fields.
"""
import json
import os
import tempfile

STATE_PATH = "/tmp/gen_agent_state.json"
STATIC_PATH = "/tmp/gen_agent_static.json"


def atomic_write(path, obj):
    """Write JSON atomically so the viewer never reads a half-written file."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:  # noqa: BLE001
        try:
            os.unlink(tmp)
        except OSError:
            pass


def build_static(kb):
    """One-shot snapshot of the knowledge tables for the UI 'Knowledge' tab.

    Trimmed to combat-relevant templates (those with an effectiveness row OR a
    BuildCost) so the browser isn't handed 769 props/effects.  The counter matrix
    is shipped as a compact attacker -> {defender: effDps} for the units that
    actually fight, keyed by template (defenders limited to the same set)."""
    if not kb or not kb.loaded:
        return {"ok": False}

    combat = sorted(
        n for n, o in kb.units.items()
        if (n in kb.effectiveness) or (o.get("BuildCost") and
                                       "STRUCTURE" not in o.get("kindOf", [])))
    buildings = sorted(
        n for n, o in kb.units.items()
        if "STRUCTURE" in o.get("kindOf", []) and o.get("BuildCost"))

    def unit_card(n):
        o = kb.units.get(n, {})
        er = kb.effectiveness.get(n, {})
        return {
            "template": n,
            "side": o.get("Side"),
            "cost": o.get("BuildCost"),
            "buildTime": o.get("BuildTime"),
            "hp": o.get("maxHealth"),
            "vision": o.get("ShroudClearingRange") or o.get("VisionRange"),
            "armor": o.get("armor"),
            "roles": kb.roles.get(n, []),
            "dps": er.get("dps"),
            "range": er.get("range"),
            "damageTypes": sorted({w.get("damageType")
                                   for w in er.get("weapons", [])
                                   if w.get("damageType")}),
            "prereq": kb.prereq(n),
            "transportSlots": o.get("TransportSlotCount"),
            "aliasedFrom": er.get("aliasedFrom"),
        }

    # counter matrix limited to combat attackers x combat defenders
    matrix = {}
    defenders = [d for d in combat if kb.units.get(d, {}).get("armor")]
    for a in combat:
        er = kb.effectiveness.get(a)
        if not er:
            continue
        row = {}
        for d in defenders:
            v = kb.effective_dps(a, d)
            if v:
                row[d] = v
        if row:
            matrix[a] = row

    return {
        "ok": True,
        "meta": kb.meta,
        "units": [unit_card(n) for n in combat],
        "buildings": [unit_card(n) for n in buildings],
        "matrix": matrix,
        "matrixDefenders": defenders,
    }


def build_state(ctx, cmdr, world):
    """Live per-tick state for the viewer right panel + intel debug panels."""
    me = ctx.me or {}
    detail = getattr(cmdr, "last_detail", {}) or {}
    intel = getattr(cmdr, "intel", None)
    sectors = getattr(cmdr, "sectors", None)
    # sector overlay (classified relative to my base + the estimated enemy base)
    sect_snap = None
    if sectors is not None:
        try:
            from agent.brief import _enemy_base_guess
            from agent.skills.base import my_buildings, my_units
            core = [u for u in my_buildings(ctx)
                    if not (u.get("template") or "").startswith("CWCciv")]
            my_base = world.centroid(core) if core else None
            eb = _enemy_base_guess(world, my_buildings(ctx), my_units(ctx))
            enemy_base = (eb["x"], eb["y"]) if eb else None
            sect_snap = sectors.snapshot(my_base, enemy_base)
        except Exception:  # noqa: BLE001
            sect_snap = None
    state = {
        "inGame": True,
        "frame": ctx.frame,
        "me": {
            "player": me.get("index"),
            "side": me.get("side"),
            "money": me.get("money"),
            "power": (me.get("powerProduction", 0) or 0) -
                     (me.get("powerConsumption", 0) or 0),
        },
        "directive": getattr(cmdr, "directive", None),
        "detail": detail,
        "tasks": {"active": [], "history": []},
        "notes": [],
        "events": (ctx.journal.digest(16) if getattr(ctx, "journal", None) else []),
        "threats": (ctx.threats.threats(ctx.frame)
                    if getattr(ctx, "threats", None) else []),
        "intel": intel.snapshot() if intel and hasattr(intel, "snapshot") else None,
        "sectors": sect_snap,
        "dozer": getattr(cmdr, "_dozer_plan", None),
    }
    return state
