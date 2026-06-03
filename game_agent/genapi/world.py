"""WorldModel - decode the game's /map + /units into a queryable world state for agents.

This is the harness's in-memory model of what the agent "sees": the terrain grid (passability /
buildable surface / height) plus classified objects (relation + category + tags). Agents query this
instead of poking raw JSON.
"""

import base64
import math

# PathfindCell::CellType (see /map legend)
CELL_CLEAR, CELL_WATER, CELL_CLIFF, CELL_RUBBLE, CELL_OBSTACLE, CELL_IMPASSABLE = 0, 1, 2, 3, 4, 6
TYPE_NAME = {0: "clear", 1: "water", 2: "cliff", 3: "rubble", 4: "obstacle", 6: "impassable", 255: "unknown"}


class WorldModel:
    def __init__(self, mp, units, players, owner=None):
        self.raw_map = mp or {}
        self.units = units or []
        self.players = players or []
        # The querying agent's own player index. In OBSERVER mode the API's "local" player is the
        # observer, so relationToLocal=='enemy' is true for BOTH the bot and the real enemy — without
        # excluding `owner`, enemies() returns the bot's OWN units/buildings (it then targets its own
        # base and counts its own army as the enemy force). None = no exclusion (normal-perspective use).
        self.owner = owner
        self.width = self.raw_map.get("width", 0)
        self.height = self.raw_map.get("height", 0)
        self.cell = self.raw_map.get("cellSize", 10)
        self.types = base64.b64decode(self.raw_map["type"]) if self.raw_map.get("type") else b""
        hf = self.raw_map.get("heightField", {})
        self.height_data = base64.b64decode(hf["data"]) if hf.get("data") else None
        self.h_min = hf.get("min", 0.0)
        self.h_max = hf.get("max", 0.0)
        self.rel_by_index = {p.get("index"): p.get("relationToLocal", "neutral") for p in self.players}

    @classmethod
    def from_api(cls, client, view=None, ds=1):
        return cls(client.map(ds=ds), client.units(view=view), client.players())

    # --- terrain ---------------------------------------------------------------
    def _cell_index(self, wx, wy):
        cx, cy = int(wx / self.cell), int(wy / self.cell)
        if 0 <= cx < self.width and 0 <= cy < self.height:
            return cy * self.width + cx
        return None

    def cell_type(self, wx, wy):
        i = self._cell_index(wx, wy)
        return self.types[i] if (i is not None and i < len(self.types)) else 255

    def cell_type_name(self, wx, wy):
        return TYPE_NAME.get(self.cell_type(wx, wy), "unknown")

    def passable(self, wx, wy):
        """Ground-passable (clear or rubble); water/cliff/obstacle/impassable are not."""
        return self.cell_type(wx, wy) in (CELL_CLEAR, CELL_RUBBLE)

    def buildable(self, wx, wy):
        """Coarse build-surface check (clear ground). Confirm exact spots via the engine's
        BuildAssistant once /query/can_build exists."""
        return self.cell_type(wx, wy) == CELL_CLEAR

    def ground_height(self, wx, wy):
        if not self.height_data:
            return 0.0
        i = self._cell_index(wx, wy)
        if i is None or i >= len(self.height_data):
            return 0.0
        span = (self.h_max - self.h_min) or 1.0
        return self.h_min + (self.height_data[i] / 255.0) * span

    # --- objects ---------------------------------------------------------------
    def objects(self, category=None, relation=None, owner=None, tag=None):
        out = []
        for u in self.units:
            if category is not None and u.get("category") != category:
                continue
            if relation is not None and u.get("relationToLocal") != relation:
                continue
            if owner is not None and u.get("player") != owner:
                continue
            if tag is not None and tag not in u.get("tags", []):
                continue
            out.append(u)
        return out

    def my_units(self, owner):
        return [u for u in self.units if u.get("player") == owner and u.get("category") == "unit"]

    def enemies(self):
        out = self.objects(relation="enemy")
        if self.owner is not None:
            out = [u for u in out if u.get("player") != self.owner]
        return out

    def economy_points(self):
        """Capturable oil/supply points (capture targets)."""
        return [u for u in self.units
                if "supply_source" in u.get("tags", []) or "cash_generator" in u.get("tags", [])]

    def garrisonable(self):
        """Civilian buildings usable as bunkers."""
        return self.objects(tag="garrisonable")

    @staticmethod
    def centroid(objs):
        pts = [(u["x"], u["y"]) for u in objs if "x" in u]
        if not pts:
            return None
        return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))

    @staticmethod
    def nearest(objs, x, y):
        best, bd = None, None
        for u in objs:
            if "x" not in u:
                continue
            d = math.hypot(u["x"] - x, u["y"] - y)
            if bd is None or d < bd:
                best, bd = u, d
        return best
