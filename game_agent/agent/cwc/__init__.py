"""CWC-specialist brains for the algorithmic Commander.

This package layers Cold War Crisis domain knowledge on top of the faction-agnostic
skills/Commander: a static KnowledgeBase (extracted offline from the mod INI),
a counter-matrix combat evaluator, battlefield intelligence, a sector model, the
deterministic opening, and the goal subsystems.  Everything degrades gracefully:
if a table or template is missing, the existing keyword/role fallbacks still run.
"""
