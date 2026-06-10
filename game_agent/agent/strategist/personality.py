"""personality.py — the Strategist's per-match randomized doctrine.

The unpredictability review's #1 finding: the bot had ZERO entropy — every threshold a
class constant, every choice an argmax, every cadence a fixed period — so on a given map
it played the bit-identical game every match and a human could read it in 2-3 games.

This module is the bot's ONLY source of randomness: one RNG seeded at match start draws
a "personality" — an opening profile plus jittered doctrine knobs (attack thresholds,
raid cadence/size, retreat tolerance, rally geometry, capturer appetite). The adaptive
core logic (influence maps, counter-composition, commit estimates) stays fully intact;
only its PARAMETERS differ per match, and a few argmax picks become weighted top-k picks.
Within a match everything stays stable/sticky, so the bot is coherent, just not a script.
"""
import os
import random

# opening profiles: base build-order flavour + economy/aggression bias.
#   standard  — balanced ground game
#   fast_air  — airfield/helipad before the war factory (early heli reach/harass)
#   eco_greed — extra capturers + earlier expansion (out-flag the opponent)
#   pressure  — air capacity early + lower assault floor + bigger raids (constant aggression)
OPENINGS = ("standard", "fast_air", "eco_greed", "pressure")


class Personality:
    def __init__(self, seed=None):
        if seed is None:
            seed = int.from_bytes(os.urandom(8), "little")
        self.seed = seed
        self.rng = random.Random(seed)
        r = self.rng
        self.opening = r.choice(OPENINGS)
        # --- army doctrine ---
        self.retreat_hp = r.uniform(0.36, 0.52)     # base; per-UNIT thresholds jitter around it
        self.assault_floor = r.randint(12, 18)
        self.overwhelm = r.randint(24, 32)
        self.win_prob = r.uniform(0.34, 0.50)
        self.harass_period = r.randint(100, 210)    # mean; each raid re-rolls 0.6-1.6x of this
        self.harass_size = r.randint(3, 6)
        self.rally_frac = r.uniform(0.45, 0.85)     # how far toward the frontline the army stages
        # --- map presence ---
        self.outposts = r.randint(1, 3)             # territorial appetite: strongpoints held on the map
        self.army_mult = r.uniform(0.9, 1.15)       # stretch on the SITUATIONAL comfort cap (the cap
                                                    # itself is computed from map size + observed enemy
                                                    # force — never a hard constant)
        # --- macro doctrine ---
        self.capturer_bias = r.randint(-1, 2)
        self.expand_floor = r.randint(700, 1000)
        self.premium_taste = r.uniform(2.0, 3.2)    # bank multiple of the cheap tank that flips
                                                    # core production to premium armour (T-80U/M1A1)

    def describe(self):
        return ("opening={} floor={} ovw={} wp={:.2f} harass~{}f/{}u retreat~{:.2f} "
                "rally={:.2f} cap{:+d} taste={:.1f} posts={} armyx{:.2f} seed={}").format(
                    self.opening, self.assault_floor, self.overwhelm, self.win_prob,
                    self.harass_period, self.harass_size, self.retreat_hp,
                    self.rally_frac, self.capturer_bias, self.premium_taste,
                    self.outposts, self.army_mult, self.seed)

    def pick_weighted(self, scored, k=3):
        """Weighted pick among the top-k of [(obj, score), ...] (score-proportional) —
        replaces argmax target selection so equally good targets rotate between matches
        and within one. Returns the chosen obj (None on empty input)."""
        if not scored:
            return None
        top = sorted(scored, key=lambda t: -(t[1] or 0.0))[:max(1, k)]
        weights = [max(0.05, s or 0.0) for _, s in top]
        return self.rng.choices([o for o, _ in top], weights=weights, k=1)[0]
