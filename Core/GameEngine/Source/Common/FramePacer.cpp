/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 Electronic Arts Inc.
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/
#include "PreRTS.h"

#include "Common/FramePacer.h"

#include "GameClient/View.h"

#include "GameLogic/GameLogic.h"
#include "GameLogic/ScriptEngine.h"

#include "GameNetwork/NetworkDefs.h"
#include "GameNetwork/NetworkInterface.h"


FramePacer* TheFramePacer = nullptr;

FramePacer::FramePacer()
{
	// Set the time slice size to 1 ms.
	timeBeginPeriod(1);

	m_maxFPS = BaseFps;
	m_logicTimeScaleFPS = LOGICFRAMES_PER_SECOND;
	m_updateTime = 1.0f / (Real)BaseFps; // initialized to something to avoid division by zero on first use
	m_enableFpsLimit = FALSE;
	m_enableLogicTimeScale = FALSE;
	m_isTimeFrozen = FALSE;
	m_isGameHalted = FALSE;
	m_macHighFps = FALSE;

#if defined(__APPLE__)
	// TheSuperHackers @port macOS: high-render-FPS with correct game speed.
	//
	// The Apple render cap (getActualFramesPerSecondLimit) defaults to 30 because
	// with logic-time-scale DISABLED, canUpdateRegularGameLogic() steps the
	// simulation once per RENDER frame — so rendering above 30 FPS runs the whole
	// game (units + animations) proportionally fast. That is why the cap was
	// pinned at 30.
	//
	// When the user opts into a higher render cap via GEN_FPS_CAP (>30, or 0 =
	// uncapped), enable the engine's existing logic-time-scale decoupling and pin
	// it to LOGICFRAMES_PER_SECOND (30). Then canUpdateRegularGameLogic() switches
	// to its real-time accumulator path (GameEngine.cpp) and steps logic at 30 Hz
	// regardless of render FPS, while getActualLogicTimeScaleOverFpsRatio() scales
	// animation time steps by min(1, 30/renderFPS). Result: smooth high-FPS render
	// with the original 30 Hz game speed. Camera scroll is already FPS-independent
	// via getBaseOverUpdateFpsRatio(). This is the same mechanism the External
	// Control API uses (setLogicTimeScaleFps + enableLogicTimeScale).
	//
	// Default (GEN_FPS_CAP unset / == 30) leaves this OFF — identical to prior
	// behavior. Network games are out of scope for the macOS port; note that the
	// accumulator path is single-player-oriented (network sync uses its own rate).
	{
		const char *e = ::getenv("GEN_FPS_CAP");
		const Int capN = (e && *e) ? atoi(e) : 30;
		if (capN > (Int)LOGICFRAMES_PER_SECOND || capN <= 0)
		{
			m_macHighFps = TRUE;
			m_enableLogicTimeScale = TRUE;
			m_logicTimeScaleFPS = LOGICFRAMES_PER_SECOND;
		}
		// GEN_LOGIC_FPS=N (harness/debug): step the SIMULATION at N Hz instead of
		// the stock 30 — the whole game runs N/30× fast. Used to compress leak /
		// soak reproductions (e.g. 45 → battles evolve 1.5× faster). Single-player
		// only, same accumulator path as above.
		const char *lf = ::getenv("GEN_LOGIC_FPS");
		if (lf && *lf && atoi(lf) > 0)
		{
			m_macHighFps = TRUE;
			m_enableLogicTimeScale = TRUE;
			m_logicTimeScaleFPS = atoi(lf);
		}
	}
#endif
}

FramePacer::~FramePacer()
{
	// Restore the previous time slice for Windows.
	timeEndPeriod(1);
}

void FramePacer::update()
{
	// TheSuperHackers @bugfix xezon 05/08/2025 Re-implements the frame rate limiter
	// with higher resolution counters to cap the frame rate more accurately to the desired limit.
	const UnsignedInt maxFps = getActualFramesPerSecondLimit();// allowFpsLimit ? getFramesPerSecondLimit() : RenderFpsPreset::UncappedFpsValue;
	m_updateTime = m_frameRateLimit.wait(maxFps);
}

void FramePacer::setFramesPerSecondLimit( Int fps )
{
	DEBUG_LOG(("FramePacer::setFramesPerSecondLimit() - setting max fps to %d (TheGlobalData->m_useFpsLimit == %d)", fps, TheGlobalData->m_useFpsLimit));
	m_maxFPS = fps;
}

Int FramePacer::getFramesPerSecondLimit()  const
{
	return m_maxFPS;
}

void FramePacer::enableFramesPerSecondLimit( Bool enable )
{
	m_enableFpsLimit = enable;
}

Bool FramePacer::isFramesPerSecondLimitEnabled() const
{
	return m_enableFpsLimit;
}

Bool FramePacer::isActualFramesPerSecondLimitEnabled() const
{
	Bool allowFpsLimit = true;

	if (TheTacticalView != nullptr)
	{
		allowFpsLimit &= TheTacticalView->getTimeMultiplier()<=1 && !TheScriptEngine->isTimeFast();
	}

	if (TheGameLogic != nullptr)
	{
#if defined(_ALLOW_DEBUG_CHEATS_IN_RELEASE)
		allowFpsLimit &= !(!TheGameLogic->isGamePaused() && TheGlobalData->m_TiVOFastMode);
#else	//always allow this cheat key if we're in a replay game.
		allowFpsLimit &= !(!TheGameLogic->isGamePaused() && TheGlobalData->m_TiVOFastMode && TheGameLogic->isInReplayGame());
#endif
	}

	allowFpsLimit &= TheGlobalData->m_useFpsLimit;
	allowFpsLimit &= isFramesPerSecondLimitEnabled();

	return allowFpsLimit;
}

Int FramePacer::getActualFramesPerSecondLimit() const
{
#if defined(__APPLE__)
	// macOS port: pin the render frame-rate cap at 30 FPS by default, in
	// every game state (main menu shellmap, cutscenes, loadscreen, missions,
	// skirmish, score screen). The original game was effectively CPU-bound
	// at ~30 on period hardware and the cutscene/animation timings are tuned
	// to that — running render at 60+ on Apple Silicon visibly speeds up
	// camera moves and ambient idle anims even though logic still ticks at
	// LOGICFRAMES_PER_SECOND=30. (Logic is decoupled from render rate;
	// units don't move faster, but visual motion ramp does.)
	//
	// Without this clamp, the engine's per-state setFramesPerSecondLimit()
	// calls swing the cap wildly (240 default → 20 during loadscreen → 240
	// again in mission), and the engine-side gate `m_useFpsLimit` is OFF by
	// default (Options.ini has no FPSLimit key on a fresh install). The
	// result is uncapped render in everything outside skirmish (where the
	// in-game Options menu surfaces the toggle), riding only on CAMetalLayer
	// VSync — which on a 75 Hz display floats around 75 with dips when
	// video upload spikes hit.
	//
	// Override with `GEN_FPS_CAP=N` env (0 / negative → uncapped). Cached
	// on first read for the rest of the process lifetime.
	static int s_cap = -2;
	if (s_cap == -2) {
		const char *e = ::getenv("GEN_FPS_CAP");
		s_cap = (e && *e) ? atoi(e) : 30;
	}
	if (s_cap <= 0) return RenderFpsPreset::UncappedFpsValue;
	return s_cap;
#else
	return isActualFramesPerSecondLimitEnabled() ? getFramesPerSecondLimit() : RenderFpsPreset::UncappedFpsValue;
#endif
}

Real FramePacer::getUpdateTime()  const
{
	return m_updateTime;
}

Real FramePacer::getUpdateFps()  const
{
	return 1.0f / m_updateTime;
}

Real FramePacer::getBaseOverUpdateFpsRatio(Real minUpdateFps)
{
	// Update fps is floored to default 5 fps, 200 ms.
	// Useful to prevent insane ratios on frame spikes/stalls.
	return (Real)BaseFps / std::max(getUpdateFps(), minUpdateFps);
}

void FramePacer::setTimeFrozen(Bool frozen)
{
	m_isTimeFrozen = frozen;
}

void FramePacer::setGameHalted(Bool halted)
{
	m_isGameHalted = halted;
}

Bool FramePacer::isTimeFrozen() const
{
	return m_isTimeFrozen;
}

Bool FramePacer::isGameHalted() const
{
	return m_isGameHalted;
}

void FramePacer::setLogicTimeScaleFps( Int fps )
{
	m_logicTimeScaleFPS = fps;
}

Int FramePacer::getLogicTimeScaleFps() const
{
	return m_logicTimeScaleFPS;
}

void FramePacer::enableLogicTimeScale( Bool enable )
{
	m_enableLogicTimeScale = enable;
}

Bool FramePacer::isLogicTimeScaleEnabled() const
{
	return m_enableLogicTimeScale;
}

Int FramePacer::getActualLogicTimeScaleFps(LogicTimeQueryFlags flags) const
{
	if (m_isTimeFrozen && (flags & IgnoreFrozenTime) == 0)
	{
		return 0;
	}

	if (m_isGameHalted && (flags & IgnoreHaltedGame) == 0)
	{
		return 0;
	}

	if (TheNetwork != nullptr)
	{
		return TheNetwork->getFrameRate();
	}

	if (isLogicTimeScaleEnabled())
	{
		return getLogicTimeScaleFps();
	}

	// Returns uncapped value to align with the render update as per the original game behavior.
	return RenderFpsPreset::UncappedFpsValue;
}

Real FramePacer::getActualLogicTimeScaleRatio(LogicTimeQueryFlags flags) const
{
	return (Real)getActualLogicTimeScaleFps(flags) / LOGICFRAMES_PER_SECONDS_REAL;
}

Real FramePacer::getActualLogicTimeScaleOverFpsRatio(LogicTimeQueryFlags flags) const
{
	// TheSuperHackers @info Clamps ratio to min 1, because the logic
	// frame rate is currently capped by the render frame rate.
	return min(1.0f, (Real)getActualLogicTimeScaleFps(flags) / getUpdateFps());
}

Real FramePacer::getLogicTimeStepSeconds(LogicTimeQueryFlags flags) const
{
	return SECONDS_PER_LOGICFRAME_REAL * getActualLogicTimeScaleOverFpsRatio(flags);
}

Real FramePacer::getLogicTimeStepMilliseconds(LogicTimeQueryFlags flags) const
{
	return MSEC_PER_LOGICFRAME_REAL * getActualLogicTimeScaleOverFpsRatio(flags);
}
