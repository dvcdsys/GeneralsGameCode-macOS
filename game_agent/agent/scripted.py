"""ScriptedAgent - a minimal NO-LLM baseline that validates the observe->decide->act loop.

It rallies the external player's idle units toward the nearest capturable economy point (oil/supply),
falling back to the map centre. Purpose: prove the harness drives a real player end-to-end and give
the LLM agent a reference to beat. NOT a serious strategy.
"""

import math

from agent.base import Agent


class ScriptedAgent(Agent):
    name = "scripted-rally"

    def __init__(self):
        self._target = None

    def decide(self, world, me, client):
        my = world.my_units(me["index"])
        if not my:
            return []
        ids = [u["id"] for u in my]
        cx, cy = world.centroid(my)

        # Pick a target once: nearest capturable economy point, else the map centre.
        if self._target is None:
            econ = world.economy_points()
            pt = world.nearest(econ, cx, cy) if econ else None
            if pt:
                self._target = (pt["x"], pt["y"])
            else:
                self._target = (world.width * world.cell / 2.0, world.height * world.cell / 2.0)

        tx, ty = self._target
        if math.hypot(tx - cx, ty - cy) < 60.0:    # arrived: nothing to do this tick
            return []
        return [{"ids": ids, "verb": "attack_move", "params": {"pos": {"x": tx, "y": ty, "z": 0.0}}}]
