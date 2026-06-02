"""SkillRegistry — maps skill names to classes and emits the LLM tool catalog.

The registry is the bridge between the skill library and the planner: `skill_tools()` returns the
function-calling descriptors for every registered skill, which the planner hands to Ollama as `tools`.
When the model calls one of those tools, the planner instantiates the matching skill via `create()`
and hands it to the TaskManager. Register a new skill class and it becomes available to the model with
no other change.
"""

from agent.skills.library import ALL_SKILLS


class SkillRegistry:
    def __init__(self):
        self._skills = {}

    def register(self, cls):
        self._skills[cls.name] = cls
        return self

    def get(self, name):
        return self._skills.get(name)

    def has(self, name):
        return name in self._skills

    def create(self, name, params=None):
        cls = self._skills.get(name)
        return cls(params) if cls else None

    def names(self):
        return sorted(self._skills)

    def skill_tools(self):
        """Function-calling descriptors for all registered skills (for Ollama `tools`)."""
        return [cls.tool_spec() for cls in self._skills.values()]


def build_default_registry():
    reg = SkillRegistry()
    for cls in ALL_SKILLS:
        reg.register(cls)
    return reg
