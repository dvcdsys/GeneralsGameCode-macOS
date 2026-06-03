"""commander — the always-on ALGORITHMIC CWC bot (L1 of the Commander architecture).

Plays a full, competent game with NO LLM by orchestrating the proven macro skills as standing orders
plus continuous autonomous offense. A StrategyDirective (file/LLM) only re-weights it.
See docs/COMMANDER_PLAN.md.
"""

from agent.commander.commander import Commander, run_commander

__all__ = ["Commander", "run_commander"]
