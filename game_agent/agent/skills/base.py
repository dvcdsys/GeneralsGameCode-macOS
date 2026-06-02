"""Skill base class + shared execution context + helper queries.

A skill's `tick(ctx)` is called by the executor every fast tick. It advances the skill's own state
machine, issues commands through `ctx.client`, and returns/sets a status. Skills must be:

- **Idempotent-ish:** re-issuing intent (move/guard/attack-move) every few ticks is fine.
- **Self-limiting:** give up (FAILED) after a bounded number of retries / a timeout, never spin forever.
- **Defensive about live JSON shapes:** the game's /units + /buildable keys can vary; the helpers below
  try several key names so a skill degrades gracefully rather than crashing the whole executor.
"""

import math

# --- statuses ------------------------------------------------------------------
PENDING = "pending"      # accepted, not yet acted on
RUNNING = "running"      # in progress
DONE = "done"            # completed successfully (terminal)
FAILED = "failed"        # could not complete (terminal)
BLOCKED = "blocked"      # waiting on a precondition (money/power/builder) — retried each tick
CANCELLED = "cancelled"  # cancelled by planner/human (terminal)

TERMINAL = (DONE, FAILED, CANCELLED)


class SkillContext:
    """Everything a skill needs for one tick. Rebuilt each executor tick (world/frame are fresh)."""

    def __init__(self, world, me, client, threats=None, journal=None, frame=0, taskmgr=None):
        self.world = world
        self.me = me
        self.client = client
        self.threats = threats
        self.journal = journal
        self.frame = frame
        self.taskmgr = taskmgr  # lets a skill see sibling tasks (e.g. avoid double-booking a dozer)

    @property
    def player(self):
        return self.me["index"]


class Skill:
    name = "skill"
    description = "abstract skill"
    # JSON Schema for the tool's `parameters` (OpenAI/Ollama function-calling shape).
    param_schema = {"type": "object", "properties": {}, "required": []}

    def __init__(self, params=None):
        self.params = dict(params or {})
        self.status = PENDING
        self.detail = ""
        self.started_frame = None
        self._attempts = 0

    # subclasses implement this; set self.status / self.detail, optionally issue commands via ctx.client
    def tick(self, ctx):
        raise NotImplementedError

    def status_line(self):
        return self.detail or self.status

    @classmethod
    def tool_spec(cls):
        """The Ollama/OpenAI function-calling descriptor for this skill."""
        return {
            "type": "function",
            "function": {
                "name": cls.name,
                "description": cls.description,
                "parameters": cls.param_schema,
            },
        }

    # --- small helpers for subclasses -----------------------------------------
    def _begin(self, ctx):
        if self.started_frame is None:
            self.started_frame = ctx.frame

    def _elapsed(self, ctx):
        return ctx.frame - (self.started_frame or ctx.frame)


# ==============================================================================
# Shared world/queries helpers (defensive about live JSON key names)
# ==============================================================================

def obj_pos(u):
    return (u.get("x", 0.0), u.get("y", 0.0))


def is_building(u):
    # NB: in the CWC mod many production buildings report category "garrisonable" (you can garrison
    # them), and oil/supply report "economy" — they are all immobile structures, so count them.
    cat = u.get("category")
    if cat in ("structure", "building", "garrisonable", "economy"):
        return True
    tags = u.get("tags", [])
    return ("structure" in tags) or ("building" in tags)


def my_objects(ctx, category=None):
    p = ctx.player
    out = []
    for u in ctx.world.units:
        if u.get("player") != p:
            continue
        if category == "unit" and u.get("category") != "unit":
            continue
        if category == "building" and not is_building(u):
            continue
        out.append(u)
    return out


def my_units(ctx):
    """My mobile units (category == 'unit')."""
    return my_objects(ctx, "unit")


def my_buildings(ctx):
    return my_objects(ctx, "building")


def find_object(world, oid):
    for u in world.units:
        if u.get("id") == oid:
            return u
    return None


def is_dozerish(u):
    t = (u.get("template") or "").lower()
    tags = [str(x).lower() for x in u.get("tags", [])]
    return ("dozer" in t or "worker" in t or "construction" in t
            or "dozer" in tags or "worker" in tags)


# Templates that are units but NOT front-line fighters — never send these to attack/defend.
_NONCOMBAT_HINTS = ("dozer", "worker", "construction", "drone", "drop", "supply",
                    "ambulance", "tractor", "crawler", "spy", "medic")


def is_combat_unit(u):
    if u.get("category") != "unit":
        return False
    t = (u.get("template") or "").lower()
    return not any(h in t for h in _NONCOMBAT_HINTS)


def find_dozers(ctx):
    """Construction units (dozers / workers) owned by me."""
    return [u for u in my_units(ctx) if is_dozerish(u)]


def _entry_name(e):
    for k in ("template", "name", "internalName", "displayName"):
        v = e.get(k)
        if v:
            return v
    return None


def _entry_builder(e):
    for k in ("builderId", "builder", "factoryId", "producerId", "id"):
        v = e.get(k)
        if v:
            return v
    return None


def buildable_now(ctx):
    """Raw /buildable payload (defensive — returns {} on miss)."""
    bd = ctx.client.buildable(ctx.player)
    return bd if isinstance(bd, dict) else {}


def find_producer(ctx, template):
    """Return (builderId, entry) for a unit/structure makeable right now, matching `template`
    (case-insensitive exact, then substring). None if nothing currently makes it."""
    bd = buildable_now(ctx)
    avail = bd.get("available") or bd.get("items") or []
    tl = template.lower()
    # exact first
    for e in avail:
        nm = (_entry_name(e) or "").lower()
        if nm == tl:
            b = _entry_builder(e)
            if b:
                return b, e
    # substring fallback
    for e in avail:
        nm = (_entry_name(e) or "").lower()
        if nm and (tl in nm or nm in tl):
            b = _entry_builder(e)
            if b:
                return b, e
    return None, None


def select_combat_units(ctx, ids=None, near=None, radius=None):
    """Pick a working set of FIGHTING units: explicit `ids` if given (filtered to combat units), else
    all my combat units (optionally those within `radius` of `near`). Excludes dozers, drones, supply,
    etc. so we never 'attack' with a builder or a recon drone."""
    if ids:
        idset = set(ids)
        return [u for u in my_units(ctx) if u.get("id") in idset and is_combat_unit(u)]
    pool = [u for u in my_units(ctx) if is_combat_unit(u)]
    if near is not None and radius is not None:
        nx, ny = near
        pool = [u for u in pool if math.hypot(u.get("x", 0) - nx, u.get("y", 0) - ny) <= radius]
    return pool


def find_trainable(ctx, predicate):
    """All currently-trainable/buildable items matching predicate(template_lower, entry) ->
    list of (template, builderId, cost, entry)."""
    bd = buildable_now(ctx)
    avail = bd.get("available") or bd.get("items") or []
    out = []
    for e in avail:
        t = _entry_name(e)
        if t and predicate(t.lower(), e):
            out.append((t, _entry_builder(e), e.get("cost", 0), e))
    return out


def find_trainable_combat(ctx):
    """Combat units producible right now (cheapest first)."""
    r = find_trainable(ctx, lambda tl, e: e.get("how") == "train"
                        and not any(h in tl for h in _NONCOMBAT_HINTS))
    return sorted(r, key=lambda x: x[2])


def find_trainable_dozer(ctx):
    r = find_trainable(ctx, lambda tl, e: e.get("how") == "train"
                       and ("dozer" in tl or "worker" in tl))
    return r[0] if r else None


def capturable_points(ctx):
    """Neutral/enemy economy + tech points worth capturing (oil/supply/cash/tech/capturable flags),
    not already mine. These give economy and map control — capture them early."""
    out = []
    for u in ctx.world.units:
        if u.get("player") == ctx.player:
            continue
        cat = u.get("category")
        tags = [str(t).lower() for t in u.get("tags", [])]
        is_cap = (cat == "economy"
                  or any(t in tags for t in ("supply_source", "cash_generator", "capturable", "tech")))
        if is_cap and u.get("relationToLocal") in ("neutral", "enemy") and "x" in u:
            out.append(u)
    return out


def resolve_point(ctx, params, default=None):
    """Resolve a target point from params: explicit `pos`, then `area`, then `default`, then base
    centroid, then map centre."""
    for key in ("pos", "area", "location", "at"):
        p = params.get(key)
        if isinstance(p, dict) and "x" in p and "y" in p:
            return (float(p["x"]), float(p["y"]))
    if default is not None:
        return default
    base = ctx.world.centroid(my_buildings(ctx)) or ctx.world.centroid(my_units(ctx))
    if base:
        return base
    return (ctx.world.width * ctx.world.cell / 2.0, ctx.world.height * ctx.world.cell / 2.0)


def find_build_spot(ctx, cx, cy, attempt=0, min_radius=200.0, max_radius=900.0,
                    step=60.0, clearance=190.0):
    """Find a placement cell near (cx,cy) that is terrain-buildable AND far enough from existing
    buildings. The engine rejects 'illegal build location' for cells too close to the base even when
    the terrain is clear — empirically a structure must sit ~200+ world-units from existing buildings,
    not just on clear ground. So we start the search at `min_radius` and require `clearance` from every
    known building, rather than hugging the base.

    `attempt` rotates the search so each retry probes a *different* sector — without this, a rejected
    spot is re-picked identically and every retry fails the same way. Final legality is still validated
    game-side (isLocationLegalToBuild); this keeps candidates inside the usually-legal envelope and
    keeps retries moving."""
    w = ctx.world
    blds = [(u.get("x", 0.0), u.get("y", 0.0)) for u in ctx.world.units if is_building(u)]

    def clear_of_buildings(x, y):
        return all(math.hypot(x - bx, y - by) >= clearance for bx, by in blds)

    base_ang = attempt * 1.7  # irrational-ish step so successive attempts spread around the circle
    # pass 1: buildable terrain AND clear of building footprints
    r = min_radius
    while r <= max_radius:
        steps = max(8, int(2 * math.pi * r / step))
        for k in range(steps):
            a = base_ang + 2 * math.pi * k / steps
            x, y = cx + r * math.cos(a), cy + r * math.sin(a)
            if w.buildable(x, y) and clear_of_buildings(x, y):
                return (x, y)
        r += step
    # pass 2: relax the footprint check, just need buildable terrain
    r = min_radius
    while r <= max_radius:
        steps = max(8, int(2 * math.pi * r / step))
        for k in range(steps):
            a = base_ang + 2 * math.pi * k / steps
            x, y = cx + r * math.cos(a), cy + r * math.sin(a)
            if w.buildable(x, y):
                return (x, y)
        r += step
    return (cx, cy)
