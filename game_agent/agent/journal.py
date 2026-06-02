"""EventJournal + AgentNotes — the harness's bounded battlefield memory.

The LLM has a finite context window, so we never feed it the raw event firehose. Two cheap structures
bridge "the game produced thousands of events" and "the planner needs a few sentences of history":

- **EventJournal**: a daemon thread over WS /events. Keeps a bounded ring of raw events (for exact
  counts like "units produced since frame F") and, separately, a short rolling list of *notable* digest
  lines (my structure finished, my unit died, enemy unit appeared) — already summarised, capped, ready
  to drop into the brief.
- **AgentNotes**: a small scratchpad the planner writes to (tool `note`) and reads back next tick. This
  is the agent's own long-horizon memory ("enemy massing armor NE", "expanding to the east oil") that
  survives across briefs without re-deriving it from the world each time. Capped so it can't grow
  unbounded.
"""

import threading
from collections import deque


class EventJournal:
    def __init__(self, client, owner, cap=4000, digest_cap=40):
        self._client = client
        self._owner = owner
        self._events = deque(maxlen=cap)
        self._digest = deque(maxlen=digest_cap)
        self._lock = threading.Lock()
        self._stop = False
        self._thread = None

    # --- lifecycle ------------------------------------------------------------
    def start(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="event-journal", daemon=True)
            self._thread.start()
        return self

    def stop(self):
        self._stop = True

    def _run(self):
        while not self._stop:
            try:
                for ev in self._client.events():
                    if self._stop:
                        return
                    self._record(ev)
            except Exception:  # noqa: BLE001 — match end / WS blip -> reconnect
                if self._stop:
                    return

    # --- ingest ---------------------------------------------------------------
    def _record(self, ev):
        with self._lock:
            self._events.append(ev)
            line = self._notable(ev)
            if line:
                self._digest.append(line)

    def _notable(self, ev):
        t = ev.get("type")
        f = ev.get("frame", 0)
        mine = (ev.get("player") == self._owner)
        if t == "structure_complete" and mine:
            return "f{}: my {} finished".format(f, ev.get("template"))
        if t == "unit_died" and mine:
            return "f{}: lost my {}".format(f, ev.get("template"))
        if t == "unit_produced" and not mine and ev.get("player") is not None:
            return "f{}: enemy built {}".format(f, ev.get("template"))
        if t == "unit_died" and not mine:
            return None  # too noisy
        return None

    # --- query ----------------------------------------------------------------
    def count(self, type, template=None, player=None, since=None):
        with self._lock:
            n = 0
            for ev in self._events:
                if ev.get("type") != type:
                    continue
                if template is not None and ev.get("template") != template:
                    continue
                if player is not None and ev.get("player") != player:
                    continue
                if since is not None and ev.get("frame", 0) < since:
                    continue
                n += 1
            return n

    def recent(self, n=10):
        with self._lock:
            return list(self._events)[-n:]

    def digest(self, max_lines=20):
        with self._lock:
            return list(self._digest)[-max_lines:]


class AgentNotes:
    """A bounded scratchpad the planner reads/writes for long-horizon memory."""

    def __init__(self, cap=20):
        self._notes = deque(maxlen=cap)
        # the model's evolving plain-text strategy (current read of the situation + its plan); this is
        # persistent memory it reads back each round and the human sees in the UI
        self.strategy = {"situation": "", "plan": "", "frame": 0}
        self.strategy_history = deque(maxlen=10)

    def set_strategy(self, situation, plan, frame=0):
        situation, plan = (situation or "").strip(), (plan or "").strip()
        if situation or plan:
            self.strategy = {"situation": situation, "plan": plan, "frame": frame}
            self.strategy_history.append(self.strategy)

    def add(self, text, frame=0):
        text = (text or "").strip()
        if text:
            self._notes.append({"frame": frame, "text": text})

    def clear(self):
        self._notes.clear()

    def all(self):
        return list(self._notes)

    def lines(self):
        return ["f{}: {}".format(n["frame"], n["text"]) for n in self._notes]
