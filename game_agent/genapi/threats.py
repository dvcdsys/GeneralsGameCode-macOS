"""ThreatTracker - a background reactive layer over the WS /events 'combat' stream.

The decision loop is intentionally low-Hz (strategic), but "one of my units is being attacked" needs a
faster reaction than the next tick. This listener runs on its own daemon thread, filters `combat` events
to a given player, and aggregates them into a live threat picture that decide() can read cheaply:
per victim — who is hitting it, cumulative damage, hit count, last frame. Entries expire after a window
of no new hits, so the picture reflects *current* pressure.

The combat event is ground truth (not fog-filtered): `attackerId` is known even if the shooter sits in
fog. A fog-respecting agent should cross-check `attackerId`/`topAttacker` against its `view=N` units and,
if the attacker isn't visible, treat it as a direction-only threat (scout / reposition) rather than a
free target.

Usage:
    tt = ThreatTracker(client, owner=me["index"]).start()
    ...
    for t in tt.threats(now_frame):          # most-recent first
        # t["victimId"] is under attack by t["topAttacker"] (t["attackers"] = all), t["damage"], t["hits"]
    tt.stop()                                 # optional; it's a daemon thread otherwise
"""

import threading
import time


class ThreatTracker:
    def __init__(self, client, owner, ttl_frames=150):
        """owner = the player index whose units we watch (e.g. the external/bot player).
        ttl_frames = how long (in logic frames; ~30/s) a threat lingers after its last hit."""
        self._client = client
        self._owner = owner
        self._ttl = ttl_frames
        self._lock = threading.Lock()
        self._by_victim = {}      # victimId -> aggregate dict
        self._last_frame = 0
        self._stop = False
        self._thread = None

    # --- lifecycle -------------------------------------------------------------
    def start(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="threat-tracker", daemon=True)
            self._thread.start()
        return self

    def stop(self):
        self._stop = True

    def _run(self):
        while not self._stop:
            try:
                for ev in self._client.events():          # blocks; polls with a 1s socket timeout
                    if self._stop:
                        return
                    if ev.get("type") != "combat" or ev.get("player") != self._owner:
                        continue
                    self._record(ev)
            except Exception:  # noqa: BLE001  (match end / restart / WS blip) -> reconnect
                if self._stop:
                    return
                time.sleep(1.0)

    # --- aggregation -----------------------------------------------------------
    def _record(self, ev):
        f = int(ev.get("frame", 0))
        vid = ev.get("victimId")
        with self._lock:
            if f > self._last_frame:
                self._last_frame = f
            t = self._by_victim.get(vid)
            if t is None:
                t = {"victimId": vid, "attackers": {}, "damage": 0.0, "hits": 0,
                     "firstFrame": f, "lastFrame": f}
                self._by_victim[vid] = t
            aid = ev.get("attackerId")
            if aid:
                t["attackers"][aid] = t["attackers"].get(aid, 0) + 1
            t["damage"] += float(ev.get("amount", 0.0))
            t["hits"] += 1
            if f > t["lastFrame"]:
                t["lastFrame"] = f

    # --- query -----------------------------------------------------------------
    def threats(self, now_frame=None):
        """Current threats (most-recent first). Pass the live frame (client.healthz()['frame']) to
        expire stale entries precisely; otherwise the latest event frame is used."""
        with self._lock:
            nf = now_frame if now_frame is not None else self._last_frame
            cutoff = nf - self._ttl
            for vid in [v for v, t in self._by_victim.items() if t["lastFrame"] < cutoff]:
                del self._by_victim[vid]
            out = []
            for t in self._by_victim.values():
                ranked = sorted(t["attackers"].items(), key=lambda kv: -kv[1])
                out.append({
                    "victimId": t["victimId"],
                    "attackers": [a for a, _ in ranked],
                    "topAttacker": ranked[0][0] if ranked else None,
                    "damage": round(t["damage"], 1),
                    "hits": t["hits"],
                    "lastFrame": t["lastFrame"],
                })
            out.sort(key=lambda x: -x["lastFrame"])
            return out

    def under_attack(self, now_frame=None):
        return bool(self.threats(now_frame))
