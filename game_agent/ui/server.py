#!/usr/bin/env python3
"""ui/server.py - the harness UI server: serves the interactive world-view + agent control.

Part of the HARNESS (not the game). It serves the static canvas page (map_live.html, which fetches the
game API directly — the API sends Access-Control-Allow-Origin: *) AND bridges the browser to the agent
process via two small endpoints over the file-based control channel the orchestrator uses:

    GET  /agent/state      -> contents of /tmp/gen_agent_state.json   (tasks, notes, events, last plan)
    POST /agent/directive  -> writes /tmp/gen_agent_directive.json     ({text, ts}) — human standing intent

The agent process and this server stay decoupled: they only share two files in /tmp (same idiom as the
game's action log). Stdlib only.

Usage:
    python3 ui/server.py                 # serves on http://localhost:8088, opens the browser
    python3 ui/server.py --port 9000 --no-open
"""

import argparse
import http.server
import json
import os
import socketserver
import time
import webbrowser

STATE_PATH = "/tmp/gen_agent_state.json"
DIRECTIVE_PATH = "/tmp/gen_agent_directive.json"
HERE = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def log_message(self, *a):  # quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] == "/agent/state":
            try:
                with open(STATE_PATH) as f:
                    return self._json(200, json.load(f))
            except Exception:  # noqa: BLE001
                return self._json(200, {"inGame": False, "tasks": {"active": [], "history": []},
                                        "notes": [], "events": [], "threats": []})
        return super().do_GET()

    def do_POST(self):
        if self.path.split("?")[0] == "/agent/directive":
            n = int(self.headers.get("Content-Length", 0) or 0)
            try:
                body = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
            except Exception:  # noqa: BLE001
                body = {}
            text = (body.get("text", "") or "").strip()
            try:
                with open(DIRECTIVE_PATH, "w") as f:
                    json.dump({"text": text, "ts": int(time.time() * 1000)}, f)
                return self._json(200, {"ok": True, "text": text})
            except Exception as e:  # noqa: BLE001
                return self._json(500, {"ok": False, "error": str(e)})
        return self._json(404, {"error": "not found"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    url = "http://localhost:{}/map_live.html".format(args.port)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", args.port), Handler) as httpd:
        print("== serving bot world-view + agent control at", url, "==")
        print("   GET /agent/state · POST /agent/directive  (Ctrl-C to stop)")
        if not args.no_open:
            try:
                webbrowser.open(url)
            except Exception:  # noqa: BLE001
                pass
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped.")


if __name__ == "__main__":
    main()
