#!/usr/bin/env python3
"""trajectory.py — sample the live game into a compact per-tick metrics log for autonomous analysis.

Polls the API + the orchestrator state file every --period seconds and appends one JSON line with:
frame, inGame, external player money/power, my army/building counts (junk-filtered), enemy contact
count, captured economy points, victory outcome, and the agent's current strategy + active tasks.

Run alongside `make run` + `make agent AGENT=ollama` to record the full game arc, then analyze
/tmp/gen_traj.jsonl to see exactly where the bot stalls or wins.
"""
import json
import os
import sys
import time
import urllib.request

PORT = os.environ.get("GEN_API_PORT", "3459")
BASE = "http://127.0.0.1:%s" % PORT
STATE = "/tmp/gen_agent_state.json"
OUT = os.environ.get("GEN_TRAJ_OUT", "/tmp/gen_traj.jsonl")


def get(path, t=4.0):
    try:
        with urllib.request.urlopen(BASE + path, timeout=t) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:
        return None


_JUNK = ("marker", "sensor", "shell", "bullet", "projectile", "fake", "decoy", "treeson",
         "onfire", "blood", "rubble", "debris", "smoke", "explosion", "flare", "spark", "casing")


def is_junk(name):
    n = (name or "").lower()
    return any(s in n for s in _JUNK)


def external_index(players):
    for p in players or []:
        if p.get("controller") == "external":
            return p.get("index")
    return None


def main():
    period = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    print("trajectory -> %s every %ss (Ctrl-C to stop)" % (OUT, period))
    while True:
        health = get("/healthz") or {}
        frame = health.get("frame")
        ingame = health.get("inGame")
        row = {"t": round(time.time(), 1), "frame": frame, "inGame": ingame}
        if ingame:
            players = get("/players")
            ext = external_index(players)
            row["ext"] = ext
            if ext is not None:
                me = next((p for p in players if p.get("index") == ext), {})
                row["money"] = me.get("money")
                row["power"] = (me.get("powerProduction", 0) or 0) - (me.get("powerConsumption", 0) or 0)
                row["side"] = me.get("side")
                units = get("/units?player=%s" % ext) or []
                if isinstance(units, list):
                    real = [u for u in units if not is_junk(u.get("template"))]
                    blds = [u for u in real if (u.get("category") or "") in
                            ("structure", "building", "garrisonable", "economy")]
                    row["units"] = len(real)
                    row["blds"] = len(blds)
            # session outcome
            sess = get("/session") or {}
            outs = sess.get("players") or sess.get("outcome")
            if outs:
                row["outcome"] = outs
        # agent state file
        try:
            st = json.load(open(STATE))
            strat = st.get("strategy") or {}
            row["strat"] = (strat.get("situation", "")[:70], strat.get("plan", "")[:70])
            tasks = st.get("tasks") or []
            row["tasks"] = ["%s:%s" % (t.get("skill"), t.get("status")) for t in tasks][:8]
        except Exception:
            pass
        with open(OUT, "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(json.dumps(row, ensure_ascii=False)[:240])
        time.sleep(period)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
