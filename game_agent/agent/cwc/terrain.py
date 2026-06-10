"""terrain — passability heatmap from the /map pathfinder grid.

The engine's hierarchical pathfinder RETRIES a failed path EVERY frame for as long as a unit holds an
unreachable order. When the whole assault attack_targets buildings whose tiles (and the cluttered tiles
around them) are non-pathable — especially a base tucked in a map corner — dozens of units flood
FindHierarchicalPath failures every frame, which bogs the sim and (with this DEBUG_CRC build) destabilizes
it at the assault climax.

Fix: don't hand units an unreachable goal. Decode the /map `type` grid (base64, one byte per cell, legend
clear=0 water=1 cliff=2 rubble=3 obstacle=4 impassable=6; buildings read as obstacle) into a passability
bitmap, and for a target building return a REACHABLE firing position near it (a clear cell on the approach
side, within weapon range). Units attack-MOVE there — a reachable goal, no per-frame path-fail flood — and
their attack-move auto-engages the building (and defenders) once in range.

Degrades safely: a missing/garbage grid → passable() returns True everywhere → staging falls back to the
raw building position (i.e. the old attack_target behaviour), never worse.
"""
import base64
import math

_BLOCKED = {1, 2, 4, 6}      # water, cliff, obstacle(=buildings), impassable. clear(0)/rubble(3) are walkable.


class Passability:
    def __init__(self, map_dict):
        self.ok = False
        self.W = self.H = 0
        self.cs = 10
        self.grid = b""
        try:
            self.W = int(map_dict["width"])
            self.H = int(map_dict["height"])
            self.cs = float(map_dict.get("cellSize", 10)) or 10
            raw = base64.b64decode(map_dict["type"])
            if len(raw) == self.W * self.H:
                self.grid = raw
                self.ok = True
        except Exception:  # noqa: BLE001 — any decode problem → degrade to "everything passable"
            self.ok = False

    def _cell(self, wx, wy):
        cx = int(wx // self.cs)
        cy = int(wy // self.cs)
        if 0 <= cx < self.W and 0 <= cy < self.H:
            return self.grid[cy * self.W + cx]
        return 255

    def passable(self, wx, wy):
        if not self.ok:
            return True
        return self._cell(wx, wy) not in _BLOCKED

    def nearest_clear(self, wx, wy, max_r=400.0, step=20.0):
        """Nearest walkable world point to (wx,wy) by expanding rings; None if nothing within max_r."""
        if not self.ok or self.passable(wx, wy):
            return (wx, wy)
        r = step
        while r <= max_r:
            n = max(8, int(2 * math.pi * r / step))
            for i in range(n):
                a = 2 * math.pi * i / n
                px, py = wx + math.cos(a) * r, wy + math.sin(a) * r
                if self.passable(px, py):
                    return (px, py)
            r += step
        return None

    def firing_pos(self, bx, by, fx, fy, weapon_range=300.0):
        """A REACHABLE firing position against the building at (bx,by) for a force coming from (fx,fy):
        walk inward from the force toward the building and return the LAST walkable point still within
        weapon_range of the building — i.e. as close as we can stand on clear ground and still shoot it.
        Falls back to the building position (old attack_target behaviour) when the grid is unknown."""
        if not self.ok:
            return (bx, by)
        d = math.hypot(bx - fx, by - fy)
        if d < 1.0:
            return (bx, by)
        ux, uy = (bx - fx) / d, (by - fy) / d
        best = None
        # sample from just outside weapon range up to the building edge
        start = max(0.0, d - weapon_range)
        t = start
        while t <= d:
            px, py = fx + ux * t, fy + uy * t
            if self.passable(px, py) and math.hypot(px - bx, py - by) <= weapon_range:
                best = (px, py)        # keep the closest-to-building walkable point in range
            t += self.cs
        if best is not None:
            return best
        # nothing on the direct line → nearest clear cell to the building
        nc = self.nearest_clear(bx, by, max_r=weapon_range)
        return nc or (bx, by)
