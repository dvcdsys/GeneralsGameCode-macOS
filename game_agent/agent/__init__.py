"""agent - the in-game agent that plays as the PLAYER_EXTERNAL opponent.

`base.Agent` is the interface (observe -> decide -> act) and `base.run` is the driver loop.
`scripted.ScriptedAgent` is a minimal NO-LLM baseline. The future `ollama_agent` (qwen/gemma 7B
via Ollama) plugs in here behind the same interface (see docs/AGENT.md).
"""
