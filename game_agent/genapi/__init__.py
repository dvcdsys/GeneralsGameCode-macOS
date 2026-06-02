"""genapi - Python client library for the game's external-control API.

The API is part of the GAME (the engine modification, on 127.0.0.1:3459 REST + :3460 WS). This
package is the HARNESS side: a thin, dependency-free client other harness code (agents, UI server,
tools) builds on.

    from genapi.client import GameClient
    from genapi.world import WorldModel

    c = GameClient()                 # 127.0.0.1:3459 (env GEN_API_PORT)
    me = c.external_player()         # the PLAYER_EXTERNAL slot
    world = WorldModel.from_api(c)   # decoded /map + classified /units
"""

from .client import GameClient
from .world import WorldModel

__all__ = ["GameClient", "WorldModel"]
