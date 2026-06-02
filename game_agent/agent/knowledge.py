"""Game-knowledge digest built from the GAME's own /catalog — so the LLM knows the RULES (units,
buildings, costs, fuel/power, prerequisites/tech-tree, and which units can CAPTURE) instead of guessing
or hallucinating stock-game names. The catalog is static for a match, so this is composed ONCE and
injected into the planner's system context.

Everything here is sourced from /catalog (incl. the engine-provided `canCapture` / `abilities`); nothing
is hardcoded per faction.
"""

_BLD_CATS = ("structure", "building", "garrisonable", "economy")


def faction_prefix(side=None, my_templates=None):
    """Resolve the CWC template prefix (CWCus / CWCru) for the bot, preferring its actual unit/building
    template names, falling back to the side string."""
    for t in (my_templates or []):
        tl = t or ""
        if tl.startswith("CWCus"):
            return "CWCus"
        if tl.startswith("CWCru"):
            return "CWCru"
    s = (side or "").lower()
    if "rus" in s:
        return "CWCru"
    if "usa" in s or "america" in s or s == "us":
        return "CWCus"
    return None


def _short(dn):
    return " ".join((dn or "").replace("\n", " ").split())[:48]


def capture_capable_templates(catalog):
    """Template names the engine reports as able to capture buildings/flags (data-driven, no guessing)."""
    return {e.get("name") for e in (catalog or []) if e.get("canCapture")}


def compose_catalog_digest(catalog, prefix):
    """A compact, readable rules sheet for the bot's faction: every building and unit it can make,
    with cost, fuel, prerequisites and capture ability — all from the live catalog."""
    if not prefix or not catalog:
        return ""
    mine = [e for e in catalog if (e.get("name") or "").startswith(prefix)]
    blds = [e for e in mine if e.get("category") in _BLD_CATS]
    units = [e for e in mine if e.get("category") == "unit"]
    cap_names = sorted(e.get("name") for e in units if e.get("canCapture"))

    lines = ["GAME KNOWLEDGE (CWC mod, your faction). Build/train ONLY these exact template names.",
             "ECONOMY/POWER: fuel +N = produces fuel (power), -N = consumes it; keep total >= 0."]
    if cap_names:
        lines.append("CAPTURE: only these units can capture flags/oil/tech points: " + ", ".join(cap_names))
    lines.append("BUILDINGS:")
    for e in sorted(blds, key=lambda x: x.get("cost", 0)):
        bits = ["${}".format(e.get("cost", 0))]
        if e.get("power"):
            bits.append("fuel {:+d}".format(e["power"]))
        if e.get("prerequisites"):
            bits.append("needs " + ", ".join(e["prerequisites"]))
        lines.append("- {} ({}): {}".format(e.get("name"), _short(e.get("displayName")), "; ".join(bits)))
    lines.append("UNITS:")
    for e in sorted(units, key=lambda x: x.get("cost", 0)):
        bits = ["${}".format(e.get("cost", 0))]
        tags = [t for t in (e.get("tags") or []) if t not in ("infantry",)]
        if tags:
            bits.append("/".join(tags))
        if e.get("prerequisites"):
            bits.append("needs " + ", ".join(e["prerequisites"]))
        if e.get("canCapture"):
            bits.append("CAN CAPTURE")
        lines.append("- {} ({}): {}".format(e.get("name"), _short(e.get("displayName")), "; ".join(bits)))
    return "\n".join(lines)
