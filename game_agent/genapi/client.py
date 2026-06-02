"""GameClient - thin REST+WS wrapper over the game's external-control API.

Standard library only. The API is served by the engine modification (see docs/EXTERNAL_CONTROL_API.md
in the repo root). This client is the harness's single point of contact with it, so tools/agents
don't re-implement HTTP plumbing.
"""

import json
import os
import urllib.error
import urllib.request


class GameClient:
    def __init__(self, host="127.0.0.1", port=None, ws_port=None, timeout=8.0):
        self.host = host
        self.port = int(port if port is not None else os.environ.get("GEN_API_PORT", "3459"))
        self.ws_port = int(ws_port if ws_port is not None
                           else os.environ.get("GEN_API_WS_PORT", str(self.port + 1)))
        self.timeout = timeout
        self.base = "http://{}:{}".format(host, self.port)

    # --- low level -------------------------------------------------------------
    def _req(self, method, path, body=None):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read().decode("utf-8"))
            except Exception:  # noqa: BLE001
                return e.code, None
        except Exception as e:  # noqa: BLE001
            return None, {"error": str(e)}

    def get(self, path):
        return self._req("GET", path)

    def post(self, path, body):
        return self._req("POST", path, body)

    # --- reads -----------------------------------------------------------------
    def healthz(self):
        return self.get("/healthz")[1]

    def players(self):
        return self.get("/players")[1] or []

    def state(self):
        return self.get("/state")[1]

    def units(self, player=None, view=None):
        q = []
        if player is not None:
            q.append("player={}".format(player))
        if view is not None:
            q.append("view={}".format(view))
        qs = ("?" + "&".join(q)) if q else ""
        return self.get("/units" + qs)[1] or []

    def resources(self, player):
        return self.get("/resources?player={}".format(player))[1]

    def session(self):
        return self.get("/session")[1]

    def map(self, ds=1, zone=False):
        qs = "?ds={}".format(ds) + ("&zone=1" if zone else "")
        return self.get("/map" + qs)[1]

    # --- mutations -------------------------------------------------------------
    def control(self, action, value=None):
        body = {"action": action}
        if value is not None:
            body["value"] = value
        return self.post("/control", body)[1]

    def pause(self):
        return self.control("pause")

    def resume(self):
        return self.control("resume")

    def step(self, n=1):
        return self.control("step", n)

    def speed(self, fps):
        return self.control("speed", fps)

    def command(self, player, ids, verb, params=None):
        body = {"player": player, "ids": ids, "verb": verb}
        if params is not None:
            body["params"] = params
        return self.post("/command", body)[1]

    def commands(self, cmds):
        return self.post("/commands", cmds)[1]

    def set_seed(self, seed):
        return self.post("/session", {"seed": seed})[1]

    # --- convenience -----------------------------------------------------------
    def external_player(self):
        """The PLAYER_EXTERNAL slot (the agent's player), or None."""
        return next((p for p in self.players() if p.get("controller") == "external"), None)

    def in_game(self):
        h = self.healthz()
        return bool(h and h.get("inGame"))

    def events(self, duration=None, path="/events"):
        """Yield game-event dicts from the WS /events stream (see genapi.ws)."""
        from genapi.ws import stream_events
        yield from stream_events(self.host, self.ws_port, path=path, duration=duration)
