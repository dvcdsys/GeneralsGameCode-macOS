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

// FILE: ExternalControlInterface.h ///////////////////////////////////////////////////////////////
// Milestone 1: embedded external-control API server.
//
// An external process (eventually a small LLM) drives an API-controlled player over a local
// HTTP/WebSocket interface: it reads game state, issues unit/structure orders, and controls match
// tempo (pause/step/speed). The server runs on its own thread(s) and NEVER touches engine state
// directly -- all engine access happens on the logic thread at a fixed drain seam each tick.
//
// This header is the public face of the subsystem; the concrete implementation lives in
// Source/Common/ExternalControl/. The whole module is compiled only when RTS_HAS_EXTERNAL_CONTROL
// is defined (driven by the RTS_BUILD_EXTERNAL_CONTROL CMake option).
///////////////////////////////////////////////////////////////////////////////////////////////////

#pragma once

#include "Common/SubsystemInterface.h"

//-------------------------------------------------------------------------------------------------
/** Abstract face of the external-control subsystem. For Milestone 1 Step 0 this only carries the
  * SubsystemInterface lifecycle; request/command/event plumbing is added in later steps. */
class ExternalControlInterface : public SubsystemInterface
{
public:
	virtual ~ExternalControlInterface() { }

	/** Drain and service any pending API requests on the engine (logic) thread. Called once per
	  * engine loop from GameEngine::update(), before the game-logic update, so reads see a coherent
	  * end-of-previous-frame snapshot and (later) command injection lands in the same frame. Runs
	  * even while the game is paused or in the shell menu, so health/state/control stay responsive. */
	virtual void serviceRequests() = 0;

	/** Single-step support: if the API has queued one or more logic-frame steps (via
	  * POST /control {action:"step"}), consume one and return true so GameEngine::update advances
	  * exactly one logic frame even while the game is paused. Called on the engine thread. */
	virtual bool consumePendingStep() = 0;

	//---------------------------------------------------------------------------------------------
	// Game-event stream (WebSocket /events). All emit methods below are called from gameplay taps
	// on the logic thread and are cheap no-ops unless a /events client is connected (see
	// eventsActive). The implementation pushes onto a fixed-capacity ring that a separate
	// broadcaster thread drains to connected clients ~30 Hz.
	//---------------------------------------------------------------------------------------------

	/** Fast gate for hot-path taps (e.g. combat damage): true only while at least one /events
	  * WebSocket client is connected, so callers can skip building event arguments otherwise.
	  * Safe to call from the logic thread (atomic). */
	virtual bool eventsActive() const = 0;

	/** Emit a "unit_died" event (from Object::onDie). killerId is the damage source (0 if none). */
	virtual void eventUnitDied(unsigned id, unsigned killerId, int ownerIndex, const char* templateName) = 0;

	/** Emit a "unit_produced" event (a factory finished a unit; from Player::onUnitCreated). */
	virtual void eventUnitProduced(unsigned id, int ownerIndex, const char* templateName, unsigned factoryId) = 0;

	/** Emit a "structure_complete" event (from Player::onStructureConstructionComplete). */
	virtual void eventStructureComplete(unsigned id, int ownerIndex, const char* templateName) = 0;

	/** Emit a "combat" event when actual damage was applied (from Object::attemptDamage). Gate the
	  * call with eventsActive() so the user's normal game pays nothing when no client listens. */
	virtual void eventCombatDamage(unsigned victimId, unsigned attackerId, int victimOwner,
		float amount, int damageType) = 0;
};

//-------------------------------------------------------------------------------------------------
/// Factory; mirrors createGameLogic()/createMessageStream() etc. Returns a heap-allocated instance.
extern ExternalControlInterface* createExternalControl();

//-------------------------------------------------------------------------------------------------
/// The single external-control subsystem instance (null until GameEngine::init registers it).
extern ExternalControlInterface* TheExternalControl;
