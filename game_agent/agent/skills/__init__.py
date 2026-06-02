"""Skill library — the extensible automation layer the LLM planner orchestrates.

A Skill is a parameterised, stateful routine that expands one high-level intent ("build a power plant
in the north", "assemble 4 rocket infantry at the ridge") into many low-level API commands over many
ticks, tracking its own progress. Each skill is exposed to the LLM as a native function-calling tool
(see `registry.SkillRegistry.skill_tools`), so the model issues tasks instead of guessing coordinates;
the deterministic executor (agent.tasks.TaskManager) carries them out at a fast cadence.
"""

from agent.skills.base import (  # noqa: F401
    Skill, SkillContext, PENDING, RUNNING, DONE, FAILED, BLOCKED, CANCELLED,
)
from agent.skills.registry import SkillRegistry, build_default_registry  # noqa: F401
