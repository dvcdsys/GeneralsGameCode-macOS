#!/usr/bin/env python3
"""ui/server.py - the harness UI server: serves the interactive world-view (map_live.html) over http.

Part of the HARNESS (not the game). The page is a static HTML/canvas that fetches the game API
directly (the API sends Access-Control-Allow-Origin: *); we serve it from http:// (not file://) so
the browser allows the fetches. As the agent grows, this server will also expose agent state +
human-control endpoints (pause agent / manual orders / override) — see docs/AGENT.md. Stdlib only.

Usage:
    python3 ui/server.py                 # serves on http://localhost:8088, opens the browser
    python3 ui/server.py --port 9000 --no-open
"""

import argparse
import functools
import http.server
import os
import socketserver
import webbrowser


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=here)
    url = "http://localhost:{}/map_live.html".format(args.port)

    with socketserver.TCPServer(("127.0.0.1", args.port), handler) as httpd:
        print("== serving bot world-view at", url, "==")
        print("   (Ctrl-C to stop; the page talks to the game API on its own)")
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
