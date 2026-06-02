#!/usr/bin/env python3
"""threats_watch.py - live view of attacks on the external (bot) player, via ThreatTracker.

Proves the reactive combat-event layer: starts a background ThreatTracker for the PLAYER_EXTERNAL slot
and prints the current threat picture once a second (who's hitting which of my units, damage, hits).

    GEN_API_PORT=3459 python3 tools/threats_watch.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from genapi.client import GameClient        # noqa: E402
from genapi.threats import ThreatTracker     # noqa: E402


def main():
    c = GameClient()
    me = c.external_player()
    if not me:
        print("no external player (launch with GEN_AUTO_EXTERNAL=1)")
        return 1
    owner = me["index"]
    print("== watching threats on external player #{} (Ctrl-C to stop) ==".format(owner))
    tt = ThreatTracker(c, owner).start()
    try:
        while True:
            frame = (c.healthz() or {}).get("frame")
            ts = tt.threats(now_frame=frame)
            if ts:
                print("frame {}: {} unit(s) under attack".format(frame, len(ts)))
                for t in ts[:8]:
                    print("   victim {} <- attacker {} (all {}) | dmg {} over {} hits | last f{}".format(
                        t["victimId"], t["topAttacker"], t["attackers"], t["damage"], t["hits"], t["lastFrame"]))
            else:
                print("frame {}: no active threats".format(frame))
            time.sleep(1.0)
    except KeyboardInterrupt:
        tt.stop()
        print("\nstopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
