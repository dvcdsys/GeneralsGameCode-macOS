"""Agent interface + driver loop.

An agent is anything with a decide(world, me, client) method. The loop handles connecting, waiting
for the match, building the WorldModel each tick (fog-aware via `view`), and dispatching the agent's
returned commands. The Ollama agent will subclass Agent and implement decide() by prompting the model.
"""

import time

from genapi.world import WorldModel


class Agent:
    name = "agent"

    def on_start(self, client):
        """Optional: one-time setup (e.g. fetch /catalog once it exists)."""

    def decide(self, world, me, client):
        """Return a list of command dicts {ids, verb, params} (player is filled in by the loop).

        `world` is a WorldModel, `me` is the /players entry for the external player.
        """
        return []


def run(agent, client, hz=0.5, view="self", max_ticks=None, verbose=True):
    """Drive `agent` against a live match.

    view: None = omniscient; "self" = the external player's fog; or an explicit player index.
    hz:   decisions per second (strategic cadence — keep it low).
    """
    agent.on_start(client)
    tick = 0
    while True:
        if not client.in_game():
            if verbose:
                print("[agent] waiting for in-game ...")
            time.sleep(1.0)
            continue
        me = client.external_player()
        if not me:
            if verbose:
                print("[agent] no external player (launch with GEN_AUTO_EXTERNAL=1)")
            time.sleep(1.0)
            continue

        v = me["index"] if view == "self" else view
        world = WorldModel.from_api(client, view=v)
        cmds = agent.decide(world, me, client) or []
        for c in cmds:
            if isinstance(c, dict) and "verb" in c:
                c.setdefault("player", me["index"])
                res = client.command(**c)
                if verbose:
                    print("[agent] {} ({} units) -> accepted={}".format(
                        c.get("verb"), len(c.get("ids", [])), (res or {}).get("accepted")))

        tick += 1
        if max_ticks and tick >= max_ticks:
            break
        time.sleep(1.0 / hz if hz else 1.0)
