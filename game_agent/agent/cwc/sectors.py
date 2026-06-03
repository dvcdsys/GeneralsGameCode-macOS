"""SectorModel — divide the map into sectors and keep per-sector statistics.

Two construction strategies (the plan's 4a/4b):
  - GRID (default): an N×N grid over the map's world-coordinate bounds.  Zero
    engine dependency, works the instant we know the map dimensions.
  - ZONE (optional later): pathfinder connectivity zones from /map?zone=1.

Per-sector stats are written by BattlefieldIntel each tick (enemy seen, my units,
capture points, last combat frame).  classify() labels sectors home/front/flank/
rear relative to my base and the estimated enemy base, which the expansion/recon
goals use to place squads and scouts.  Pure model; issues no commands.
"""
import math


class SectorModel:
    def __init__(self, world, grid=4):
        # world bounds in world units (cells * cellSize)
        self.cell = (world.cell or 10)
        self.W = (world.width or 0) * self.cell
        self.H = (world.height or 0) * self.cell
        self.n = max(2, grid)
        self.sw = (self.W / self.n) if self.W else 1
        self.sh = (self.H / self.n) if self.H else 1
        self.stats = {}            # sid -> accumulators (reset/aged by intel)

    # -- geometry ----------------------------------------------------------
    def sector_of(self, x, y):
        if not self.W or not self.H:
            return (0, 0)
        cx = min(self.n - 1, max(0, int(x / self.sw)))
        cy = min(self.n - 1, max(0, int(y / self.sh)))
        return (cx, cy)

    def centroid(self, sid):
        cx, cy = sid
        return ((cx + 0.5) * self.sw, (cy + 0.5) * self.sh)

    def neighbors(self, sid):
        cx, cy = sid
        out = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < self.n and 0 <= ny < self.n:
                    out.append((nx, ny))
        return out

    def all_sectors(self):
        return [(x, y) for x in range(self.n) for y in range(self.n)]

    # -- classification relative to my/enemy base --------------------------
    def classify(self, sid, my_base, enemy_base):
        """home / front_edge / flank / rear / contested / neutral."""
        if not my_base:
            return "neutral"
        c = self.centroid(sid)
        dm = math.hypot(c[0] - my_base[0], c[1] - my_base[1])
        diag = math.hypot(self.W, self.H) or 1
        if dm < 0.18 * diag:
            return "home"
        if not enemy_base:
            return "neutral"
        de = math.hypot(c[0] - enemy_base[0], c[1] - enemy_base[1])
        if de < 0.22 * diag:
            return "front_edge"          # next to the enemy = our assault front
        # project onto the my->enemy axis to tell front vs flank vs rear
        ax, ay = enemy_base[0] - my_base[0], enemy_base[1] - my_base[1]
        alen = math.hypot(ax, ay) or 1
        ux, uy = ax / alen, ay / alen
        vx, vy = c[0] - my_base[0], c[1] - my_base[1]
        along = (vx * ux + vy * uy)      # distance toward the enemy
        perp = abs(vx * (-uy) + vy * ux)  # lateral offset from the axis
        if along < 0:
            return "rear"
        if perp > 0.3 * diag:
            return "flank"
        return "contested"

    # -- stats (written by intel) -----------------------------------------
    def reset_stats(self):
        self.stats = {}

    def bump(self, sid, key, n=1):
        s = self.stats.setdefault(sid, {})
        s[key] = s.get(key, 0) + n

    def snapshot(self, my_base=None, enemy_base=None):
        """Compact per-sector view for the UI overlay."""
        out = []
        for sid in self.all_sectors():
            s = self.stats.get(sid, {})
            out.append({
                "sid": list(sid),
                "x": (sid[0] + 0.5) * self.sw,
                "y": (sid[1] + 0.5) * self.sh,
                "w": self.sw, "h": self.sh,
                "cls": self.classify(sid, my_base, enemy_base),
                "enemy": s.get("enemy", 0),
                "mine": s.get("mine", 0),
                "points": s.get("points", 0),
            })
        return {"n": self.n, "sectors": out}
