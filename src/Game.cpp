// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "buildopts.h"

#include "Game.h"

#include "Body.h"
#include "DeathView.h"
#include "FileSystem.h"
#include "GameLog.h"
#include "GameSaveError.h"
#include "HyperspaceCloud.h"
#include "JsonUtils.h"
#include "MathUtil.h"
#include "collider/CollisionSpace.h"
#include "core/GZipFormat.h"
#include "galaxy/Economy.h"
#include "lua/LuaEvent.h"
#include "lua/LuaSerializer.h"
#include "pigui/LuaPiGui.h"
#if WITH_OBJECTVIEWER
#include "ObjectViewerView.h"
#endif
#include "Pi.h"
#include "Player.h"
#include "SaveGameManager.h"
#include "SectorView.h"
#include "Sensors.h"
#include "Sfx.h"
#include "Ship.h"
#include "Space.h"
#include "SpaceStation.h"
#include "SystemView.h"
#include "WorldView.h"
#include "galaxy/GalaxyGenerator.h"
#include "galaxy/Sector.h"
#include "ship/GunManager.h"
#include "ship/PlayerShipController.h"
#include "ship/SupercruiseController.h"
#include "imgui/imgui.h"
#include "imgui/imgui_internal.h"

Game::Game(const SystemPath &path, const double startDateTime, const char *shipType) :
	m_galaxy(GalaxyGenerator::Create()),
	m_time(startDateTime),
	m_playedDuration(0),
	m_state(State::NORMAL),
	m_wantHyperspace(false),
	m_hyperspaceProgress(0),
	m_hyperspaceDuration(0),
	m_hyperspaceEndTime(0),
	m_timeAccel(TIMEACCEL_1X),
	m_requestedTimeAccel(TIMEACCEL_1X),
	m_forceTimeAccel(false)
{
	PROFILE_SCOPED()
	Ship::ClearBlackBoxLog();
	// Now that we have a Galaxy, check the starting location
	if (!path.IsBodyPath())
		throw InvalidGameStartLocation("SystemPath is not a body path");
	RefCountedPtr<const Sector> s = m_galaxy->GetSector(path);
	if (size_t(path.systemIndex) >= s->m_systems.size()) {
		char buf[128];
		std::sprintf(buf, "System %u in sector <%d,%d,%d> does not exist",
			unsigned(path.systemIndex), int(path.sectorX), int(path.sectorY), int(path.sectorZ));
		throw InvalidGameStartLocation(std::string(buf));
	}
	RefCountedPtr<StarSystem> sys = m_galaxy->GetStarSystem(path);
	if (path.bodyIndex >= sys->GetNumBodies()) {
		char buf[256];
		std::sprintf(buf, "Body %d in system <%d,%d,%d : %d ('%s')> does not exist", unsigned(path.bodyIndex),
			int(path.sectorX), int(path.sectorY), int(path.sectorZ), unsigned(path.systemIndex), sys->GetName().c_str());
		throw InvalidGameStartLocation(std::string(buf));
	}

	m_space.reset(new Space(this, m_galaxy, path));

	Body *b = m_space->FindBodyForPath(&path);
	assert(b);

	m_player.reset(new Player(shipType));

	m_space->AddBody(m_player.get());

	if (b->GetType() == ObjectType::SPACESTATION) {
		m_player->SetFrame(b->GetFrame());
		m_player->SetDockedWith(static_cast<SpaceStation *>(b), 0);
	} else {
		auto f = Frame::GetFrame(b->GetFrame());
		if (f->IsRotFrame()) {
			m_player->SetFrame(f->GetParent());
		} else {
			m_player->SetFrame(b->GetFrame());
		}
		// random orbit
		// Taken from: LuaSpace.cpp, _orbital_velocity_random_direction()
		const SystemBody *sbody = b->GetSystemBody();
		vector3d pos{ MathUtil::RandomPointOnSphere(1.2 * b->GetPhysRadius()) };
		// calculating basis from radius - vector
		vector3d k = pos.Normalized();
		vector3d i;
		if (std::fabs(k.z) > 0.999999)	 // very vertical = z
			i = vector3d(1.0, 0.0, 0.0); // second ort = x
		else
			i = k.Cross(vector3d(0.0, 0.0, 1.0)).Normalized();
		vector3d j = k.Cross(i);
		// generating random 2d direction and putting it into basis
		vector3d randomOrthoDirection = MathUtil::RandomPointOnCircle(1.0) * matrix3x3d::FromVectors(i, j, k).Transpose();
		// calculate the value of the orbital velocity
		double orbitalVelocity = sqrt(G * sbody->GetMass() / pos.Length());

		m_player->SetPosition(pos);
		m_player->SetVelocity(randomOrthoDirection * orbitalVelocity);
	}

	// Record when we started playing this save so we can determine how long it's been played this session
	m_sessionStartTimestamp = std::chrono::steady_clock::now().time_since_epoch().count();

	CreateViews();

	EmitPauseState(IsPaused());

	Pi::GetApp()->RequestProfileFrame("NewGame");
}

Game::~Game()
{
	DestroyViews();

	// XXX this shutdown sequence is critical:
	// 1- RemoveBody marks the Player for removal from Space,
	// 2- Space is destroyed, which actually goes through its removal list,
	//    removes the Player from Space and calls SetFrame(0) on it, which unlinks
	//    any references it has to other Space items
	// 3- Player is destroyed
	//
	// note that because of the declaration order of m_space and m_player in Game,
	// without these explicit Reset() calls, m_player would be deleted before m_space is,
	// which causes problems because then when Space is destroyed it tries to reference
	// the deleted Player object (to call SetFrame(0))
	//
	// ideally we'd split Player out into two objects, the physics part that
	// is owned by the space, and the game part that holds all the player
	// attributes and whatever else

	m_space->RemoveBody(m_player.get());
	m_space.reset();
	m_player.reset();
	m_galaxy->FlushCaches();
}

Game::Game(const Json &jsonObj) :
	m_timeAccel(TIMEACCEL_PAUSED),
	m_requestedTimeAccel(TIMEACCEL_PAUSED),
	m_forceTimeAccel(false)
{
	PROFILE_SCOPED()
	Ship::ClearBlackBoxLog();
	try {
		int version = jsonObj["version"];
		Output("savefile version: %d\n", version);
		if (version != SaveGameManager::CurrentSaveVersion()) {
			Output("can't load savefile, expected version: %d\n", SaveGameManager::CurrentSaveVersion());
			throw SavedGameWrongVersionException();
		}
	} catch (Json::type_error &) {
		throw SavedGameCorruptException();
	}

	// Preparing the Lua stuff
	Pi::luaSerializer->InitTableRefs();
	Pi::luaSerializer->LoadPersistent(jsonObj);

	GalacticEconomy::LoadFromJson(jsonObj);

	// galaxy generator
	m_galaxy = Galaxy::LoadFromJson(jsonObj);

	try {
		// game state
		m_time = jsonObj["time"];
		m_state = jsonObj["state"].get<State>();

		m_wantHyperspace = jsonObj["want_hyperspace"];
		m_hyperspaceProgress = jsonObj["hyperspace_progress"];
		m_hyperspaceDuration = jsonObj["hyperspace_duration"];
		m_hyperspaceEndTime = jsonObj["hyperspace_end_time"];
		m_hardcore = jsonObj.value("hardcore", false);

		// space, all the bodies and things
		m_space.reset(new Space(this, m_galaxy, jsonObj, m_time));

		unsigned int player = jsonObj["player"];
		m_player.reset(static_cast<Player *>(m_space->GetBodyByIndex(player)));

		assert(!m_player->IsDead()); // Pioneer does not support necromancy

		// hyperspace clouds being brought over from the previous system
		Json hyperspaceCloudArray = jsonObj["hyperspace_clouds"].get<Json::array_t>();
		for (Uint32 i = 0; i < hyperspaceCloudArray.size(); i++) {
			m_hyperspaceClouds.push_back(static_cast<HyperspaceCloud *>(Body::FromJson(hyperspaceCloudArray[i], 0)));
		}

		const Json &gameInfo = jsonObj["game_info"];
		m_playedDuration = gameInfo.value("duration", 0.0);

	} catch (Json::type_error &) {
		throw SavedGameCorruptException();
	}

	// views
	LoadViewsFromJson(jsonObj);

	// lua components
	// the contents of m_space->m_bodies must not change until after this call
	Pi::luaSerializer->LoadComponents(jsonObj, m_space.get());

	// lua
	Pi::luaSerializer->FromJson(jsonObj);

	Pi::luaSerializer->UninitTableRefs();

	m_sessionStartTimestamp = std::chrono::steady_clock::now().time_since_epoch().count();

	EmitPauseState(IsPaused());

	Pi::GetApp()->RequestProfileFrame("LoadGame");
}

void Game::ToJson(Json &jsonObj)
{
	PROFILE_SCOPED()
	// preparing the lua serializer
	Pi::luaSerializer->InitTableRefs();
	Pi::luaSerializer->SavePersistent(jsonObj);

	// version
	jsonObj["version"] = SaveGameManager::CurrentSaveVersion();

	// galaxy generator
	m_galaxy->ToJson(jsonObj);

	GalacticEconomy::SaveToJson(jsonObj);

	// game state
	jsonObj["time"] = m_time;
	jsonObj["state"] = Uint32(m_state);

	jsonObj["want_hyperspace"] = m_wantHyperspace;
	jsonObj["hyperspace_progress"] = m_hyperspaceProgress;
	jsonObj["hyperspace_duration"] = m_hyperspaceDuration;
	jsonObj["hyperspace_end_time"] = m_hyperspaceEndTime;
	jsonObj["hardcore"] = m_hardcore;

	// Delete camera frame from frame structure:
	bool have_cam_frame = m_gameViews->m_worldView->GetCameraContext()->GetTempFrame().valid();
	if (have_cam_frame) m_gameViews->m_worldView->EndCameraFrame();

	// space, all the bodies and things
	m_space->ToJson(jsonObj);
	jsonObj["player"] = m_space->GetIndexForBody(m_player.get());

	// hyperspace clouds being brought over from the previous system
	Json hyperspaceCloudArray = Json::array(); // Create JSON array to contain hyperspace cloud data.
	for (std::list<HyperspaceCloud *>::const_iterator i = m_hyperspaceClouds.begin(); i != m_hyperspaceClouds.end(); ++i) {
		Json hyperspaceCloudArrayEl = Json::object(); // Create JSON object to contain hyperspace cloud.
		(*i)->ToJson(hyperspaceCloudArrayEl, m_space.get());
		hyperspaceCloudArray.push_back(hyperspaceCloudArrayEl); // Append hyperspace cloud object to array.
	}
	jsonObj["hyperspace_clouds"] = hyperspaceCloudArray; // Add hyperspace cloud array to supplied object.

	// views. must be saved in init order
	m_gameViews->m_sectorView->SaveToJson(jsonObj);
	m_gameViews->m_worldView->SaveToJson(jsonObj);

	// lua components
	// the contents of m_space->m_bodies must not change until after this call
	Pi::luaSerializer->SaveComponents(jsonObj, m_space.get());

	// lua
	Pi::luaSerializer->ToJson(jsonObj);

	// Stuff to show in the preview in load game window
	// some may be redundant, but this won't require loading up a game to get it all
	Json gameInfo = Json::object();
	float credits = 0;

	{
		pi_lua_import(Lua::manager->GetLuaState(), "PlayerState");
		ScopedTable state(LuaTable(Lua::manager->GetLuaState(), -1));

		credits = state.Call<float>("GetMoney");
	}

	// Get the player's character name
	// TODO: add an easier way to get the player's character object once player+ship are split more firmly
	pi_lua_import(Lua::manager->GetLuaState(), "Character");
	LuaTable characters(Lua::manager->GetLuaState(), -1);

	std::string character_name = characters.Sub("persistent").Sub("player").Get<std::string>("name");
	gameInfo["character"] = character_name;

	// Remove the Character table
	lua_pop(Lua::manager->GetLuaState(), 1);

	// Determine how long we've been playing this save (since we created or loaded it)
	std::chrono::steady_clock::duration start_time(m_sessionStartTimestamp);
	auto playtime_duration = std::chrono::steady_clock::now().time_since_epoch() - start_time;

	auto playtime_this_session = std::chrono::duration_cast<std::chrono::seconds>(playtime_duration).count();

	gameInfo["duration"] = m_playedDuration + playtime_this_session;

	// Information about the player's ship
	gameInfo["shipHull"] = Pi::player->GetShipType()->name;
	gameInfo["shipName"] = Pi::player->GetShipName();

	gameInfo["system"] = Pi::game->GetSpace()->GetStarSystem()->GetName();
	gameInfo["credits"] = credits;
	gameInfo["ship"] = Pi::player->GetShipType()->id;
	if (Pi::player->IsDocked()) {
		gameInfo["docked_at"] = Pi::player->GetDockedWith()->GetSystemBody()->GetName();
	}

	switch (Pi::player->GetFlightState()) {
	case Ship::FlightState::DOCKED:
		gameInfo["flight_state"] = "docked";
		break;
	case Ship::FlightState::DOCKING:
		gameInfo["flight_state"] = "docking";
		break;
	case Ship::FlightState::FLYING:
		gameInfo["flight_state"] = "flying";
		break;
	case Ship::FlightState::HYPERSPACE:
		gameInfo["flight_state"] = "hyperspace";
		break;
	case Ship::FlightState::JUMPING:
		gameInfo["flight_state"] = "jumping";
		break;
	case Ship::FlightState::LANDED:
		gameInfo["flight_state"] = "landed";
		break;
	case Ship::FlightState::UNDOCKING:
		gameInfo["flight_state"] = "undocking";
		break;
	case Ship::FlightState::SUPERCRUISE:
		gameInfo["flight_state"] = "supercruise";
		break;
	default:
		gameInfo["flight_state"] = "unknown";
		break;
	}

	jsonObj["game_info"] = gameInfo;

	Pi::luaSerializer->UninitTableRefs();

	// Bring back camera frame:
	if (have_cam_frame) m_gameViews->m_worldView->BeginCameraFrame();
}

void Game::TimeStep(float step)
{
	PROFILE_SCOPED()
	m_time += step; // otherwise planets lag time accel changes by a frame
	if (m_state == State::HYPERSPACE && Pi::game->GetTime() >= m_hyperspaceEndTime)
		m_time = m_hyperspaceEndTime;

	m_space->TimeStep(step);

	SfxManager::TimeStepAll(step, m_space->GetRootFrame());

	if (m_state == State::HYPERSPACE) {
		// Pure white screen throughout hyperspace transit after the jump-out animation
		m_hyperspaceFlashAlpha = 1.0f;
		if (Pi::game->GetTime() >= m_hyperspaceEndTime) {
			SwitchToNormalSpace();
			m_player->EnterSystem();
			if (SupercruiseController *sc = m_player->GetSupercruise())
				sc->EnterSupercruiseOnHyperspaceExit();
			m_hyperspaceFlashAlpha = 1.0f;
			m_hyperspaceEntryFovTimer = HYPERSPACE_ENTRY_FOV_DURATION;
			RequestTimeAccel(TIMEACCEL_1X);
		} else {
			m_hyperspaceProgress += step;
		}
		return;
	}

	if (m_player && m_player->IsHyperspaceJumpSurging()) {
		const float p = m_player->GetHyperspaceJumpSurgeProgress();
		// Keep artificial HUD lines crisp until the physical world has blown out completely white (p >= 0.92)
		m_hyperspaceFlashAlpha = (p > 0.92f) ? Clamp((p - 0.92f) / 0.08f, 0.0f, 1.0f) : 0.0f;
		m_hyperspaceEntryFovTimer = 0.0f;
	} else {
		if (m_hyperspaceFlashAlpha > 0.0f) {
			m_hyperspaceFlashAlpha = std::max(0.0f, m_hyperspaceFlashAlpha - step / 0.16f);
		}
		if (m_hyperspaceEntryFovTimer > 0.0f) {
			m_hyperspaceEntryFovTimer = std::max(0.0f, m_hyperspaceEntryFovTimer - step);
		}
	}

	if (m_wantHyperspace) {
		assert(m_state == State::NORMAL);
		SwitchToHyperspace();
		return;
	}
}

bool Game::UpdateTimeAccel()
{
	PROFILE_SCOPED()
	// don't modify the timeaccel if the game is paused
	if (m_requestedTimeAccel == Game::TIMEACCEL_PAUSED) {
		SetTimeAccel(Game::TIMEACCEL_PAUSED);
		return false;
	}

	TimeAccel newTimeAccel = m_requestedTimeAccel;

	// ludicrous speed
	if (m_player->GetFlightState() == Ship::HYPERSPACE) {
		newTimeAccel = Game::TIMEACCEL_HYPERSPACE;
		RequestTimeAccel(newTimeAccel);
	}

	// Pioneer: Expanse 1:1 Real-Time Flight Clock:
	// During all active flight states (FLYING, SUPERCRUISE, DOCKING, UNDOCKING, JUMPING),
	// lock simulation time to 1x real-time. In-system travel uses FSD Supercruise instead of time compression.
	else if (m_player->GetFlightState() == Ship::FLYING ||
		m_player->GetFlightState() == Ship::SUPERCRUISE ||
		m_player->GetFlightState() == Ship::DOCKING ||
		m_player->GetFlightState() == Ship::JUMPING ||
		m_player->GetFlightState() == Ship::UNDOCKING) {
		newTimeAccel = std::min(newTimeAccel, Game::TIMEACCEL_1X);
		RequestTimeAccel(newTimeAccel);
	}

	// no change
	if (newTimeAccel == m_timeAccel)
		return false;

	SetTimeAccel(newTimeAccel);
	return true;
}

void Game::WantHyperspace()
{
	assert(m_state == State::NORMAL);
	m_wantHyperspace = true;
}

double Game::GetHyperspaceArrivalProbability() const
{
	double progress = m_hyperspaceProgress / m_hyperspaceDuration;
	const double fudge = 4.0;
	const double scale = 1.0 / (1.0 - exp(-fudge));
	return scale * (1.0 - exp(-fudge * progress));
}

void Game::RemoveHyperspaceCloud(HyperspaceCloud *cloud)
{
	m_hyperspaceClouds.remove(cloud);
}

void Game::SwitchToHyperspace()
{
	PROFILE_SCOPED()

	// Drop sensor contacts now so HUD objects are not left pointing at ships
	// that this function is about to delete.
	if (Sensors *sensors = m_player->GetSensors())
		sensors->ClearContacts();

	// remember where we came from so we can properly place the player on exit
	m_hyperspaceSource = m_space->GetStarSystem()->GetPath();
	m_hyperspaceDest = m_player->GetHyperspaceDest();

	// find all the departure clouds, convert them to arrival clouds and store
	// them for the next system
	m_hyperspaceClouds.clear();
	for (Body *b : m_space->GetBodies()) {

		if (!b->IsType(ObjectType::HYPERSPACECLOUD)) continue;

		// only want departure clouds with ships in them
		HyperspaceCloud *cloud = static_cast<HyperspaceCloud *>(b);
		if (cloud->IsArrival() || cloud->GetShip() == 0)
			continue;

		// make sure they're going to the same place as us
		if (!m_hyperspaceDest.IsSameSystem(cloud->GetShip()->GetHyperspaceDest()))
			continue;

		// remove it from space
		m_space->RemoveBody(cloud);

		// player and the clouds are coming to the next system, but we don't
		// want the player to have any memory of what they were (we're just
		// reusing them for convenience). tell the player it was deleted so it
		// can clean up
		m_player->NotifyRemoved(cloud);

		// turn the cloud around
		cloud->GetShip()->SetHyperspaceDest(m_hyperspaceSource);
		cloud->SetIsArrival(true);

		// and remember it
		m_hyperspaceClouds.push_back(cloud);
	}

	Output(SIZET_FMT " clouds brought over\n", m_hyperspaceClouds.size());

	// remove the player from space
	m_space->RemoveBody(m_player.get());

	// create hyperspace :)
	m_space.reset(); // HACK: Here because next line will create Frames *before* deleting existing ones
	m_space.reset(new Space(this, m_galaxy, m_space.get()));

	m_space->GetBackground()->SetDrawFlags(Background::Container::DRAW_STARS);

	// Reset planner
	Pi::planner->ResetStartTime();
	Pi::planner->ResetDv();

	// put the player in it
	m_player->SetFrame(m_space->GetRootFrame());
	m_space->AddBody(m_player.get());

	// put player at the origin. kind of unnecessary since it won't be moving
	// but at least it gives some consistency
	m_player->SetPosition(vector3d::Zero);
	m_player->SetVelocity(vector3d::Zero);
	m_player->SetOrient(matrix3x3d::Identity);

	// animation and end time counters
	m_hyperspaceProgress = 0;
	m_hyperspaceDuration = m_player->GetHyperspaceDuration();
	m_hyperspaceEndTime = Pi::game->GetTime() + m_hyperspaceDuration;
	m_hyperspaceFlashAlpha = 1.0f;

	m_state = State::HYPERSPACE;
	m_wantHyperspace = false;

	Output("Started hyperspacing...\n");
}

void Game::SwitchToNormalSpace()
{
	PROFILE_SCOPED()
	// remove the player from hyperspace
	m_space->RemoveBody(m_player.get());

	// create a new space for the system
	m_space.reset(); // HACK: Here because next line will create Frames *before* deleting existing ones
	m_space.reset(new Space(this, m_galaxy, m_hyperspaceDest, m_space.get()));
	m_state = State::NORMAL;

	// put the player in it
	m_player->SetFrame(m_space->GetRootFrame());
	m_space->AddBody(m_player.get());

	// place it
	vector3d pos, vel;
	Body *primary = nullptr;
	m_space->GetHyperspaceExitParams(m_hyperspaceSource, m_hyperspaceDest, pos, vel, &primary);
	m_player->SetPosition(pos);
	m_player->SetVelocity(vel);

	// orient ship in direction of travel (facing primary star)
	{
		vector3d oz = -vel.Normalized();
		vector3d ox = MathUtil::OrthogonalDirection(vel);
		vector3d oy = oz.Cross(ox).Normalized();
		m_player->SetOrient(matrix3x3d::FromVectors(ox, oy, oz));
	}

	// Lock navigation target onto the primary star
	m_player->SetNavTarget(primary);
	m_hyperspaceFlashAlpha = 1.0f;

	// place the exit cloud
	HyperspaceCloud *cloud = new HyperspaceCloud(0, Pi::game->GetTime(), true);
	cloud->SetFrame(m_space->GetRootFrame());
	cloud->SetPosition(m_player->GetPosition());
	m_space->AddBody(cloud);

	for (std::list<HyperspaceCloud *>::iterator i = m_hyperspaceClouds.begin(); i != m_hyperspaceClouds.end(); ++i) {
		cloud = *i;

		cloud->SetFrame(m_space->GetRootFrame());
		cloud->SetPosition(m_space->GetHyperspaceExitPoint(m_hyperspaceSource, m_hyperspaceDest));

		m_space->AddBody(cloud);

		if (cloud->GetDueDate() < Pi::game->GetTime()) {
			// they emerged from hyperspace some time ago
			Ship *ship = cloud->EvictShip();

			ship->SetFrame(m_space->GetRootFrame());
			ship->SetVelocity(vector3d(0, 0, -100.0));
			ship->SetOrient(matrix3x3d::Identity);
			ship->SetFlightState(Ship::FLYING);

			const SystemPath &sdest = ship->GetHyperspaceDest();
			if (sdest.IsSystemPath()) {
				// travelling to the system as a whole, so just dump them on
				// the cloud - we can't do any better in this case
				ship->SetPosition(cloud->GetPosition());
			}

			else {
				// on their way to a body. they're already in-system so we
				// want to simulate some travel to their destination. we
				// naively assume full accel for half the distance, flip and
				// full brake for the rest.
				Body *target_body = m_space->FindBodyForPath(&sdest);
				double dist_to_target = cloud->GetPositionRelTo(target_body).Length();
				double half_dist_to_target = dist_to_target / 2.0;
				//double accel = -(ship->GetShipType()->linThrust[ShipType::THRUSTER_FORWARD] / ship->GetMass());
				double accel = -ship->GetAccelFwd();
				double travel_time = Pi::game->GetTime() - cloud->GetDueDate();

				// I can't help but feel some actual math would do better here
				double speed = 0;
				double dist = 0;
				while (travel_time > 0 && dist <= half_dist_to_target) {
					speed += accel;
					dist += speed;
					travel_time--;
				}
				while (travel_time > 0 && dist < dist_to_target) {
					speed -= accel;
					dist += speed;
					travel_time--;
				}

				if (travel_time <= 0) {
					pos =
						target_body->GetPositionRelTo(m_space->GetRootFrame()) +
						cloud->GetPositionRelTo(target_body).Normalized() * (dist_to_target - dist);
					ship->SetPosition(pos);
				}

				else {
					// ship made it with time to spare. just put it somewhere
					// near the body. the script should be issuing a dock or
					// flyto command in onEnterSystem so it should sort it
					// itself out long before the player can get near

					SystemBody *sbody = m_space->GetStarSystem()->GetBodyByPath(&sdest);
					if (sbody->GetType() == SystemBody::TYPE_STARPORT_ORBITAL) {
						ship->SetFrame(target_body->GetFrame());
						ship->SetPosition(MathUtil::RandomPointOnSphere(1000.0) * 1000.0); // somewhere 1000km out
					}

					else {
						if (sbody->GetType() == SystemBody::TYPE_STARPORT_SURFACE) {
							sbody = sbody->GetParent();
							SystemPath path = m_space->GetStarSystem()->GetPathOf(sbody);
							target_body = m_space->FindBodyForPath(&path);
						}

						double sdist = sbody->GetRadius() * 2.0;

						ship->SetFrame(target_body->GetFrame());
						ship->SetPosition(MathUtil::RandomPointOnSphere(sdist));
					}
				}
			}

			m_space->AddBody(ship);

			LuaEvent::Queue("onShipEnterSystem", ship);
		}
	}
	m_hyperspaceClouds.clear();

	LuaEvent::Queue("onEnterSystem", m_player.get());

	m_space->GetBackground()->SetDrawFlags(Background::Container::DRAW_SKYBOX | Background::Container::DRAW_STARS);

	// HACK: we call RebuildObjectTrees to make the internal state of CollisionSpace valid
	// This is absolutely not our job and CollisionSpace should be redesigned to fix this.
	Frame::GetFrame(m_player->GetFrame())->GetCollisionSpace()->RebuildObjectTrees();
}

static bool IsPrisonStation(const SpaceStation *st)
{
	if (!st) return false;
	const std::string &stType = st->GetSystemBody() ? st->GetSystemBody()->GetSpaceStationType() : "";
	if (stType == "orbital_station_penal") return true;
	const std::string &stName = st->GetLabel();
	if (stName.find("Prison") != std::string::npos ||
	    stName.find("Penal") != std::string::npos ||
	    stName.find("Correctional") != std::string::npos ||
	    stName.find("Penitentiary") != std::string::npos ||
	    stName.find("Detention") != std::string::npos) {
		return true;
	}
	return false;
}

void Game::TriggerPlayerEscapePodRecovery()
{
	if (!m_player) return;

	// Clear targets, AI, supercruise, and input state from previous life/system
	m_player->AIClearInstructions();
	if (m_player->GetSupercruise()) {
		m_player->GetSupercruise()->Reset();
	}
	if (PlayerShipController *psc = m_player->GetPlayerController()) {
		psc->ResetMouseCapture();
	}
	auto gm = m_player->GetComponent<GunManager>();
	if (gm) {
		gm->SetAllGroupsFiring(false);
	}
	m_player->SetNavTarget(nullptr);
	m_player->SetCombatTarget(nullptr);
	m_player->SetFollowTarget(nullptr);
	if (Pi::input) {
		Pi::input->ClearAllInput();
	}
	ImGui::GetIO().ClearInputKeys();
	ImGui::GetIO().ClearInputMouse();
	ImGui::ClearActiveID();
	ImGui::SetWindowFocus(nullptr);
	ImGui::SetMouseCursor(ImGuiMouseCursor_Arrow);

	// Check if the player is being remanded to correctional custody (outstanding fines / warrants)
	bool isCriminal = false;
	lua_State *l = Lua::manager->GetLuaState();
	pi_lua_import(l, "PlayerState");
	lua_getfield(l, -1, "GetTotalFinesOutstanding");
	if (lua_isfunction(l, -1)) {
		if (lua_pcall(l, 0, 1, 0) == 0) {
			double fine = lua_tonumber(l, -1);
			if (fine > 0.0) isCriminal = true;
			lua_pop(l, 1);
		}
	} else {
		lua_pop(l, 1);
		lua_getfield(l, -1, "GetCrimeOutstanding");
		if (lua_isfunction(l, -1)) {
			if (lua_pcall(l, 0, 2, 0) == 0) {
				double fine = lua_tonumber(l, -1);
				if (fine > 0.0) isCriminal = true;
				lua_pop(l, 2);
			}
		} else {
			lua_pop(l, 1);
		}
	}
	lua_pop(l, 1);

	// 1. Locate starports in current system (only route to prison stations if player is criminal)
	SpaceStation *targetStation = nullptr;
	SpaceStation *foundPrison = nullptr;
	SpaceStation *foundCivilianOrbital = nullptr;
	SpaceStation *foundCivilianStation = nullptr;
	double bestPrisonDistSq = 1e36;
	double bestCivilianOrbitalDistSq = 1e36;
	double bestCivilianStationDistSq = 1e36;

	for (Body *b : m_space->GetBodies()) {
		if (b && b->IsType(ObjectType::SPACESTATION) && !b->IsDead()) {
			SpaceStation *st = static_cast<SpaceStation *>(b);
			const double dSq = m_player->GetPositionRelTo(b).LengthSqr();
			if (IsPrisonStation(st)) {
				if (dSq < bestPrisonDistSq) {
					bestPrisonDistSq = dSq;
					foundPrison = st;
				}
			} else {
				if (!st->IsGroundStation() && dSq < bestCivilianOrbitalDistSq) {
					bestCivilianOrbitalDistSq = dSq;
					foundCivilianOrbital = st;
				}
				if (dSq < bestCivilianStationDistSq) {
					bestCivilianStationDistSq = dSq;
					foundCivilianStation = st;
				}
			}
		}
	}

	double bestStationDistSq = 1e36;
	if (isCriminal && foundPrison) {
		targetStation = foundPrison;
		bestStationDistSq = bestPrisonDistSq;
	} else if (!isCriminal) {
		// Non-criminal player: MUST ONLY be recovered to a civilian station!
		if (foundCivilianOrbital) {
			targetStation = foundCivilianOrbital;
			bestStationDistSq = bestCivilianOrbitalDistSq;
		} else if (foundCivilianStation) {
			targetStation = foundCivilianStation;
			bestStationDistSq = bestCivilianStationDistSq;
		}
		// If current system only has a prison station (e.g. Barnard's Star), targetStation remains nullptr
		// so SAR will transport the non-criminal player to a nearby civilian system.
	} else {
		// Criminal player in a system without a designated penal facility
		if (foundCivilianOrbital) {
			targetStation = foundCivilianOrbital;
			bestStationDistSq = bestCivilianOrbitalDistSq;
		} else if (foundCivilianStation) {
			targetStation = foundCivilianStation;
			bestStationDistSq = bestCivilianStationDistSq;
		}
	}

	double recoveryDays = 0.5;

	// 2. Compute SAR recovery time and relocate if no eligible civilian/penal station exists in current system
	if (targetStation) {
		// In-system SAR recovery: ~4 to 36 hours depending on AU distance to nearest station
		const double distAU = std::sqrt(bestStationDistSq) / AU;
		recoveryDays = 0.15 + Pi::rng.Double() * 0.15 + std::min(1.5, distAU * 0.04);
	} else {
		const SystemPath currentPath = m_space->GetStarSystem()->GetPath();
		SystemPath nearestInhabited = currentPath;
		double bestDistSq = 1e18;

		RefCountedPtr<const Sector> curSec = m_galaxy->GetSector(currentPath);
		for (int dz = -3; dz <= 3; ++dz) {
			for (int dy = -3; dy <= 3; ++dy) {
				for (int dx = -3; dx <= 3; ++dx) {
					SystemPath secPath(currentPath.sectorX + dx, currentPath.sectorY + dy, currentPath.sectorZ + dz);
					RefCountedPtr<const Sector> sec = m_galaxy->GetSector(secPath);
					if (!sec) continue;
					for (size_t i = 0; i < sec->m_systems.size(); ++i) {
						const Sector::System &sys = sec->m_systems[i];
						if (sys.GetPopulation() > 0 && sys.GetNumStars() > 0) {
							// Avoid selecting current system again if it had no eligible station
							if (secPath.sectorX == currentPath.sectorX && secPath.sectorY == currentPath.sectorY &&
							    secPath.sectorZ == currentPath.sectorZ && int(i) == currentPath.systemIndex) {
								continue;
							}
							float dSq = curSec
								? Sector::DistanceBetweenSqr(curSec, currentPath.systemIndex, sec, i)
								: float((dx * dx + dy * dy + dz * dz) * Sector::SIZE * Sector::SIZE);
							if (dSq < bestDistSq) {
								bestDistSq = dSq;
								nearestInhabited = SystemPath(secPath.sectorX, secPath.sectorY, secPath.sectorZ, i);
							}
						}
					}
				}
			}
		}

		double distLy = 10.0;
		if (bestDistSq < 1e17) {
			distLy = std::max(1.0, std::sqrt(bestDistSq));
		} else {
			nearestInhabited = SystemPath(0, 0, 0, 0); // Sol fallback
			const double dx = double(currentPath.sectorX - nearestInhabited.sectorX) * Sector::SIZE;
			const double dy = double(currentPath.sectorY - nearestInhabited.sectorY) * Sector::SIZE;
			const double dz = double(currentPath.sectorZ - nearestInhabited.sectorZ) * Sector::SIZE;
			distLy = std::max(1.0, std::sqrt(dx * dx + dy * dy + dz * dz));
		}

		// Cross-system SAR jump/relay transit (~0.365 days/ly -> 1000 ly ~ 1 yr, 80,000 ly across galaxy ~ 30 yrs)
		recoveryDays = 0.5 + Pi::rng.Double() * 0.5 + distLy * 0.365;

		LuaEvent::Queue("onLeaveSystem", m_player.get());
		m_space->RemoveBody(m_player.get());
		m_space.reset();
		m_space.reset(new Space(this, m_galaxy, nearestInhabited, nullptr));
		m_space->GetBackground()->SetDrawFlags(Background::Container::DRAW_SKYBOX | Background::Container::DRAW_STARS);
		m_player->SetFrame(m_space->GetRootFrame());
		m_space->AddBody(m_player.get());

		SpaceStation *foundPrisonReloc = nullptr;
		SpaceStation *foundCivilianOrbitalReloc = nullptr;
		SpaceStation *foundCivilianStationReloc = nullptr;
		for (Body *b : m_space->GetBodies()) {
			if (b && b->IsType(ObjectType::SPACESTATION) && !b->IsDead()) {
				SpaceStation *st = static_cast<SpaceStation *>(b);
				if (IsPrisonStation(st)) {
					if (!foundPrisonReloc) foundPrisonReloc = st;
				} else {
					if (!st->IsGroundStation() && !foundCivilianOrbitalReloc) {
						foundCivilianOrbitalReloc = st;
					}
					if (!foundCivilianStationReloc) {
						foundCivilianStationReloc = st;
					}
				}
			}
		}

		if (isCriminal && foundPrisonReloc) {
			targetStation = foundPrisonReloc;
		} else if (!isCriminal) {
			targetStation = foundCivilianOrbitalReloc ? foundCivilianOrbitalReloc : foundCivilianStationReloc;
			// Safety: If nearestInhabited happened to be a dedicated penal system, redirect clean player to Sol
			if (!targetStation) {
				nearestInhabited = SystemPath(0, 0, 0, 0); // Sol
				LuaEvent::Queue("onLeaveSystem", m_player.get());
				m_space->RemoveBody(m_player.get());
				m_space.reset();
				m_space.reset(new Space(this, m_galaxy, nearestInhabited, nullptr));
				m_space->GetBackground()->SetDrawFlags(Background::Container::DRAW_SKYBOX | Background::Container::DRAW_STARS);
				m_player->SetFrame(m_space->GetRootFrame());
				m_space->AddBody(m_player.get());
				for (Body *b : m_space->GetBodies()) {
					if (b && b->IsType(ObjectType::SPACESTATION) && !b->IsDead()) {
						SpaceStation *st = static_cast<SpaceStation *>(b);
						if (!IsPrisonStation(st)) {
							if (!st->IsGroundStation() && !foundCivilianOrbitalReloc) {
								foundCivilianOrbitalReloc = st;
							}
							if (!foundCivilianStationReloc) {
								foundCivilianStationReloc = st;
							}
						}
					}
				}
				targetStation = foundCivilianOrbitalReloc ? foundCivilianOrbitalReloc : foundCivilianStationReloc;
			}
		} else {
			targetStation = foundCivilianOrbitalReloc ? foundCivilianOrbitalReloc : foundCivilianStationReloc;
		}

		LuaEvent::Queue("onEnterSystem", m_player.get());
	}

	// Invariable guarantee: Non-criminal player is NEVER placed at a prison station
	if (!isCriminal && targetStation && IsPrisonStation(targetStation)) {
		targetStation = nullptr;
	}

	// 3. Advance simulation clock by calculated SAR recovery duration
	m_time += recoveryDays * 86400.0;

	// 4. Revive player and dock at station in the station's frame
	m_player->Revive();
	if (targetStation) {
		m_player->SetFrame(targetStation->GetFrame());
		int port = targetStation->GetFreeDockingPort(m_player.get());
		if (port < 0) port = 0;
		m_player->SetDockedWith(targetStation, port);
		m_player->UpdateInterpTransform(1.0);
		Frame::GetFrame(m_player->GetFrame())->GetCollisionSpace()->RebuildObjectTrees();
	}
	if (Pi::input) {
		Pi::input->ClearAllInput();
	}
	ImGui::GetIO().ClearInputKeys();
	ImGui::GetIO().ClearInputMouse();
	ImGui::ClearActiveID();
	ImGui::SetWindowFocus(nullptr);
	ImGui::SetMouseCursor(ImGuiMouseCursor_Arrow);

	// 5. Reset flash and switch to Station View
	m_hyperspaceFlashAlpha = 0.0f;
	Pi::SetView(GetSpaceStationView());

	// 6. Notify Lua of successful rescue and recovery
	LuaEvent::Queue("onPlayerRescued", recoveryDays, targetStation);
	LuaEvent::Emit();
}

const float Game::s_timeAccelRates[] = {
	0.0f,	  // paused
	1.0f,	  // 1x
	10.0f,	  // 10x
	100.0f,	  // 100x
	1000.0f,  // 1000x
	10000.0f, // 10000x
	100000.0f // hyperspace
};

const float Game::s_timeInvAccelRates[] = {
	0.0f,	 // paused
	1.0f,	 // 1x
	0.1f,	 // 10x
	0.01f,	 // 100x
	0.001f,	 // 1000x
	0.0001f, // 10000x
	0.00001f // hyperspace
};

void Game::SetTimeAccel(TimeAccel t)
{
	// don't want player to spin like mad when hitting time accel
	if ((t != m_timeAccel) && (t > TIMEACCEL_1X) &&
		m_player->GetPlayerController()->GetRotationDamping()) {
		m_player->SetAngVelocity(vector3d::Zero);
		m_player->SetTorque(vector3d::Zero);
		m_player->SetAngThrusterState(vector3d(0.0));
	}

	// Give all currently flying ships a half-step acceleration to stop autopilot overshoot
	if (t < m_timeAccel)
		for (Body *b : m_space->GetBodies())
			if (b->IsType(ObjectType::SHIP)) {
				Ship *ship = static_cast<Ship *>(b);
				if (ship->GetFlightState() == Ship::FLYING)
					ship->TimeAccelAdjust(0.5f * GetTimeStep());
			}

	bool emitPaused = (t == TIMEACCEL_PAUSED && t != m_timeAccel);
	bool emitResumed = (m_timeAccel == TIMEACCEL_PAUSED && t != TIMEACCEL_PAUSED);

	m_timeAccel = t;

	if (emitPaused) {
		EmitPauseState(true);
	}

	if (emitResumed) {
		EmitPauseState(false);
	}

	if (m_timeAccel == TIMEACCEL_PAUSED || m_timeAccel == TIMEACCEL_HYPERSPACE) {
		m_requestedTimeAccel = m_timeAccel;
		m_forceTimeAccel = false;
	}
}

void Game::RequestTimeAccel(TimeAccel t, bool force)
{
	m_requestedTimeAccel = t;
	m_forceTimeAccel = force;
}

void Game::RequestTimeAccelInc(bool force)
{
	switch (m_requestedTimeAccel) {
	case Game::TIMEACCEL_1X:
		m_requestedTimeAccel = Game::TIMEACCEL_10X;
		break;
	case Game::TIMEACCEL_10X:
		m_requestedTimeAccel = Game::TIMEACCEL_100X;
		break;
	case Game::TIMEACCEL_100X:
		m_requestedTimeAccel = Game::TIMEACCEL_1000X;
		break;
	case Game::TIMEACCEL_1000X:
		m_requestedTimeAccel = Game::TIMEACCEL_10000X;
		break;
	default:
		// ignore if paused, hyperspace or 10000X
		break;
	}
	m_forceTimeAccel = force;
}

void Game::RequestTimeAccelDec(bool force)
{
	switch (m_requestedTimeAccel) {
	case Game::TIMEACCEL_10X:
		m_requestedTimeAccel = Game::TIMEACCEL_1X;
		break;
	case Game::TIMEACCEL_100X:
		m_requestedTimeAccel = Game::TIMEACCEL_10X;
		break;
	case Game::TIMEACCEL_1000X:
		m_requestedTimeAccel = Game::TIMEACCEL_100X;
		break;
	case Game::TIMEACCEL_10000X:
		m_requestedTimeAccel = Game::TIMEACCEL_1000X;
		break;
	default:
		// ignore if paused, hyperspace or 1X
		break;
	}
	m_forceTimeAccel = force;
}

#if WITH_OBJECTVIEWER
ObjectViewerView *Game::GetObjectViewerView() const
{
	return m_gameViews->m_objectViewerView;
}
#endif

Game::Views::Views() :
	m_sectorView(nullptr),
	m_systemView(nullptr),
	m_worldView(nullptr),
	m_deathView(nullptr),
	m_spaceStationView(nullptr),
	m_infoView(nullptr)
{
}

void Game::Views::SetRenderer(Graphics::Renderer *r)
{
	// view manager will handle setting this probably
	m_infoView->SetRenderer(r);
	m_sectorView->SetRenderer(r);
	m_systemView->SetRenderer(r);
	m_spaceStationView->SetRenderer(r);
	m_worldView->SetRenderer(r);
	m_deathView->SetRenderer(r);

#if WITH_OBJECTVIEWER
	m_objectViewerView->SetRenderer(r);
#endif
}

void Game::Views::Init(Game *game)
{
	m_sectorView = new SectorView(game);
	m_worldView = new WorldView(game);
	m_systemView = new SystemView(game);
	m_spaceStationView = new View("StationView");
	m_infoView = new View("InfoView");
	m_deathView = new DeathView(game);

#if WITH_OBJECTVIEWER
	m_objectViewerView = new ObjectViewerView();
#endif

	SetRenderer(Pi::renderer);
}

void Game::Views::LoadFromJson(const Json &jsonObj, Game *game)
{
	m_sectorView = new SectorView(jsonObj, game);
	m_worldView = new WorldView(jsonObj, game);

	m_systemView = new SystemView(game);
	m_spaceStationView = new View("StationView");
	m_infoView = new View("InfoView");
	m_deathView = new DeathView(game);

#if WITH_OBJECTVIEWER
	m_objectViewerView = new ObjectViewerView();
#endif

	SetRenderer(Pi::renderer);
}

Game::Views::~Views()
{
#if WITH_OBJECTVIEWER
	if (m_objectViewerView) delete m_objectViewerView;
#endif

	if (m_deathView) delete m_deathView;
	if (m_infoView) delete m_infoView;
	if (m_spaceStationView) delete m_spaceStationView;
	if (m_systemView) delete m_systemView;
	if (m_worldView) delete m_worldView;
	if (m_sectorView) delete m_sectorView;
}

// XXX this should be in some kind of central UI management class that
// creates a set of UI views held by the game. right now though the views
// are rather fundamentally tied to their global points and assume they
// can all talk to each other. given the difficulty of disentangling all
// that and the impending move to Rocket, its better right now to just
// manage creation and destruction here to get the timing and order right
void Game::CreateViews()
{
	PROFILE_SCOPED()
	Pi::SetView(nullptr);

	// XXX views expect Pi::game and Pi::player to exist
	Pi::game = this;
	Pi::player = m_player.get();

	m_gameViews.reset(new Views);
	m_gameViews->Init(this);

	log = new GameLog();
}

// XXX mostly a copy of CreateViews
void Game::LoadViewsFromJson(const Json &jsonObj)
{
	Pi::SetView(nullptr);

	// XXX views expect Pi::game and Pi::player to exist
	Pi::game = this;
	Pi::player = m_player.get();

	m_gameViews.reset(new Views);
	m_gameViews->LoadFromJson(jsonObj, this);

	log = new GameLog();
}

void Game::DestroyViews()
{
	Pi::SetView(nullptr);

	m_gameViews.reset();

	delete log;
	log = 0;
}

void Game::EmitPauseState(bool paused)
{
	if (paused) {
		// Notify UI that time is paused.
		LuaEvent::Queue("onGamePaused");
		LuaEvent::Queue(PiGui::GetEventQueue(), "onGamePaused");
		Sound::Pause(1);
	} else {
		// Notify the UI that time is running again.
		LuaEvent::Queue("onGameResumed");
		LuaEvent::Queue(PiGui::GetEventQueue(), "onGameResumed");
		Sound::Pause(0);
	}
	LuaEvent::Emit();
}
