"""compose_brief — turn the full WorldModel + memory into a small structured brief for the LLM.

This is the crux of making a small model play well: a 7-30B model cannot read thousands of objects, so
we hand it a compact, stable digest — my economy, my forces grouped by type, visible enemy contacts,
the always-known economy/capture geography (with fog status), what I can build right now, the live task
queue, the threat picture, recent notable events, my own notes, and the human commander's standing
directive. Everything is JSON-serialisable and intentionally terse (~1-3 KB).
"""

import math


def _group_by_template(objs):
    groups = {}
    for u in objs:
        t = u.get("template", "?")
        g = groups.setdefault(t, {"template": t, "count": 0, "ids": [], "xs": [], "ys": []})
        g["count"] += 1
        if len(g["ids"]) < 24:
            g["ids"].append(u.get("id"))
        if "x" in u:
            g["xs"].append(u["x"])
            g["ys"].append(u["y"])
    out = []
    for g in groups.values():
        xs, ys = g.pop("xs"), g.pop("ys")
        if xs:
            g["at"] = {"x": round(sum(xs) / len(xs)), "y": round(sum(ys) / len(ys))}
        out.append(g)
    out.sort(key=lambda g: -g["count"])
    return out


def _enemy_contacts(world):
    enemies = world.enemies()
    groups = {}
    for u in enemies:
        key = (u.get("template", "?"), u.get("shroud", "clear"))
        g = groups.setdefault(key, {"template": key[0], "shroud": key[1], "count": 0,
                                    "ids": [], "xs": [], "ys": []})
        g["count"] += 1
        if len(g["ids"]) < 12:
            g["ids"].append(u.get("id"))
        if "x" in u:
            g["xs"].append(u["x"])
            g["ys"].append(u["y"])
    out = []
    for g in groups.values():
        xs, ys = g.pop("xs"), g.pop("ys")
        if xs:
            g["at"] = {"x": round(sum(xs) / len(xs)), "y": round(sum(ys) / len(ys))}
        out.append(g)
    out.sort(key=lambda g: -g["count"])
    return out


def _points(world):
    """Economy/capture/garrison geography with fog status — always plannable."""
    out = []
    seen = set()
    for u in world.economy_points() + world.garrisonable():
        oid = u.get("id")
        if oid in seen:
            continue
        seen.add(oid)
        out.append({
            "id": oid,
            "template": u.get("template"),
            "kind": ("econ" if u in world.economy_points() else "garrison"),
            "shroud": u.get("shroud", "clear"),
            "relation": u.get("relationToLocal"),
            "at": {"x": round(u.get("x", 0)), "y": round(u.get("y", 0))},
        })
    return out[:40]


def _buildable(client, player):
    bd = client.buildable(player)
    if not isinstance(bd, dict):
        return {}
    avail = bd.get("available") or bd.get("items") or []
    names = []
    for e in avail:
        for k in ("template", "name", "internalName", "displayName"):
            if e.get(k):
                names.append(e[k])
                break
    prod = bd.get("powerProduction", 0) or 0
    cons = bd.get("powerConsumption", 0) or 0
    return {
        "money": bd.get("money"),
        "powerMargin": prod - cons,
        "makeableNow": sorted(set(names))[:60],
    }


def compose_brief(ctx, taskmgr, notes, directive=""):
    world, me = ctx.world, ctx.me
    p = ctx.player
    mine = [u for u in world.units if u.get("player") == p]
    my_units = [u for u in mine if u.get("category") == "unit"]
    my_blds = [u for u in mine if u.get("category") != "unit"]

    threats = ctx.threats.threats(ctx.frame) if ctx.threats else []
    brief = {
        "frame": ctx.frame,
        "me": {
            "player": p,
            "side": me.get("side") or me.get("faction"),
            "money": me.get("money"),
            "powerMargin": (me.get("powerProduction", 0) or 0) - (me.get("powerConsumption", 0) or 0),
            "unitCount": len(my_units),
            "buildingCount": len(my_blds),
        },
        "myForces": _group_by_template(my_units),
        "myBuildings": _group_by_template(my_blds),
        "buildable": _buildable(ctx.client, p),
        "enemyContacts": _enemy_contacts(world),
        "points": _points(world),
        "threats": [{"victim": t["victimId"], "attacker": t["topAttacker"],
                     "damage": t["damage"], "hits": t["hits"]} for t in threats[:8]],
        "tasks": taskmgr.summary(),
        "recentEvents": ctx.journal.digest(16) if ctx.journal else [],
        "notes": notes.lines() if notes else [],
        "directive": directive or "",
    }
    return brief
