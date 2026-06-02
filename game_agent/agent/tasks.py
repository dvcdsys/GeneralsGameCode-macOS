"""TaskManager — the deterministic executor's work queue.

A Task wraps one Skill instance with an id + priority. Every fast executor tick, `tick(ctx)` advances
each active task (highest priority first); terminal tasks (done/failed/cancelled) move to a bounded
history. The planner (LLM) mutates this queue between ticks: `add` (when it calls a skill tool),
`cancel`, `set_priority`. `snapshot()` is the structured state the UI renders and the brief summarises.

This is the layer that makes the LLM's slowness irrelevant: the model sets intent rarely; the executor
carries multi-tick skills forward every ~0.5s in between.
"""

import threading

from agent.skills.base import TERMINAL, CANCELLED, FAILED


class Task:
    def __init__(self, tid, skill, priority=5, created_frame=0):
        self.id = tid
        self.skill = skill
        self.priority = int(priority)
        self.created_frame = created_frame

    @property
    def name(self):
        return self.skill.name

    def snapshot(self):
        return {
            "id": self.id,
            "skill": self.skill.name,
            "params": self.skill.params,
            "status": self.skill.status,
            "detail": self.skill.status_line(),
            "priority": self.priority,
            "createdFrame": self.created_frame,
        }


class TaskManager:
    def __init__(self, history_cap=30):
        self._tasks = {}        # id -> Task (active)
        self._history = []      # list of snapshots (terminal), most-recent last
        self._next_id = 1
        self._history_cap = history_cap
        # the planner mutates the queue from a background thread while the executor ticks it
        self._lock = threading.RLock()

    MAX_ACTIVE = 100  # hard cap on concurrent tasks (they all run in parallel every tick)

    # --- mutation (planner-facing) --------------------------------------------
    def add(self, skill, priority=5, frame=0):
        with self._lock:
            if len(self._tasks) >= self.MAX_ACTIVE:
                return None  # at the parallel-task cap; caller treats None as "not created"
            tid = self._next_id
            self._next_id += 1
            self._tasks[tid] = Task(tid, skill, priority=priority, created_frame=frame)
            return tid

    def cancel(self, tid):
        with self._lock:
            t = self._tasks.get(tid)
            if not t:
                return False
            t.skill.status = CANCELLED
            t.skill.detail = "cancelled"
            self._retire(t)
            return True

    def set_priority(self, tid, priority):
        with self._lock:
            t = self._tasks.get(tid)
            if not t:
                return False
            t.priority = int(priority)
            return True

    # --- execution (executor-facing) ------------------------------------------
    def tick(self, ctx):
        with self._lock:
            tasks = sorted(self._tasks.values(), key=lambda x: (-x.priority, x.id))
        for t in tasks:
            try:
                t.skill.tick(ctx)
            except Exception as e:  # noqa: BLE001  — one bad skill must not kill the executor
                t.skill.status = FAILED
                t.skill.detail = "error: {}".format(e)
            if t.skill.status in TERMINAL:
                with self._lock:
                    self._retire(t)

    def _retire(self, t):
        self._tasks.pop(t.id, None)
        self._history.append(t.snapshot())
        if len(self._history) > self._history_cap:
            self._history = self._history[-self._history_cap:]

    # --- introspection --------------------------------------------------------
    def active(self):
        with self._lock:
            return [t.snapshot() for t in sorted(self._tasks.values(), key=lambda x: (-x.priority, x.id))]

    def history(self):
        with self._lock:
            return list(self._history)

    def snapshot(self):
        return {"active": self.active(), "history": self.history()}

    def summary(self):
        """Order ledger for the LLM brief: each active order with the units it commands, its target,
        and the WHY the commander recorded — so the LLM keeps context of its own assignments."""
        out = []
        for s in self.active():
            p = s.get("params") or {}
            tgt = None
            if p.get("targetId") is not None:
                tgt = "point/obj {}".format(p["targetId"])
            elif isinstance(p.get("area"), dict):
                tgt = "area {},{}".format(round(p["area"].get("x", 0)), round(p["area"].get("y", 0)))
            elif isinstance(p.get("pos"), dict):
                tgt = "pos {},{}".format(round(p["pos"].get("x", 0)), round(p["pos"].get("y", 0)))
            elif p.get("structure"):
                tgt = p["structure"]
            elif p.get("unit"):
                tgt = "{}x{}".format(p.get("count", 1), p["unit"])
            out.append({"id": s["id"], "skill": s["skill"], "status": s["status"],
                        "units": p.get("ids"), "target": tgt, "why": p.get("reason"),
                        "detail": s["detail"]})
        return out
