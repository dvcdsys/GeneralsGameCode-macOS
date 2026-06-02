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

// FILE: ExternalControlSystem.cpp ////////////////////////////////////////////////////////////////
// Milestone 1 Step 3: embedded HTTP server + read-only endpoints.
//
// Architecture
//   - An HTTP listener (cpp-httplib) runs on its own std::thread and NEVER touches engine state.
//     Each request becomes a PendingRequest pushed onto a mutex-guarded inbound queue; the handler
//     then blocks on a per-request condition variable until the engine fills in the response.
//   - The engine (logic/main) thread drains and services that queue once per loop via
//     serviceRequests(), called from GameEngine::update(). All engine reads happen there, so they
//     are single-threaded with the rest of the simulation and frame-coherent.
//   - Thread-safety of allocation: the engine's global operator new routes through the
//     DynamicMemoryAllocator, which is guarded by TheDmaCriticalSection, so std/json/httplib
//     allocations on the listener thread are safe (the same path the audio/network threads use).
//
// Implemented: read endpoints (/healthz, /players, /units, /resources, /state), control
// (/control pause/resume/step/speed), commands (/command, /commands), and a WebSocket game-event
// stream (/events, default port API+1). Events are pushed by gameplay taps (Object::onDie,
// Player::onUnitCreated/onStructureConstructionComplete, Object::attemptDamage) onto a bounded ring
// that a broadcaster thread drains to connected clients ~30 Hz; taps no-op when no client listens.
///////////////////////////////////////////////////////////////////////////////////////////////////

// Third-party headers first, so engine macros (min/max, etc.) do not leak into them.
#include <httplib.h>
#include <nlohmann/json.hpp>
#include <ixwebsocket/IXNetSystem.h>
#include <ixwebsocket/IXWebSocketServer.h>
#include <ixwebsocket/IXWebSocket.h>
#include <ixwebsocket/IXConnectionState.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "Common/ExternalControl/ExternalControlInterface.h"
#include "Common/GameMemory.h"
#include "Common/Debug.h"
#include "Common/GameCommon.h"			// PlayerType, LOGICFRAMES_PER_SECOND
#include "Common/FramePacer.h"			// TheFramePacer (speed / logic time scale)
#include "Common/NameKeyGenerator.h"	// KEYNAME
#include "Common/Player.h"
#include "Common/PlayerList.h"
#include "Common/Team.h"
#include "Common/KindOf.h"				// KINDOF_* (object classification for /units, /map overlays)
#include "Common/Energy.h"
#include "Common/Money.h"
#include "Common/ThingTemplate.h"
#include "Common/ThingFactory.h"		// TheThingFactory->findTemplate (build/train verbs, /catalog)
#include "Common/BuildAssistant.h"		// TheBuildAssistant (build_structure/sell, /buildable)
#include "Common/SpecialPower.h"		// TheSpecialPowerStore (special_power verb)
#include "Common/ProductionPrerequisite.h"	// prereq list (/catalog tech tree)
#include "GameLogic/Module/ProductionUpdate.h"	// ProductionUpdateInterface (train_unit)
#include "GameLogic/Module/UpdateModule.h"		// ExitInterface::setRallyPoint (set_rally)
#include "GameLogic/Module/ContainModule.h"		// getContain()->getContainCount (/units passengers)
#include "GameLogic/ExperienceTracker.h"		// veterancy / experience (/units)
#include "GameClient/ControlBar.h"				// CommandSet/CommandButton, TheControlBar (/buildable)
#include "GameLogic/GameLogic.h"
#include "GameLogic/Object.h"
#include "Common/ObjectStatusTypes.h"	// OBJECT_STATUS_STEALTHED/DETECTED/DISGUISED (synth fog)
#include "GameLogic/Module/BodyModule.h"
#include "GameLogic/AI.h"				// TheAI, AIGroup, createGroup (command dispatch)
#include "GameLogic/AIPathfind.h"		// Pathfinder grid, PathfindCell, LAYER_GROUND (/map)
#include "GameLogic/TerrainLogic.h"		// TheTerrainLogic ground height (/map)
#include "GameLogic/VictoryConditions.h"	// TheVictoryConditions (/session outcome)
#include "Common/GlobalData.h"			// TheGlobalData->m_headless (/session)
#include "Common/RandomValue.h"			// GetGameLogicRandomSeed (/session)
#include "Common/Recorder.h"			// TheRecorder mode/playback (/session)
#include "GameNetwork/GameInfo.h"		// TheGameInfo->setSeed (/session seed, pre-start)
#include "GameNetwork/GameSpy/ThreadUtils.h"	// WideCharStringToMultiByte

using json = nlohmann::json;

ExternalControlInterface* TheExternalControl = nullptr;

namespace
{

const int   DEFAULT_API_PORT      = 3459;
const char* API_BIND_HOST         = "127.0.0.1";
const int   REQUEST_TIMEOUT_MS    = 5000;
const int   NO_MAX_SHOTS          = 0x7fffffff;	// mirrors NO_MAX_SHOTS_LIMIT (Weapon.h): fire indefinitely

/// The set of operations the engine thread knows how to service. (Step 3: reads only.)
enum RequestKind
{
	REQ_HEALTHZ,
	REQ_PLAYERS,
	REQ_STATE,
	REQ_UNITS,
	REQ_RESOURCES,
	REQ_CONTROL,
	REQ_COMMAND,
	REQ_COMMANDS,
	REQ_SESSION,		///< GET /session: seed/outcome/replay/headless
	REQ_SESSION_SET,	///< POST /session: set seed (pre-start only)
	REQ_MAP,			///< GET /map: pathfinder cell grid (type/height/zone)
	REQ_CATALOG,		///< GET /catalog: static per-template stats + tech tree
	REQ_BUILDABLE		///< GET /buildable?player=N: what player N can build/train now
};

/// One in-flight request handed from the listener thread to the engine thread and back.
struct PendingRequest
{
	RequestKind kind;
	int playerArg = -1;			///< /units, /resources: filter/select by player index (-1 = all)
	std::string strArg;			///< /control: action ("pause"/"resume"/"step"/"speed")
	double numArg = 0.0;		///< /control: numeric value (step count, speed fps)
	nlohmann::json payload;		///< /command (object) or /commands (array): the parsed command(s)

	// Filled in by the engine thread:
	int status = 200;
	std::string responseJson;
	bool done = false;
	std::mutex mtx;
	std::condition_variable cv;
};

std::string controllerName(PlayerType t)
{
	switch (t)
	{
		case PLAYER_HUMAN:    return "human";
		case PLAYER_COMPUTER: return "computer";
		case PLAYER_EXTERNAL: return "external";
		default:              return "unknown";
	}
}

std::string narrow(UnicodeString u)
{
	if (u.isEmpty())
		return std::string();
	return WideCharStringToMultiByte(u.str());
}

/// Relationship of player p to the local (human) player, as a stable string.
const char* relationName(Player* local, Player* p)
{
	if (!p)            return "unknown";
	if (local == p)    return "self";
	if (!local)        return "unknown";
	Team* t = p->getDefaultTeam();
	if (!t)            return "unknown";
	switch (local->getRelationship(t))
	{
		case ALLIES:  return "ally";
		case ENEMIES: return "enemy";
		case NEUTRAL: return "neutral";
		default:      return "unknown";
	}
}

/// Coarse object-classification tags so a bot/viewer can model the world (structures vs units,
/// capturable points, oil/supply, garrisonable "bunkers", base defenses, etc.).
nlohmann::json objectTags(Object* o)
{
	nlohmann::json t = nlohmann::json::array();
	if (o->isKindOf(KINDOF_STRUCTURE))                  t.push_back("structure");
	if (o->isKindOf(KINDOF_INFANTRY))                   t.push_back("infantry");
	if (o->isKindOf(KINDOF_VEHICLE))                    t.push_back("vehicle");
	if (o->isKindOf(KINDOF_AIRCRAFT))                   t.push_back("aircraft");
	if (o->isKindOf(KINDOF_DOZER))                      t.push_back("dozer");
	if (o->isKindOf(KINDOF_HARVESTER))                  t.push_back("harvester");
	if (o->isKindOf(KINDOF_COMMANDCENTER))              t.push_back("command_center");
	if (o->isKindOf(KINDOF_GARRISONABLE_UNTIL_DESTROYED)) t.push_back("garrisonable");
	if (o->isKindOf(KINDOF_CAPTURABLE))                 t.push_back("capturable");
	if (o->isKindOf(KINDOF_TECH_BUILDING))              t.push_back("tech_building");
	if (o->isKindOf(KINDOF_SUPPLY_SOURCE))              t.push_back("supply_source");
	if (o->isKindOf(KINDOF_CASH_GENERATOR))             t.push_back("cash_generator");
	if (o->isKindOf(KINDOF_MP_COUNT_FOR_VICTORY))       t.push_back("victory_building");
	if (o->isKindOf(KINDOF_FS_BASE_DEFENSE) || o->isKindOf(KINDOF_TECH_BASE_DEFENSE)) t.push_back("base_defense");
	return t;
}

/// Single primary category for quick rendering/filtering.
const char* primaryCategory(Object* o)
{
	if (o->isKindOf(KINDOF_STRUCTURE))
	{
		if (o->isKindOf(KINDOF_SUPPLY_SOURCE) || o->isKindOf(KINDOF_CASH_GENERATOR)) return "economy";
		if (o->isKindOf(KINDOF_TECH_BUILDING) || o->isKindOf(KINDOF_CAPTURABLE))     return "tech";
		if (o->isKindOf(KINDOF_GARRISONABLE_UNTIL_DESTROYED))                        return "garrisonable";
		if (o->isKindOf(KINDOF_FS_BASE_DEFENSE) || o->isKindOf(KINDOF_TECH_BASE_DEFENSE)) return "defense";
		return "structure";
	}
	if (o->isKindOf(KINDOF_INFANTRY) || o->isKindOf(KINDOF_VEHICLE) || o->isKindOf(KINDOF_AIRCRAFT))
		return "unit";
	return "prop";
}

/// Same coarse tags/category, but for a ThingTemplate (static, no live Object) — used by /catalog.
nlohmann::json templateTags(const ThingTemplate* tt)
{
	nlohmann::json t = nlohmann::json::array();
	if (tt->isKindOf(KINDOF_STRUCTURE))                    t.push_back("structure");
	if (tt->isKindOf(KINDOF_INFANTRY))                     t.push_back("infantry");
	if (tt->isKindOf(KINDOF_VEHICLE))                      t.push_back("vehicle");
	if (tt->isKindOf(KINDOF_AIRCRAFT))                     t.push_back("aircraft");
	if (tt->isKindOf(KINDOF_DOZER))                        t.push_back("dozer");
	if (tt->isKindOf(KINDOF_HARVESTER))                    t.push_back("harvester");
	if (tt->isKindOf(KINDOF_COMMANDCENTER))                t.push_back("command_center");
	if (tt->isKindOf(KINDOF_GARRISONABLE_UNTIL_DESTROYED)) t.push_back("garrisonable");
	if (tt->isKindOf(KINDOF_CAPTURABLE))                   t.push_back("capturable");
	if (tt->isKindOf(KINDOF_TECH_BUILDING))                t.push_back("tech_building");
	if (tt->isKindOf(KINDOF_SUPPLY_SOURCE))                t.push_back("supply_source");
	if (tt->isKindOf(KINDOF_CASH_GENERATOR))               t.push_back("cash_generator");
	if (tt->isKindOf(KINDOF_FS_BASE_DEFENSE) || tt->isKindOf(KINDOF_TECH_BASE_DEFENSE)) t.push_back("base_defense");
	return t;
}
const char* templateCategory(const ThingTemplate* tt)
{
	if (tt->isKindOf(KINDOF_STRUCTURE))
	{
		if (tt->isKindOf(KINDOF_SUPPLY_SOURCE) || tt->isKindOf(KINDOF_CASH_GENERATOR)) return "economy";
		if (tt->isKindOf(KINDOF_TECH_BUILDING) || tt->isKindOf(KINDOF_CAPTURABLE))     return "tech";
		if (tt->isKindOf(KINDOF_GARRISONABLE_UNTIL_DESTROYED))                         return "garrisonable";
		if (tt->isKindOf(KINDOF_FS_BASE_DEFENSE) || tt->isKindOf(KINDOF_TECH_BASE_DEFENSE)) return "defense";
		return "structure";
	}
	if (tt->isKindOf(KINDOF_INFANTRY) || tt->isKindOf(KINDOF_VEHICLE) || tt->isKindOf(KINDOF_AIRCRAFT))
		return "unit";
	return "prop";
}
const char* veterancyName(VeterancyLevel v)
{
	switch (v)
	{
		case LEVEL_VETERAN: return "veteran";
		case LEVEL_ELITE:   return "elite";
		case LEVEL_HEROIC:  return "heroic";
		default:            return "regular";
	}
}
const char* canMakeName(CanMakeType c)
{
	switch (c)
	{
		case CANMAKE_OK:                  return "ok";
		case CANMAKE_NO_PREREQ:           return "no_prereq";
		case CANMAKE_NO_MONEY:            return "no_money";
		case CANMAKE_FACTORY_IS_DISABLED: return "factory_disabled";
		case CANMAKE_QUEUE_FULL:          return "queue_full";
		case CANMAKE_PARKING_PLACES_FULL: return "parking_full";
		case CANMAKE_MAXED_OUT_FOR_PLAYER:return "maxed_out";
		default:                          return "unknown";
	}
}

/// Standard base64 of a raw byte buffer (used to ship the /map grids compactly).
std::string base64(const unsigned char* data, size_t len)
{
	static const char tbl[] =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string out;
	out.reserve(((len + 2) / 3) * 4);
	size_t i = 0;
	for (; i + 2 < len; i += 3)
	{
		unsigned n = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
		out.push_back(tbl[(n >> 18) & 63]);
		out.push_back(tbl[(n >> 12) & 63]);
		out.push_back(tbl[(n >> 6) & 63]);
		out.push_back(tbl[n & 63]);
	}
	if (i < len)
	{
		unsigned n = data[i] << 16;
		bool two = (i + 1 < len);
		if (two) n |= data[i + 1] << 8;
		out.push_back(tbl[(n >> 18) & 63]);
		out.push_back(tbl[(n >> 12) & 63]);
		out.push_back(two ? tbl[(n >> 6) & 63] : '=');
		out.push_back('=');
	}
	return out;
}

} // anonymous namespace

//-------------------------------------------------------------------------------------------------
class ExternalControlSystem : public ExternalControlInterface
{
public:
	ExternalControlSystem()
		: m_port(DEFAULT_API_PORT), m_wsPort(DEFAULT_API_PORT + 1), m_enabled(true), m_running(false) { }
	virtual ~ExternalControlSystem() { stopServer(); }

	virtual void init() override
	{
		if (const char* off = ::getenv("GEN_API_OFF"); off && off[0])
			m_enabled = false;
		if (const char* p = ::getenv("GEN_API_PORT"); p && p[0])
		{
			int v = ::atoi(p);
			if (v > 0 && v < 65536)
			{
				m_port = v;
				m_wsPort = v + 1;	// keep WS adjacent to REST unless overridden below
			}
		}
		if (const char* wp = ::getenv("GEN_API_WS_PORT"); wp && wp[0])
		{
			int v = ::atoi(wp);
			if (v > 0 && v < 65536)
				m_wsPort = v;
		}

		if (!m_enabled)
		{
			DEBUG_LOG(("ExternalControl: disabled via GEN_API_OFF"));
			return;
		}

		openActionLog();
		startServer();
	}

	virtual void reset() override
	{
		// New game / shutdown of a match: abandon any in-flight requests; keep the server running.
		failAllPending("game reset");
		m_fogMemory.clear();	// scouted-structure memory does not carry across matches
		logMarker("reset");	// match boundary, so action timelines are separable
	}

	virtual void update() override { /* draining is driven explicitly via serviceRequests() */ }

	//---------------------------------------------------------------------------------------------
	virtual void serviceRequests() override
	{
		if (!m_running)
			return;

		std::deque<std::shared_ptr<PendingRequest> > batch;
		{
			std::lock_guard<std::mutex> lk(m_queueMutex);
			batch.swap(m_inbound);
		}

		for (std::shared_ptr<PendingRequest>& req : batch)
		{
			service(*req);
			{
				std::lock_guard<std::mutex> lk(req->mtx);
				req->done = true;
			}
			req->cv.notify_one();
		}
	}

	//---------------------------------------------------------------------------------------------
	virtual bool consumePendingStep() override
	{
		int cur = m_pendingSteps.load();
		while (cur > 0)
		{
			if (m_pendingSteps.compare_exchange_weak(cur, cur - 1))
				return true;
		}
		return false;
	}

	//---------------------------------------------------------------------------------------------
	// Event emission (logic-thread taps). All no-op unless a /events client is connected.
	//---------------------------------------------------------------------------------------------
	virtual bool eventsActive() const override { return m_running && m_hasClients.load(); }

	virtual void eventUnitDied(unsigned id, unsigned killerId, int ownerIndex, const char* templateName) override
	{
		if (!eventsActive()) return;
		pushEvent(json{ {"type", "unit_died"}, {"id", id}, {"killerId", killerId},
			{"player", ownerIndex}, {"template", templateName ? templateName : ""} });
	}

	virtual void eventUnitProduced(unsigned id, int ownerIndex, const char* templateName, unsigned factoryId) override
	{
		if (!eventsActive()) return;
		pushEvent(json{ {"type", "unit_produced"}, {"id", id}, {"player", ownerIndex},
			{"template", templateName ? templateName : ""}, {"factoryId", factoryId} });
	}

	virtual void eventStructureComplete(unsigned id, int ownerIndex, const char* templateName) override
	{
		if (!eventsActive()) return;
		pushEvent(json{ {"type", "structure_complete"}, {"id", id}, {"player", ownerIndex},
			{"template", templateName ? templateName : ""} });
	}

	virtual void eventCombatDamage(unsigned victimId, unsigned attackerId, int victimOwner,
		float amount, int damageType) override
	{
		if (!eventsActive()) return;
		pushEvent(json{ {"type", "combat"}, {"victimId", victimId}, {"attackerId", attackerId},
			{"player", victimOwner}, {"amount", amount}, {"damageType", damageType} });
	}

private:
	//---------------------------------------------------------------------------------------------
	// Listener-thread side
	//---------------------------------------------------------------------------------------------
	void startServer()
	{
		m_running = true;
		m_thread = std::thread([this]() { serverThreadMain(); });
		DEBUG_LOG(("ExternalControl: HTTP server starting on %s:%d", API_BIND_HOST, m_port));
		startWsServer();
	}

	void stopServer()
	{
		if (!m_running)
			return;
		m_running = false;
		m_server.stop();
		if (m_wsServer)
			m_wsServer->stop();
		if (m_broadcastThread.joinable())
			m_broadcastThread.join();
		if (m_thread.joinable())
			m_thread.join();
		if (m_wsServer)
		{
			m_wsServer.reset();
			ix::uninitNetSystem();
		}
		failAllPending("server shutting down");
		DEBUG_LOG(("ExternalControl: HTTP server stopped"));
	}

	//---------------------------------------------------------------------------------------------
	// WebSocket /events server (its own IO thread + a broadcaster thread). Never touches engine
	// state: it only reads the event ring (mutex-guarded) and writes to sockets.
	//---------------------------------------------------------------------------------------------
	void startWsServer()
	{
		ix::initNetSystem();
		m_wsServer = std::unique_ptr<ix::WebSocketServer>(new ix::WebSocketServer(m_wsPort, API_BIND_HOST));
		m_wsServer->setOnClientMessageCallback(
			[this](std::shared_ptr<ix::ConnectionState> /*state*/, ix::WebSocket& ws,
				const ix::WebSocketMessagePtr& msg)
			{
				if (msg->type == ix::WebSocketMessageType::Open)
				{
					m_hasClients = true;	// flips taps live before the broadcaster's next pass
					json hello{ {"type", "hello"}, {"api", "external-control"}, {"stream", "events"} };
					ws.send(hello.dump());
				}
			});

		std::pair<bool, std::string> ok = m_wsServer->listen();
		if (!ok.first)
		{
			DEBUG_LOG(("ExternalControl: WS /events failed to bind %s:%d (%s)",
				API_BIND_HOST, m_wsPort, ok.second.c_str()));
			m_wsServer.reset();
			ix::uninitNetSystem();
			return;
		}
		m_wsServer->start();
		m_broadcastThread = std::thread([this]() { broadcastThreadMain(); });
		DEBUG_LOG(("ExternalControl: WS /events listening on %s:%d", API_BIND_HOST, m_wsPort));
	}

	void broadcastThreadMain()
	{
		using namespace std::chrono;
		while (m_running)
		{
			std::this_thread::sleep_for(milliseconds(33));	// ~30 Hz
			if (!m_wsServer)
				break;

			std::set<std::shared_ptr<ix::WebSocket> > clients = m_wsServer->getClients();
			m_hasClients = !clients.empty();
			if (clients.empty())
				continue;

			json events = json::array();
			uint64_t dropped = 0;
			{
				std::lock_guard<std::mutex> lk(m_eventMutex);
				for (const RingEvent& re : m_eventRing)
					if (re.seq > m_lastBroadcastSeq)
						events.push_back(re.data);
				if (!m_eventRing.empty())
					m_lastBroadcastSeq = m_eventRing.back().seq;
				dropped = m_eventsDropped;
				m_eventsDropped = 0;
			}

			if (events.empty() && dropped == 0)
				continue;

			json batch{ {"type", "events"}, {"events", events} };
			if (dropped)
				batch["dropped"] = (unsigned)dropped;
			std::string payload = batch.dump();
			for (const std::shared_ptr<ix::WebSocket>& c : clients)
				c->send(payload);
		}
	}

	void serverThreadMain()
	{
		using httplib::Request;
		using httplib::Response;

		m_server.Get("/healthz", [this](const Request&, Response& res) {
			respond(res, REQ_HEALTHZ, -1);
		});
		m_server.Get("/players", [this](const Request&, Response& res) {
			respond(res, REQ_PLAYERS, -1);
		});
		m_server.Get("/state", [this](const Request&, Response& res) {
			respond(res, REQ_STATE, -1);
		});
		m_server.Get("/units", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_UNITS;
			pr->playerArg = req.has_param("player") ? ::atoi(req.get_param_value("player").c_str()) : -1;
			// ?view=N applies player N's fog-of-war: only objects N can see are returned.
			pr->numArg = req.has_param("view") ? (double)::atoi(req.get_param_value("view").c_str()) : -1.0;
			respondReq(res, pr);
		});
		m_server.Get("/resources", [this](const Request& req, Response& res) {
			int player = req.has_param("player") ? ::atoi(req.get_param_value("player").c_str()) : -1;
			respond(res, REQ_RESOURCES, player);
		});
		m_server.Post("/control", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_CONTROL;
			try
			{
				json body = json::parse(req.body);
				if (body.contains("action") && body["action"].is_string())
					pr->strArg = body["action"].get<std::string>();
				if (body.contains("value") && body["value"].is_number())
					pr->numArg = body["value"].get<double>();
			}
			catch (...)
			{
				res.status = 400;
				res.set_content("{\"error\":\"invalid JSON body\"}", "application/json");
				return;
			}
			if (pr->strArg.empty())
			{
				res.status = 400;
				res.set_content("{\"error\":\"missing 'action' (pause|resume|step|speed)\"}", "application/json");
				return;
			}
			respondReq(res, pr);
		});
		m_server.Post("/command", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_COMMAND;
			try { pr->payload = json::parse(req.body); }
			catch (...) { res.status = 400; res.set_content("{\"error\":\"invalid JSON body\"}", "application/json"); return; }
			respondReq(res, pr);
		});
		m_server.Post("/commands", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_COMMANDS;
			try { pr->payload = json::parse(req.body); }
			catch (...) { res.status = 400; res.set_content("{\"error\":\"invalid JSON body\"}", "application/json"); return; }
			respondReq(res, pr);
		});
		m_server.Get("/session", [this](const Request&, Response& res) {
			respond(res, REQ_SESSION, -1);
		});
		m_server.Get("/map", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_MAP;
			pr->playerArg = req.has_param("ds") ? ::atoi(req.get_param_value("ds").c_str()) : 1;	// downsample
			pr->numArg = req.has_param("zone") ? 1.0 : 0.0;										// include zone ids?
			respondReq(res, pr);
		});
		m_server.Get("/catalog", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_CATALOG;
			if (req.has_param("side")) pr->strArg = req.get_param_value("side");	// optional faction filter
			respondReq(res, pr);
		});
		m_server.Get("/buildable", [this](const Request& req, Response& res) {
			int player = req.has_param("player") ? ::atoi(req.get_param_value("player").c_str()) : -1;
			respond(res, REQ_BUILDABLE, player);
		});
		m_server.Post("/session", [this](const Request& req, Response& res) {
			std::shared_ptr<PendingRequest> pr = std::make_shared<PendingRequest>();
			pr->kind = REQ_SESSION_SET;
			try { pr->payload = json::parse(req.body); }
			catch (...) { res.status = 400; res.set_content("{\"error\":\"invalid JSON body\"}", "application/json"); return; }
			respondReq(res, pr);
		});

		// Allow browser-based tools (the live map viewer) to fetch the API cross-origin.
		m_server.set_post_routing_handler([](const httplib::Request&, httplib::Response& res) {
			res.set_header("Access-Control-Allow-Origin", "*");
		});

		// Blocks until stop() is called from stopServer().
		if (!m_server.listen(API_BIND_HOST, m_port))
		{
			DEBUG_LOG(("ExternalControl: failed to bind %s:%d (port in use?)", API_BIND_HOST, m_port));
			m_running = false;
		}
	}

	/// Build a simple (GET) request and run it through the engine thread.
	void respond(httplib::Response& res, RequestKind kind, int playerArg)
	{
		std::shared_ptr<PendingRequest> req = std::make_shared<PendingRequest>();
		req->kind = kind;
		req->playerArg = playerArg;
		respondReq(res, req);
	}

	/// Hand a request to the engine thread, block for the response, write it out.
	void respondReq(httplib::Response& res, std::shared_ptr<PendingRequest> req)
	{
		{
			std::lock_guard<std::mutex> lk(m_queueMutex);
			if (!m_running)
			{
				res.status = 503;
				res.set_content("{\"error\":\"server stopping\"}", "application/json");
				return;
			}
			m_inbound.push_back(req);
		}

		std::unique_lock<std::mutex> lk(req->mtx);
		bool ok = req->cv.wait_for(lk, std::chrono::milliseconds(REQUEST_TIMEOUT_MS),
			[&req]() { return req->done; });

		if (!ok)
		{
			res.status = 503;
			res.set_content("{\"error\":\"engine did not service request in time\"}", "application/json");
			return;
		}
		res.status = req->status;
		res.set_content(req->responseJson, "application/json");
	}

	void failAllPending(const char* why)
	{
		std::deque<std::shared_ptr<PendingRequest> > batch;
		{
			std::lock_guard<std::mutex> lk(m_queueMutex);
			batch.swap(m_inbound);
		}
		for (std::shared_ptr<PendingRequest>& req : batch)
		{
			{
				std::lock_guard<std::mutex> lk(req->mtx);
				req->status = 503;
				req->responseJson = std::string("{\"error\":\"") + why + "\"}";
				req->done = true;
			}
			req->cv.notify_one();
		}
	}

	//---------------------------------------------------------------------------------------------
	// Engine-thread side: all engine reads happen here.
	//---------------------------------------------------------------------------------------------
	void service(PendingRequest& req)
	{
		switch (req.kind)
		{
			case REQ_HEALTHZ:   req.responseJson = buildHealthz().dump(); break;
			case REQ_PLAYERS:   req.responseJson = buildPlayers().dump(); break;
			case REQ_STATE:     req.responseJson = buildState().dump();   break;
			case REQ_UNITS:     req.responseJson = buildUnits(req.playerArg, (int)req.numArg).dump(); break;
			case REQ_RESOURCES:
			{
				json out = buildResources(req.playerArg, req.status);
				req.responseJson = out.dump();
				break;
			}
			case REQ_CONTROL:
			{
				json out = buildControl(req.strArg, req.numArg, req.status);
				req.responseJson = out.dump();
				logAction("control", json{ {"action", req.strArg}, {"value", req.numArg} }, out, req.status);
				break;
			}
			case REQ_COMMAND:
			{
				json out = executeCommand(req.payload, req.status);
				req.responseJson = out.dump();
				logAction("command", req.payload, out, req.status);
				break;
			}
			case REQ_COMMANDS:
			{
				json arr = json::array();
				if (req.payload.is_array())
				{
					for (const json& c : req.payload)
					{
						int st = 200;
						arr.push_back(executeCommand(c, st));
					}
				}
				else
				{
					req.status = 400;
					arr = json{ {"error", "body must be a JSON array of commands"} };
				}
				req.responseJson = arr.dump();
				logAction("commands", req.payload, arr, req.status);
				break;
			}
			case REQ_SESSION:   req.responseJson = buildSession().dump(); break;
			case REQ_SESSION_SET:
			{
				json out = setSession(req.payload, req.status);
				req.responseJson = out.dump();
				logAction("session", req.payload, out, req.status);
				break;
			}
			case REQ_MAP:
			{
				int ds = req.playerArg > 0 ? req.playerArg : 1;
				json out = buildMap(ds, req.numArg != 0.0, req.status);
				req.responseJson = out.dump();
				break;
			}
			case REQ_CATALOG:  req.responseJson = buildCatalog(req.strArg).dump(); break;
			case REQ_BUILDABLE:
			{
				json out = buildBuildable(req.playerArg, req.status);
				req.responseJson = out.dump();
				break;
			}
			default:
				req.status = 404;
				req.responseJson = "{\"error\":\"unknown request\"}";
				break;
		}
	}

	json buildHealthz()
	{
		json o;
		o["ok"] = true;
		o["frame"]  = TheGameLogic ? (unsigned)TheGameLogic->getFrame() : 0u;
		o["inGame"] = TheGameLogic ? (bool)TheGameLogic->isInGame() : false;
		o["paused"] = TheGameLogic ? (bool)TheGameLogic->isGamePaused() : false;
		return o;
	}

	json playerObject(Player* p)
	{
		json o;
		o["index"]       = (int)p->getPlayerIndex();
		o["controller"]  = controllerName(p->getPlayerType());
		o["name"]        = KEYNAME(p->getPlayerNameKey()).str();
		o["displayName"] = narrow(p->getPlayerDisplayName());
		o["side"]        = p->getSide().str();
		o["money"]       = p->getMoney() ? (unsigned)p->getMoney()->countMoney() : 0u;
		if (p->getEnergy())
		{
			o["powerProduction"]  = (int)p->getEnergy()->getProduction();
			o["powerConsumption"] = (int)p->getEnergy()->getConsumption();
		}
		// Relationship to the local (human) player, so allies/enemies are visible over the API.
		if (ThePlayerList)
			o["relationToLocal"] = relationName(ThePlayerList->getLocalPlayer(), p);
		return o;
	}

	json buildPlayers()
	{
		json arr = json::array();
		if (ThePlayerList)
		{
			for (Int i = 0; i < ThePlayerList->getPlayerCount(); ++i)
			{
				Player* p = ThePlayerList->getNthPlayer(i);
				if (p)
					arr.push_back(playerObject(p));
			}
		}
		return arr;
	}

	json buildState()
	{
		json o;
		o["frame"]                 = TheGameLogic ? (unsigned)TheGameLogic->getFrame() : 0u;
		o["paused"]                = TheGameLogic ? (bool)TheGameLogic->isGamePaused() : false;
		o["inGame"]                = TheGameLogic ? (bool)TheGameLogic->isInGame() : false;
		o["logicFramesPerSecond"]  = (int)LOGICFRAMES_PER_SECOND;
		o["players"]               = buildPlayers();
		return o;
	}

	json buildUnits(int playerFilter, int viewPlayer = -1)
	{
		json arr = json::array();
		if (TheGameLogic)
		{
			Player* local = ThePlayerList ? ThePlayerList->getLocalPlayer() : nullptr;

			// Synthesized fog-of-war for ?view=N (see m_fogMemory docs). getShroudedStatus(N) can't be
			// trusted (non-local AI players get a permanent full-map reveal), so we derive line-of-
			// sight from the view player's + allies' live unit vision, and cache a snapshot of every
			// building so a planner keeps knowing about it (frozen, last-known state) once out of sight.
			struct Looker { Real x, y, r2; };
			std::vector<Looker> lookers;
			Player* viewP = (viewPlayer >= 0 && ThePlayerList) ? ThePlayerList->getNthPlayer(viewPlayer) : nullptr;
			std::map<unsigned, FogEntry>* fog = viewP ? &m_fogMemory[viewPlayer] : nullptr;
			if (viewP)
			{
				for (Object* o = TheGameLogic->getFirstObject(); o; o = o->getNextObject())
				{
					Player* op = o->getControllingPlayer();
					if (!op) continue;
					bool friendly = (op == viewP);
					if (!friendly) { Team* t = op->getDefaultTeam(); friendly = t && viewP->getRelationship(t) == ALLIES; }
					if (!friendly) continue;
					Real range = o->getShroudClearingRange();	// 0 for dead / under-construction / blind
					if (range <= 0.0f) continue;
					const Coord3D* p = o->getPosition();
					if (!p) continue;
					Looker lk; lk.x = p->x; lk.y = p->y; lk.r2 = range * range;
					lookers.push_back(lk);
				}
			}
			auto inSight = [&](Real x, Real y) -> bool {
				for (size_t i = 0; i < lookers.size(); ++i)
				{
					Real dx = x - lookers[i].x, dy = y - lookers[i].y;
					if (dx * dx + dy * dy <= lookers[i].r2) return true;
				}
				return false;
			};
			// Full ground-truth json for one object; fog handling is layered on by the caller.
			auto liveJson = [&](Object* obj, int owner) -> json {
				json u;
				u["id"]       = (unsigned)obj->getID();
				u["template"] = obj->getTemplate() ? obj->getTemplate()->getName().str() : "";
				u["player"]   = owner;
				u["relationToLocal"] = relationName(local, obj->getControllingPlayer());
				u["category"]        = primaryCategory(obj);
				json tags = objectTags(obj);
				if (!tags.empty())
					u["tags"] = tags;
				const Coord3D* pos = obj->getPosition();
				if (pos) { u["x"] = pos->x; u["y"] = pos->y; u["z"] = pos->z; }
				if (BodyModuleInterface* body = obj->getBodyModule())
				{
					u["health"]    = body->getHealth();
					u["maxHealth"] = body->getMaxHealth();
				}
				// Dynamic combat-relevant state (lean: only when non-default).
				VeterancyLevel vet = obj->getVeterancyLevel();
				if (vet != LEVEL_REGULAR) u["veterancy"] = veterancyName(vet);	// promoted ranks
				if (const ExperienceTracker* xt = obj->getExperienceTracker())
				{
					int xp = xt->getCurrentExperience();
					if (xp > 0) u["experience"] = xp;
				}
				Real vis = obj->getVisionRange();
				if (vis > 0.0f) u["visionRange"] = (double)vis;
				if (ContainModuleInterface* c = obj->getContain())
				{
					int n = (int)c->getContainCount();
					if (n > 0) u["contains"] = n;					// passengers garrisoned/loaded
				}
				return u;
			};

			std::set<unsigned> emitted;	// ids surfaced from the live list this call (for the phantom pass)

			for (Object* obj = TheGameLogic->getFirstObject(); obj; obj = obj->getNextObject())
			{
				Player* cp = obj->getControllingPlayer();
				int owner = cp ? (int)cp->getPlayerIndex() : -1;
				if (playerFilter >= 0 && owner != playerFilter)
					continue;

				if (!viewP)
				{
					arr.push_back(liveJson(obj, owner));	// no fog requested -> ground truth
					continue;
				}

				// Own + allied objects: always visible with live state (shared vision).
				bool friendly = (owner == viewPlayer);
				if (!friendly && cp) { Team* t = cp->getDefaultTeam(); friendly = t && viewP->getRelationship(t) == ALLIES; }
				if (friendly)
				{
					arr.push_back(liveJson(obj, owner));
					continue;
				}

				// Undetected stealth is invisible regardless of line of sight.
				if (obj->testStatus(OBJECT_STATUS_STEALTHED) &&
					!obj->testStatus(OBJECT_STATUS_DETECTED) &&
					!obj->testStatus(OBJECT_STATUS_DISGUISED))
					continue;

				const Coord3D* p = obj->getPosition();
				bool visible    = p && inSight(p->x, p->y);
				bool isBuilding = obj->isKindOf(KINDOF_STRUCTURE);
				Relationship rel = NEUTRAL;
				if (cp) { Team* t = cp->getDefaultTeam(); rel = t ? viewP->getRelationship(t) : NEUTRAL; }
				bool isNeutral = (rel == NEUTRAL);
				unsigned id = (unsigned)obj->getID();

				if (visible)
				{
					json u = liveJson(obj, owner);
					if (isBuilding && fog) { FogEntry e; e.snap = u; e.everSeen = true; (*fog)[id] = e; }
					u["shroud"] = "clear";
					arr.push_back(u);
					emitted.insert(id);
					continue;
				}

				// Out of sight: replay the cached snapshot (frozen state) if we have one.
				if (fog)
				{
					std::map<unsigned, FogEntry>::iterator it = fog->find(id);
					if (it != fog->end())
					{
						json out = it->second.snap;
						out["shroud"] = it->second.everSeen ? "cached" : "undefined";
						arr.push_back(out);
						emitted.insert(id);
						continue;
					}
				}
				// Never seen before. Neutral buildings are static map landmarks a planner must know
				// about -> report position (state undefined). Enemy buildings & all units stay hidden
				// until scouted.
				if (isBuilding && isNeutral)
				{
					json u = liveJson(obj, owner);
					u.erase("health"); u.erase("maxHealth");
					u["shroud"] = "undefined";
					if (fog) { FogEntry e; e.snap = u; e.everSeen = false; (*fog)[id] = e; }
					arr.push_back(u);
					emitted.insert(id);
				}
			}

			// Phantom pass: a cached building absent from the live list was destroyed/removed while
			// out of sight. Keep reporting it (the bot doesn't know yet) until its tile is back in
			// sight, then confirm it gone and forget it.
			if (fog)
			{
				for (std::map<unsigned, FogEntry>::iterator it = fog->begin(); it != fog->end(); )
				{
					if (emitted.count(it->first)) { ++it; continue; }
					json& snap = it->second.snap;
					int owner = snap.value("player", -1);
					if (playerFilter >= 0 && owner != playerFilter) { ++it; continue; }
					if (snap.contains("x") && inSight((Real)snap.value("x", 0.0), (Real)snap.value("y", 0.0)))
					{
						it = fog->erase(it);	// tile back in sight, object not there -> confirmed gone
						continue;
					}
					json out = snap;
					out["shroud"] = it->second.everSeen ? "cached" : "undefined";
					arr.push_back(out);
					++it;
				}
			}
		}
		return arr;
	}

	json buildResources(int player, int& statusOut)
	{
		Player* p = (player >= 0 && ThePlayerList) ? ThePlayerList->getNthPlayer(player) : nullptr;
		if (!p)
		{
			statusOut = 404;
			return json{ {"error", "no such player; pass ?player=<index>"} };
		}
		json o;
		o["player"] = player;
		o["money"]  = p->getMoney() ? (unsigned)p->getMoney()->countMoney() : 0u;
		if (p->getEnergy())
		{
			o["powerProduction"]  = (int)p->getEnergy()->getProduction();
			o["powerConsumption"] = (int)p->getEnergy()->getConsumption();
		}
		return o;
	}

	/// /catalog: static per-template stats for everything a player can build/train — cost, build
	/// time, power, refund, side, category/tags, command set, and prerequisite display (tech tree).
	/// Optional ?side=USA filters by faction. The agent uses this to plan economy + build orders.
	json buildCatalog(const std::string& sideFilter)
	{
		json arr = json::array();
		if (!TheThingFactory) return arr;
		Player* lp = ThePlayerList ? ThePlayerList->getLocalPlayer() : nullptr;
		for (const ThingTemplate* tt = TheThingFactory->firstTemplate(); tt; tt = tt->friend_getNextTemplate())
		{
			if (!tt->isBuildableItem()) continue;	// only things a player can actually build/train
			std::string side = tt->getDefaultOwningSide().str();
			if (!sideFilter.empty() && side != sideFilter) continue;
			json e;
			e["name"]        = tt->getName().str();
			e["displayName"] = narrow(tt->getDisplayName());
			e["side"]        = side;
			e["category"]    = templateCategory(tt);
			json tags = templateTags(tt); if (!tags.empty()) e["tags"] = tags;
			e["cost"]        = tt->friend_getBuildCost();
			e["buildTime"]   = tt->friend_getBuildTime();
			e["refund"]      = tt->getRefundValue();
			int power = tt->getEnergyProduction();
			if (power) e["power"] = power;			// >0 produces, <0 consumes
			e["commandSet"]  = tt->friend_getCommandSetString().str();
			int pc = tt->getPrereqCount();
			if (pc > 0 && lp)
			{
				json prereqs = json::array();
				for (int i = 0; i < pc; ++i)
				{
					std::string s = narrow(tt->getNthPrereq(i)->getRequiresList(lp));
					if (!s.empty()) prereqs.push_back(s);
				}
				if (!prereqs.empty()) e["prerequisites"] = prereqs;	// display text (tech tree)
			}
			arr.push_back(e);
		}
		return arr;
	}

	/// /buildable?player=N: what player N can build/train RIGHT NOW. Walks each owned builder's
	/// command set, lists its build/train options with a live canMake status, and a flat `available`
	/// union of everything currently makeable (with the builderId to issue build_structure/train_unit).
	json buildBuildable(int player, int& statusOut)
	{
		Player* p = (player >= 0 && ThePlayerList) ? ThePlayerList->getNthPlayer(player) : nullptr;
		if (!p) { statusOut = 404; return json{ {"error", "no such player; pass ?player=<index>"} }; }
		json o;
		o["player"] = player;
		o["money"]  = p->getMoney() ? (unsigned)p->getMoney()->countMoney() : 0u;
		if (p->getEnergy())
		{
			o["powerProduction"]  = (int)p->getEnergy()->getProduction();
			o["powerConsumption"] = (int)p->getEnergy()->getConsumption();
		}
		json builders = json::array(), available = json::array();
		std::set<std::string> seen;
		if (TheGameLogic && TheControlBar && TheBuildAssistant)
		{
			for (Object* b = TheGameLogic->getFirstObject(); b; b = b->getNextObject())
			{
				if (b->getControllingPlayer() != p) continue;
				const AsciiString csName = b->getCommandSetString();
				if (csName.isEmpty()) continue;
				const CommandSet* cs = TheControlBar->findCommandSet(csName);
				if (!cs) continue;
				json opts = json::array();
				for (int i = 0; i < MAX_COMMANDS_PER_SET; ++i)
				{
					const CommandButton* cb = cs->getCommandButton(i);
					if (!cb) continue;
					GUICommandType gt = cb->getCommandType();
					if (gt != GUI_COMMAND_UNIT_BUILD && gt != GUI_COMMAND_DOZER_CONSTRUCT) continue;
					const ThingTemplate* tt = cb->getThingTemplate();
					if (!tt) continue;
					CanMakeType cm = TheBuildAssistant->canMakeUnit(b, (ThingTemplate*)tt);
					const char* how = (gt == GUI_COMMAND_DOZER_CONSTRUCT) ? "build" : "train";
					json bo;
					bo["template"] = tt->getName().str();
					bo["cost"]     = tt->friend_getBuildCost();
					bo["how"]      = how;
					bo["canMake"]  = canMakeName(cm);
					opts.push_back(bo);
					if (cm == CANMAKE_OK && !seen.count(tt->getName().str()))
					{
						seen.insert(tt->getName().str());
						json a;
						a["template"]  = tt->getName().str();
						a["how"]       = how;
						a["builderId"] = (unsigned)b->getID();
						a["cost"]      = tt->friend_getBuildCost();
						available.push_back(a);
					}
				}
				if (!opts.empty())
				{
					json bd;
					bd["id"]       = (unsigned)b->getID();
					bd["template"] = b->getTemplate() ? b->getTemplate()->getName().str() : "";
					bd["options"]  = opts;
					builders.push_back(bd);
				}
			}
		}
		o["builders"]  = builders;	// per-builder option lists (with reasons)
		o["available"] = available;	// flat: everything buildable NOW + the builderId to use
		return o;
	}

	json buildControl(const std::string& action, double value, int& statusOut)
	{
		json o;
		o["action"] = action;
		if (action == "pause")
		{
			if (TheGameLogic) TheGameLogic->setGamePaused(true);
			o["ok"] = true;
		}
		else if (action == "resume")
		{
			if (TheGameLogic) TheGameLogic->setGamePaused(false);
			o["ok"] = true;
		}
		else if (action == "step")
		{
			const int n = (value >= 1.0) ? (int)value : 1;
			// Step implies controlled, paused advance: pause, then grant n forced logic frames
			// that GameEngine::update consumes (one per loop) via consumePendingStep().
			if (TheGameLogic && !TheGameLogic->isGamePaused())
				TheGameLogic->setGamePaused(true);
			m_pendingSteps += n;
			o["ok"] = true;
			o["stepsQueued"] = n;
		}
		else if (action == "speed")
		{
			const int fps = (value >= 1.0) ? (int)value : (int)LOGICFRAMES_PER_SECOND;
			if (TheFramePacer)
			{
				TheFramePacer->setLogicTimeScaleFps(fps);
				TheFramePacer->enableLogicTimeScale(TRUE);
			}
			o["ok"] = true;
			o["logicTimeScaleFps"] = fps;
		}
		else
		{
			statusOut = 400;
			o["ok"] = false;
			o["error"] = "unknown action; use pause|resume|step|speed";
		}
		if (TheGameLogic)
		{
			o["frame"]  = (unsigned)TheGameLogic->getFrame();
			o["paused"] = (bool)TheGameLogic->isGamePaused();
		}
		return o;
	}

	Coord3D jsonToCoord(const json& j)
	{
		Coord3D c;
		c.x = c.y = c.z = 0.0f;
		if (j.is_array())
		{
			if (j.size() > 0 && j[0].is_number()) c.x = (Real)j[0].get<double>();
			if (j.size() > 1 && j[1].is_number()) c.y = (Real)j[1].get<double>();
			if (j.size() > 2 && j[2].is_number()) c.z = (Real)j[2].get<double>();
		}
		else if (j.is_object())
		{
			if (j.contains("x") && j["x"].is_number()) c.x = (Real)j["x"].get<double>();
			if (j.contains("y") && j["y"].is_number()) c.y = (Real)j["y"].get<double>();
			if (j.contains("z") && j["z"].is_number()) c.z = (Real)j["z"].get<double>();
		}
		return c;
	}

	/** Execute one command for an external player. Builds an AIGroup from the owned ObjectIDs and
	  * issues the verb with CMD_FROM_AI (the same deterministic path the engine AI uses). */
	json executeCommand(const json& cmd, int& statusOut)
	{
		json r;
		const std::string verb = cmd.value("verb", std::string());
		const int playerIdx = cmd.value("player", -1);
		r["verb"] = verb;

		if (!TheAI || !TheGameLogic || !ThePlayerList)
		{
			statusOut = 503; r["accepted"] = false; r["error"] = "engine not ready"; return r;
		}

		Player* p = (playerIdx >= 0) ? ThePlayerList->getNthPlayer(playerIdx) : nullptr;
		if (!p)
		{
			statusOut = 404; r["accepted"] = false;
			r["error"] = "no such player; pass \"player\":<index> (see GET /players)";
			return r;
		}
		if (p->getPlayerType() != PLAYER_EXTERNAL)
		{
			statusOut = 403; r["accepted"] = false;
			r["error"] = "player is not external-controlled (controller must be 'external')";
			return r;
		}

		// Build the group from owned object IDs.
		AIGroupPtr group = TheAI->createGroup();
		int matched = 0, skipped = 0;
		if (cmd.contains("ids") && cmd["ids"].is_array())
		{
			for (const json& idv : cmd["ids"])
			{
				if (!idv.is_number()) { ++skipped; continue; }
				ObjectID oid = (ObjectID)idv.get<unsigned>();
				Object* o = TheGameLogic->findObjectByID(oid);
				if (o && o->getControllingPlayer() == p) { group->add(o); ++matched; }
				else ++skipped;
			}
		}
		r["unitsMatched"] = matched;
		if (skipped) r["unitsSkipped"] = skipped;

		const json params = (cmd.contains("params") && cmd["params"].is_object()) ? cmd["params"] : json::object();

		// First owned object from ids[] (for single-object verbs: train_unit / build_structure / set_rally).
		auto firstOwned = [&]() -> Object* {
			if (cmd.contains("ids") && cmd["ids"].is_array())
				for (const json& idv : cmd["ids"])
					if (idv.is_number())
					{
						Object* o = TheGameLogic->findObjectByID((ObjectID)idv.get<unsigned>());
						if (o && o->getControllingPlayer() == p) return o;
					}
			return nullptr;
		};
		// Any object addressed by params.targetId (target need not be owned: capture/repair/power).
		auto targetObj = [&]() -> Object* {
			return (params.contains("targetId") && params["targetId"].is_number())
				? TheGameLogic->findObjectByID((ObjectID)params["targetId"].get<unsigned>()) : nullptr;
		};

		const bool needsUnits = (verb == "move" || verb == "attack_move" || verb == "attack_target"
			|| verb == "stop" || verb == "guard_zone" || verb == "retreat"
			|| verb == "capture" || verb == "garrison" || verb == "ungarrison" || verb == "evacuate"
			|| verb == "repair" || verb == "sell" || verb == "special_power" || verb == "ability");
		if (needsUnits && group->isEmpty())
		{
			statusOut = 400; r["accepted"] = false;
			r["error"] = "no owned units matched the given ids";
			return r;
		}

		if (verb == "move" || verb == "retreat")
		{
			Coord3D pos = jsonToCoord(params.contains("pos") ? params["pos"] : params);
			group->groupMoveToPosition(&pos, FALSE, CMD_FROM_AI);
			r["accepted"] = true;
		}
		else if (verb == "attack_move")
		{
			Coord3D pos = jsonToCoord(params.contains("pos") ? params["pos"] : params);
			group->groupAttackMoveToPosition(&pos, NO_MAX_SHOTS, CMD_FROM_AI);
			r["accepted"] = true;
		}
		else if (verb == "attack_target")
		{
			ObjectID tid = (ObjectID)(params.contains("targetId") && params["targetId"].is_number()
				? params["targetId"].get<unsigned>() : 0u);
			Object* victim = TheGameLogic->findObjectByID(tid);
			if (!victim)
			{
				statusOut = 400; r["accepted"] = false;
				r["error"] = "target object not found (params.targetId)";
				return r;
			}
			group->groupAttackObject(victim, NO_MAX_SHOTS, CMD_FROM_AI);
			r["accepted"] = true;
		}
		else if (verb == "stop")
		{
			group->groupIdle(CMD_FROM_AI);
			r["accepted"] = true;
		}
		else if (verb == "guard_zone")
		{
			// Dual-zone guard: anchor = stand/return position, engage = watched zone center.
			Coord3D anchor = jsonToCoord(params.contains("anchor") ? params["anchor"] : params);
			Coord3D engage = jsonToCoord(params.contains("engage") ? params["engage"] : params);
			group->groupGuardPositionFromPosition(&anchor, &engage, GUARDMODE_FROM_POSITION, CMD_FROM_AI);
			r["accepted"] = true;
			json warns = json::array();
			if (params.contains("aggression"))
				warns.push_back("aggression accepted but not yet mapped to engine GuardMode (M1)");
			if (params.contains("fallback") || params.contains("fallback_if"))
				warns.push_back("fallback_if accepted but not implemented (M1)");
			if (!warns.empty()) r["warnings"] = warns;
		}
		// --- unit actions: capture / garrison / repair / sell / special power -----------------
		else if (verb == "capture" || verb == "garrison")
		{
			Object* tgt = targetObj();
			if (!tgt) { statusOut = 400; r["accepted"] = false; r["error"] = "need params.targetId (building to enter/capture)"; return r; }
			group->groupEnter(tgt, CMD_FROM_AI);		// enter hostile bldg -> capture; civilian -> garrison
			r["accepted"] = true;
		}
		else if (verb == "ungarrison" || verb == "evacuate")
		{
			Object* tgt = targetObj();
			if (tgt) group->groupExit(tgt, CMD_FROM_AI);	// these passengers leave that container
			else     group->groupEvacuate(CMD_FROM_AI);		// these containers empty themselves
			r["accepted"] = true;
		}
		else if (verb == "repair")
		{
			Object* tgt = targetObj();
			if (!tgt) { statusOut = 400; r["accepted"] = false; r["error"] = "need params.targetId (object to repair)"; return r; }
			group->groupRepair(tgt, CMD_FROM_AI);
			r["accepted"] = true;
		}
		else if (verb == "sell")
		{
			group->groupSell(CMD_FROM_AI);				// group = the building(s) to sell
			r["accepted"] = true;
		}
		else if (verb == "special_power")
		{
			std::string name = params.contains("power") ? params.value("power", std::string())
			                                            : params.value("which", std::string());
			const SpecialPowerTemplate* sp = (TheSpecialPowerStore && !name.empty())
				? TheSpecialPowerStore->findSpecialPowerTemplate(AsciiString(name.c_str())) : nullptr;
			if (!sp) { statusOut = 400; r["accepted"] = false; r["error"] = "unknown special power (params.power); see /catalog"; return r; }
			UnsignedInt spid = sp->getID();
			Object* tgt = targetObj();
			if (tgt)
				group->groupDoSpecialPowerAtObject(spid, tgt, 0);
			else if (params.contains("pos"))
			{
				Coord3D pos = jsonToCoord(params["pos"]);
				group->groupDoSpecialPowerAtLocation(spid, &pos, 0.0f, nullptr, 0);
			}
			else
				group->groupDoSpecialPower(spid, 0);
			r["accepted"] = true;
		}
		else if (verb == "ability")
		{
			// Generic command-button ability (deploy, weapon toggle, upgrade, hack internet, ...).
			std::string bn = params.contains("button") ? params.value("button", std::string())
			                                            : params.value("which", std::string());
			const CommandButton* cb = (TheControlBar && !bn.empty())
				? TheControlBar->findCommandButton(AsciiString(bn.c_str())) : nullptr;
			if (!cb) { statusOut = 400; r["accepted"] = false; r["error"] = "unknown command button (params.button)"; return r; }
			Object* tgt = targetObj();
			if (tgt)
				group->groupDoCommandButtonAtObject(cb, tgt, CMD_FROM_AI);
			else if (params.contains("pos"))
			{
				Coord3D pos = jsonToCoord(params["pos"]);
				group->groupDoCommandButtonAtPosition(cb, &pos, CMD_FROM_AI);
			}
			else
				group->groupDoCommandButton(cb, CMD_FROM_AI);
			r["accepted"] = true;
		}
		// --- production / construction: train_unit / build_structure / set_rally ---------------
		else if (verb == "train_unit")
		{
			Object* factory = firstOwned();
			if (!factory) { statusOut = 400; r["accepted"] = false; r["error"] = "need a production building id in ids[0]"; return r; }
			std::string tn = params.value("template", std::string());
			const ThingTemplate* tt = (TheThingFactory && !tn.empty())
				? TheThingFactory->findTemplate(AsciiString(tn.c_str()), FALSE) : nullptr;
			if (!tt) { statusOut = 400; r["accepted"] = false; r["error"] = "unknown template (params.template); see /catalog or /buildable"; return r; }
			ProductionUpdateInterface* pu = factory->getProductionUpdateInterface();
			if (!pu) { statusOut = 400; r["accepted"] = false; r["error"] = "ids[0] is not a production building"; return r; }
			int count = params.value("count", 1), queued = 0;
			for (int k = 0; k < count && k < 20; ++k)
				if (pu->queueCreateUnit(tt, pu->requestUniqueUnitID())) ++queued;
			r["queued"] = queued;
			r["accepted"] = (queued > 0);
			if (queued == 0) { statusOut = 400; r["error"] = "queueCreateUnit refused (prereq / money / queue full?)"; }
		}
		else if (verb == "build_structure")
		{
			std::string tn = params.value("template", std::string());
			const ThingTemplate* tt = (TheThingFactory && !tn.empty())
				? TheThingFactory->findTemplate(AsciiString(tn.c_str()), FALSE) : nullptr;
			if (!tt) { statusOut = 400; r["accepted"] = false; r["error"] = "unknown template (params.template); see /catalog"; return r; }
			if (!params.contains("pos")) { statusOut = 400; r["accepted"] = false; r["error"] = "need params.pos"; return r; }
			Coord3D pos = jsonToCoord(params["pos"]);
			Real angle = (Real)params.value("angle", 0.0);
			Object* builder = firstOwned();				// dozer/worker; may be null for instant placement
			if (!TheBuildAssistant) { statusOut = 503; r["accepted"] = false; r["error"] = "build assistant unavailable"; return r; }
			LegalBuildCode lbc = TheBuildAssistant->isLocationLegalToBuild(&pos, tt, angle,
				BuildAssistant::TERRAIN_RESTRICTIONS | BuildAssistant::NO_OBJECT_OVERLAP, builder, p);
			if (lbc != LBC_OK) { statusOut = 400; r["accepted"] = false; r["error"] = "illegal build location"; r["code"] = (int)lbc; return r; }
			Object* bldg = TheBuildAssistant->buildObjectNow(builder, tt, &pos, angle, p);
			r["accepted"] = (bldg != nullptr);
			if (bldg) r["objectId"] = (unsigned)bldg->getID();
			else { statusOut = 400; r["error"] = "buildObjectNow failed"; }
		}
		else if (verb == "set_rally")
		{
			Object* obj = firstOwned();
			if (!obj) { statusOut = 400; r["accepted"] = false; r["error"] = "need a building id in ids[0]"; return r; }
			if (!params.contains("pos")) { statusOut = 400; r["accepted"] = false; r["error"] = "need params.pos"; return r; }
			Coord3D pos = jsonToCoord(params["pos"]);
			ExitInterface* ei = obj->getObjectExitInterface();
			if (!ei) { statusOut = 400; r["accepted"] = false; r["error"] = "object has no rally/exit interface"; return r; }
			ei->setRallyPoint(&pos);
			r["accepted"] = true;
		}
		else
		{
			statusOut = 400; r["accepted"] = false;
			r["error"] = "unknown verb (move|attack_move|attack_target|stop|guard_zone|retreat|capture|"
			             "garrison|ungarrison|repair|sell|special_power|ability|train_unit|build_structure|set_rally)";
			return r;
		}

		r["frame"] = (unsigned)TheGameLogic->getFrame();
		return r;
	}

	//---------------------------------------------------------------------------------------------
	// /session: determinism + match-lifecycle reporting (seed, headless, replay, outcome).
	//---------------------------------------------------------------------------------------------
	const char* recorderModeName()
	{
		if (!TheRecorder)
			return "none";
		switch (TheRecorder->getMode())
		{
			case RECORDERMODETYPE_RECORD:              return "record";
			case RECORDERMODETYPE_PLAYBACK:            return "playback";
			case RECORDERMODETYPE_SIMULATION_PLAYBACK: return "simulation_playback";
			default:                                   return "none";
		}
	}

	json buildSession()
	{
		const bool inGame = TheGameLogic && TheGameLogic->isInGame();
		json o;
		o["inGame"]   = inGame;
		o["frame"]    = TheGameLogic ? (unsigned)TheGameLogic->getFrame() : 0u;
		o["paused"]   = TheGameLogic ? (bool)TheGameLogic->isGamePaused() : false;
		o["seed"]     = (unsigned)GetGameLogicRandomSeed();
		o["headless"] = TheGlobalData ? (bool)TheGlobalData->m_headless : false;

		json rep;
		rep["mode"]        = recorderModeName();
		rep["playingBack"] = TheRecorder ? (bool)TheRecorder->isPlaybackInProgress() : false;
		o["replay"] = rep;

		json outcome;
		if (TheVictoryConditions)
		{
			outcome["victoryConditions"] = (int)TheVictoryConditions->getVictoryConditions();
			outcome["endFrame"]          = (unsigned)TheVictoryConditions->getEndFrame();
			std::string localResult;
			if (TheVictoryConditions->amIObserver())
				localResult = "observer";
			else if (TheVictoryConditions->isLocalAlliedVictory())
				localResult = "victory";
			else if (TheVictoryConditions->isLocalDefeat() || TheVictoryConditions->isLocalAlliedDefeat())
				localResult = "defeat";
			else
				localResult = "undecided";
			outcome["localResult"] = localResult;

			// Per-player win/lose (only meaningful while a match exists).
			if (inGame && ThePlayerList)
			{
				json parr = json::array();
				for (Int i = 0; i < ThePlayerList->getPlayerCount(); ++i)
				{
					Player* p = ThePlayerList->getNthPlayer(i);
					if (!p)
						continue;
					json pj;
					pj["index"]      = (int)p->getPlayerIndex();
					pj["controller"] = controllerName(p->getPlayerType());
					pj["victory"]    = (bool)TheVictoryConditions->hasAchievedVictory(p);
					pj["defeated"]   = (bool)TheVictoryConditions->hasBeenDefeated(p);
					parr.push_back(pj);
				}
				outcome["players"] = parr;
			}
			outcome["decided"] = (localResult != "undecided")
				|| (TheVictoryConditions->getEndFrame() != 0);
		}
		o["outcome"] = outcome;
		return o;
	}

	json setSession(const json& body, int& statusOut)
	{
		json r;
		if (!(body.contains("seed") && body["seed"].is_number()))
		{
			statusOut = 400; r["ok"] = false;
			r["error"] = "POST body must contain an integer 'seed'";
			return r;
		}
		const unsigned seed = body["seed"].get<unsigned>();
		r["seed"] = seed;

		// The seed is consumed by the match-start path (GameInfo -> InitGameLogicRandom). Once a
		// match is live it is locked; reseeding mid-game would desync. Set it BEFORE start (e.g. in
		// a headless/scripted launch) -- our auto-skirmish boots straight in, so this will usually
		// report 409 unless driven before the match is created.
		if (TheGameLogic && TheGameLogic->isInGame())
		{
			statusOut = 409; r["ok"] = false;
			r["error"] = "seed locked: a match is already in progress (set seed before start)";
			return r;
		}
		if (TheGameInfo)
		{
			TheGameInfo->setSeed((Int)seed);
			r["ok"] = true;
			r["note"] = "seed staged on TheGameInfo; takes effect when the next match starts";
		}
		else
		{
			statusOut = 409; r["ok"] = false;
			r["error"] = "no active GameInfo to seed (no game is being set up)";
		}
		return r;
	}

	//---------------------------------------------------------------------------------------------
	// /map: export the pathfinder cell grid so an external bot can "see" the terrain (passability,
	// build-surface, height). Native resolution is PATHFIND_CELL_SIZE (10 world units) -- the same
	// grid the engine itself uses for movement and structure-footprint legality.
	//---------------------------------------------------------------------------------------------
	json buildMap(int ds, bool includeZone, int& statusOut)
	{
		json o;
		if (!TheAI || !TheAI->pathfinder() || !TheGameLogic || !TheGameLogic->isInGame())
		{
			statusOut = 503;
			o["error"] = "no map: engine is not in a game";
			return o;
		}
		Pathfinder* pf = TheAI->pathfinder();
		const ICoord2D* hi = pf->getExtent();		// grid spans [0..hi.x] x [0..hi.y]
		const int cellsX = hi->x + 1;
		const int cellsY = hi->y + 1;
		if (ds < 1) ds = 1;
		const int W = (cellsX + ds - 1) / ds;
		const int H = (cellsY + ds - 1) / ds;

		o["cellSize"]       = (int)PATHFIND_CELL_SIZE * ds;	// world units per exported cell
		o["nativeCellSize"] = (int)PATHFIND_CELL_SIZE;
		o["downsample"]     = ds;
		o["width"]          = W;
		o["height"]         = H;
		o["origin"]         = json{ {"x", 0}, {"y", 0} };
		o["legend"]         = json{ {"clear",0},{"water",1},{"cliff",2},{"rubble",3},
									{"obstacle",4},{"impassable",6},{"unknown",255} };

		std::vector<unsigned char>  typeBuf;   typeBuf.reserve((size_t)W * H);
		std::vector<unsigned char>  heightBuf; heightBuf.reserve((size_t)W * H);
		std::vector<float>          rawH;      rawH.reserve((size_t)W * H);
		std::vector<unsigned short> zoneBuf;   if (includeZone) zoneBuf.reserve((size_t)W * H);

		float hmin = 1.0e30f, hmax = -1.0e30f;
		for (int cy = 0; cy < cellsY; cy += ds)
		{
			for (int cx = 0; cx < cellsX; cx += ds)
			{
				PathfindCell* cell = pf->getCell(LAYER_GROUND, cx, cy);
				unsigned char  t = 255;
				unsigned short z = 0;
				if (cell)
				{
					t = (unsigned char)cell->getType();
					z = (unsigned short)cell->getZone();
				}
				typeBuf.push_back(t);
				if (includeZone)
					zoneBuf.push_back(z);

				float wx = (cx + 0.5f) * PATHFIND_CELL_SIZE_F;
				float wy = (cy + 0.5f) * PATHFIND_CELL_SIZE_F;
				float h  = TheTerrainLogic ? TheTerrainLogic->getGroundHeight(wx, wy) : 0.0f;
				rawH.push_back(h);
				if (h < hmin) hmin = h;
				if (h > hmax) hmax = h;
			}
		}

		const float span = (hmax > hmin) ? (hmax - hmin) : 1.0f;
		for (size_t i = 0; i < rawH.size(); ++i)
		{
			int q = (int)((rawH[i] - hmin) / span * 255.0f + 0.5f);
			if (q < 0)   q = 0;
			if (q > 255) q = 255;
			heightBuf.push_back((unsigned char)q);
		}

		o["type"] = base64(typeBuf.data(), typeBuf.size());
		json hj;
		hj["min"]  = hmin;
		hj["max"]  = hmax;
		hj["data"] = base64(heightBuf.data(), heightBuf.size());
		o["heightField"] = hj;

		if (includeZone)
		{
			std::vector<unsigned char> zb;
			zb.reserve(zoneBuf.size() * 2);
			for (size_t i = 0; i < zoneBuf.size(); ++i)
			{
				zb.push_back((unsigned char)(zoneBuf[i] & 0xFF));
				zb.push_back((unsigned char)((zoneBuf[i] >> 8) & 0xFF));
			}
			o["zone"] = base64(zb.data(), zb.size());	// little-endian uint16 per cell
		}
		return o;
	}

	//---------------------------------------------------------------------------------------------
	// Bot-action log. JSONL, one record per mutating API call, for offline analysis.
	//---------------------------------------------------------------------------------------------
	static long long nowMillis()
	{
		return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::system_clock::now().time_since_epoch()).count();
	}

	void openActionLog()
	{
		if (::getenv("GEN_API_LOG_OFF"))
			return;
		const char* lp = ::getenv("GEN_API_LOG");
		m_logPath = (lp && lp[0]) ? lp : "/tmp/gen_api_actions.jsonl";
		m_actionLog.open(m_logPath.c_str(), std::ios::app);
		m_logEnabled = m_actionLog.is_open();
		DEBUG_LOG(("ExternalControl: action log -> %s (%s)", m_logPath.c_str(),
			m_logEnabled ? "on" : "FAILED TO OPEN"));
		logMarker("boot");
	}

	/// Lightweight timeline marker (boot / reset).
	void logMarker(const char* type)
	{
		if (!m_logEnabled)
			return;
		json rec;
		rec["t"]     = nowMillis();
		rec["frame"] = TheGameLogic ? (unsigned)TheGameLogic->getFrame() : 0u;
		rec["type"]  = type;
		m_actionLog << rec.dump() << "\n";
		m_actionLog.flush();
	}

	/// Record one mutating action: the request as received and the engine's result/status.
	void logAction(const char* type, const json& request, const json& result, int status)
	{
		if (!m_logEnabled)
			return;
		json rec;
		rec["t"]       = nowMillis();
		rec["frame"]   = TheGameLogic ? (unsigned)TheGameLogic->getFrame() : 0u;
		rec["type"]    = type;
		rec["status"]  = status;
		rec["request"] = request;
		rec["result"]  = result;
		m_actionLog << rec.dump() << "\n";
		m_actionLog.flush();
	}

	/// Push one event onto the ring (logic thread). Stamps seq + current frame; drops oldest on overflow.
	void pushEvent(json e)
	{
		std::lock_guard<std::mutex> lk(m_eventMutex);
		const uint64_t seq = ++m_eventSeq;
		e["seq"]   = (unsigned long long)seq;
		e["frame"] = TheGameLogic ? (unsigned)TheGameLogic->getFrame() : 0u;
		m_eventRing.push_back(RingEvent{ seq, std::move(e) });
		while (m_eventRing.size() > EVENT_RING_CAP)
		{
			m_eventRing.pop_front();
			++m_eventsDropped;
		}
	}

	//---------------------------------------------------------------------------------------------
	int               m_port;
	int               m_wsPort;
	bool              m_enabled;
	std::atomic<bool> m_running;
	std::thread       m_thread;
	httplib::Server   m_server;

	std::mutex                                  m_queueMutex;
	std::deque<std::shared_ptr<PendingRequest> > m_inbound;

	std::atomic<int> m_pendingSteps{0};			///< logic frames to force-advance while paused (step)

	// --- /events WebSocket -----------------------------------------------------------------------
	struct RingEvent { uint64_t seq; json data; };
	std::unique_ptr<ix::WebSocketServer> m_wsServer;
	std::thread                          m_broadcastThread;
	std::atomic<bool>                    m_hasClients{false};	///< fast gate for taps (eventsActive)

	std::mutex             m_eventMutex;			///< guards the ring + seq/dropped cursors
	std::deque<RingEvent>  m_eventRing;
	uint64_t               m_eventSeq = 0;			///< monotonic event id
	uint64_t               m_lastBroadcastSeq = 0;	///< broadcaster cursor (shared across clients)
	uint64_t               m_eventsDropped = 0;		///< ring overflow counter, reported then reset
	static const size_t    EVENT_RING_CAP = 1024;

	// --- synthesized fog-of-war (?view=N) --------------------------------------------------------
	// The engine grants AI/non-local players a permanent full-map reveal (the skirmish AI "sees
	// all"), so getShroudedStatus(externalIndex) is NOT a realistic fog model for a bot. Instead we
	// synthesize fog from the view player's + allies' actual unit vision (shroud-clearing range).
	// Buildings are persistent landmarks a planner must know about, so we cache a SNAPSHOT of each
	// the moment it is in sight and replay it (frozen, last-known state) while it is out of sight:
	//   shroud "clear"     = in sight now, live state;
	//   shroud "cached"    = a building seen before, now out of sight -> last-known snapshot;
	//   shroud "undefined" = a NEUTRAL building never yet seen -> position known (static map
	//                        landmark), state unknown (no health/owner asserted).
	// A cached/undefined building stays reported (even after it is destroyed off-screen) until the
	// view player re-gains sight of its tile and confirms it gone. Keyed by view-player index;
	// cleared on reset(). ObjectIDs are unique within a match, so caching by id is safe.
	struct FogEntry { json snap; bool everSeen; };		///< snap = full /units object as last seen
	std::map<int, std::map<unsigned, FogEntry> > m_fogMemory;	///< viewPlayer -> objId -> snapshot

	// --- bot-action log (JSONL) ------------------------------------------------------------------
	// Authoritative record of every mutating API call (command/commands/control/session), stamped
	// with wall-clock ms + logic frame, for later analysis when developing bots. Engine-thread only.
	std::ofstream m_actionLog;
	bool          m_logEnabled = false;
	std::string   m_logPath;
};

//-------------------------------------------------------------------------------------------------
ExternalControlInterface* createExternalControl()
{
	return MSGNEW("GameEngineSubsystem") ExternalControlSystem();
}
