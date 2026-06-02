"""compose_brief — turn the full WorldModel + memory into a small structured brief for the LLM.

This is the crux of making a small model play well: a 7-30B model cannot read thousands of objects, so
we hand it a compact, stable digest — my economy, my forces grouped by type, visible enemy contacts,
the always-known economy/capture geography (with fog status), what I can build right now, the live task
queue, the threat picture, recent notable events, my own notes, and the human commander's standing
directive. Everything is JSON-serialisable and intentionally terse (~1-3 KB).
"""

import math

from agent.skills.base import is_building, is_junk


def _group_by_template(objs):
    groups = {}
    for u in objs:
        t = u.get("template", "?")
        g = groups.setdefault(t, {"template": t, "count": 0, "ids": [], "xs": [], "ys": [], "_building": []})
        g["count"] += 1
        if len(g["ids"]) < 24:
            g["ids"].append(u.get("id"))
        if u.get("constructing"):
            g["_building"].append(round(u.get("constructionPercent", 0)))
        if "x" in u:
            g["xs"].append(u["x"])
            g["ys"].append(u["y"])
    out = []
    for g in groups.values():
        xs, ys = g.pop("xs"), g.pop("ys")
        bld = g.pop("_building")
        if xs:
            g["at"] = {"x": round(sum(xs) / len(xs)), "y": round(sum(ys) / len(ys))}
        if bld:  # some of these are still going up — show the commander so it doesn't duplicate
            g["constructing"] = "{} building ({}%)".format(len(bld), ",".join(str(p) for p in bld))
        out.append(g)
    out.sort(key=lambda g: -g["count"])
    return out


def _enemy_contacts(world):
    enemies = [u for u in world.enemies() if not is_junk(u)]  # drop shells/sensors/decoys/markers
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


def _base_centroid(objs):
    pts = [(u["x"], u["y"]) for u in objs if "x" in u]
    if not pts:
        return None
    return {"x": round(sum(x for x, _ in pts) / len(pts)),
            "y": round(sum(y for _, y in pts) / len(pts))}


def _enemy_base_guess(world, my_blds, my_units):
    """Best estimate of where to send the army to find & kill the enemy.
    1) If we've SCOUTED any enemy buildings, aim at their centroid (true location).
    2) Otherwise aim at the opposite corner: reflect our base through the map centre. On standard
       skirmish maps the AI starts in the far corner, so this reliably leads the strike force into
       the enemy base, where attack-move grinds through whatever is there."""
    enemy_blds = [u for u in world.enemies() if is_building(u) and "x" in u]
    if enemy_blds:
        g = _base_centroid(enemy_blds)
        return {**g, "source": "scouted", "count": len(enemy_blds)}
    home = _base_centroid(my_blds) or _base_centroid(my_units)
    if not home:
        return None
    w = (world.width or 0) * (world.cell or 0)
    h = (world.height or 0) * (world.cell or 0)
    if w and h:
        return {"x": round(w - home["x"]), "y": round(h - home["y"]), "source": "opposite_corner"}
    return None


def compose_brief(ctx, taskmgr, notes, directive=""):
    world, me = ctx.world, ctx.me
    p = ctx.player
    mine = [u for u in world.units if u.get("player") == p and not is_junk(u)]
    my_units = [u for u in mine if u.get("category") == "unit"]
    my_blds = [u for u in mine if is_building(u)]

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
        "myBaseAt": _base_centroid(my_blds) or _base_centroid(my_units),
        "enemyBaseGuess": _enemy_base_guess(world, my_blds, my_units),
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
        "currentStrategy": (notes.strategy if notes else None),
        "directive": directive or "",
    }
    return brief
