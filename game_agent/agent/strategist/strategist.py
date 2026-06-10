"""strategist.py — the Strategist bot: a strong, dynamic, map-aware CWC commander.

This is the new always-on algorithmic brain (no LLM required). Each tick it:
  1. observes the enemy (BattlefieldIntel),
  2. rebuilds the influence heat maps (presence / threat / value) over the map,
  3. runs MACRO  — economy + construction + tech + counter-composed production (macro.Macro),
  4. runs the ARMY — every unit assigned a job from the heat maps (army.ArmyController).

It replaces the baseline commander's death-spiral macro and its turtling offense with a
coherent spend plan (never bankrupts, always keeps dozers + a standing army) and an
aggressive, influence-driven army that scouts, harasses, defends dynamically, counters the
enemy composition, and times concentrated assaults on the enemy base.

run_strategist() is the standalone driver (robust to flaky /healthz, publishes viewer state).
A StrategyDirective file only re-weights the doctrine; no LLM is needed to play or win.
"""
import math
import time

from agent.skills.base import (
    SkillContext, set_capture_templates, select_combat_units, my_units, my_buildings,
    is_building, is_combat_unit, my_flag_count,
)
from agent.knowledge import capture_capable_templates
from agent.cwc.knowledge_base import get_kb
from agent.cwc.intel import BattlefieldIntel
from agent.cwc import uistate, combat_eval
from agent.strategist.influence import InfluenceMap, mil_power
from agent.strategist.playbook import get_playbook
from agent.strategist.macro import Macro
from agent.strategist.army import ArmyController
from agent.strategist.personality import Personality
from agent.strategy import resolve_directive, load_directive, DIRECTIVE_PATH
from genapi.world import WorldModel


class Strategist:
    def __init__(self, owner, directive_path=DIRECTIVE_PATH):
        self.owner = owner
        self.directive_path = directive_path
        self.directive = resolve_directive()
        self._dir_mtime = None
        self.kb = get_kb()
        self.pb = get_playbook()
        self.intel = BattlefieldIntel(self.kb, owner)
        # per-match PERSONALITY: the bot's only randomness source — a fresh doctrine draw every
        # match (opening, thresholds, cadences) so a human can't script-read it across games
        self.personality = Personality()
        self.macro = Macro(owner, self.kb, self.pb, personality=self.personality)
        self.army = ArmyController(owner, self.kb, self.pb, personality=self.personality)
        self.terrain = None
        self.sectors = None          # viewer compatibility (built by the runner if desired)
        self.last_detail = {}
        self._dozer_plan = None      # viewer compatibility
        self._im = None
        self._base_scouted = False   # have we ever seen the enemy's real base (>=3 structures)?
        self._dominating_now = False
        self._apply_directive()

    # --------------------------------------------------------------- config ---
    def _reload_directive(self):
        import os
        try:
            m = os.path.getmtime(self.directive_path)
        except OSError:
            return
        if m == self._dir_mtime:
            return
        self.directive, _ = load_directive(self.directive_path)
        self._dir_mtime = m
        self._apply_directive()

    def _apply_directive(self):
        d = self.directive
        off = d.get("offense", {})
        army = d.get("army", {})
        # aggression knobs
        if "min_win_prob" in off:
            self.army.WIN_PROB = float(off["min_win_prob"])
        if off.get("engage") is False:
            self.army.WIN_PROB = 0.95        # effectively defensive
        if army.get("target"):
            self.macro.ARMY_CAP = min(60, max(self.macro.ARMY_FLOOR, int(army["target"])))

    # --------------------------------------------------------------- target ---
    DOM_MIN_ARMY = 18    # need a real force before we can claim dominance

    def _army_target(self, ctx):
        """Dynamic army size, ADAPTED to economy AND the enemy's strength (a cheating AI out-produces a
        fair bot, so the target must scale aggressively and track the threat). When DOMINATING the bot
        stops GROWING the army but keeps REPLACING losses (a maintenance level) — so it conserves
        resources without letting the closing assault bleed out (the live-match failure)."""
        army = [u for u in select_combat_units(ctx) if u["id"] not in self.macro.capture_force()]
        n = len(army)
        # income-scaled: FLAGS pay, oils don't (counting oils inflated the target with zero income)
        flags = my_flag_count(ctx)
        captured = len([u for u in ctx.world.units if u.get("player") == ctx.player
                        and (u.get("template") or "").startswith("CWCciv")])
        oil = max(0, captured - flags)
        if n >= self.DOM_MIN_ARMY and self._dominating(ctx, army):
            self._dominating_now = True
            return max(self.macro.ARMY_FLOOR, 24 + flags // 2)      # maintain (replace losses), don't grow
        self._dominating_now = False
        nfac = sum(1 for u in my_buildings(ctx)
                   if any(k in (u.get("template") or "").lower()
                          for k in ("barrack", "warfact", "war_fact", "airfield", "helipad")))
        target = 24 + 6 * flags + oil + 3 * nfac
        sc = getattr(self.macro, "_sc", None)
        if sc and sc.get("enemy_tier", 0) >= 1.5:                   # promoted / air-capable enemy -> bigger army
            target = int(target * (1.0 + min(1.0, sc["enemy_tier"] - 1.0)))
        if ctx.frame > 12000:                                      # long game -> the AI has scaled, so do we
            target = int(target * 1.15)
        # SITUATIONAL comfort cap (anti-flood, user: "не жорсткий кап — рахуй по мапі і по тому, що
        # на ній відбувається"): the baseline a map of this size needs to hold territory, RAISED to
        # match the enemy force actually observed (with a margin), stretched by personality. The bot
        # never saturates the map for its own sake, but it also never refuses to match a real threat.
        # ARMY_CAP=72 stays as the safety ceiling only.
        sc = getattr(self.macro, "_sc", None) or {}
        map_base = 28 + int((sc.get("diag") or 4000.0) / 280.0)    # small ~38, medium ~43, large ~50
        enemy_pow = 0.0
        for t, c in ((self.intel.enemy_profile() if self.intel else {}) or {}).items():
            enemy_pow += mil_power(self.kb, t)[0] * c
        enemy_equiv = enemy_pow / 1.8                              # ~average unit weight -> unit count
        cap = max(map_base, int(enemy_equiv * 1.15))
        if self.personality:
            cap = int(cap * self.personality.army_mult)
        return max(self.macro.ARMY_FLOOR, min(self.macro.ARMY_CAP, cap, target))

    def _dominating(self, ctx, army):
        """Are we clearly WINNING? Conservative — needs a crushing engagement edge over the enemy's
        actual army, OR the enemy's scouted base razed away while we're committed. Used only to stop
        OVERBUILDING (economy/defence keep running); flips off the moment the enemy recovers."""
        enemy_blds_known = len(self.intel.all_enemy_buildings()) if self.intel else 0
        if enemy_blds_known >= 3:
            self._base_scouted = True
        # enemy base collapsed: we found their base, now it's essentially gone, and we're committed
        if self._base_scouted and self.army.committed and enemy_blds_known <= 2:
            return True
        enemy_force = {}
        for e in ctx.world.enemies():
            if is_building(e):
                continue
            t = e.get("template")
            if t and is_combat_unit(e):
                enemy_force[t] = enemy_force.get(t, 0) + 1
        if not enemy_force and self.intel:
            enemy_force = dict(self.intel.enemy_profile())
        if not enemy_force or not (self.kb and self.kb.loaded):
            return False
        # require a real economy edge to back the "dominating" call (avoids a noisy-estimate false
        # positive that would freeze production AND force an over-confident attack). FLAGS only —
        # oils pay nothing, so they can't back an income claim.
        if my_flag_count(ctx) < 6:
            return False
        my_force = {}
        for u in army:
            t = u.get("template")
            if t:
                my_force[t] = my_force.get(t, 0) + 1
        est = combat_eval.engagement_estimate(self.kb, my_force, enemy_force)
        return est.get("win_prob", 0) >= 0.85 and (est.get("dps_ratio") or 0) >= 2.0

    # ----------------------------------------------------------------- step ---
    def step(self, ctx):
        self._reload_directive()
        # expose CWC brains to skills + observe the enemy (pure read) FIRST
        ctx.kb = self.kb
        ctx.intel = self.intel
        try:
            self.intel.observe(ctx)
        except Exception:  # noqa: BLE001 — intel is best-effort
            pass

        im = InfluenceMap(ctx.world, self.kb, self.owner,
                          extra_enemy_buildings=self.intel.all_enemy_buildings())
        self._im = im

        # MACRO: economy + construction + tech + counter-composed production. Garrisoned units are
        # invisible to /units, so subtract them from the target macro chases — otherwise every
        # soldier sitting in a building gets "replaced" and the army silently overshoots its cap.
        army_target = max(self.macro.ARMY_FLOOR,
                          self._army_target(ctx) - self.army.garrisoned_count())
        want_siege = self.army.committed
        mdetail = self.macro.tick(ctx, im, self.intel, army_target=army_target, want_siege=want_siege)

        # ARMY: every unit gets a job from the heat maps
        self.army.terrain = self.terrain
        reserved = self.macro.capture_force()
        self.army.command(ctx, im, self.intel, reserved, dominating=self._dominating_now)

        self.last_detail = {
            "build": mdetail.get("build", ""),
            "army": mdetail.get("army", ""),
            "capture": mdetail.get("cap", ""),
            "main": self.army.detail,
            "attack": self.army.detail,
            "target": "army_tgt={}".format(army_target),
        }
        return self.last_detail


# ------------------------------------------------------------------------------
# Standalone runner (mirrors agent.commander.run_commander; robust to flaky /healthz)
# ------------------------------------------------------------------------------
def _heartbeat(ctx, strat, world):
    me = ctx.me
    army = len(select_combat_units(ctx))
    blds = len(my_buildings(ctx))
    enemy_blds = len([u for u in world.enemies() if is_building(u)])
    mine_civ = [u for u in ctx.world.units if u.get("player") == ctx.player
                and (u.get("template") or "").startswith("CWCciv")]
    flags = sum(1 for u in mine_civ if "flag" in (u.get("template") or "").lower())
    oil = len(mine_civ) - flags
    a = strat.last_detail
    dom = " DOMINATING" if getattr(strat, "_dominating_now", False) else ""
    print("[strat f{}] ${} units={} bldgs={} army={} flags={} oil={} | enemyBldgs={} committed={}{} | "
          "{} | build:{} | cap:{} | {}".format(
              ctx.frame, me.get("money"), len(my_units(ctx)), blds, army, flags, oil, enemy_blds,
              strat.army.committed, dom, a.get("army", ""), a.get("build", ""),
              a.get("capture", ""), a.get("main", "")),
          flush=True)


def run_strategist(client, view="self", fast_hz=2.0, directive_path=DIRECTIVE_PATH,
                   heartbeat_s=10.0, verbose=True):
    from agent.journal import EventJournal
    from genapi.threats import ThreatTracker

    print("== strategist (algorithmic CWC bot v2: heatmaps + dynamic army, no LLM) on {} ==".format(
        client.base), flush=True)
    strat = None
    threats = journal = None
    owner = None
    map_cache = None
    catalog_loaded = False
    was_in_game = False
    last_hb = 0.0
    consec_miss = 0
    MATCH_END_MISSES = 16

    while True:
        try:
            alive = client.in_game()
        except Exception:  # noqa: BLE001
            alive = False
        if not alive:
            consec_miss += 1
            if consec_miss < MATCH_END_MISSES and was_in_game:
                time.sleep(0.4)
                continue
            if was_in_game:
                try:
                    sess = client.session() or {}
                except Exception:  # noqa: BLE001
                    sess = {}
                print("== MATCH ENDED == outcome={}".format(sess.get("outcome")), flush=True)
                uistate.atomic_write(uistate.STATE_PATH,
                                     {"inGame": False, "outcome": sess.get("outcome")})
            was_in_game = False
            map_cache = None
            catalog_loaded = False
            strat = None
            time.sleep(1.5)
            continue
        consec_miss = 0

        try:
            me = client.external_player()
            if not me:
                time.sleep(1.0)
                continue
            if strat is None:
                owner = me["index"]
                strat = Strategist(owner, directive_path)
                threats = ThreatTracker(client, owner)
                journal = EventJournal(client, owner)
                threats.start()
                journal.start()
                was_in_game = True
                print("[strat] match start: external idx={} side={}".format(owner, me.get("side")), flush=True)
                print("[strat] personality: {}".format(strat.personality.describe()), flush=True)
                import os as _os
                _spd = _os.getenv("GEN_SIM_SPEED")
                if _spd:
                    try:
                        client.speed(int(_spd))
                        print("[strat] sim speed -> {} fps".format(int(_spd)), flush=True)
                    except Exception:  # noqa: BLE001
                        pass

            v = me["index"] if view == "self" else view
            if map_cache is None:
                map_cache = client.map(ds=1)
                try:
                    from agent.cwc.terrain import Passability
                    strat.terrain = Passability(map_cache)
                except Exception:  # noqa: BLE001
                    strat.terrain = None
            world = WorldModel(map_cache, client.units(view=v), client.players(), owner=owner)
            frame = (client.healthz() or {}).get("frame", 0)
            ctx = SkillContext(world, me, client, threats=threats, journal=journal, frame=frame,
                               taskmgr=None)

            if not catalog_loaded:
                cat = client.catalog() or []
                if cat:
                    cap = capture_capable_templates(cat)
                    set_capture_templates(cap)
                    strat.kb.merge_catalog(cat)
                    uistate.atomic_write(uistate.STATIC_PATH, uistate.build_static(strat.kb))
                    _setup_science(strat, me)
                    catalog_loaded = True
                    print("[strat] catalog: {} entries, canCapture~{}, faction={}".format(
                        len(cat), len(cap), strat.macro.prefix or me.get("side")), flush=True)
                    # FAIR START: the stand pauses the match right after load (`make run`) so the
                    # enemy AI can't play its first minute while the bot is still attaching. We're
                    # fully initialized now — release the match. Harmless if nothing is paused.
                    try:
                        client.resume()
                        print("[strat] match resumed (fair start)", flush=True)
                    except Exception:  # noqa: BLE001
                        pass

            strat.step(ctx)

            # FAIR TECH: buy pending sciences with EARNED rank points (engine gates it; no free grants)
            wl = getattr(strat, "_sci_wishlist", None)
            if wl and frame - getattr(strat, "_last_sci", -10 ** 9) > 150:
                strat._last_sci = frame
                res = client.command(owner, [], "purchase_science", {"sciences": wl}) or {}
                bought = set(res.get("purchased") or [])
                if bought:
                    strat._sci_wishlist = [s for s in wl if s not in bought]
                    print("[strat] bought sciences: {}".format(
                        sorted(b.replace("SCIENCE_", "") for b in bought)), flush=True)

            try:
                st = uistate.build_state(ctx, strat, world)
                if strat._im is not None:
                    st["influence"] = strat._im.overlay(ds=1)
                uistate.atomic_write(uistate.STATE_PATH, st)
            except Exception:  # noqa: BLE001
                pass

            now = time.time()
            if verbose and now - last_hb >= heartbeat_s:
                _heartbeat(ctx, strat, world)
                last_hb = now
        except Exception as e:  # noqa: BLE001 — a transient blip must not kill the bot
            if verbose:
                import traceback
                print("[strat] tick error: {}".format(e), flush=True)
                traceback.print_exc()
        time.sleep(1.0 / fast_hz if fast_hz else 0.5)


def _setup_science(strat, me):
    """Prioritised science wishlist (ranks first to climb the tree, then unit-prereq tech, then powers).
    Purchased with earned rank points only — the engine owns all gating."""
    kb = strat.kb
    sl = (me.get("side") or "").lower()
    pfx = "SCIENCE_CWCru" if sl.startswith("rus") else \
          ("SCIENCE_CWCus" if (sl.startswith("us") or "america" in sl) else None)
    unit_pre = sorted({s for pre in kb.tech.get("objects", {}).values()
                       for s in (pre.get("science") or [])})
    side_sci = [s for s in kb.tech.get("sciences", {}) if pfx and s.startswith(pfx)]
    ranks = sorted(s for s in side_sci if "Rank" in s)
    others = sorted(s for s in side_sci if "Rank" not in s and s not in unit_pre)
    seen, wishlist = set(), []
    for s in ranks + unit_pre + others:
        if s not in seen:
            seen.add(s)
            wishlist.append(s)
    strat._sci_wishlist = wishlist
    print("[strat] science wishlist: {} items (bought with EARNED rank points)".format(len(wishlist)),
          flush=True)
