"""army.py — the Strategist's dynamic combat controller.

Every combat unit gets a JOB every tick — nothing idles (the baseline left its whole army
sitting in 'explore'). Jobs are assigned from the influence map + scouted intel:

  RETREAT  — a badly-damaged unit pulls back toward home to survive/heal
  SCOUT    — a couple of cheap units continuously reveal the map / find the enemy base
  DEFEND   — a DYNAMIC home guard, sized to the actual threat on the base (small when safe,
             so the surplus is free to attack; the whole army recalls when the base is hit)
  HARASS   — a fast detachment raids the softest high-value enemy target (lowest local enemy
             influence) — constant pressure, and it scouts the back line
  ASSAULT  — the main force. CONTAINS the frontline and grinds the enemy base once a favourable
             engagement (or an economy edge) makes committing worthwhile. Concentrated via the
             influence approach vector (flank the kill-zone), executed by the proven SquadSystem
             micro (combined-arms focus-fire, ATGM tactics, reachable firing positions).

Aggression is the inversion of the baseline: it commits on a real edge OR an economy edge,
keeps pressuring even before committing, and always harasses — so it plays like a competent,
active opponent instead of turtling to death.
"""
import math

from agent.skills.base import (
    select_combat_units, my_units, my_buildings, is_building, is_combat_unit,
    incoming_attacks_near, enemy_units_near, my_flag_count,
)
from agent.brief import _enemy_base_guess
from agent.cwc import combat_eval
from agent.cwc.squads import SquadSystem
from agent.strategist.influence import mil_power
from agent.strategist.stance import StanceDoctrine
from agent.strategist.airdefense import AirDefense


class ArmyController:
    RETREAT_HP = 0.45          # pull a unit back BEFORE it's nearly dead — preserves army mass (else the
                               # army bleeds below the commit/harass thresholds and can never re-mass)
    SCOUTS = 2                 # cheap units kept scouting
    DEFEND_BASE_R = 850.0      # tighter perimeter — a distant enemy probe shouldn't pull the whole guard
    DEFEND_MIN = 2             # minimal home guard when totally safe
    DEFEND_BUFFER = 3          # extra guards beyond the counted threat
    DEFEND_MAX = 10            # cap the home guard while NOT committed (don't let defense eat the army)
    COMMIT_HOME_GUARD = 7      # tiny guard once committed — send the BULK to counter-attack their base
    HARASS_SIZE = 4            # units in a raid detachment
    HARASS_PERIOD = 140        # re-pick raid targets faster (don't keep marching at a razed target)
    ASSAULT_FLOOR = 15         # never commit the main force below a viable mass (smaller just melts)
    OVERWHELM = 28             # commit regardless of estimate at/above this
    WIN_PROB = 0.42            # engagement edge required to commit (low = aggressive)
    GRIND_FLAGS = 4            # captured FLAGS (real income) that justify an economy-edge grind
    GRIND_WIN_PROB = 0.24      # floor below which a clash is genuinely losing
    GRIND_ARMY = 20            # a solid force that, with an economy edge, attacks regardless of the
                               # (noisy) estimate — sitting still loses to the AI's scaling
    REISSUE = 90               # frames between re-issuing direct (defend/harass/scout) orders
    COMMIT_DROP = 6            # main force below this -> abandon the commit and re-mass

    def __init__(self, owner, kb, playbook, personality=None):
        self.owner = owner
        self.kb = kb
        self.pb = playbook
        self.pers = personality
        # PERSONALITY: the per-match RNG draw overrides the doctrine constants (instance attrs
        # shadow the class defaults) — fixed thresholds were human-countable in 2-3 games.
        if personality:
            self.RETREAT_HP = personality.retreat_hp
            self.ASSAULT_FLOOR = personality.assault_floor
            self.OVERWHELM = personality.overwhelm
            self.WIN_PROB = personality.win_prob
            self.HARASS_PERIOD = personality.harass_period
            self.HARASS_SIZE = personality.harass_size
            if personality.opening == "pressure":
                self.ASSAULT_FLOOR = max(10, self.ASSAULT_FLOOR - 3)
                self.HARASS_SIZE = min(7, self.HARASS_SIZE + 1)
        self.OUTPOST_MAX = personality.outposts if personality else 2
        self.stance = StanceDoctrine(kb)
        self.airdef = AirDefense(kb)
        self.squads = SquadSystem(kb)
        self.terrain = None
        self.committed = False
        self._outposts = {}        # site key -> {"pos": (x,y), "ids": set(), "ordered": frame}
        self._commit_size = 0      # force size when the assault committed (for a proportional abort)
        self._commit_ids = set()   # the committed wave's unit ids — abort on DEATHS, not damage
        self._commit_frame = -10 ** 9
        self._swarmed = False      # hysteresis state for the all-hands-home recall
        self._retreat_ids = set()  # units in the retreat state (enter < threshold, exit on heal)
        self._last_retreat = -10 ** 9
        self._defend_tid = None
        self._protect_last = {}    # uid -> frame of the last protect intervention (anti-churn)
        self._protect_fleeing = set()
        self._focus_id = None
        self._focus_since = 0
        self._last_harass = -10 ** 9
        self._harass_gap = self.HARASS_PERIOD
        self._last_defend = -10 ** 9
        self._last_scout = -10 ** 9
        self._last_flush = -10 ** 9
        self._last_aa = -10 ** 9
        self._aa_reserve_ids = set()
        self._sc_air = False       # enemy has shown aircraft (set from intel each command)
        self._scout_ids = []
        self._scout_corner = 0
        self._corner_seq = None
        self._rally_off = 0.0      # lateral staging offset (re-drawn periodically while massing)
        self._rally_drawn = -10 ** 9
        self.detail = "init"

    def _retreat_thr(self, uid):
        """Per-UNIT retreat threshold around the personality base — a single global HP fraction
        let a human read the exact bar level that flips any unit from threat to victim."""
        try:
            h = (int(uid) * 2654435761) & 0xFFFF
        except (TypeError, ValueError):
            h = hash(uid) & 0xFFFF
        return max(0.25, min(0.60, self.RETREAT_HP + (h / 65535.0 - 0.5) * 0.16))

    # ----------------------------------------------------------------- main ---
    def command(self, ctx, im, intel, reserved, dominating=False):
        self._dominating = dominating
        world = ctx.world
        army = [u for u in select_combat_units(ctx) if u["id"] not in reserved and "x" in u]
        ubid = {u["id"]: u for u in army}
        if not army:
            self.detail = "no army"
            return
        core = [u for u in my_buildings(ctx) if not (u.get("template") or "").startswith("CWCciv")]
        base = world.centroid(core) or world.centroid(my_buildings(ctx)) or world.centroid(army)

        # has the enemy shown aircraft (visible now OR ever scouted)? -> keep a bigger AA reserve
        self._sc_air = False
        if self.kb:
            if any(self.kb.fine_role(e.get("template")) in ("heli", "jet") for e in world.enemies()):
                self._sc_air = True
            elif intel:
                self._sc_air = any(self.kb.fine_role(t) in ("heli", "jet")
                                   for t in (intel.enemy_profile() or {}))

        # enemy reference points
        enemy_base = intel.enemy_base_estimate() if intel else None
        guess = _enemy_base_guess(world, my_buildings(ctx), my_units(ctx))
        guess_pt = (guess["x"], guess["y"]) if guess else None
        objective = enemy_base or guess_pt

        assigned = set()
        report = {}

        # 1) RETREAT badly-hurt units — a STATE with hysteresis, not a per-tick HP test. Enter below
        # the unit's own threshold, exit only when healed well above it (medics fix infantry; vehicles
        # that can't heal become second-line home guards instead of permanent move-spammed pacifists).
        # Fighting withdrawal: attack_move home, order re-issued on the REISSUE clock — the old
        # per-tick plain `move` reset the unit's order state every tick so it could never return fire.
        self._retreat_ids &= set(ubid)
        retreat, came_home = [], []
        for u in army:
            mx, hp = u.get("maxHealth"), u.get("health")
            if not mx or hp is None:
                continue
            thr = self._retreat_thr(u["id"])
            if u["id"] in self._retreat_ids:
                if hp >= mx * min(0.92, thr + 0.25):
                    self._retreat_ids.discard(u["id"])           # healed -> rejoin the fight
                elif base and math.hypot(u["x"] - base[0], u["y"] - base[1]) <= 380.0:
                    came_home.append(u)                          # made it home -> second-line guard
                else:
                    retreat.append(u)
            elif hp < mx * thr:
                self._retreat_ids.add(u["id"])
                retreat.append(u)
        for u in retreat:
            assigned.add(u["id"])
        if retreat and base and ctx.frame - self._last_retreat >= self.REISSUE:
            self._last_retreat = ctx.frame
            self._amove(ctx, [u["id"] for u in retreat], base)
        report["retreat"] = len(retreat)

        # the fighting force available for the commit decision (retreating units excluded; home
        # cripples folded into the guard below)
        available = [u for u in army if u["id"] not in assigned]

        # 2) COMMIT DECISION on the WHOLE force — decided BEFORE carving out defenders, so a base under
        # pressure can't suppress the attack. Against an aggressive AI the winning move is usually to
        # counter-attack its (under-defended) base, not to turtle and get out-scaled.
        threat_objs = enemy_units_near(ctx, base, self.DEFEND_BASE_R) if base else []
        incoming = incoming_attacks_near(ctx, base, self.DEFEND_BASE_R * 1.6) if base else []
        threat_combat = [e for e in threat_objs if is_combat_unit(e) and not is_building(e)]
        threat_n = len(threat_combat)
        # SWARMED is power-weighted with enter/exit hysteresis: the old raw object count let ~12
        # $100 riflemen (or harmless transports) recall a 30-tank assault, repeatably, forever.
        tpow = sum(mil_power(self.kb, e.get("template"))[0] for e in threat_combat)
        apow = sum(mil_power(self.kb, u.get("template"))[0] for u in army) or 1.0
        if self._swarmed:
            self._swarmed = tpow >= 0.30 * apow
        else:
            self._swarmed = threat_n >= 10 and tpow >= 0.55 * apow
        swarmed = self._swarmed
        if swarmed:
            self.committed = False                     # base genuinely overrun -> all hands home
        elif not self.committed:
            ok, _why = self._commit(ctx, im, intel, available)
            # never commit with NO objective at all (committed + nowhere to go = a fake assault state)
            if ok and objective is not None and (
                    enemy_base is not None or len(available) >= self.OVERWHELM or self._dominating):
                self.committed = True
                self._commit_size = len(available)
                self._commit_ids = {u["id"] for u in available}
                self._commit_frame = ctx.frame
        else:
            # abort on real LOSSES of the committed wave (deaths), never on damage — chip damage
            # shoving units into retreat used to U-turn every assault without a single kill.
            alive = sum(1 for uid in self._commit_ids if uid in ubid)
            if (ctx.frame - self._commit_frame > 240
                    and alive < max(self.COMMIT_DROP, int(self._commit_size * 0.35))):
                self.committed = False                 # the wave actually died -> re-mass

        # 3) DEFEND — guard sized to the threat, but CAPPED to a small home guard once committed (the
        # bulk goes on offence). Everyone home only if truly swarmed.
        if swarmed:
            guard_need = len(army)
        elif threat_n or incoming:
            cap = self.COMMIT_HOME_GUARD if self.committed else self.DEFEND_MAX
            guard_need = max(self.DEFEND_MIN, min(threat_n + self.DEFEND_BUFFER, cap))
        else:
            guard_need = self.DEFEND_MIN
        guard = self._pick_defenders(army, assigned, base, guard_need, threat_combat)
        for u in guard:
            assigned.add(u["id"])
        for u in came_home:
            assigned.add(u["id"])                      # cripples at home reinforce the guard
        self._defend(ctx, [u["id"] for u in guard] + [u["id"] for u in came_home],
                     base, threat_combat, incoming)
        report["defend"] = len(guard) + len(came_home)

        # 4) SCOUT — keep a couple of cheap units finding/tracking the enemy
        scouts = self._maintain_scouts(ctx, army, assigned, base, objective, guess_pt, enemy_base is None)
        for sid in scouts:
            assigned.add(sid)
        report["scout"] = len(scouts)

        # remaining = offensive pool
        pool = [u for u in army if u["id"] not in assigned]

        # 4b) OUTPOSTS — hold strategic ground the way a human does: small mixed strongpoints
        # (infantry eyes + armor on the road + AA waiting for planes) on the corridor toward the
        # enemy and at exposed owned flags. Map PRESENCE, not just one ball at one rally point.
        post_n = 0
        if not swarmed:
            post_n = self._outposts_tick(ctx, im, army, assigned, pool, base, objective)
            if post_n:
                pool = [u for u in pool if u["id"] not in self._outpost_ids()]
        else:
            self._release_outposts(ctx)                # base overrun -> posts (incl. garrisons) come home
        if post_n:
            report["post"] = post_n

        # 4c) AIR DEFENCE — the USSR AA doctrine brain (fighters loiter+scramble, SA-11 forward
        # zone-denial, SA-9 base ring + hit-and-hide + map interceptors, manpads point-defence,
        # loose Shilkas routed to flags). Claims only SURPLUS AA — posts keep their 1 AA each and the
        # assault keeps AA in its column, so all three legs (posts / march / standing) stay covered.
        aa_n = 0
        if not swarmed:
            aa_n = self.airdef.assign(ctx, pool, assigned, base, objective, im)
            if aa_n:
                pool = [u for u in pool if u["id"] not in self.airdef.claimed]
        if aa_n:
            report["aa"] = "{}[{}]".format(aa_n, self.airdef.detail)

        # 4) HARASS — raid the softest high-value enemy target with a fast detachment. Fire even under
        # LIGHT pressure and with a small surplus, so the bot scouts + pressures the enemy backline EARLY
        # instead of conceding the map until it has a 16-unit surplus (which arrives too late).
        harass_n = 0
        # light pressure = little combat POWER near the base and no base-local attacks. The old gate
        # (raw count <= 2 AND no attack anywhere on the map) was a $300 off-switch for all raiding.
        light_pressure = tpow <= 2.5 and not incoming
        if light_pressure and len(pool) > self.HARASS_SIZE * 2:
            harass_n = self._harass(ctx, im, intel, pool, base)
            if harass_n:
                # the harass detachment is the LAST `harass_n` of pool (set inside _harass)
                pool = [u for u in pool if u["id"] not in self._harass_ids]
        report["harass"] = harass_n

        # 5) ASSAULT / CONTAIN — the main force
        main_phase = self._main_force(ctx, im, intel, pool, ubid, base, objective, enemy_base, guess_pt)
        report["main"] = "{}{}".format(len(pool), main_phase)

        # 6) GARRISON FLUSH — enemy infantry holed up in buildings get dug out by the right tools:
        #    artillery (area) / snipers (anti-infantry) / CAS air. Overrides their squad order this tick.
        if ctx.frame - self._last_flush >= self.REISSUE:
            fl = self._flush_garrisons(ctx, army)
            if fl:
                self._last_flush = ctx.frame
                report["flush"] = fl

        # 6b) UNIT PRESERVATION — the per-unit STATE MATRIX (user doctrine): every unit under fire is
        #    classified by "can I answer my attacker?" — if not, nearby friends that CAN counter the
        #    attacker are tasked onto it (the AA standing behind the heli-pounded tank finally shoots),
        #    and a worn victim falls back to the nearest cover group to regroup instead of dying alone.
        prot = self._protect(ctx, army, ubid, base)
        if prot:
            report["protect"] = prot

        # 7) INFANTRY DOCTRINE — holding infantry goes PRONE (AT mode when armor is near), moving
        #    infantry STANDS first (full speed). The stance toggles are what make the bot read as a
        #    player instead of a script (user feedback).
        holders = list(guard) + came_home
        for o in self._outposts.values():
            holders += [ubid[uid] for uid in o["ids"] if uid in ubid]
        movers = list(retreat)
        movers += [ubid[uid] for uid in getattr(self, "_harass_ids", set()) if uid in ubid]
        movers += [ubid[sid] for sid in self._scout_ids if sid in ubid]
        movers += [ubid[uid] for uid in self._protect_fleeing if uid in ubid]   # stand up to flee
        for o in self._outposts.values():
            # garrison-bound members still OUTSIDE the bunker must STAND — a prone soldier crawls
            # toward the building forever and never gets in (why "не завантажує юнітів у будівлі")
            movers += [ubid[uid] for uid in (o.get("inside") or ()) if uid in ubid]
        if self.committed:
            movers += pool
        else:
            holders += pool                            # the massing main force holds ground -> dig in
        st = self.stance.apply(ctx, holders, movers)
        if st:
            report["stance"] = st

        self.detail = " ".join("{}={}".format(k, v) for k, v in report.items())

    def _flush_garrisons(self, ctx, army):
        """Enemy infantry garrisoned in (civilian) buildings are immune to small-arms but soft to AREA
        and anti-infantry fire. Send artillery + snipers + ground-attack air to dig them out — the
        precise counter to a turtled garrison (the user's doctrine)."""
        garrisons = []
        for e in ctx.world.enemies():
            if not is_building(e) or "x" not in e:
                continue
            tags = [str(t).lower() for t in e.get("tags", [])]
            if (e.get("category") == "garrisonable" or "garrisonable" in tags) and (e.get("contains") or 0) > 0:
                garrisons.append(e)
        if not garrisons or not self.kb:
            return 0
        flushers = []
        for u in army:
            if "x" not in u:
                continue
            r = self.kb.fine_role(u.get("template"))
            if r in ("artillery", "sniper"):
                flushers.append(u)
            elif r in ("heli", "jet") and self.pb and self.pb.air_kind_of(u.get("template")) == "ground_attack":
                flushers.append(u)
        used = 0
        for u in flushers:
            g = min(garrisons, key=lambda b: (b["x"] - u["x"]) ** 2 + (b["y"] - u["y"]) ** 2)
            if math.hypot(g["x"] - u["x"], g["y"] - u["y"]) < 1400.0:
                ctx.client.command(ctx.player, [u["id"]], "attack_target", {"targetId": g["id"]})
                used += 1
        return used

    # --------------------------------------------------------------- helpers --
    def _move(self, ctx, ids, pos):
        if ids:
            ctx.client.command(ctx.player, list(ids), "move", {"pos": {"x": pos[0], "y": pos[1], "z": 0.0}})

    def _amove(self, ctx, ids, pos):
        if ids:
            ctx.client.command(ctx.player, list(ids), "attack_move",
                               {"pos": {"x": pos[0], "y": pos[1], "z": 0.0}})

    def _nearest_free(self, army, assigned, pt, k):
        if k <= 0 or not pt:
            return []
        free = [u for u in army if u["id"] not in assigned]
        free.sort(key=lambda u: (u["x"] - pt[0]) ** 2 + (u["y"] - pt[1]) ** 2)
        return free[:k]

    def _pick_defenders(self, army, assigned, pt, k, foes):
        """Home guard picked by COUNTER VALUE against the actual attackers, not just proximity —
        riflemen 'guarding' against helicopters or ATGM carriers is how the base got wrecked
        (user feedback: 'гелікоптери рознесли все та птури на базі брдм'). AA answers air, guns/
        armor answer light vehicles; distance only breaks ties."""
        if k <= 0 or not pt:
            return []
        free = [u for u in army if u["id"] not in assigned]
        foe_templates = [e.get("template") for e in (foes or []) if e.get("template")][:8]
        if not foe_templates or not (self.kb and self.kb.loaded):
            free.sort(key=lambda u: (u["x"] - pt[0]) ** 2 + (u["y"] - pt[1]) ** 2)
            return free[:k]

        def key(u):
            s = 0.0
            for ft in foe_templates:
                s += combat_eval.counter_score_strict(self.kb, u.get("template"), ft) or 0.0
            d = math.hypot(u.get("x", 0) - pt[0], u.get("y", 0) - pt[1])
            return (-s, d)                             # best counter first, nearest among equals
        free.sort(key=key)
        return free[:k]

    # --------------------------------------------------------------- defend ---
    def _defend(self, ctx, ids, base, foes, incoming):
        """Home guard orders. Target = the most DANGEROUS combat foe in the perimeter (power over
        proximity, so one cheap fast unit dangled at the edge can't kite the whole guard away), and
        the order is only re-issued when the target changes or the REISSUE clock elapses — the old
        per-tick nearest-retarget made guards twitch between targets and reset their attack runs."""
        if not ids or not base:
            return
        tgt_id = None
        if foes:
            def danger(e):
                p = mil_power(self.kb, e.get("template"))[0]
                d = math.hypot(e.get("x", 0) - base[0], e.get("y", 0) - base[1])
                return p / (1.0 + d / 400.0)
            tgt_id = max(foes, key=danger)["id"]
        elif incoming:
            tgt_id = incoming[0]
        if tgt_id is not None:
            if tgt_id == self._defend_tid and ctx.frame - self._last_defend < self.REISSUE:
                return
            self._last_defend = ctx.frame
            self._defend_tid = tgt_id
            ctx.client.command(ctx.player, ids, "attack_target", {"targetId": tgt_id})
            return
        self._defend_tid = None
        if ctx.frame - self._last_defend < self.REISSUE:
            return
        self._last_defend = ctx.frame
        ctx.client.command(ctx.player, ids, "guard_zone",
                           {"anchor": {"x": base[0], "y": base[1]},
                            "engage": {"x": base[0], "y": base[1]}})

    # --------------------------------------------------------------- scout ----
    def _maintain_scouts(self, ctx, army, assigned, base, objective, guess_pt, base_unknown):
        # keep existing live scouts
        live = [u["id"] for u in army if u["id"] in self._scout_ids and u["id"] not in assigned]
        # recruit cheap units up to SCOUTS
        if len(live) < self.SCOUTS:
            free = [u for u in army if u["id"] not in assigned and u["id"] not in live]

            # UNARMED AIR first (a weaponless transport heli is a perfect flying scout and useless
            # for anything else), then cheapest ground (recon, light, cheap infantry)
            def scout_key(u):
                t = u.get("template")
                if self.kb:
                    flying_eye = (self.kb.fine_role(t) in ("heli", "jet")
                                  and self.kb.loaded and not self.kb.is_armed(t))
                    return (0 if flying_eye else 1, self.kb.cost(t) or 999)
                return (1, 999)
            free.sort(key=scout_key)
            for u in free:
                if len(live) >= self.SCOUTS:
                    break
                live.append(u["id"])
        self._scout_ids = live
        if not live:
            return []
        if ctx.frame - self._last_scout >= self.REISSUE * 2:
            self._last_scout = ctx.frame
            # send scouts toward the enemy (find the base) or sweep map corners when base unknown
            target = objective
            if base_unknown or target is None:
                target = self._corner(ctx, base)
            for i, sid in enumerate(live):
                t = target if i == 0 else (guess_pt or target)
                if t:
                    self._move(ctx, [sid], t)
        return live

    def _corner(self, ctx, base):
        W = (ctx.world.width or 0) * (ctx.world.cell or 0)
        H = (ctx.world.height or 0) * (ctx.world.cell or 0)
        corners = [(W * 0.85, H * 0.85), (W * 0.15, H * 0.85),
                   (W * 0.85, H * 0.15), (W * 0.15, H * 0.15)]
        if base:                                       # farthest corner from home first (likely enemy)
            corners.sort(key=lambda c: -((c[0] - base[0]) ** 2 + (c[1] - base[1]) ** 2))
        # per-match shuffled tour AFTER the far corner — the fixed rotation let a human camp the
        # known scouting lane and blind the bot for the whole game, every game
        if self._corner_seq is None:
            rest = [1, 2, 3]
            if self.pers:
                self.pers.rng.shuffle(rest)
            self._corner_seq = [0] + rest
        self._scout_corner = (self._scout_corner + 1) % len(self._corner_seq)
        return corners[self._corner_seq[self._scout_corner]]

    # ----------------------------------------------------------- protection ---
    # The per-unit STATE MATRIX (user doctrine: "матриці станів"):
    #   state          condition                                  response
    #   ENGAGED_OK     under fire, CAN hurt the attacker          leave it to the squad logic
    #   HUNTED         under fire, CANNOT hurt the attacker       protectors respond; victim steps
    #                                                             to cover when it's being worn down
    #   PROTECTOR      can hurt a hunted friend's attacker        attack_target the attacker
    # Examples this exists for: a tank pounded by a heli while AA idles right behind it; AA running
    # ahead and dying to machine-gunners while rifles stand next to it.
    PROTECT_R = 800.0          # how far protectors/cover are looked for
    PROTECT_COOLDOWN = 70      # frames between interventions per unit (anti order-churn)
    PROTECT_MAX = 8            # command budget per tick

    def _protect(self, ctx, army, ubid, base):
        tt = getattr(ctx, "threats", None)
        if not tt or not (self.kb and self.kb.loaded):
            return 0
        try:
            events = tt.threats(ctx.frame)
        except Exception:  # noqa: BLE001
            return 0
        by_victim = {}
        for t in events:
            vid, aid = t.get("victimId"), t.get("topAttacker")
            if vid in ubid and aid:
                by_victim[vid] = aid
        self._protect_fleeing &= set(by_victim)       # no longer under fire -> state resets
        if not by_victim:
            return 0
        enemies_by_id = {e.get("id"): e for e in ctx.world.enemies()}
        acted = 0
        for vid, aid in by_victim.items():
            if acted >= self.PROTECT_MAX:
                break
            if vid in self._retreat_ids:               # already in full retreat (HP layer owns it)
                continue
            if ctx.frame - self._protect_last.get(vid, -10 ** 9) < self.PROTECT_COOLDOWN:
                continue
            victim = ubid[vid]
            att = enemies_by_id.get(aid)
            att_tmpl = att.get("template") if att else None
            if att_tmpl and (combat_eval.counter_score_strict(self.kb, victim.get("template"), att_tmpl)
                             or 0.0) > 0.05:
                continue                               # ENGAGED_OK — it can answer; let it fight
            # HUNTED: collect protectors — nearby friends that CAN hurt the attacker
            protectors = []
            if att_tmpl:
                for u in army:
                    if u["id"] == vid or "x" not in u or u["id"] in self._retreat_ids:
                        continue
                    d2 = (u["x"] - victim["x"]) ** 2 + (u["y"] - victim["y"]) ** 2
                    if d2 > self.PROTECT_R ** 2:
                        continue
                    if (combat_eval.counter_score_strict(self.kb, u.get("template"), att_tmpl) or 0.0) > 0.05:
                        protectors.append((d2, u))
                protectors.sort(key=lambda p: p[0])
            if protectors and att is not None:
                ids = [u["id"] for _d, u in protectors[:3]]
                ctx.client.command(ctx.player, ids, "attack_target", {"targetId": aid})
                for i in ids:
                    self._protect_last[i] = ctx.frame
                acted += 1
            # the victim itself: being WORN DOWN with no answer -> step back to the nearest cover
            # (protector, else any friend, else home) and regroup; healthy victims keep their job
            hp, mx = victim.get("health"), victim.get("maxHealth")
            worn = bool(mx and hp is not None and hp < mx * 0.7)
            if worn:
                cover = None
                if protectors:
                    cover = protectors[0][1]
                else:
                    friends = [u for u in army if u["id"] != vid and "x" in u
                               and u["id"] not in self._retreat_ids and u["id"] not in by_victim]
                    if friends:
                        cover = min(friends, key=lambda u: (u["x"] - victim["x"]) ** 2
                                    + (u["y"] - victim["y"]) ** 2)
                tgt = (cover["x"], cover["y"]) if cover else base
                if tgt:
                    ctx.client.command(ctx.player, [vid], "move",
                                       {"pos": {"x": tgt[0], "y": tgt[1], "z": 0.0}})
                    self._protect_last[vid] = ctx.frame
                    self._protect_fleeing.add(vid)
                    acted += 1
        if len(self._protect_last) > 500:
            self._protect_last = {k: v for k, v in self._protect_last.items() if k in ubid}
        return acted

    # ------------------------------------------------------------ AA reserve --
    AA_RESERVE_BASE = 2        # AA units always kept home (more when the enemy can fly)
    AA_RESERVE_R = 700.0       # they hold a guard ring this far from the base centroid

    # ------------------------------------------------------------- outposts ---
    OUTPOST_SIZE = 3

    def _outpost_ids(self):
        return {uid for o in self._outposts.values() for uid in o["ids"]}

    def _outposts_tick(self, ctx, im, army, assigned, pool, base, objective):
        """STRONGPOINTS across the map (the user's doctrine when playing himself): tiny mixed
        detachments holding ground that matters — the corridor between the bases ("tanks guard the
        road"), and owned flags exposed toward the enemy ("infantry watching territory, AA waiting
        for planes"). Count scales with the army and the personality's territorial appetite.
        Sticky membership; casualties are replaced from the pool; posts dissolve when swarmed."""
        want = 0
        if len(army) >= 14:
            want = min(self.OUTPOST_MAX, (len(army) - 8) // 7)
        sites = []
        if want and base and objective:
            front = im.frontline_point(base, objective)
            sites.append(("corridor", front))          # the road between the bases
        if want and base:
            flags = [u for u in ctx.world.units
                     if u.get("player") == ctx.player and "x" in u
                     and "flag" in (u.get("template") or "").lower()
                     and math.hypot(u["x"] - base[0], u["y"] - base[1]) > self.DEFEND_BASE_R]
            if objective:                              # most exposed flags first
                flags.sort(key=lambda f: math.hypot(f["x"] - objective[0], f["y"] - objective[1]))
            for f in flags:
                sites.append(("flag{}".format(f.get("id")), (f["x"], f["y"])))
        sites = sites[:want]
        live = {k for k, _ in sites}
        for k in list(self._outposts):
            if k not in live:                          # site no longer worth holding -> release units
                self._evacuate_post(ctx, self._outposts[k])
                del self._outposts[k]
        ubid = {u["id"]: u for u in army}
        total = 0
        for key, pos in sites:
            o = self._outposts.setdefault(key, {"pos": pos, "ids": set(), "ordered": -10 ** 9,
                                                "bunker": None, "inside": set(), "g_since": 0})
            # drop dead members and members yanked away by higher-priority jobs (retreat/guard)
            o["ids"] = {uid for uid in o["ids"] if uid in ubid and uid not in assigned}
            moved = math.hypot(pos[0] - o["pos"][0], pos[1] - o["pos"][1]) > 250.0
            o["pos"] = pos
            self._post_garrison(ctx, o, pos, ubid)
            free = [u for u in pool if u["id"] not in assigned and u["id"] not in o["ids"]]
            added = self._fill_outpost(o, free, pos)
            for uid in o["ids"] | o["inside"]:
                assigned.add(uid)
            order_ids = sorted(o["ids"] - o["inside"])
            if order_ids and (added or moved or ctx.frame - o["ordered"] >= self.REISSUE * 3):
                o["ordered"] = ctx.frame
                ctx.client.command(ctx.player, order_ids, "guard_zone",
                                   {"anchor": {"x": pos[0], "y": pos[1]},
                                    "engage": {"x": pos[0], "y": pos[1]}})
            total += len(o["ids"]) + len(o["inside"])
        return total

    def _post_garrison(self, ctx, o, pos, ubid):
        """The post's infantry occupies a garrisonable neutral building at the site ("сідає у
        будинки") — a real cover multiplier and exactly what a human does on a strongpoint. The
        garrisoned civilian building flips to our control; on losing the site we evacuate."""
        if o["bunker"] is not None:
            b = ctx.world.by_id(o["bunker"]) if hasattr(ctx.world, "by_id") else \
                next((x for x in ctx.world.units if x.get("id") == o["bunker"]), None)
            occupied = b is not None and b.get("player") == ctx.player and (b.get("contains") or 0) > 0
            if occupied:
                o["inside"] = {uid for uid in o["inside"] if uid not in ubid}  # truly inside = invisible
                return
            # building razed/lost, or our squad never made it in within ~30s -> give up on it
            visible = {uid for uid in o["inside"] if uid in ubid}
            if b is None or ctx.frame - o["g_since"] > 900:
                o["ids"] |= visible
                o["inside"] = set()
                o["bunker"] = None
            return
        if not o["ids"]:
            return
        bld = None
        best = None
        for u in ctx.world.units:
            if u.get("relationToLocal") != "neutral" or "x" not in u or (u.get("contains") or 0):
                continue
            tags = [str(t).lower() for t in u.get("tags", [])]
            if u.get("category") != "garrisonable" and "garrisonable" not in tags:
                continue
            d = math.hypot(u["x"] - pos[0], u["y"] - pos[1])
            if d <= 340.0 and (best is None or d < best):
                bld, best = u, d
        if bld is None:
            return
        inf = [uid for uid in o["ids"]
               if uid in ubid and self.kb
               and self.kb.fine_role(ubid[uid].get("template")) in ("infantry", "mg_inf", "sniper")][:2]
        if not inf:
            return
        ctx.client.command(ctx.player, inf, "garrison", {"targetId": bld["id"]})
        o["bunker"] = bld["id"]
        o["inside"] = set(inf)
        o["ids"] -= set(inf)
        o["g_since"] = ctx.frame

    def _evacuate_post(self, ctx, o):
        if o.get("bunker") is not None:
            ctx.client.command(ctx.player, [o["bunker"]], "evacuate", {})

    def _release_outposts(self, ctx):
        for o in self._outposts.values():
            self._evacuate_post(ctx, o)
        self._outposts.clear()

    def garrisoned_count(self):
        return sum(len(o.get("inside") or ()) for o in self._outposts.values())

    # one of each: eyes/anti-infantry, armor for the road, AA waiting for aircraft
    _POST_ROLES = (("anti_inf", ("rifle", "mg_inf", "infantry", "sniper", "ifv", "recon")),
                   ("anti_armor", ("mbt", "tank", "at_inf", "light_at", "atgm")),
                   ("anti_air", ("aa", "aa_inf", "aa_veh")))

    def _fill_outpost(self, o, free, pos):
        added = 0
        slots = self.OUTPOST_SIZE - len(o.get("inside") or ())   # garrisoned members fill slots too
        if len(o["ids"]) >= slots or not free:
            return added

        def nearest(cands):
            return min(cands, key=lambda u: (u["x"] - pos[0]) ** 2 + (u["y"] - pos[1]) ** 2)
        for _need, roles in self._POST_ROLES:
            if len(o["ids"]) >= slots or not free:
                break
            cands = [u for u in free
                     if (((self.kb.fine_role(u.get("template")) if self.kb else "") or "") in roles)]
            if not cands:
                continue                                # role not fielded yet -> pad below
            pick = nearest(cands)
            free.remove(pick)
            o["ids"].add(pick["id"])
            added += 1
        while len(o["ids"]) < slots and free:
            pick = nearest(free)
            free.remove(pick)
            o["ids"].add(pick["id"])
            added += 1
        return added

    # -------------------------------------------------------------- harass ----
    def _harass(self, ctx, im, intel, pool, base):
        if ctx.frame - self._last_harass < self._harass_gap:
            # keep an existing raid going
            ids = [u["id"] for u in pool if u["id"] in getattr(self, "_harass_ids", set())]
            self._harass_ids = set(ids)
            return len(ids)
        targets = [b for b in (intel.all_enemy_buildings() if intel else []) if "x" in b]
        if not targets:
            self._harass_ids = set()
            return 0
        # weighted top-k target pick (personality) — strict argmax let the human leave one juicy
        # building as bait and farm the raid party at the same spot every cycle
        scored = im.raid_scores(targets)
        if self.pers:
            tgt = self.pers.pick_weighted(scored, k=3)
        else:
            tgt = max(scored, key=lambda t: t[1])[0] if scored else None
        if tgt is None:
            self._harass_ids = set()
            return 0
        # raid-suited units first (fast vehicles / recon / ground-attack air), then cheapest — the
        # pure cost sort always sent the 4 slowest riflemen to walk across the map and die
        def raid_key(u):
            r = (self.kb.fine_role(u.get("template")) if self.kb else "") or ""
            fast = 0 if r in ("recon", "ifv", "heli", "jet", "light_at") else 1
            return (fast, (self.kb.cost(u.get("template")) or 999) if self.kb else 999)
        squad = sorted(pool, key=raid_key)[:self.HARASS_SIZE]
        ids = [u["id"] for u in squad]
        self._harass_ids = set(ids)
        self._last_harass = ctx.frame
        # re-roll the next raid window so the cadence isn't a metronome a human sets a clock by
        if self.pers:
            self._harass_gap = int(self.HARASS_PERIOD * self.pers.rng.uniform(0.6, 1.6))
        # approach the raid target via the lowest-influence flank
        cen = ctx.world.centroid(squad) or base
        ap = im.approach_point(cen, (tgt["x"], tgt["y"]), standoff=120.0)
        self._amove(ctx, ids, ap)
        return len(ids)

    # --------------------------------------------------------------- main -----
    def _main_force(self, ctx, im, intel, pool, ubid, base, objective, enemy_base, guess_pt):
        if not pool:
            return ":none"                              # all on defence/scout this tick (command owns commit)
        ids = [u["id"] for u in pool]
        force_ubid = {u["id"]: u for u in pool}
        # commit state is decided in command() on the whole force; here we just EXECUTE it.
        cen = ctx.world.centroid(pool)
        if self.committed and objective is not None:
            phase = "assault"
            focus = self._pick_focus(ctx, im, intel, cen)
            raze = [b for b in (intel.all_enemy_buildings() if intel else []) if "x" in b]
            self.squads.command(ctx, ids, objective, force_ubid, "march",
                                raze=raze, aggressive=True, focus=focus, terrain=self.terrain)
            return ":assault"
        # NOT committed -> MASS just behind the frontline and hold (don't bleed units into the enemy
        # before we're strong enough to commit — that churn is what kept the army small). The squad
        # 'combat' tactic still engages anything that comes to us; HARASS supplies the forward pressure.
        anchor = base or cen
        if objective is not None and anchor:
            front = im.frontline_point(anchor, objective)
            # personality rally: fraction toward the front is a per-match draw, and the staging
            # point slides laterally off the base->front axis (re-drawn periodically) — the old
            # fixed 0.7 on-axis point was a free pre-sighted artillery magnet every match
            frac = self.pers.rally_frac if self.pers else 0.7
            if self.pers and ctx.frame - self._rally_drawn > 600:
                self._rally_drawn = ctx.frame
                self._rally_off = self.pers.rng.uniform(-1.0, 1.0)
            dx, dy = front[0] - anchor[0], front[1] - anchor[1]
            d = math.hypot(dx, dy) or 1.0
            off = self._rally_off * min(380.0, d * 0.35)
            rally = (anchor[0] + dx * frac - dy / d * off,
                     anchor[1] + dy * frac + dx / d * off)
            self.squads.command(ctx, ids, rally, force_ubid, "combat",
                                raze=None, aggressive=False, focus=None, terrain=self.terrain)
            return ":mass"
        # no objective at all -> sweep toward a corner to find the enemy
        tgt = guess_pt or self._corner(ctx, base)
        self.squads.command(ctx, ids, tgt, force_ubid, "march",
                            raze=None, aggressive=False, focus=None, terrain=self.terrain)
        return ":seek"

    def _commit(self, ctx, im, intel, pool):
        n = len(pool)
        if n < self.ASSAULT_FLOOR:
            return False, "massing({}/{})".format(n, self.ASSAULT_FLOOR)
        if getattr(self, "_dominating", False):
            return True, "dominating-push"          # we're winning -> finish them, don't sit
        if n >= self.OVERWHELM:
            return True, "overwhelm({})".format(n)
        if not (self.kb and self.kb.loaded):
            return n >= 20, "no-kb"
        my_force = {}
        for u in pool:
            t = u.get("template")
            if t:
                my_force[t] = my_force.get(t, 0) + 1
        enemy_force = {}
        for e in ctx.world.enemies():
            if is_building(e):
                continue
            t = e.get("template")
            if t and is_combat_unit(e):
                enemy_force[t] = enemy_force.get(t, 0) + 1
        if not enemy_force and intel:
            enemy_force = dict(intel.enemy_profile())
        if not enemy_force:
            return n >= 18, "no-enemy-seen"
        est = combat_eval.engagement_estimate(self.kb, my_force, enemy_force)
        wp = est["win_prob"]
        if wp >= self.WIN_PROB:
            return True, "edge wp={:.2f}".format(wp)
        flags = my_flag_count(ctx)
        # economy-edge GRIND: a solid force + good income ATTACKS regardless of the noisy estimate —
        # we replace losses faster than the enemy, and passivity just loses to the AI's scaling. Only
        # bail if the clash is genuinely hopeless (wp below the grind floor). FLAGS only: oils pay
        # nothing, so counting them claimed an "economy edge" with zero actual income.
        if n >= self.GRIND_ARMY and flags >= self.GRIND_FLAGS and wp >= self.GRIND_WIN_PROB:
            return True, "grind wp={:.2f} flags={} n={}".format(wp, flags, n)
        return False, "wait wp={:.2f} n={}".format(wp, n)

    def _pick_focus(self, ctx, im, intel, cen):
        """Sticky focus building: the high-value enemy structure nearest the main force, kept
        until it's razed (gone from intel), so the whole force grinds one thing down."""
        blds = {b["id"]: b for b in (intel.all_enemy_buildings() if intel else [])
                if "x" in b and "id" in b}
        if not blds:
            self._focus_id = None
            return None
        if self._focus_id in blds:
            return blds[self._focus_id]
        cx, cy = cen if cen else (0, 0)
        prod_ids = {b["id"] for b in (intel.production_targets() if intel else [])}

        def score(b):
            d = math.hypot(b["x"] - cx, b["y"] - cy)
            bonus = 400.0 if b["id"] in prod_ids else 0.0
            return d - bonus
        focus = min(blds.values(), key=score)
        self._focus_id = focus["id"]
        self._focus_since = ctx.frame
        return focus
