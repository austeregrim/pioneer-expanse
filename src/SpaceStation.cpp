// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SpaceStation.h"

#include "AnimationCurves.h"
#include "Camera.h"
#include "CityOnPlanet.h"
#include "EnumStrings.h"
#include "Frame.h"
#include "Game.h"
#include "GameLog.h"
#include "GameSaveError.h"
#include "JsonUtils.h"
#include "Lang.h"
#include "MathUtil.h"
#include "NavLights.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "Quaternion.h"
#include "Ship.h"
#include "ShipAICmd.h"
#include "Space.h"
#include "SpaceStationType.h"
#include "StringF.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/VertexArray.h"
#include "lua/LuaEvent.h"
#include "scenegraph/Animation.h"
#include "scenegraph/CollisionGeometry.h"
#include "scenegraph/MatrixTransform.h"
#include "scenegraph/Model.h"
#include "scenegraph/ModelSkin.h"
#include "ship/PlayerShipController.h"
#include "ship/SupercruiseController.h"
#include "utils.h"

SpaceStation::SpaceStation(const SystemBody *sbody) :
	ModelBody(),
	m_type(nullptr),
	m_corridorShip(nullptr),
	m_lastLaunchTime(0.0)
{
	m_sbody = sbody;

	m_oldAngDisplacement = 0.0;

	m_doorAnimationStep = m_doorAnimationState = 0.0;

	InitStation();
}

SpaceStation::SpaceStation(const Json &jsonObj, Space *space) :
	ModelBody(jsonObj, space),
	m_type(nullptr),
	m_corridorShip(nullptr),
	m_lastLaunchTime(0.0)
{
	try {
		Json spaceStationObj = jsonObj["space_station"];

		m_oldAngDisplacement = 0.0;

		Json shipDockingArray = spaceStationObj["ship_docking"].get<Json::array_t>();
		m_shipDocking.reserve(shipDockingArray.size());
		for (Uint32 i = 0; i < shipDockingArray.size(); i++) {
			m_shipDocking.push_back(shipDocking_t());
			shipDocking_t &sd = m_shipDocking.back();

			Json shipDockingArrayEl = shipDockingArray[i];
			if (shipDockingArrayEl.count("index_for_body"))
				sd.shipIndex = shipDockingArrayEl["index_for_body"];
			if (shipDockingArrayEl.count("stage"))
				sd.stage = shipDockingArrayEl["stage"];
			if (shipDockingArrayEl.count("stage_pos"))
				sd.stagePos = shipDockingArrayEl["stage_pos"]; // For some reason stagePos was saved as a float in pre-JSON system (saved & loaded as double here).
			if (shipDockingArrayEl.count("from_pos"))
				sd.fromPos = shipDockingArrayEl["from_pos"];
			if (shipDockingArrayEl.count("from_rot"))
				sd.fromRot = shipDockingArrayEl["from_rot"];
		}

		// retrieve each of the port details and bay IDs
		Json portArray = spaceStationObj["ports"].get<Json::array_t>();
		m_ports.reserve(portArray.size());
		for (Uint32 i = 0; i < portArray.size(); i++) {
			m_ports.push_back(SpaceStationType::SPort());
			SpaceStationType::SPort &port = m_ports.back();

			Json portArrayEl = portArray[i];
			if (portArrayEl["in_use"].is_boolean())
				port.inUse = portArrayEl["in_use"];
		}

		m_sbody = space->GetStationSystemBodyByIndex(spaceStationObj["index_for_system_body"], GetLabel());
		if (m_sbody && m_sbody->GetName() != GetLabel())
			SetLabel(m_sbody->GetName().c_str());

		m_doorAnimationStep = spaceStationObj["door_animation_step"];
		m_doorAnimationState = spaceStationObj["door_animation_state"];

		InitStation();

		GetModel()->SetLabel(GetLabel());

		m_navLights->LoadFromJson(spaceStationObj);
	} catch (Json::type_error &) {
		throw SavedGameCorruptException();
	}
}

void SpaceStation::Init()
{
	SpaceStationType::Init();
}

void SpaceStation::SaveToJson(Json &jsonObj, Space *space)
{
	ModelBody::SaveToJson(jsonObj, space);

	Json spaceStationObj({}); // Create JSON object to contain space station data.

	Json shipDockingArray = Json::array(); // Create JSON array to contain ship docking data.
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		Json shipDockingArrayEl({}); // Create JSON object to contain ship docking.
		Uint32 bodyIndex = space->GetIndexForBody(m_shipDocking[i].ship);
		if (bodyIndex != 0) {
			shipDockingArrayEl["index_for_body"] = bodyIndex;
			shipDockingArrayEl["stage"] = m_shipDocking[i].stage;
			shipDockingArrayEl["stage_pos"] = m_shipDocking[i].stagePos; // stagePos is a double but was saved as a float in pre-JSON system for some reason (saved as double here).
			shipDockingArrayEl["from_pos"] = m_shipDocking[i].fromPos;
			shipDockingArrayEl["from_rot"] = m_shipDocking[i].fromRot;
		}
		shipDockingArray.push_back(shipDockingArrayEl); // Append ship docking object to array.
	}
	spaceStationObj["ship_docking"] = shipDockingArray; // Add ship docking array to space station object.

	// store each of the port details and bay IDs
	Json portArray = Json::array(); // Create JSON array to contain port data.
	for (Uint32 i = 0; i < m_ports.size(); i++) {
		Json portArrayEl({}); // Create JSON object to contain port.

		if (m_ports[i].inUse)
			portArrayEl["in_use"] = m_ports[i].inUse;

		portArray.push_back(portArrayEl); // Append port object to array.
	}
	spaceStationObj["ports"] = portArray; // Add port array to space station object.

	spaceStationObj["index_for_system_body"] = space->GetIndexForSystemBody(m_sbody);

	spaceStationObj["door_animation_step"] = m_doorAnimationStep;
	spaceStationObj["door_animation_state"] = m_doorAnimationState;

	m_navLights->SaveToJson(spaceStationObj);

	jsonObj["space_station"] = spaceStationObj; // Add space station object to supplied object.
}

static float calculate_max_offset_squared(float portMaxShipSize, float shipBboxRad)
{
	float maxOffset = std::max((portMaxShipSize * 0.5f - shipBboxRad), portMaxShipSize / 5.f);
	return maxOffset * maxOffset;
}

void SpaceStation::PostLoadFixup(Space *space)
{
	ModelBody::PostLoadFixup(space);
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		auto &sd = m_shipDocking[i];
		sd.ship = static_cast<Ship *>(space->GetBodyByIndex(m_shipDocking[i].shipIndex));

		if (!sd.ship) continue;

		auto pPort = m_type->FindPortByBay(i);
		const Aabb &bbox = sd.ship->GetAabb();
		const float bboxRad = vector2f(float(bbox.max.x), float(bbox.max.z)).Length();
		sd.maxOffset = calculate_max_offset_squared(pPort->maxShipSize, bboxRad);
		ComputeHangarBayGeometry(int(i), sd.ship, sd.hangarHalfX, sd.hangarHalfZ, sd.hangarDepth);
	}
}

void SpaceStation::InitStation()
{
	PROFILE_SCOPED()
	m_adjacentCity = 0;
	for (int i = 0; i < NUM_STATIC_SLOTS; i++)
		m_staticSlot[i] = false;
	Random rand(m_sbody->GetSeed());
	const bool ground = m_sbody->GetType() == SystemBody::TYPE_STARPORT_ORBITAL ? false : true;
	const std::string &space_station_type = m_sbody->GetSpaceStationType();
	if (space_station_type != "") {
		m_type = SpaceStationType::FindByName(space_station_type);
		if (m_type == nullptr)
			Output("WARNING: SpaceStation::InitStation wants to initialize a custom station of type %s, but no station type with that id has been found.\n", space_station_type.c_str());
	}
	if (m_type == nullptr) {
		// If m_shipDocking was already loaded from a savegame, match station type
		// by loaded port count (e.g. 18 ports for 2k vs 64 ports for 5k/10k)
		if (!m_shipDocking.empty()) {
			m_type = SpaceStationType::FindByPortCount(m_shipDocking.size(), ground);
		}
		if (m_type == nullptr)
			m_type = SpaceStationType::RandomStationType(rand, ground);
	}

	if (m_shipDocking.empty()) {
		m_shipDocking.reserve(m_type->NumDockingPorts());
		for (unsigned int i = 0; i < m_type->NumDockingPorts(); i++) {
			m_shipDocking.push_back(shipDocking_t());
		}
		// only (re)set these if we've not come from the ::Load method
		m_doorAnimationStep = m_doorAnimationState = 0.0;
	} else if (m_shipDocking.size() != m_type->NumDockingPorts()) {
		m_shipDocking.resize(m_type->NumDockingPorts());
	}
	assert(m_shipDocking.size() == m_type->NumDockingPorts());

	// This SpaceStation's bay ports are an instance of...
	if (m_ports.size() != m_type->Ports().size()) {
		m_ports = m_type->Ports();
	} else {
		// since we might have loaded from JSON we've got a little bit of useful info in m_ports already
		// backup the current data
		auto backup = m_ports;
		// clear it all to default
		m_ports = m_type->Ports();
		// now restore the "inUse" variable only since it's the only bit that might have changed
		for (size_t p = 0; p < m_ports.size(); p++) {
			m_ports[p].inUse = backup[p].inUse;
		}
	}

	SetStatic(ground); // orbital stations are dynamic now

	// XXX hack. if we loaded a game then ModelBody::Load already restored the
	// model and we shouldn't overwrite it
	if (!GetModel())
		SetModel(m_type->ModelName().c_str());

	SceneGraph::Model *model = GetModel();

	m_navLights.reset(new NavLights(model, 2.2f));
	m_navLights->SetEnabled(true);

	if (ground) SetClipRadius(CityOnPlanet::RADIUS); // overrides setmodel

	m_doorAnimation = model->FindAnimation("doors");

	SceneGraph::ModelSkin skin;
	skin.SetDecal("pioneer");

	skin.SetRandomColors(rand);
	skin.Apply(model);
	if (model->SupportsPatterns()) {
		model->SetPattern(rand.Int32(0, model->GetNumPatterns() - 1));
	}
}

SpaceStation::~SpaceStation()
{
	if (m_adjacentCity) delete m_adjacentCity;
}

void SpaceStation::NotifyRemoved(const Body *const removedBody)
{
	if (m_corridorShip == removedBody)
		m_corridorShip = nullptr;
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (m_shipDocking[i].ship == removedBody) {
			m_shipDocking[i].ship = nullptr;
			m_shipDocking[i].stage = DockStage::NONE;
			LockPort(i, false);
		}
	}
}

int SpaceStation::GetMyDockingPort(const Ship *s) const
{
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (s == m_shipDocking[i].ship) return i;
	}
	return -1;
}

int SpaceStation::NumShipsDocked() const
{
	Sint32 numShipsDocked = 0;
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (NULL != m_shipDocking[i].ship)
			++numShipsDocked;
	}
	return numShipsDocked;
}

int SpaceStation::GetFreeDockingPortCount() const
{
	int freePorts = 0;
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (m_shipDocking[i].ship == nullptr)
			++freePorts;
	}
	return freePorts;
}

static double GetHangarElevatorDepth(const Ship *ship)
{
	if (!ship) return 20.0;
	const Aabb &aabb = ship->GetAabb();
	return std::max(14.0, (aabb.max.y - aabb.min.y) + 6.0);
}

void SpaceStation::ComputeHangarBayGeometry(int bay, const Ship *ship, float &outHalfX, float &outHalfZ, float &outDepth) const
{
	const float maxBayHalf = m_type ? std::max(7.5f, m_type->GetBayMaxHalfExtent(bay) - 2.0f) : 14.0f;
	if (!ship) {
		outHalfX = Clamp(11.0f, 6.5f, maxBayHalf);
		outHalfZ = Clamp(13.0f, 7.5f, maxBayHalf);
		outDepth = 18.0f;
		return;
	}
	const Aabb &aabb = ship->GetAabb();
	const float shipHalfX = std::max(std::fabs(float(aabb.min.x)), std::fabs(float(aabb.max.x)));
	const float shipHalfZ = std::max(std::fabs(float(aabb.min.z)), std::fabs(float(aabb.max.z)));
	outHalfX = Clamp(shipHalfX + 2.2f, 6.5f, maxBayHalf);
	outHalfZ = Clamp(shipHalfZ + 2.5f, 7.5f, maxBayHalf);
	outDepth = float(GetHangarElevatorDepth(ship));
}

bool SpaceStation::StowShipInHangar(Ship *ship)
{
	if (!ship || ship->IsDead() || ship->IsType(ObjectType::PLAYER))
		return false;

	const int bay = GetMyDockingPort(ship);
	if (bay < 0 || Uint32(bay) >= m_shipDocking.size())
		return false;

	shipDocking_t &dt = m_shipDocking[bay];
	if (dt.stage != DockStage::DOCKED || ship->GetFlightState() != Ship::DOCKED)
		return false;

	dt.stage = DockStage::HANGAR_STOWING;
	dt.stagePos = 0.0;
	dt.fromPos = vector3d::Zero;
	dt.fromRot = Quaterniond(1.0, 0.0, 0.0, 0.0);
	ComputeHangarBayGeometry(bay, ship, dt.hangarHalfX, dt.hangarHalfZ, dt.hangarDepth);
	return true;
}

bool SpaceStation::BeginUnstowFromHangar(Ship *ship, const int bay)
{
	if (!ship || ship->IsDead() || bay < 0 || Uint32(bay) >= m_shipDocking.size())
		return false;
	if (m_shipDocking[bay].ship != nullptr)
		return false;

	ship->SetDockedWith(this, bay);

	shipDocking_t &dt = m_shipDocking[bay];
	dt.stage = DockStage::HANGAR_UNSTOWING;
	dt.stagePos = 0.0;
	ComputeHangarBayGeometry(bay, ship, dt.hangarHalfX, dt.hangarHalfZ, dt.hangarDepth);
	dt.fromPos = vector3d(0.0, -double(dt.hangarDepth), 0.0);
	dt.fromRot = Quaterniond(1.0, 0.0, 0.0, 0.0);
	PositionDockedShip(ship, bay);
	ship->UpdateInterpTransform(1.0);
	return true;
}

int SpaceStation::GetFreeDockingPort(const Ship *s) const
{
	assert(s);
	for (unsigned int i = 0; i < m_type->NumDockingPorts(); i++) {
		if (m_shipDocking[i].ship == nullptr) {
			// size-of-ship vs size-of-bay check
			const SpaceStationType::SPort *const pPort = m_type->FindPortByBay(i);
			if (!pPort) continue;

			const Aabb &bbox = s->GetAabb();
			const double bboxRad = bbox.GetRadius();

			if (pPort->minShipSize < bboxRad && bboxRad < pPort->maxShipSize) {
				return i;
			}
		}
	}
	return -1;
}

void SpaceStation::SetDocked(Ship *ship, const int bay)
{
	assert(m_shipDocking.size() > Uint32(bay));
	m_shipDocking[bay].ship = ship;
	m_shipDocking[bay].fromPos = vector3d::Zero;
	m_shipDocking[bay].fromRot = Quaterniond(1.0, 0.0, 0.0, 0.0);
	m_shipDocking[bay].stagePos = 0.0;

	// have to do this crap again in case it was called directly (Ship::SetDockWith())
	ship->SetFlightState(Ship::DOCKED);
	ship->SetVelocity(vector3d(0.0));
	ship->SetAngVelocity(vector3d(0.0));
	PositionDockedShip(ship, bay);
	SwitchToStage(bay, DockStage::DOCKED);
}

void SpaceStation::SwapDockedShipsPort(const int oldBay, const int newBay)
{
	if (oldBay == newBay)
		return;

	// set new location
	Ship *ship = m_shipDocking[oldBay].ship;
	assert(ship);
	ship->SetDockedWith(this, newBay);

	m_shipDocking[oldBay].ship = nullptr;
	SwitchToStage(oldBay, DockStage::NONE);
}

bool SpaceStation::IsLargeCorridorShip(const Ship *ship)
{
	if (!ship) return false;
	if (ship->GetClipRadius() > 22.0) return true;
	const Aabb &aabb = ship->GetAabb();
	const double width = aabb.max.x - aabb.min.x;
	const double height = aabb.max.y - aabb.min.y;
	if (width > 28.0 || height > 28.0) return true;
	if (ship->GetShipType() && ship->GetShipType()->hullMass >= 180) return true;
	return false;
}

bool SpaceStation::GetCorridorGeometry(vector3d &outPortPos, vector3d &outCorridorDir, vector3d &outLaneDir) const
{
	if (!m_type || !m_type->IsOrbitalStation()) return false;

	SpaceStationType::positionOrient_t portPosOrient;
	SpaceStationType::positionOrient_t clearPosOrient;
	if (!m_type->GetShipApproachWaypoints(0, DockStage::APPROACH2, portPosOrient) ||
		!m_type->GetShipApproachWaypoints(0, DockStage::APPROACH1, clearPosOrient)) {
		return false;
	}

	outPortPos = portPosOrient.pos;
	const vector3d d = clearPosOrient.pos - portPosOrient.pos;
	if (d.LengthSqr() > 1.0)
		outCorridorDir = d.NormalizedSafe();
	else
		outCorridorDir = vector3d(0.0, 0.0, 1.0);

	// Transverse horizontal axis across the mail slot entrance:
	vector3d lDir = portPosOrient.xaxis.NormalizedSafe();
	if (fabs(lDir.Dot(outCorridorDir)) > 0.8) {
		lDir = outCorridorDir.Cross(portPosOrient.yaxis).NormalizedSafe();
		if (lDir.LengthSqr() < 0.1) {
			lDir = outCorridorDir.Cross(vector3d(0.0, 1.0, 0.0)).NormalizedSafe();
		}
	} else {
		lDir = (lDir - outCorridorDir * (lDir.Dot(outCorridorDir))).NormalizedSafe();
	}
	outLaneDir = lDir;
	return true;
}

double SpaceStation::GetCorridorLaneOffset(const Ship *ship, bool isInbound) const
{
	if (!m_type || !m_type->IsOrbitalStation() || !ship) return 0.0;

	// Leaving ships navigate on the direct path from the station center/axis to the external waypoint
	if (!isInbound) {
		return 0.0;
	}

	// Larger ships have center priority to avoid clipping the station doorway
	if (IsLargeCorridorShip(ship)) {
		return 0.0;
	}

	// Smaller inbound ships (and player autopilot on smaller ships) use a starboard offset on approach
	return 12.0;
}

double SpaceStation::EvaluateCorridorTrafficAvoidance(
	Ship *ship,
	bool isInbound,
	const vector3d &corridorDir,
	const vector3d &laneDir,
	double axialDist,
	vector3d &outDesiredLateralOffset) const
{
	const double baseLaneOffset = GetCorridorLaneOffset(ship, isInbound);
	// Taper baseline inbound offset near the doorway so the vessel passes cleanly through the entrance trigger
	double taperedBaseOffset = baseLaneOffset;
	if (isInbound && axialDist < 120.0) {
		taperedBaseOffset *= Clamp((axialDist - 15.0) / 105.0, 0.0, 1.0);
	}
	outDesiredLateralOffset = laneDir * taperedBaseOffset;

	if (!ship) return 1.0;

	// Players docking autopilot determines lane from ship size, but players watch out for traffic on their own
	if (ship->IsType(ObjectType::PLAYER)) {
		return 1.0;
	}

	if (!Pi::game || !Pi::game->GetSpace()) return 1.0;

	vector3d portPos, cDir, lDir;
	if (!GetCorridorGeometry(portPos, cDir, lDir)) return 1.0;

	const double scanRadius = std::max(GetClipRadius() * 1.5 + 800.0, 2600.0);
	Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(const_cast<SpaceStation*>(this), scanRadius);

	const double myRadius = ship->GetClipRadius();
	const double myMassMetric = ship->GetShipType() ? double(ship->GetShipType()->hullMass) * 0.12 : 0.0;
	const double mySize = std::max(myRadius, myMassMetric);
	const bool myIsLarge = IsLargeCorridorShip(ship);
	const matrix3x3d stOrient = GetOrient();
	const vector3d myPosInStation = ship->GetPositionRelTo(this) * stOrient;
	const vector3d myCenterPos = portPos + axialDist * corridorDir;
	const vector3d myCurrentLateral = myPosInStation - myCenterPos;

	double speedMultiplier = 1.0;
	double maxStrafeNeeded = 0.0;
	vector3d bestStrafeDir = isInbound ? laneDir : -laneDir;

	for (Body *b : nearby) {
		if (!b || b == ship || !b->IsType(ObjectType::SHIP)) continue;
		Ship *other = static_cast<Ship*>(b);
		if (other->IsDead() || other->GetFlightState() == Ship::DOCKED ||
			other->GetFlightState() == Ship::HYPERSPACE || other->GetFlightState() == Ship::JUMPING)
			continue;

		const vector3d otherPosInStation = other->GetPositionRelTo(this) * stOrient;
		const vector3d otherVelInStation = other->GetVelocityRelTo(this) * stOrient;
		const double otherAxialDist = (otherPosInStation - portPos).Dot(corridorDir);
		const vector3d otherCenterPos = portPos + otherAxialDist * corridorDir;
		const vector3d otherLateralVec = otherPosInStation - otherCenterPos;
		const double otherLateralDist = otherLateralVec.Length();

		// Ignore ships outside the corridor cylinder (-800m to +2400m axial, < 160m lateral)
		if (otherAxialDist < -800.0 || otherAxialDist > 2400.0 || otherLateralDist > 160.0)
			continue;

		const double otherRadius = other->GetClipRadius();
		const double otherMassMetric = other->GetShipType() ? double(other->GetShipType()->hullMass) * 0.12 : 0.0;
		const double otherSize = std::max(otherRadius, otherMassMetric);
		const bool otherIsLarge = IsLargeCorridorShip(other);
		const bool otherIsPlayer = other->IsType(ObjectType::PLAYER);
		const int otherBay = GetMyDockingPort(other);
		const bool otherIsLeaving = (other->GetAICommand() && other->GetAICommand()->GetType() == AICommand::CMD_DEPART) ||
			(otherBay >= 0 && SpaceStationType::IsUndockStage(m_shipDocking[otherBay].stage)) ||
			(otherVelInStation.Dot(corridorDir) > 4.0 && !(other->GetAICommand() && other->GetAICommand()->GetType() == AICommand::CMD_DOCK));
		const bool otherIsInbound = !otherIsLeaving;

		// CASE 1: Same-direction traffic (both leaving or both entering)
		if (isInbound == otherIsInbound) {
			// A vessel ahead along our direction of travel has right of way; NEVER stop or yield for a vessel behind us!
			const double axialAheadDist = isInbound ? (axialDist - otherAxialDist) : (otherAxialDist - axialDist);
			if (axialAheadDist <= 1.0 || axialAheadDist > 380.0)
				continue;

			// If identical axial distance within 2m, break tie deterministically by ship size then pointer
			if (axialAheadDist < 3.0 && mySize > otherSize)
				continue;

			const double minFollowDist = myRadius + otherRadius + 65.0;
			if (axialAheadDist < minFollowDist) {
				speedMultiplier = 0.0;
			} else if (axialAheadDist < minFollowDist + 100.0) {
				speedMultiplier = std::min(speedMultiplier, (axialAheadDist - minFollowDist) / 100.0);
			}

			// If we are smaller and close behind a larger ship, strafe out of its wake
			if (!myIsLarge && (otherIsLarge || otherSize > mySize * 1.25) && axialAheadDist < 140.0) {
				vector3d diffLat = myCurrentLateral - otherLateralVec;
				diffLat -= corridorDir * diffLat.Dot(corridorDir);
				vector3d sDir = (diffLat.LengthSqr() > 4.0) ? diffLat.NormalizedSafe() : (isInbound ? laneDir : -laneDir);
				double strafeMag = std::min(otherLateralDist + myRadius + otherRadius + 18.0, 42.0 - myRadius);
				if (strafeMag > maxStrafeNeeded) {
					maxStrafeNeeded = strafeMag;
					bestStrafeDir = sDir;
				}
			}
			continue;
		}

		// CASE 2: Opposite-direction traffic (one leaving, one entering)
		// Check if the other ship has already passed behind us:
		const double passMargin = myRadius + otherRadius + 25.0;
		const double axialSep = isInbound ? (axialDist - otherAxialDist) : (otherAxialDist - axialDist);
		if (axialSep < -passMargin || axialSep > 900.0)
			continue;

		// Determine Right-of-Way Hierarchy:
		// 1. Player priority (NPCs give way to player)
		// 2. Larger ships have right of way over smaller ships ("right of way for larger ships, smaller ships need to strafe out of way")
		// 3. Leaving ships have right of way over entering ships ("right of way for ships leaving")
		bool weMustYield = false;
		if (otherIsPlayer) {
			weMustYield = true;
		} else if (otherIsLarge && !myIsLarge) {
			weMustYield = true;
		} else if (myIsLarge && !otherIsLarge) {
			weMustYield = false;
		} else if (otherSize > mySize * 1.30 + 3.0) {
			weMustYield = true;
		} else if (mySize > otherSize * 1.30 + 3.0) {
			weMustYield = false;
		} else {
			// Comparable size: leaving ship has right of way over entering ship!
			weMustYield = isInbound;
		}

		if (!weMustYield) {
			// We have right of way! Continue along our primary path.
			continue;
		}

		// We must give way and strafe out of the way!
		vector3d diffLat = myCurrentLateral - otherLateralVec;
		diffLat -= corridorDir * diffLat.Dot(corridorDir);
		vector3d sDir = (diffLat.LengthSqr() > 4.0) ? diffLat.NormalizedSafe() : (isInbound ? laneDir : -laneDir);

		const double neededClearance = otherLateralDist + myRadius + otherRadius + 22.0;
		double allowedStrafe = neededClearance;
		if (axialDist > 70.0) {
			// Outside the station entrance in open space: strafe wide out of the corridor
			allowedStrafe = Clamp(neededClearance, 60.0, 110.0);
		} else if (axialDist < -50.0) {
			// Inside the wide station interior cylinder: strafe toward cylinder side
			const double maxInterior = std::max(22.0, 75.0 - myRadius);
			allowedStrafe = Clamp(neededClearance, 35.0, maxInterior);
		} else {
			// Inside the airlock doorway throat: strafe to doorway edge without hitting the wall
			const double maxDoorway = std::max(14.0, 44.0 - myRadius);
			allowedStrafe = std::min(neededClearance, maxDoorway);
		}

		if (allowedStrafe > maxStrafeNeeded) {
			maxStrafeNeeded = allowedStrafe;
			bestStrafeDir = sDir;
		}

		const double currentLateralSep = (myCurrentLateral - otherLateralVec).Length();
		const double safePassSep = myRadius + otherRadius + 14.0;

		if (isInbound && axialDist > 40.0) {
			// Inbound ship outside station: hold forward progress while strafing clear of the leaving/larger ship
			speedMultiplier = 0.0;
		} else if (!isInbound && axialDist < -40.0 && otherAxialDist <= 220.0 && otherAxialDist >= -120.0) {
			// Smaller leaving ship inside station yielding to a larger entering ship: hold at strafed offset inside until it passes
			speedMultiplier = 0.0;
		} else {
			// In the throat or passing: if lateral separation is not yet safe, hold forward motion while strafing; otherwise clear throat
			if (currentLateralSep < safePassSep && axialSep > 0.0) {
				speedMultiplier = 0.0;
			} else {
				speedMultiplier = std::min(speedMultiplier, 0.65);
			}
		}
	}

	if (maxStrafeNeeded > 0.0) {
		outDesiredLateralOffset = bestStrafeDir * maxStrafeNeeded;
	}

	return speedMultiplier;
}

bool SpaceStation::IsCorridorOccupied(const Ship *excludeShip) const
{
	if (excludeShip && excludeShip->IsType(ObjectType::PLAYER))
		return false;

	if (m_corridorShip && (m_corridorShip->IsDead() || m_corridorShip->GetFlightState() == Ship::HYPERSPACE ||
		m_corridorShip->GetFlightState() == Ship::DOCKED)) {
		const_cast<SpaceStation*>(this)->m_corridorShip = nullptr;
	}

	if (Pi::game && m_corridorShip) {
		const double now = Pi::game->GetTime();
		if (now > 0.0 && (now - m_lastLaunchTime) > 45.0) {
			const_cast<SpaceStation*>(this)->m_corridorShip = nullptr;
		}
	}

	// Ground stations use simple radial clearance
	if (IsGroundStation()) {
		if (!m_corridorShip || m_corridorShip == excludeShip) return false;
		const double dist = m_corridorShip->GetPositionRelTo(this).Length();
		if (dist > std::min(GetClipRadius() * 0.8 + 200.0, 450.0)) {
			const_cast<SpaceStation*>(this)->m_corridorShip = nullptr;
			return false;
		}
		return true;
	}

	// Orbital station live corridor & queue check:
	// 1. Check active docking or undocking animations inside the station cylinder
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		const shipDocking_t &dt = m_shipDocking[i];
		if (!dt.ship || dt.ship->IsDead() || dt.ship == excludeShip) continue;
		if (SpaceStationType::IsUndockStage(dt.stage) ||
			dt.stage == DockStage::DOCK_ANIMATION_1 ||
			dt.stage == DockStage::DOCK_ANIMATION_2) {
			return true;
		}
	}

	// 2. Scan live vessels in the station interior and external corridor
	if (Pi::game && Pi::game->GetSpace()) {
		vector3d portPos, corridorDir, laneDir;
		if (GetCorridorGeometry(portPos, corridorDir, laneDir)) {
			const matrix3x3d stOrient = GetOrient();
			const bool excludeIsDeparting = excludeShip && excludeShip->GetAICommand() && excludeShip->GetAICommand()->GetType() == AICommand::CMD_DEPART;
			const bool excludeIsLarge = excludeShip ? IsLargeCorridorShip(excludeShip) : false;
			const double excludeSize = excludeShip ? std::max(excludeShip->GetClipRadius(), excludeShip->GetShipType() ? double(excludeShip->GetShipType()->hullMass) * 0.12 : 0.0) : 0.0;
			const double excludeDist = excludeShip ? excludeShip->GetPositionRelTo(this).Length() : 0.0;

			Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(const_cast<SpaceStation*>(this), 2800.0);
			for (Body *b : nearby) {
				if (!b || b == excludeShip || !b->IsType(ObjectType::SHIP)) continue;
				Ship *other = static_cast<Ship*>(b);
				if (other->IsDead() || other->GetFlightState() == Ship::DOCKED ||
					other->GetFlightState() == Ship::HYPERSPACE || other->GetFlightState() == Ship::JUMPING)
					continue;

				const vector3d otherPosInStation = other->GetPositionRelTo(this) * stOrient;
				const double otherAxialDist = (otherPosInStation - portPos).Dot(corridorDir);
				const vector3d otherCenterPos = portPos + otherAxialDist * corridorDir;
				const double otherLateralDist = (otherPosInStation - otherCenterPos).Length();

				const bool otherIsDeparting = (other->GetAICommand() && other->GetAICommand()->GetType() == AICommand::CMD_DEPART);
				const bool otherIsDocking = (other->GetAICommand() && other->GetAICommand()->GetType() == AICommand::CMD_DOCK);

				// Right of way for ships leaving: any departing ship inside the station or within 1100m on the exit path
				// blocks inbound ships from leaving their APPROACH1 holding queue
				if (otherIsDeparting && otherAxialDist < 1100.0 && otherLateralDist < 130.0) {
					return true;
				}

				// Any ship currently inside the station interior cylinder blocks additional corridor entries
				if (IsInsideStation(other)) {
					return true;
				}

				if (!excludeIsDeparting && otherIsDocking) {
					// Strict 1-at-a-time inbound corridor queue:
					// If another inbound ship is already traversing the corridor inside 850m, wait at APPROACH1
					if (otherAxialDist < 850.0 && otherAxialDist > -200.0 && otherLateralDist < 130.0) {
						return true;
					}

					// Priority in the APPROACH1 holding queue: larger waiting ships have right of way over smaller waiting ships
					const double otherDist = other->GetPositionRelTo(this).Length();
					if (otherDist < 2600.0 && excludeDist > 1200.0) {
						const bool otherIsLarge = IsLargeCorridorShip(other);
						const double otherSize = std::max(other->GetClipRadius(), other->GetShipType() ? double(other->GetShipType()->hullMass) * 0.12 : 0.0);
						if ((otherIsLarge && !excludeIsLarge) || (otherSize > excludeSize * 1.30 + 3.0)) {
							return true;
						}
					}
				}
			}
		}
	}

	if (m_corridorShip && m_corridorShip != excludeShip) {
		const double dist = m_corridorShip->GetPositionRelTo(this).Length();
		const double clearDist = std::max(GetClipRadius() * 1.5 + 500.0, 2200.0);
		if (dist <= clearDist) {
			return true;
		}
		const_cast<SpaceStation*>(this)->m_corridorShip = nullptr;
	}

	return false;
}

bool SpaceStation::ClaimCorridor(Ship *ship)
{
	if (!ship) return false;
	if (IsCorridorOccupied(ship)) return false;

	m_corridorShip = ship;
	if (Pi::game) m_lastLaunchTime = Pi::game->GetTime();
	return true;
}

bool SpaceStation::CanLaunch(const Ship *ship) const
{
	if (!ship) return false;

	int bay = GetMyDockingPort(ship);
	if (bay == -1) return false;
	if (m_shipDocking[bay].stage != DockStage::DOCKED) return false;

	// The player always has priority and is never prevented from launching
	if (ship->IsType(ObjectType::PLAYER)) {
		return true;
	}

	if (IsPortLocked(bay)) return false;

	// Safety separation between consecutive launches to prevent departure overcrowding
	if (Pi::game) {
		const double now = Pi::game->GetTime();
		if (now > 0.0 && (now - m_lastLaunchTime) < MIN_LAUNCH_SEPARATION) {
			return false;
		}
	}

	if (IsGroundStation()) {
		return !IsCorridorOccupied(ship);
	}

	// Orbital station launch queue:
	// 1. Do not launch if another bay is currently running undock or dock animations inside the cylinder
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		const shipDocking_t &dt = m_shipDocking[i];
		if (!dt.ship || dt.ship->IsDead() || dt.ship == ship) continue;

		if (SpaceStationType::IsUndockStage(dt.stage) ||
			dt.stage == DockStage::DOCK_ANIMATION_1 ||
			dt.stage == DockStage::DOCK_ANIMATION_2) {
			return false;
		}
	}

	// 2. Check live ships inside the station and in the immediate doorway throat:
	// Leaving ships have right of way over inbound ships waiting at APPROACH1 (> 550m),
	// but must queue one-at-a-time behind preceding departing ships (< 650m) and yield to
	// any inbound ship already committed inside the final 550m doorway throat (or large inbound ship < 1200m).
	if (Pi::game && Pi::game->GetSpace()) {
		vector3d portPos, corridorDir, laneDir;
		if (GetCorridorGeometry(portPos, corridorDir, laneDir)) {
			const matrix3x3d stOrient = GetOrient();
			Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(const_cast<SpaceStation*>(this), 2000.0);
			for (Body *b : nearby) {
				if (!b || b == ship || !b->IsType(ObjectType::SHIP)) continue;
				Ship *other = static_cast<Ship*>(b);
				if (other->IsDead() || other->GetFlightState() == Ship::DOCKED ||
					other->GetFlightState() == Ship::HYPERSPACE || other->GetFlightState() == Ship::JUMPING)
					continue;

				if (IsInsideStation(other)) {
					return false;
				}

				const vector3d otherPosInStation = other->GetPositionRelTo(this) * stOrient;
				const double otherAxialDist = (otherPosInStation - portPos).Dot(corridorDir);
				const vector3d otherCenterPos = portPos + otherAxialDist * corridorDir;
				const double otherLateralDist = (otherPosInStation - otherCenterPos).Length();

				const bool otherIsDeparting = (other->GetAICommand() && other->GetAICommand()->GetType() == AICommand::CMD_DEPART);
				if (otherIsDeparting && otherAxialDist < 650.0 && otherLateralDist < 120.0) {
					return false; // Wait until previous departing ship is at least 650m outside
				}

				const double throatDist = IsLargeCorridorShip(other) ? 1100.0 : 550.0;
				if (!otherIsDeparting && otherAxialDist < throatDist && otherAxialDist > -150.0 && otherLateralDist < 90.0) {
					return false; // Inbound vessel already committed to doorway throat
				}
			}
		}
	}

	return true;
}

double SpaceStation::GetLaunchWaitTime() const
{
	double wait = 0.0;
	if (Pi::game) {
		const double now = Pi::game->GetTime();
		const double elapsed = now - m_lastLaunchTime;
		if (elapsed < MIN_LAUNCH_SEPARATION) {
			wait = MIN_LAUNCH_SEPARATION - elapsed;
		}
	}
	if (IsCorridorOccupied()) {
		if (m_corridorShip && !m_corridorShip->IsDead() && m_corridorShip->GetFlightState() != Ship::DOCKED) {
			const double dist = m_corridorShip->GetPositionRelTo(this).Length();
			const double clearDist = IsGroundStation() ? std::min(GetClipRadius() * 0.8 + 200.0, 450.0) : std::max(GetClipRadius() * 1.5 + 500.0, 2500.0);
			if (dist < clearDist) {
				const double corridorWait = std::max(3.0, (clearDist - dist) / 35.0);
				wait = std::max(wait, corridorWait);
			}
		}
	}
	if (m_type && m_type->IsOrbitalStation()) {
		for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
			const shipDocking_t &dt = m_shipDocking[i];
			if (dt.ship && !dt.ship->IsDead() && dt.stage == DockStage::DOCK_ANIMATION_1) {
				wait = std::max(wait, 8.0);
				break;
			}
		}
	}
	for (auto &bayIter : m_ports) {
		if (bayIter.inUse) {
			wait = std::max(wait, 6.0);
			break;
		}
	}
	return std::max(0.0, wait);
}

void SpaceStation::NotifyCorridorCleared(const Ship *ship)
{
	if (m_corridorShip == ship) {
		m_corridorShip = nullptr;
	}
}

bool SpaceStation::LaunchShip(Ship *ship, const int bay)
{
	if (!CanLaunch(ship)) return false;

	m_corridorShip = ship;
	if (Pi::game) m_lastLaunchTime = Pi::game->GetTime();

	if (ship->ManualDocking()) {
		// no one except the player can launch without the autopilot
		assert(ship->IsType(ObjectType::PLAYER));
		auto p = static_cast<Player*>(ship);
		p->DoFixspeedTakeoff(this);
		SwitchToStage(bay, DockStage::LEAVE);
		return true;
	}

	shipDocking_t &sd = m_shipDocking[bay];
	if (SpaceStationType::IsUndockStage(sd.stage)) return true; // already launching
	LockPort(bay, true);

	sd.ship = ship;
	sd.stagePos = 0.0;

	m_doorAnimationStep = 0.3; // open door

	sd.fromPos = (ship->GetPosition() - GetPosition()) * GetOrient(); // station space
	sd.fromRot = Quaterniond::FromMatrix3x3(GetOrient().Transpose() * ship->GetOrient());

	ship->SetFlightState(Ship::UNDOCKING);
	SwitchToStage(bay, DockStage::UNDOCK_BEGIN);

	return true;
}

void SpaceStation::TakeoverUndock(Ship *ship)
{
	if (!ship) return;
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		shipDocking_t &dt = m_shipDocking[i];
		if (dt.ship == ship && SpaceStationType::IsUndockStage(dt.stage)) {
			// Update the ship's position to its exact interpolated location right now
			PositionDockingShip(ship, i);

			// Match station rotational reference frame
			ship->SetAngVelocity(GetAngVelocity());
			const vector3d pPos = ship->GetPositionRelTo(this);
			const vector3d tangent = GetAngVelocity().Cross(pPos);
			const vector3d radial = ship->GetOrient().VectorY() * 1.5;
			ship->SetVelocity(GetVelocity() + tangent + radial);
			ship->ClearLinThrusterState();
			ship->ClearAngThrusterState();

			// Release ship to free flight
			ship->SetFlightState(Ship::FLYING);
			ship->ResetLaunchLockTimeout();

			if (ship->IsType(ObjectType::PLAYER)) {
				Player *p = static_cast<Player *>(ship);
				if (PlayerShipController *con = p->GetPlayerController()) {
					con->SetCruiseDirection(PlayerShipController::CRUISE_FWD);
					if (con->GetFlightControlState() != CONTROL_FIXSPEED) {
						con->SetFlightControlState(CONTROL_MANUAL);
					}
					if (!IsGroundStation()) {
						con->SetFollowTarget(this);
						con->SetFollowMode(PlayerShipController::FOLLOW_ORI);
					}
				}
			}

			// Free docking bay and trigger undocked event
			ship->OnUndocked(this, i);
			dt.ship = nullptr;
			dt.stagePos = 0;
			dt.maxOffset = 0;
			LockPort(i, false);

			// Keep airlock open if inside an orbital station cylinder
			if (m_type && m_type->IsOrbitalStation() && IsInsideStation(ship)) {
				m_doorAnimationStep = 0.3;
			} else {
				m_doorAnimationStep = -0.3;
			}

			SwitchToStage(i, DockStage::NONE);
			return;
		}
	}
}

// gets number of undocked ships within a given radius from the station
int SpaceStation::GetNearbyTraffic(double radius)
{
	int shipsNearby = 0;
	Space::BodyNearList traffic = Pi::game->GetSpace()->GetBodiesMaybeNear(this, radius);
	for (Body *body : traffic) {
		if (!body->IsType(ObjectType::SHIP)) continue;
		shipsNearby++;
	}
	return shipsNearby - NumShipsDocked();
}

bool SpaceStation::GetDockingClearance(Ship *s)
{
	assert(m_shipDocking.size() == m_type->NumDockingPorts());
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (m_shipDocking[i].ship == s) {
			LuaEvent::Queue("onDockingClearanceDenied", this, s,
				EnumStrings::GetString("DockingRefusedReason", int(DockingRefusedReason::ClearanceAlreadyGranted)));
			return (m_shipDocking[i].stage != DockStage::NONE); // grant docking only if the ship is not already docked/undocking
		}
	}

	const Aabb &bbox = s->GetAabb();
	const float bboxRad = vector2f(float(bbox.max.x), float(bbox.max.z)).Length();

	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		// initial unoccupied check
		if (m_shipDocking[i].ship != 0) continue;

		// size-of-ship vs size-of-bay check
		const SpaceStationType::SPort *const pPort = m_type->FindPortByBay(i);
		if (!pPort) continue;

		// distance-to-station check (covers 1,000 km Supercruise drop-in range plus buffer)
		const double shipDist = s->GetPositionRelTo(this).Length();
		double requestDist = SupercruiseController::SUBLIGHT_AUTOPILOT_MAX_DIST;
		if (s->IsType(ObjectType::PLAYER) && shipDist > requestDist) {
			LuaEvent::Queue("onDockingClearanceDenied", this, s,
				EnumStrings::GetString("DockingRefusedReason", int(DockingRefusedReason::TooFarFromStation)));
			return false;
		}

		if (pPort->minShipSize < bboxRad && bboxRad < pPort->maxShipSize) {
			shipDocking_t &sd = m_shipDocking[i];
			sd.ship = s;
			sd.stagePos = 0;
			sd.maxOffset = calculate_max_offset_squared(pPort->maxShipSize, bboxRad);
			LuaEvent::Queue("onDockingClearanceGranted", this, s);
			SwitchToStage(i, DockStage::CLEARANCE_GRANTED);
			return true;
		}
	}

	LuaEvent::Queue("onDockingClearanceDenied", this, s,
		EnumStrings::GetString("DockingRefusedReason", int(DockingRefusedReason::NoBaysAvailable)));
	return false;
}

bool SpaceStation::BeginOrbitalDockingSequence(Ship *s)
{
	if (!s || IsGroundStation() || s->IsDead()) return false;
	if (s->GetFlightState() != Ship::FLYING) return false;
	if (s->ManualDocking()) return false;
	if (s->GetAICommand() && s->GetAICommand()->GetType() == AICommand::CMD_DEPART) return false;

	int bay = -1;
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (m_shipDocking[i].ship == s) {
			bay = i;
			break;
		}
	}
	if (bay == -1 || IsPortLocked(bay) || m_shipDocking[bay].stage != DockStage::CLEARANCE_GRANTED) {
		return false;
	}

	shipDocking_t &sd = m_shipDocking[bay];
	sd.ship = s;
	sd.stagePos = 0;
	sd.fromPos = (s->GetPosition() - GetPosition()) * GetOrient(); // station space
	sd.fromRot = Quaterniond::FromMatrix3x3(GetOrient().Transpose() * s->GetOrient());

	s->SetFlightState(Ship::DOCKING);
	s->SetVelocity(vector3d(0.0));
	s->SetAngVelocity(vector3d(0.0));
	s->ClearThrusterState();

	SwitchToStage(bay, (m_type->NumUndockStages() == 0) ? DockStage::TOUCHDOWN : DockStage::DOCK_ANIMATION_1);
	return true;
}

bool SpaceStation::OnCollision(Body *b, Uint32 flags, double relVel)
{
	if (!b->IsType(ObjectType::SHIP)) return true;
	Ship *s = static_cast<Ship *>(b);

	std::string surface = "Station Superstructure Hull";
	if (flags & SceneGraph::CollisionGeometry::DOCKING)
		surface = "Station Docking Bay Pad Surface";
	else if (flags & SceneGraph::CollisionGeometry::ENTRANCE)
		surface = "Station Airlock Mail Slot";

	s->RecordCollision(this, surface, relVel);

	// Entrance / mail slot airlock is an open doorway with NO physical barrier.
	// If an inbound autopilot ship with CLEARANCE_GRANTED reaches the entrance trigger,
	// transition it into the interior docking sequence; never bounce or damage any ship on ENTRANCE.
	if (flags & SceneGraph::CollisionGeometry::ENTRANCE) {
		BeginOrbitalDockingSequence(s);
		return false;
	}

	bool touchOrbitalPad = (flags & SceneGraph::CollisionGeometry::DOCKING) && !IsGroundStation();

	int bay = -1;
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if (m_shipDocking[i].ship == s) {
			bay = i;
			break;
		}
	}

	bool bayUnavailable = bay == -1 || IsPortLocked(bay) || m_shipDocking[bay].stage == DockStage::NONE;
	if (bayUnavailable) {
		return DoShipDamage(s, flags, relVel);
	}

	if (IsGroundStation() || touchOrbitalPad) {
		// must be oriented sensibly and have wheels down
		matrix4x4d bayTrans = GetBayTransform(bay);

		vector3d dockingNormal = bayTrans.Up();
		const double dot = s->GetOrient().VectorY().Dot(dockingNormal);
		if ((dot < 0.99) || (s->GetWheelState() < 1.0))
		{
			return DoShipDamage(s, flags, relVel); // <0.99 harsh?
		}
		// check speed
		if (s->GetVelocity().Length() > MAX_LANDING_SPEED)
		{
			return DoShipDamage(s, flags, relVel);
		}
		// check if you're near your pad
		float dist = (s->GetPosition() - bayTrans.GetTranslate()).LengthSqr();
		// docking allowed only if inside a circle 70% greater than pad itself (*1.7)
		float maxDist = static_cast<float>(m_type->FindPortByBay(bay)->maxShipSize / 2) * 1.7;
		if (dist > (maxDist * maxDist))
		{
			return DoShipDamage(s, flags, relVel);
		}
	}

	// docking is in progress
	if (s->GetFlightState() == Ship::DOCKING) return false;

	// launch docking
	// set up a control structure
	// from now on, the location of the ship will be set by the station using this data
	shipDocking_t &sd = m_shipDocking[bay];
	sd.ship = s;
	sd.stagePos = 0;
	// capture the current location of the ship
	sd.fromPos = (s->GetPosition() - GetPosition()) * GetOrient(); // station space
	sd.fromRot = Quaterniond::FromMatrix3x3(GetOrient().Transpose() * s->GetOrient());
	// prepare the ship for passive existence
	s->SetFlightState(Ship::DOCKING);
	s->SetVelocity(vector3d(0.0));
	s->SetAngVelocity(vector3d(0.0));
	s->ClearThrusterState();

	SwitchToStage(bay, (touchOrbitalPad || m_type->NumUndockStages() == 0) ? DockStage::TOUCHDOWN : DockStage::DOCK_ANIMATION_1);

	return false;
}

bool SpaceStation::DoShipDamage(Ship *s, Uint32 flags, double relVel)
{
	if (s == nullptr) return false;
	s->DynamicBody::OnCollision(this, flags, relVel);
	return true;
}

void SpaceStation::SwitchToStage(Uint32 bay, DockStage stage)
{
	shipDocking_t &dt = m_shipDocking[bay];

	switch (stage) {

	case DockStage::TOUCHDOWN: {
		dt.ship->ClearThrusterState();
		// remember the position of the ship relative to the pad
		matrix4x4d padSpace = GetBayTransform(bay);
		padSpace.Translate(0.0, -dt.ship->GetLandingPosOffset(), 0.0);
		padSpace = padSpace.Inverse();
		matrix3x3d shipToPadOrient = padSpace.GetOrient() * dt.ship->GetOrient();
		// the position of the ship relative to the pad will be saved here
		// all subsequent stages will use this
		dt.fromRot = Quaterniond::FromMatrix3x3(shipToPadOrient);
		dt.fromPos = padSpace * dt.ship->GetPosition();

		SwitchToStage(bay, DockStage::LEVELING);
		break;
	}

	// if we want to generate a docking event
	case DockStage::JUST_DOCK: {
		dt.ship->OnDocked(this, bay);
		m_doorAnimationStep = -0.3; // close door
		dt.ship->SetDockedWith(this, bay);
		break;
	}

	case DockStage::UNDOCK_BEGIN: {
		if (m_type->NumUndockStages() > 0) {
			SwitchToStage(bay, DockStage::UNDOCK_ANIMATION_1);
		} else {
			SwitchToStage(bay, DockStage::UNDOCK_END);
		}
		break;
	}

	case DockStage::UNDOCK_END:
		dt.ship->SetAngVelocity(GetAngVelocity());
		if (m_type->IsSurfaceStation()) {
			dt.ship->SetThrusterState(1, 1.0); // up
		} else if (dt.ship->IsType(ObjectType::PLAYER)) {
			dt.ship->SetThrusterState(2, -1.0); // forward
		} else {
			dt.ship->SetVelocity(GetVelocity());
			dt.ship->ClearThrusterState();
		}
		dt.ship->SetFlightState(Ship::FLYING);
		SwitchToStage(bay, DockStage::LEAVE);
		break;

	case DockStage::LEAVE:
		dt.ship->OnUndocked(this, bay);
		if (!dt.ship->IsType(ObjectType::PLAYER)) {
			dt.ship->AIDepart(this);
		}
		dt.ship = nullptr;
		dt.stagePos = 0;
		dt.maxOffset = 0;
		LockPort(bay, false);
		m_doorAnimationStep = -0.3; // close door
		SwitchToStage(bay, DockStage::NONE);
		break;

	case DockStage::CLEARANCE_GRANTED:
		m_doorAnimationStep = 0.3; // open door
		dt.stage = stage;
		break;

	default:
		dt.stage = stage;
		break;
	}
}

void SpaceStation::DockingUpdate(const double timeStep)
{
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		shipDocking_t &dt = m_shipDocking[i];
		if (!dt.ship) continue;

		switch (dt.stage) {

		case DockStage::LEVELING: // aligning the ship with the plane of the pad
			if (!LevelShip(dt.ship, i, timeStep)) continue;
			SwitchToStage(i, DockStage::REPOSITION);
			continue;

		case DockStage::REPOSITION:
			// moving the ship if it is displaced too much
			// until it is not displaced too much
			// the ship should already be correctly aligned with the wheels with the pad
			if (dt.fromPos.LengthSqr() > dt.maxOffset) {
				const float MOVE_PER_FRAME = 0.1; // meter per frame
				// with perfect alignmend fromPos is zero
				dt.fromPos -= dt.fromPos.Normalized() * MOVE_PER_FRAME;
			} else {
				SwitchToStage(i, DockStage::JUST_DOCK);
			}
			continue;

		case DockStage::DOCKED:
			continue;

		case DockStage::HANGAR_STOWING: {
			const double depth = (dt.hangarDepth > 1.0f) ? double(dt.hangarDepth) : GetHangarElevatorDepth(dt.ship);
			dt.stagePos += timeStep / HANGAR_ELEVATOR_DURATION;
			const double t = Clamp(dt.stagePos, 0.0, 1.0);
			const double seatedLift = 0.16;
			double elevY;
			if (t < 0.14) {
				elevY = seatedLift * AnimationCurves::InOutSineEasing(t / 0.14);
			} else if (t < 0.72) {
				const double u = (t - 0.14) / 0.58;
				const double eased = AnimationCurves::InOutSineEasing(u);
				elevY = seatedLift - (depth + seatedLift) * eased;
			} else {
				elevY = -depth;
			}
			dt.fromPos = vector3d(0.0, elevY, 0.0);
			PositionDockedShip(dt.ship, i);
			if (dt.stagePos >= 1.0) {
				Ship *stowedShip = dt.ship;
				dt.ship = nullptr;
				dt.stagePos = 0.0;
				dt.fromPos = vector3d::Zero;
				dt.maxOffset = 0;
				LockPort(i, false);
				SwitchToStage(i, DockStage::NONE);
				LuaEvent::Queue("onShipStowedInHangar", this, stowedShip);
				if (Pi::game && Pi::game->GetSpace()) {
					Pi::game->GetSpace()->KillBody(stowedShip);
				}
			}
			continue;
		}

		case DockStage::HANGAR_UNSTOWING: {
			const double depth = (dt.hangarDepth > 1.0f) ? double(dt.hangarDepth) : GetHangarElevatorDepth(dt.ship);
			dt.stagePos += timeStep / HANGAR_ELEVATOR_DURATION;
			const double t = Clamp(dt.stagePos, 0.0, 1.0);
			const double seatedLift = 0.16;
			double elevY;
			if (t < 0.30) {
				elevY = -depth;
			} else if (t < 0.88) {
				const double u = (t - 0.30) / 0.58;
				const double eased = AnimationCurves::InOutSineEasing(u);
				elevY = -depth + (depth + seatedLift) * eased;
			} else {
				const double u = (t - 0.88) / 0.12;
				elevY = seatedLift * (1.0 - AnimationCurves::InOutSineEasing(u));
			}
			dt.fromPos = vector3d(0.0, elevY, 0.0);
			PositionDockedShip(dt.ship, i);
			if (dt.stagePos >= 1.0) {
				dt.stagePos = 0.0;
				dt.fromPos = vector3d::Zero;
				SwitchToStage(i, DockStage::DOCKED);
				PositionDockedShip(dt.ship, i);
				LuaEvent::Queue("onShipUnstowedFromHangar", this, dt.ship);
			}
			continue;
		}

		case DockStage::CLEARANCE_GRANTED: // waiting for collision
			if (dt.stagePos >= 1.0) {
				LuaEvent::Queue("onDockingClearanceExpired", this, dt.ship);
				dt.ship = nullptr;
				m_doorAnimationStep = -0.3; // close door
				SwitchToStage(i, DockStage::NONE);
			}
			dt.stagePos += timeStep / DOCKING_CLEARANCE_TIMEOUT;
			continue;

		default:
			break;
		}

		// by default docking or undocking animation occurs

		// next animation step
		double stageDuration = SpaceStationType::IsDockStage(dt.stage) ?
			GetDockAnimStageDuration(i, dt.stage) :
			GetUndockAnimStageDuration(i, dt.stage);
		dt.stagePos += timeStep / stageDuration;

		// next animation stage
		if (dt.stagePos > 1.0) {

			// overrun due to too much time acceleration?
			if (dt.stagePos > 1.05) {
				dt.stagePos = 1.0;
				PositionDockingShip(dt.ship, i);
			}

			// transition between docking stages
			dt.stagePos = 0;
			if (dt.stage == m_type->LastDockStage()) {
				// end dock animation
				SwitchToStage(i, DockStage::TOUCHDOWN);
				continue;
			} else if (dt.stage == m_type->LastUndockStage()) {
				// end undock animation
				SwitchToStage(i, DockStage::UNDOCK_END);
				continue;
			} else {
				dt.fromPos = (dt.ship->GetPosition() - GetPosition()) * GetOrient();
				dt.fromRot = Quaterniond::FromMatrix3x3(GetOrient().Transpose() * dt.ship->GetOrient());
				// continue dock or undock animation
				SwitchToStage(i, SpaceStationType::NextAnimStage(dt.stage));
				continue;
			}
		}
	}

	m_doorAnimationState = Clamp(m_doorAnimationState + m_doorAnimationStep * timeStep, 0.0, 1.0);
	if (m_doorAnimation)
		m_doorAnimation->SetProgress(m_doorAnimationState);
}

bool SpaceStation::LevelShip(Ship *ship, int bay, const float timeStep)
{
	shipDocking_t &dt = m_shipDocking[bay];

	auto shipOrient = dt.fromRot.ToMatrix3x3<double>();
	vector3d dist = dt.fromPos;
	vector3d dockingNormal(0.0, 1.0, 0.0);

	double cosUp = dockingNormal.Dot(shipOrient.VectorY());
	if (cosUp < 0.999999) {
		// need level ship
		double angle;
		if (cosUp < 0.985)
			angle = -0.8 * timeStep;
		else
			angle = -acos(cosUp);
		vector3d rotAxis = dockingNormal.Cross(shipOrient.VectorY());
		rotAxis = rotAxis.NormalizedSafe();

		Quaterniond rot(angle, rotAxis);
		dt.fromRot = (rot * dt.fromRot).Normalized();
	}
	if (fabs(dist.y) > 0.01) {
		dt.fromPos.y = 0.0;
	}
	return (cosUp >= 0.999999) && (fabs(dist.y) < 0.01);
}

void SpaceStation::PositionDockingShip(Ship *ship, int bay) const
{
	const shipDocking_t &dt = m_shipDocking[bay];
	DockStage pStage = m_type->PivotStage(dt.stage);
	// the position of the ship at this stage is not controlled by the station
	if (pStage == DockStage::NONE) return;
	if (pStage == DockStage::MANUAL) {
		// at these stages the ship has already touched the pad,
		// so it is positioned based on dt.fromPos
		PositionDockedShip(ship, bay);
		return;
	}

	auto stageTrans = matrix4x4d(m_type->GetStageTransform(bay, pStage));

	// the last stage of the docking animation should take into account the
	// displacement of the center of the ship
	if (dt.stage == m_type->LastDockStage()) {
		stageTrans.Translate(0.0, -dt.ship->GetLandingPosOffset(), 0.0);
	}

	float ratio = pStage == DockStage::DOCK_ANIMATION_1 ?
		AnimationCurves::  OutSineEasing(dt.stagePos):
		AnimationCurves::InOutSineEasing(dt.stagePos);

	vector3d interPos = MathUtil::mix<vector3d, double>(dt.fromPos, stageTrans.GetTranslate(), ratio);

	ship->SetPosition(GetPosition() + GetOrient() * interPos);
	// use quaternion spherical linear interpolation to do
	// rotation smoothly
	Quaterniond wantQuat = Quaterniond::FromMatrix3x3(stageTrans.GetOrient());
	// use Slerp so that the turn takes the smallest path
	Quaterniond q = Quaterniond::Slerp(dt.fromRot, wantQuat, AnimationCurves::InOutSineEasing(dt.stagePos));
	ship->SetOrient(GetOrient() * q.ToMatrix3x3<double>());
}

void SpaceStation::PositionDockedShip(Ship *ship, int bay) const
{
	const shipDocking_t &dt = m_shipDocking[bay];
	// pad placement in the world:
	auto padTrans = GetBayTransform(bay);
	// ship center height
	padTrans.Translate(0.0, -ship->GetLandingPosOffset(), 0.0);

	ship->SetPosition(padTrans * dt.fromPos);
	ship->SetOrient(padTrans.GetOrient() * dt.fromRot.ToMatrix3x3<double>());
}

void SpaceStation::StaticUpdate(const float timeStep)
{
	DockingUpdate(timeStep);
	m_navLights->Update(timeStep);
}

void SpaceStation::TimeStepUpdate(const float timeStep)
{
	// rotate the thing
	double len = m_type->AngVel() * timeStep;
	if (!is_zero_exact(len)) {
		matrix3x3d r = matrix3x3d::RotateY(-len); // RotateY is backwards
		SetOrient(r * GetOrient());
	}
	m_oldAngDisplacement = len;

	// reposition the ships that are docked or docking here
	const unsigned int numPorts = std::min(static_cast<unsigned int>(m_shipDocking.size()), m_type->NumDockingPorts());
	for (unsigned int i = 0; i < numPorts; i++) {
		const shipDocking_t &dt = m_shipDocking[i];
		if (!dt.ship) { //free
			m_navLights->SetColor(i + 1, NavLights::NAVLIGHT_OFF);
			continue;
		}
		if (SpaceStationType::IsDockStage(dt.stage)) {
			m_navLights->SetColor(i + 1, NavLights::NAVLIGHT_GREEN);
			m_navLights->SetMask(i + 1, 0x33); // 00110011 on two off two
		}
		if (SpaceStationType::IsUndockStage(dt.stage)) { // undocking anim
			m_navLights->SetColor(i + 1, NavLights::NAVLIGHT_YELLOW);
		}
		if (dt.stage == DockStage::JUST_DOCK) { // just docked
			m_navLights->SetColor(i + 1, NavLights::NAVLIGHT_BLUE);
			m_navLights->SetMask(i + 1, 0xf6); // 11110110
		} else if (dt.stage == DockStage::HANGAR_STOWING) {
			m_navLights->SetColor(i + 1, NavLights::NAVLIGHT_BLUE);
			m_navLights->SetMask(i + 1, 0x55);
		} else if (dt.stage == DockStage::HANGAR_UNSTOWING) {
			m_navLights->SetColor(i + 1, NavLights::NAVLIGHT_YELLOW);
			m_navLights->SetMask(i + 1, 0x55);
		}
		if ((dt.ship->GetFlightState() == Ship::DOCKED) &&
			(dt.stage == DockStage::DOCKED || dt.stage == DockStage::HANGAR_STOWING || dt.stage == DockStage::HANGAR_UNSTOWING)) { //docked or riding pad elevator
			PositionDockedShip(dt.ship, i);
		} else if (dt.ship->GetFlightState() == Ship::DOCKING || dt.ship->GetFlightState() == Ship::UNDOCKING) {
			PositionDockingShip(dt.ship, i);
		}
	}

	if (m_corridorShip) {
		const double clearDist = IsGroundStation() ? std::min(GetClipRadius() * 0.8 + 200.0, 450.0) : std::max(GetClipRadius() * 1.5 + 500.0, 2500.0);
		const double elapsed = Pi::game ? (Pi::game->GetTime() - m_lastLaunchTime) : 0.0;
		bool insideAndInbound = false;
		if (m_type && m_type->IsOrbitalStation()) {
			bool isDeparting = (m_corridorShip->GetAICommand() && m_corridorShip->GetAICommand()->GetType() == AICommand::CMD_DEPART);
			if (!isDeparting) {
				vector3d pPos, cDir, lDir;
				if (GetCorridorGeometry(pPos, cDir, lDir)) {
					const vector3d relPos = m_corridorShip->GetPositionRelTo(this) * GetOrient();
					const double axDist = (relPos - pPos).Dot(cDir);
					const double clearInteriorDist = IsLargeCorridorShip(m_corridorShip) ? -120.0 : -60.0;
					if (axDist <= clearInteriorDist) {
						insideAndInbound = true;
					}
				} else if (IsInsideStation(m_corridorShip)) {
					insideAndInbound = true;
				}
			}
		}

		if (m_corridorShip->IsDead() || m_corridorShip->GetFlightState() == Ship::HYPERSPACE ||
			m_corridorShip->GetFlightState() == Ship::DOCKED || elapsed > 45.0 ||
			insideAndInbound || m_corridorShip->GetPositionRelTo(this).Length() > clearDist) {
			m_corridorShip = nullptr;
		}
	}

	// Any NPC ship that finds itself inside an orbital space station without docking orders
	// should immediately exit by recentering on the axis and exiting through the airlock.
	if (m_type && m_type->IsOrbitalStation() && Pi::game && Pi::game->GetSpace()) {
		Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(this, GetClipRadius() * 1.5);
		for (Body *b : nearby) {
			if (!b || !b->IsType(ObjectType::SHIP)) continue;
			Ship *s = static_cast<Ship *>(b);
			if (s->IsDead() || s->IsType(ObjectType::PLAYER)) continue;
			if (s->GetFlightState() != Ship::FLYING) continue;

			if (IsInsideStation(s)) {
				int bay = GetMyDockingPort(s);
				bool hasDockingClearance = (bay != -1 && !IsPortLocked(bay) && m_shipDocking[bay].stage != DockStage::NONE);
				bool isDeparting = (s->GetAICommand() && s->GetAICommand()->GetType() == AICommand::CMD_DEPART);

				if (!hasDockingClearance && !isDeparting) {
					s->AIDepart(this);
				}
			}
		}

		// Also verify that no NPC ship is idling or stranded without orders (CMD_NONE)
		// directly in the exterior approach/departure corridor cylinder outside the mail slot:
		vector3d pPos, cDir, lDir;
		if (GetCorridorGeometry(pPos, cDir, lDir)) {
			Space::BodyNearList corridorNearby = Pi::game->GetSpace()->GetBodiesMaybeNear(this, 5000.0);
			for (Body *b : corridorNearby) {
				if (!b || !b->IsType(ObjectType::SHIP)) continue;
				Ship *s = static_cast<Ship *>(b);
				if (s->IsDead() || s->IsType(ObjectType::PLAYER)) continue;
				if (s->GetFlightState() != Ship::FLYING) continue;

				const vector3d relPosInSt = s->GetPositionRelTo(this) * GetOrient();
				const double axDist = (relPosInSt - pPos).Dot(cDir);
				const vector3d latVec = relPosInSt - (pPos + axDist * cDir);
				const double latDist = latVec.Length();

				if (axDist > 0.0 && axDist < 4500.0 && latDist < 250.0) {
					const AICommand *cmd = s->GetAICommand();
					if (!cmd || cmd->GetType() == AICommand::CMD_NONE) {
						s->AIOrbit(this, 2.0);
					}
				}
			}
		}
	}

	ModelBody::TimeStepUpdate(timeStep);
}

void SpaceStation::UpdateInterpTransform(double alpha)
{
	double len = m_oldAngDisplacement * (1.0 - alpha);
	if (!is_zero_exact(len)) {
		matrix3x3d rot = matrix3x3d::RotateY(len); // RotateY is backwards
		m_interpOrient = rot * GetOrient();
	} else
		m_interpOrient = GetOrient();
	m_interpPos = GetPosition();
}

bool SpaceStation::IsGroundStation() const
{
	return m_type->IsSurfaceStation();
}

bool SpaceStation::IsInsideStation(const Body *b) const
{
	if (!b || !m_type || !m_type->IsOrbitalStation()) return false;

	// Position relative to station in station local coordinates:
	const vector3d relPos = b->GetPositionRelTo(this);
	const vector3d posInStation = relPos * GetOrient();

	SpaceStationType::positionOrient_t portPosOrient;
	SpaceStationType::positionOrient_t clearPosOrient;
	if (!m_type->GetShipApproachWaypoints(0, DockStage::APPROACH2, portPosOrient) ||
		!m_type->GetShipApproachWaypoints(0, DockStage::APPROACH1, clearPosOrient)) {
		return false;
	}

	const vector3d portPos = portPosOrient.pos;
	const vector3d corridorDir = (clearPosOrient.pos - portPosOrient.pos).NormalizedSafe();

	// Axial distance along the corridor from the entrance mail slot:
	// Negative = inside the station interior cylinder
	// Positive = outside the station in open space
	const double axialDist = (posInStation - portPos).Dot(corridorDir);

	// Perpendicular distance from the station central cylinder axis:
	const vector3d axisPoint = portPos + axialDist * corridorDir;
	const double offAxisDist = (posInStation - axisPoint).Length();

	// Inside station condition:
	// Ship is on the interior side of the mail slot (axialDist <= 10.0m margin),
	// within the longitudinal depth of the docking cylinder (axialDist >= -1200.0m),
	// and within the cylinder diameter (offAxisDist <= 200.0m).
	if (axialDist <= 10.0 && axialDist >= -1200.0 && offAxisDist <= 200.0) {
		return true;
	}

	return false;
}

// Renders space station and adjacent city if applicable
static const double SQRMAXCITYDIST = 1e5 * 1e5;

void SpaceStation::Render(Graphics::Renderer *r, const Camera *camera, const vector3d &viewCoords, const matrix4x4d &viewTransform)
{
	Frame *frame = Frame::GetFrame(GetFrame());
	if (!frame) return;
	Body *b = frame->GetBody();
	if (!b) return;

	if (!b->IsType(ObjectType::PLANET)) {
		// orbital spaceport -- don't make city turds or change lighting based on atmosphere
		RenderModel(r, camera, viewCoords, viewTransform);
		RenderHangarBays(r, viewCoords, viewTransform);
		m_navLights->Render(r);
		r->GetStats().AddToStatCount(Graphics::Stats::STAT_SPACESTATIONS, 1);
	} else {
		// don't render city if too far away
		if (viewCoords.LengthSqr() >= SQRMAXCITYDIST) {
			return;
		}

		if (!m_adjacentCity) {
			m_adjacentCity = new CityOnPlanet(static_cast<Planet *>(b), this, m_sbody->GetSeed());
			// Update clipping radius
			SetClipRadius(m_adjacentCity->GetClipRadius());
		}

		m_adjacentCity->Render(r, camera->GetContext(), this, viewCoords, viewTransform);

		RenderModel(r, camera, viewCoords, viewTransform);
		RenderHangarBays(r, viewCoords, viewTransform);
		m_navLights->Render(r);

		r->GetStats().AddToStatCount(Graphics::Stats::STAT_GROUNDSTATIONS, 1);
	}
}

namespace {
	void AppendBayQuad(Graphics::VertexArray &va,
		const vector3f &p0, const vector3f &p1, const vector3f &p2, const vector3f &p3,
		const Color &c0, const Color &c1, const Color &c2, const Color &c3)
	{
		va.Add(p0, c0);
		va.Add(p1, c1);
		va.Add(p2, c2);
		va.Add(p0, c0);
		va.Add(p2, c2);
		va.Add(p3, c3);
	}

	void AppendBayQuadFlat(Graphics::VertexArray &va,
		const vector3f &p0, const vector3f &p1, const vector3f &p2, const vector3f &p3,
		const Color &c)
	{
		AppendBayQuad(va, p0, p1, p2, p3, c, c, c, c);
	}

	void AppendBayBox(Graphics::VertexArray &va,
		float x0, float x1, float y0, float y1, float z0, float z1,
		const Color &topCol, const Color &sideXCol, const Color &sideZCol)
	{
		// Top (+Y)
		AppendBayQuadFlat(va,
			vector3f(x0, y1, z0), vector3f(x1, y1, z0),
			vector3f(x1, y1, z1), vector3f(x0, y1, z1), topCol);
		// Front (+Z) & Back (-Z)
		AppendBayQuadFlat(va,
			vector3f(x0, y0, z1), vector3f(x1, y0, z1),
			vector3f(x1, y1, z1), vector3f(x0, y1, z1), sideZCol);
		AppendBayQuadFlat(va,
			vector3f(x1, y0, z0), vector3f(x0, y0, z0),
			vector3f(x0, y1, z0), vector3f(x1, y1, z0), sideZCol);
		// Left (-X) & Right (+X)
		AppendBayQuadFlat(va,
			vector3f(x0, y0, z0), vector3f(x0, y0, z1),
			vector3f(x0, y1, z1), vector3f(x0, y1, z0), sideXCol);
		AppendBayQuadFlat(va,
			vector3f(x1, y0, z1), vector3f(x1, y0, z0),
			vector3f(x1, y1, z0), vector3f(x1, y1, z1), sideXCol);
	}
} // namespace

void SpaceStation::RenderHangarBays(Graphics::Renderer *r, const vector3d &viewCoords, const matrix4x4d &viewTransform)
{
	if (!r || !m_type || m_shipDocking.empty())
		return;
	if (viewCoords.LengthSqr() > 4000.0 * 4000.0)
		return;

	bool hasActiveBay = false;
	for (Uint32 i = 0; i < m_shipDocking.size(); ++i) {
		const shipDocking_t &dt = m_shipDocking[i];
		if (dt.ship && (dt.stage == DockStage::HANGAR_STOWING || dt.stage == DockStage::HANGAR_UNSTOWING)) {
			hasActiveBay = true;
			break;
		}
	}
	if (!hasActiveBay)
		return;

	if (!m_hangarSolidMat.Valid()) {
		Graphics::MaterialDescriptor desc;
		Graphics::RenderStateDesc rsd;
		rsd.blendMode = Graphics::BLEND_SOLID;
		rsd.cullMode = Graphics::CULL_NONE;
		rsd.primitiveType = Graphics::TRIANGLES;
		rsd.depthTest = true;
		rsd.depthWrite = true;
		const auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
		m_hangarSolidMat.Reset(r->CreateMaterial("vtxColor", desc, rsd, vfmt));
	}
	if (!m_hangarGlowMat.Valid()) {
		Graphics::MaterialDescriptor desc;
		Graphics::RenderStateDesc rsd;
		rsd.blendMode = Graphics::BLEND_ADDITIVE;
		rsd.cullMode = Graphics::CULL_NONE;
		rsd.primitiveType = Graphics::TRIANGLES;
		rsd.depthTest = true;
		rsd.depthWrite = false;
		const auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
		m_hangarGlowMat.Reset(r->CreateMaterial("vtxColor", desc, rsd, vfmt));
	}

	const double now = Pi::game ? Pi::game->GetTime() : 0.0;
	const float pulse = 0.45f + 0.55f * float(0.5 + 0.5 * std::sin(now * 8.5));
	const matrix4x4f stationView = matrix4x4f(viewTransform * GetInterpMatrix());

	Graphics::VertexArray solidVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
	Graphics::VertexArray glowVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);

	for (Uint32 i = 0; i < m_shipDocking.size(); ++i) {
		const shipDocking_t &dt = m_shipDocking[i];
		if (!dt.ship)
			continue;
		if (dt.stage != DockStage::HANGAR_STOWING && dt.stage != DockStage::HANGAR_UNSTOWING)
			continue;

		const float t = float(Clamp(dt.stagePos, 0.0, 1.0));
		const float halfX = (dt.hangarHalfX > 1.0f) ? dt.hangarHalfX : 11.0f;
		const float halfZ = (dt.hangarHalfZ > 1.0f) ? dt.hangarHalfZ : 13.0f;
		const float rimW = 1.15f;

		float collarDeploy = 1.0f;
		float openFrac = 1.0f;
		float clampScale = 1.0f;
		bool lockReady = false;

		if (dt.stage == DockStage::HANGAR_STOWING) {
			if (t < 0.14f) {
				collarDeploy = float(AnimationCurves::InOutSineEasing(t / 0.14f));
				openFrac = 1.0f;
			} else if (t < 0.72f) {
				collarDeploy = 1.0f;
				openFrac = 1.0f;
			} else if (t < 0.94f) {
				collarDeploy = 1.0f;
				openFrac = 1.0f - float(AnimationCurves::InOutSineEasing((t - 0.72f) / 0.22f));
			} else {
				collarDeploy = 1.0f - float(AnimationCurves::InOutSineEasing((t - 0.94f) / 0.06f));
				openFrac = 0.0f;
			}
		} else {
			if (t < 0.08f) {
				collarDeploy = float(AnimationCurves::InOutSineEasing(t / 0.08f));
				openFrac = 0.0f;
			} else if (t < 0.30f) {
				collarDeploy = 1.0f;
				openFrac = float(AnimationCurves::InOutSineEasing((t - 0.08f) / 0.22f));
			} else if (t < 0.88f) {
				collarDeploy = 1.0f;
				openFrac = 1.0f;
			} else {
				const float u = float(AnimationCurves::InOutSineEasing((t - 0.88f) / 0.12f));
				collarDeploy = 1.0f - u;
				clampScale = 1.0f - u;
				openFrac = 1.0f;
				lockReady = true;
			}
		}

		solidVerts.Clear();
		glowVerts.Clear();

		// 1. Dark illuminated hangar shaft aperture when blast doors are open
		if (openFrac > 0.02f) {
			const float shaftY = 0.06f;
			const float innerX = std::max(2.0f, halfX - 1.15f);
			const float innerZ = std::max(2.0f, halfZ - 1.15f);
			const Color deepCore(5, 7, 11, 255);
			const Color innerRim(36, 20, 10, 255);
			const Color outerRim(155, 82, 22, 255);

			AppendBayQuadFlat(solidVerts,
				vector3f(-innerX, shaftY, -innerZ), vector3f(innerX, shaftY, -innerZ),
				vector3f(innerX, shaftY, innerZ), vector3f(-innerX, shaftY, innerZ), deepCore);
			// 4 mitered warm-lit shaft perimeter strips
			AppendBayQuad(solidVerts,
				vector3f(-halfX, shaftY, -halfZ), vector3f(halfX, shaftY, -halfZ),
				vector3f(innerX, shaftY, -innerZ), vector3f(-innerX, shaftY, -innerZ),
				outerRim, outerRim, innerRim, innerRim);
			AppendBayQuad(solidVerts,
				vector3f(innerX, shaftY, innerZ), vector3f(-innerX, shaftY, innerZ),
				vector3f(-halfX, shaftY, halfZ), vector3f(halfX, shaftY, halfZ),
				innerRim, innerRim, outerRim, outerRim);
			AppendBayQuad(solidVerts,
				vector3f(-halfX, shaftY, -halfZ), vector3f(-innerX, shaftY, -innerZ),
				vector3f(-innerX, shaftY, innerZ), vector3f(-halfX, shaftY, halfZ),
				outerRim, innerRim, innerRim, outerRim);
			AppendBayQuad(solidVerts,
				vector3f(innerX, shaftY, -innerZ), vector3f(halfX, shaftY, -halfZ),
				vector3f(halfX, shaftY, halfZ), vector3f(innerX, shaftY, innerZ),
				innerRim, outerRim, outerRim, innerRim);
		}

		// 2. Beveled 3D armored collar & side door-pocket housings
		const float collarH = 0.30f * collarDeploy;
		if (collarH > 0.015f) {
			const Color collarTop(88, 96, 108, 255);
			const Color collarSideX(58, 64, 74, 255);
			const Color collarSideZ(66, 73, 84, 255);
			const float oX = halfX + rimW;
			const float oZ = halfZ + rimW;

			// North / South collar rails
			AppendBayBox(solidVerts, -oX, oX, 0.0f, collarH, halfZ, oZ, collarTop, collarSideX, collarSideZ);
			AppendBayBox(solidVerts, -oX, oX, 0.0f, collarH, -oZ, -halfZ, collarTop, collarSideX, collarSideZ);
			// West / East shutter-pocket housings (slightly thicker/taller)
			const float pocketH = 0.38f * collarDeploy;
			const Color pocketTop(74, 82, 94, 255);
			AppendBayBox(solidVerts, -oX - 0.45f, -halfX, 0.0f, pocketH, -halfZ, halfZ, pocketTop, collarSideX, collarSideZ);
			AppendBayBox(solidVerts, halfX, oX + 0.45f, 0.0f, pocketH, -halfZ, halfZ, pocketTop, collarSideX, collarSideZ);
		}

		// 3. Twin retracting segmented armored blast doors
		const float doorTopY = 0.27f * std::max(0.25f, collarDeploy);
		const float doorBotY = 0.11f;
		const float gapHalfX = halfX * openFrac;
		const float leafWidth = halfX - gapHalfX;
		if (leafWidth > 0.08f && doorTopY > doorBotY) {
			const Color leafTop(66, 74, 86, 255);
			const Color leafSideX(44, 50, 58, 255);
			const Color leafSideZ(54, 61, 70, 255);
			const Color ribCol(34, 39, 46, 255);
			const Color hazardYellow(222, 165, 22, 255);
			const Color hazardDark(22, 24, 28, 255);

			// Left door leaf [-halfX .. -gapHalfX] & Right door leaf [+gapHalfX .. +halfX]
			AppendBayBox(solidVerts, -halfX, -gapHalfX, doorBotY, doorTopY, -halfZ, halfZ, leafTop, leafSideX, leafSideZ);
			AppendBayBox(solidVerts, gapHalfX, halfX, doorBotY, doorTopY, -halfZ, halfZ, leafTop, leafSideX, leafSideZ);

			// Transverse structural rib strips across each leaf
			const int numRibs = 4;
			for (int k = 1; k < numRibs; ++k) {
				const float rz = -halfZ + (2.0f * halfZ) * (float(k) / float(numRibs));
				AppendBayBox(solidVerts, -halfX + 0.2f, -gapHalfX - 0.1f, doorTopY, doorTopY + 0.03f, rz - 0.14f, rz + 0.14f, ribCol, ribCol, ribCol);
				AppendBayBox(solidVerts, gapHalfX + 0.1f, halfX - 0.2f, doorTopY, doorTopY + 0.03f, rz - 0.14f, rz + 0.14f, ribCol, ribCol, ribCol);
			}

			// Caution stripe segments along both meeting inner edges
			const float stripeW = std::min(0.65f, leafWidth * 0.45f);
			if (stripeW > 0.06f) {
				const int numStripes = 10;
				for (int sIdx = 0; sIdx < numStripes; ++sIdx) {
					const float sz0 = -halfZ + (2.0f * halfZ) * (float(sIdx) / float(numStripes));
					const float sz1 = -halfZ + (2.0f * halfZ) * (float(sIdx + 1) / float(numStripes));
					const Color sc = (sIdx % 2 == 0) ? hazardYellow : hazardDark;
					AppendBayBox(solidVerts, -gapHalfX - stripeW, -gapHalfX, doorTopY + 0.005f, doorTopY + 0.025f, sz0, sz1, sc, sc, sc);
					AppendBayBox(solidVerts, gapHalfX, gapHalfX + stripeW, doorTopY + 0.005f, doorTopY + 0.025f, sz0, sz1, sc, sc, sc);
				}
			}
		}

		// 4. Moving elevator platform deck & 4 corner hydraulic cradle clamps
		const float platTopY = float(dt.fromPos.y) - 0.02f;
		if (platTopY > -0.35f) {
			const float platX = std::max(4.5f, halfX - 0.55f);
			const float platZ = std::max(5.5f, halfZ - 0.55f);
			const Color deckTop(82, 88, 96, 255);
			const Color deckSideX(52, 56, 62, 255);
			const Color deckSideZ(60, 65, 72, 255);
			AppendBayBox(solidVerts, -platX, platX, platTopY - 0.12f, platTopY, -platZ, platZ, deckTop, deckSideX, deckSideZ);

			const float clampH = 0.42f * clampScale;
			if (clampH > 0.03f) {
				const Color clampTop(195, 145, 28, 255);
				const Color clampSide(120, 92, 24, 255);
				const float cw = 0.75f;
				const float cx[2] = { -platX + 0.4f, platX - 0.4f - cw };
				const float cz[2] = { -platZ + 0.4f, platZ - 0.4f - cw };
				for (int xi = 0; xi < 2; ++xi) {
					for (int zi = 0; zi < 2; ++zi) {
						AppendBayBox(solidVerts, cx[xi], cx[xi] + cw, platTopY, platTopY + clampH, cz[zi], cz[zi] + cw, clampTop, clampSide, clampSide);
					}
				}
			}
		}

		// 5. Additive flashing amber / lock-green warning strips & corner beacons
		const Color glowCol = lockReady
			? Color(45, 230, 155, Uint8(165.0f + 50.0f * pulse))
			: Color(255, 165, 32, Uint8(105.0f + 135.0f * pulse));

		if (collarDeploy > 0.05f) {
			const float gY = 0.32f * collarDeploy + 0.02f;
			const float cR = 0.55f;
			const float oX = halfX + rimW * 0.55f;
			const float oZ = halfZ + rimW * 0.55f;
			const float sx[2] = { -oX, oX };
			const float sz[2] = { -oZ, oZ };
			for (int xi = 0; xi < 2; ++xi) {
				for (int zi = 0; zi < 2; ++zi) {
					AppendBayQuadFlat(glowVerts,
						vector3f(sx[xi] - cR, gY, sz[zi] - cR), vector3f(sx[xi] + cR, gY, sz[zi] - cR),
						vector3f(sx[xi] + cR, gY, sz[zi] + cR), vector3f(sx[xi] - cR, gY, sz[zi] + cR), glowCol);
				}
			}
		}
		if (openFrac > 0.05f) {
			const float stripY = 0.085f;
			const float stripW = 0.22f;
			// Longitudinal illuminated shaft edge strips
			AppendBayQuadFlat(glowVerts,
				vector3f(-halfX, stripY, -halfZ), vector3f(-halfX + stripW, stripY, -halfZ),
				vector3f(-halfX + stripW, stripY, halfZ), vector3f(-halfX, stripY, halfZ), glowCol);
			AppendBayQuadFlat(glowVerts,
				vector3f(halfX - stripW, stripY, -halfZ), vector3f(halfX, stripY, -halfZ),
				vector3f(halfX, stripY, halfZ), vector3f(halfX - stripW, stripY, halfZ), glowCol);
		}
		if (leafWidth > 0.15f && doorTopY > doorBotY) {
			const float leadY = doorTopY + 0.035f;
			const float lw = std::min(0.18f, leafWidth * 0.25f);
			AppendBayQuadFlat(glowVerts,
				vector3f(-gapHalfX - lw, leadY, -halfZ + 0.3f), vector3f(-gapHalfX, leadY, -halfZ + 0.3f),
				vector3f(-gapHalfX, leadY, halfZ - 0.3f), vector3f(-gapHalfX - lw, leadY, halfZ - 0.3f), glowCol);
			AppendBayQuadFlat(glowVerts,
				vector3f(gapHalfX, leadY, -halfZ + 0.3f), vector3f(gapHalfX + lw, leadY, -halfZ + 0.3f),
				vector3f(gapHalfX + lw, leadY, halfZ - 0.3f), vector3f(gapHalfX, leadY, halfZ - 0.3f), glowCol);
		}

		const matrix4x4f bayMat = stationView * m_type->GetStageTransform(int(i), DockStage::DOCKED);
		Graphics::Renderer::MatrixTicket mt(r, bayMat);
		if (!solidVerts.IsEmpty())
			r->DrawBuffer(&solidVerts, m_hangarSolidMat.Get());
		if (!glowVerts.IsEmpty())
			r->DrawBuffer(&glowVerts, m_hangarGlowMat.Get());
	}
}

void SpaceStation::SetLabel(const std::string &label)
{
	assert(GetModel());
	GetModel()->SetLabel(label);
	Body::SetLabel(label);
}

// find an empty position for a static ship and mark it as used. these aren't
// saved and are only needed to help modules place bulk ships. this isn't a
// great place for this, but its gotta be tracked somewhere
bool SpaceStation::AllocateStaticSlot(int &slot)
{
	// no slots at ground stations
	if (IsGroundStation())
		return false;

	for (int i = 0; i < NUM_STATIC_SLOTS; i++) {
		if (!m_staticSlot[i]) {
			m_staticSlot[i] = true;
			slot = i;
			return true;
		}
	}

	return false;
}

vector3d SpaceStation::GetTargetIndicatorPosition() const
{
	// return the next waypoint if permission has been granted for player,
	// and the docking point's position once the docking anim starts
	for (Uint32 i = 0; i < m_shipDocking.size(); i++) {
		if ((m_shipDocking[i].ship == Pi::player) &&
				(m_shipDocking[i].stage == DockStage::CLEARANCE_GRANTED)) { // last part is "not currently docked" ????
			return vector3d(m_type->GetStageTransform(i, DockStage::DOCKED).GetTranslate());
		}
	}
	return Body::GetTargetIndicatorPosition();
}

bool SpaceStation::IsPortLocked(const int bay) const
{
	for (auto &bayIter : m_ports) {
		for (auto &idIter : bayIter.bayIDs) {
			if (idIter.first == bay) {
				if (!bayIter.inUse) return false;
				// Validate: Is any bay on this port ACTUALLY in an active undocking stage?
				bool activeUndock = false;
				for (auto &checkIter : bayIter.bayIDs) {
					int b = checkIter.first;
					if (b >= 0 && Uint32(b) < m_shipDocking.size()) {
						if (m_shipDocking[b].ship && !m_shipDocking[b].ship->IsDead() &&
							SpaceStationType::IsUndockStage(m_shipDocking[b].stage)) {
							activeUndock = true;
							break;
						}
					}
				}
				if (!activeUndock) {
					// Stale lock from crashed, deleted, or finished vessel; self-heal!
					const_cast<SpaceStation*>(this)->LockPort(bay, false);
					return false;
				}
				return true;
			}
		}
	}
	return false;
}

void SpaceStation::LockPort(const int bay, const bool lockIt)
{
	for (auto &bayIter : m_ports) {
		for (auto &idIter : bayIter.bayIDs) {
			if (idIter.first == bay) {
				bayIter.inUse = lockIt;
				return;
			}
		}
	}
}

matrix4x4d SpaceStation::GetBayTransform(Uint32 bay) const {
	matrix4x4d bayTrans = matrix4x4d::Translation(GetPosition()) * GetOrient();
	bayTrans = bayTrans * matrix4x4d(m_type->GetStageTransform(bay, DockStage::DOCKED));
	return bayTrans;
}

double SpaceStation::GetDockAnimStageDuration(int bay, DockStage stage) const
{
	if (stage == DockStage::NONE) return 0.0;
	if (m_type->IsSurfaceStation()) return 0.0;
	auto dt = m_shipDocking[bay];
	vector3f p1 = vector3f(dt.fromPos);
	vector3f p2 = m_type->GetStageTransform(bay, stage).GetTranslate();
	float stageLength = (p2 - p1).Length();
	float averageVelocity = stage == m_type->LastDockStage() ? 10 : 30; // m/s
	return stageLength / averageVelocity;
}

double SpaceStation::GetUndockAnimStageDuration(int bay, DockStage stage) const
{
	if (m_type->IsSurfaceStation()) return 0.0;
	auto dt = m_shipDocking[bay];
	vector3f p1 = vector3f(dt.fromPos);
	vector3f p2 = m_type->GetStageTransform(bay, stage).GetTranslate();
	float stageLength = (p2 - p1).Length();
	float averageVelocity = 10; // m/s
	return stageLength / averageVelocity;
}

bool SpaceStation::CalcInteriorLighting(const Body *b, Color4ub &sLight, double& sIntense) const
{
	vector3d bPoint = b->GetPositionRelTo(this);
	const float dist = GetModel()->DistanceFromPointToBound("interior", vector3f(bPoint));

	// This number can be tweaked to make fading more / less gradual,
	// it could depend on ship size but this value feels good on all current ships
	const float bRadius = 30.0f;
	if(dist - bRadius < 0.0f) {
		sIntense = std::max(std::min((bRadius - dist) / bRadius, 1.0f), 0.0f);
		sLight = Color::GRAY;
		return true;
	}

	return false;
}
