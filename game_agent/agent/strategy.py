"""StrategyDirective — the declarative seam between the algorithmic Commander (L1) and the
LLM strategist / human (L2).

Every field has a CWC-tuned DEFAULT so the Commander plays a full, competent game with NO LLM; the
LLM (or a human via the UI) only PATCHES fields to re-weight the algorithm. This is the inversion of
the old M3 design (LLM micromanaged skills); here the LLM corrects *strategy*. See
docs/COMMANDER_PLAN.md §3/§8.
"""

import json
import os

DIRECTIVE_PATH = "/tmp/gen_agent_directive.json"


def default_directive():
    return {
        "posture": "expand",                 # turtle | defend | expand | pressure | all_in
        # Economy = CAPTURE neutral civ oil/gas/flag points (engine capture verb fixed). Tech order:
        # barracks ($500, infantry + $100 Assault capturers that drive the economy) → fuel depot ($3000,
        # the PREREQUISITE that unlocks the war factory) → war factory (tanks = combined arms) → defense.
        # Capture income pays for the fuel depot; without it the bot is locked to a weak infantry army.
        "economy": {"capture": True},
        "build_priority": ["barracks", "power", "warfactory", "defense"],
        "army": {"target": 40, "keep_home": 12, "min_strike": 16},
        # offense.min_win_prob = engagement_estimate edge required before the strike force commits
        # (commander._commit_decision reads it; lower = more aggressive, higher = more cautious).
        "offense": {"engage": True, "min_win_prob": 0.55},
        "recon": {"scout": True},
        # the dictated opening (fuel→barracks→warfactory→dropzone, capturer burst, MG+AT Humvee+engineers,
        # engineers-into-transports). enabled=False reverts to the plain standing build order.
        "opening": {"enabled": True, "variant": "default"},
        # per-goal weights the future LLM corrector re-weights (consumed once the goal subsystems / intent
        # arbiter land in P4; harmless until then).
        "goals": {
            "economy": {"weight": 1.0}, "development": {"weight": 0.6},
            "expansion": {"weight": 0.5}, "recon": {"weight": 0.4},
            "attack": {"weight": 1.0}, "defense": {"weight": 0.8},
        },
        # LLM/human hand-corrections to the counter matrix: enemyTemplate -> myTemplate.
        "counters": {"override": {}},
        "rationale": "default CWC doctrine",
    }


# posture → overrides merged onto the defaults. Lets the LLM/human shift the whole stance with one word.
_POSTURE_TUNING = {
    "turtle":   {"army": {"target": 20, "keep_home": 18, "min_strike": 16}, "offense": {"engage": False, "min_win_prob": 0.7},
                 "goals": {"defense": {"weight": 1.2}, "attack": {"weight": 0.3}}},
    "defend":   {"army": {"target": 22, "keep_home": 16, "min_strike": 13}, "offense": {"engage": False, "min_win_prob": 0.65},
                 "goals": {"defense": {"weight": 1.0}, "attack": {"weight": 0.5}}},
    "expand":   {"army": {"target": 26, "keep_home": 12, "min_strike": 10}, "offense": {"engage": True, "min_win_prob": 0.55},
                 "goals": {"economy": {"weight": 1.2}, "expansion": {"weight": 0.8}}},
    "pressure": {"army": {"target": 30, "keep_home": 10, "min_strike": 9},  "offense": {"engage": True, "min_win_prob": 0.5},
                 "goals": {"attack": {"weight": 1.2}}},
    "all_in":   {"army": {"target": 34, "keep_home": 4,  "min_strike": 8},  "offense": {"engage": True, "min_win_prob": 0.42},
                 "goals": {"attack": {"weight": 1.5}, "defense": {"weight": 0.3}}},
}


def _merge(base, patch):
    out = dict(base)
    for k, v in (patch or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def resolve_directive(patch=None):
    """Build a full directive from defaults + an optional posture preset + explicit field overrides."""
    d = default_directive()
    posture = (patch or {}).get("posture")
    if posture in _POSTURE_TUNING:
        d = _merge(d, _POSTURE_TUNING[posture])
    if patch:
        d = _merge(d, patch)
    return d


def load_directive(path=DIRECTIVE_PATH):
    """Read the human/LLM directive file → a directive merged over the CWC defaults.

    The file may carry a structured `strategy` object (the new L2 seam) and/or the legacy free-text
    `text` (kept only as rationale). Missing/garbage → pure defaults, so the bot never stalls on a bad
    file. Returns (directive, mtime)."""
    patch = {}
    try:
        with open(path) as f:
            raw = json.load(f)
        if isinstance(raw.get("strategy"), dict):
            patch = dict(raw["strategy"])
        if raw.get("text"):
            patch.setdefault("rationale", raw["text"])
    except Exception:  # noqa: BLE001
        pass
    mtime = os.path.getmtime(path) if os.path.exists(path) else None
    return resolve_directive(patch), mtime
