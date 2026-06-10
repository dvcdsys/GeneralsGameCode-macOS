"""combat_eval — counter-matrix reasoning over the KnowledgeBase.

Pure functions (no game I/O).  These replace the Commander's blind cheapest-first
production with composition that hard-counters what the enemy actually fields, and
give the offense a go/no-go estimate.

CWC repurposes damage types (a tank's main gun is LASER and does 0% to infantry —
only its coax small-arms kills them), so we never reason about damage types
directly; we use kb.effective_dps(), which already combined every weapon a unit
carries against a defender's armor when the tables were built.
"""

# representative target classes for the "blind" early game (no enemy seen yet):
# a balanced combined-arms rotation.
_BLIND_ROTATION = ("anti_tank", "anti_inf", "aa")


def counter_score(kb, mine, enemy):
    """Effective dps `mine` deals to `enemy` (0 if unknown)."""
    v = kb.effective_dps(mine, enemy)
    return v or 0.0


def can_hit_air(kb, template):
    """Can this unit target AIRBORNE enemies at all? (weapon AntiAirborneVehicle -> role 'aa')."""
    if not template:
        return False
    return kb.fine_role(template) == "aa" or "aa" in kb.roles_of(template)


def counter_score_strict(kb, mine, enemy):
    """counter_score, but 0 against AIRCRAFT unless `mine` can actually target airborne units.
    The effectiveness table scores weapon dps against the ARMOR type and doesn't know the weapon
    can't elevate — a T-72 'scores' 262 dps vs a helicopter it can never hit. Targeting/defense
    decisions must use THIS variant, or tanks get ordered at helis and AA never looks needed."""
    if kb.fine_role(enemy) in ("heli", "jet") or "aircraft" in kb.roles_of(enemy):
        if not can_hit_air(kb, mine):
            return 0.0
    return counter_score(kb, mine, enemy)


def _candidate_value(kb, cand, enemy_profile):
    """Weighted effective dps of `cand` against the enemy profile, per 100 cost.

    enemy_profile: {enemy_template: weight}.  Empty -> generic combat value
    (dps vs an average defender) so we still prefer real fighters over junk."""
    row = kb.eff_row(cand)
    if not row:
        return 0.0
    cost = kb.cost(cand) or 1
    if enemy_profile:
        num = 0.0
        wsum = 0.0
        for etmpl, w in enemy_profile.items():
            num += w * counter_score(kb, cand, etmpl)
            wsum += w
        val = (num / wsum) if wsum else 0.0
    else:
        val = row.get("dps", 0.0)
    # range is a mild tiebreak (reach matters in CWC's long engagements)
    reach = (row.get("range", 0) or 0) / 1000.0
    return (val / cost) * 100.0 + reach


def best_counters(kb, enemy_profile, trainable):
    """Rank trainable combat options by cost-effective counter value.

    trainable: list of (template, builder, cost, entry) from find_trainable_combat.
    Returns the same tuples, each extended with a score, best first."""
    scored = []
    for tup in trainable:
        tmpl = tup[0]
        scored.append((tup, _candidate_value(kb, tmpl, enemy_profile)))
    scored.sort(key=lambda x: x[1], reverse=True)
    return [(tup, sc) for tup, sc in scored]


def combined_arms_pick(kb, enemy_profile, trainable, rotation_k=0):
    """Pick a template to train that hard-counters the enemy while preserving a
    combined-arms mix.  When the enemy profile is known, take the top counter; when
    blind, rotate through anti_tank/anti_inf/aa so the army isn't mono-type.

    Returns (template, builder, cost, entry) or None."""
    if not trainable:
        return None
    ranked = best_counters(kb, enemy_profile, trainable)
    if enemy_profile:
        # bias to the best counter, but still vary among the top few so a single
        # enemy type doesn't make us build 100% of one unit (which then gets
        # hard-countered back).
        top = [t for t, _ in ranked[:3]] or [r[0] for r in ranked[:1]]
        return top[rotation_k % len(top)] if top else None
    # blind: rotate desired role, fall back to best raw value
    want = _BLIND_ROTATION[rotation_k % len(_BLIND_ROTATION)]
    for tup, _sc in ranked:
        if kb.has_role(tup[0], want):
            return tup
    return ranked[0][0] if ranked else None


def engagement_estimate(kb, my_force, enemy_force):
    """Coarse force-on-force outcome.

    my_force / enemy_force: {template: count}.  Returns {win_prob, dps_ratio,
    my_dps, enemy_dps}.  Uses average cross-effectiveness (each side's units
    spread fire over the other's composition) times hp pools as a time-to-kill
    proxy.  Heuristic, but good enough to gate commit/no-commit."""
    def total_dps(att, deff):
        if not att or not deff:
            return 0.0
        d_items = list(deff.items())
        d_total = sum(c for _, c in d_items) or 1
        s = 0.0
        for atmpl, ac in att.items():
            # average effective dps of this attacker over the enemy composition
            avg = 0.0
            for dtmpl, dc in d_items:
                avg += (dc / d_total) * counter_score(kb, atmpl, dtmpl)
            s += ac * avg
        return s

    def hp_pool(force):
        return sum((kb.max_health(t) or 100) * c for t, c in force.items()) or 1

    my_dps = total_dps(my_force, enemy_force)
    en_dps = total_dps(enemy_force, my_force)
    my_hp, en_hp = hp_pool(my_force), hp_pool(enemy_force)
    # time to wipe the other side
    t_kill_enemy = en_hp / my_dps if my_dps > 0 else float("inf")
    t_kill_me = my_hp / en_dps if en_dps > 0 else float("inf")
    if t_kill_enemy == float("inf"):
        win_prob = 0.0
    elif t_kill_me == float("inf"):
        win_prob = 1.0
    else:
        # faster kill => higher win prob
        win_prob = t_kill_me / (t_kill_enemy + t_kill_me)
    ratio = (my_dps / en_dps) if en_dps > 0 else float("inf")
    return {"win_prob": round(win_prob, 3),
            "dps_ratio": (round(ratio, 2) if ratio != float("inf") else None),
            "my_dps": round(my_dps, 1), "enemy_dps": round(en_dps, 1)}


def default_counter_set(kb, side, n_each=1):
    """Balanced 'I don't know what's hitting me' set: a bit of AA + anti-tank +
    anti-inf for the given side.  Returns a list of templates (cheapest per role)."""
    out = []
    for getter in (kb.anti_tank_templates, kb.anti_inf_templates, kb.aa_templates):
        cands = [t for t in getter(side) if kb.cost(t)]
        cands.sort(key=lambda t: kb.cost(t) or 9999)
        out += cands[:n_each]
    return out
