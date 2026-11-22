// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SupercruiseController.h"
#include "Frame.h"
#include "Game.h"
#include "HyperspaceCloud.h"
#include "JsonUtils.h"
#include "MathUtil.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "SectorView.h"
#include "Ship.h"
#include "ShipType.h"
#include "Space.h"
#include "SpaceStation.h"
#include "galaxy/StarSystem.h"
#include "galaxy/SystemBody.h"
#include "lua/LuaEvent.h"
#include "sound/Sound.h"

#include <algorithm>
#include <cmath>

SupercruiseController::SupercruiseController(Ship *ship) :
	m_ship(ship)
{
}

void SupercruiseController::SaveToJson(Json &jsonObj, Space *space) const
{
	Json scObj = Json::object();
	scObj["charging"] = m_charging;
	scObj["charge_countdown"] = m_chargeCountdown;
	scObj["cooldown"] = m_cooldown;
	scObj["throttle"] = m_throttle;
	scObj["speed"] = m_speed;
	scObj["assist_active"] = m_assistActive;
	scObj["dock_on_arrival"] = m_dockOnArrival;
	scObj["nullifier_cooldown"] = m_nullifierCooldown;
	scObj["heat_spike"] = m_heatSpike;
	Space *sp = space ? space : (Pi::game ? Pi::game->GetSpace() : nullptr);
	scObj["index_for_target"] = (sp && m_target) ? sp->GetIndexForBody(m_target) : 0;
	scObj["index_for_locked_ship"] = (sp && m_lockedShip) ? sp->GetIndexForBody(m_lockedShip) : 0;
	scObj["target_frame"] = m_targetFrame;
	scObj["target_offset"] = m_targetOffset;
	scObj["fsd_offline"] = m_fsdOffline;
	scObj["interdict_role"] = int(m_interdictRole);
	scObj["index_for_interdict_peer"] = (sp && m_interdictPeer) ? sp->GetIndexForBody(m_interdictPeer) : 0;
	scObj["capture_progress"] = m_captureProgress;
	scObj["escape_progress"] = m_escapeProgress;
	scObj["escape_wander_time"] = m_escapeWanderTime;
	scObj["submit_timer"] = m_submitTimer;
	scObj["submitting"] = m_submitting;
	scObj["escape_base_dir"] = m_escapeBaseDir;
	scObj["escape_dir_world"] = m_escapeDirWorld;
	jsonObj["supercruise"] = scObj;
}

void SupercruiseController::LoadFromJson(const Json &jsonObj)
{
	if (!jsonObj.count("supercruise"))
		return;
	const Json &scObj = jsonObj["supercruise"];
	m_charging = scObj.value("charging", false);
	m_chargeCountdown = scObj.value("charge_countdown", 0.0f);
	m_cooldown = scObj.value("cooldown", 0.0f);
	m_throttle = scObj.value("throttle", 0.5);
	m_speed = scObj.value("speed", 0.0);
	m_assistActive = scObj.value("assist_active", false);
	m_dockOnArrival = scObj.value("dock_on_arrival", false);
	m_nullifierCooldown = scObj.value("nullifier_cooldown", 0.0f);
	m_heatSpike = scObj.value("heat_spike", 0.0);
	m_targetIndex = scObj.value("index_for_target", 0);
	m_target = nullptr;
	m_lockedShipIndex = scObj.value("index_for_locked_ship", 0);
	m_lockedShip = nullptr;
	m_targetFrame = scObj.count("target_frame") ? scObj["target_frame"].get<FrameId>() : FrameId(FrameId::Invalid);
	m_targetOffset = scObj.count("target_offset") ? scObj["target_offset"].get<vector3d>() : vector3d(0.0);
	m_fsdOffline = scObj.value("fsd_offline", false);
	m_interdictRole = static_cast<InterdictionRole>(scObj.value("interdict_role", 0));
	m_interdictPeerIndex = scObj.value("index_for_interdict_peer", 0);
	m_interdictPeer = nullptr;
	m_captureProgress = scObj.value("capture_progress", 0.30);
	m_escapeProgress = scObj.value("escape_progress", 0.30);
	m_escapeWanderTime = scObj.value("escape_wander_time", 0.0);
	m_submitTimer = scObj.value("submit_timer", 0.0);
	m_submitting = scObj.value("submitting", false);
	m_escapeBaseDir = scObj.count("escape_base_dir") ? scObj["escape_base_dir"].get<vector3d>() : vector3d(0.0, 0.0, -1.0);
	m_escapeDirWorld = scObj.count("escape_dir_world") ? scObj["escape_dir_world"].get<vector3d>() : vector3d(0.0, 0.0, -1.0);
}

void SupercruiseController::PostLoadFixup(Space *space)
{
	m_target = (space && m_targetIndex) ? space->GetBodyByIndex(m_targetIndex) : nullptr;
	Body *lockedBody = (space && m_lockedShipIndex) ? space->GetBodyByIndex(m_lockedShipIndex) : nullptr;
	m_lockedShip = (lockedBody && lockedBody->IsType(ObjectType::SHIP)) ? static_cast<Ship *>(lockedBody) : nullptr;
	Body *peerBody = (space && m_interdictPeerIndex) ? space->GetBodyByIndex(m_interdictPeerIndex) : nullptr;
	m_interdictPeer = (peerBody && peerBody->IsType(ObjectType::SHIP)) ? static_cast<Ship *>(peerBody) : nullptr;
	if (m_interdictRole != INTERDICT_NONE && !m_interdictPeer)
		ClearInterdiction();
}

void SupercruiseController::OnDeleted(const Body *body)
{
	if (m_target == body)
		m_target = nullptr;
	if (m_lockedShip == body) {
		m_lockedShip = nullptr;
		m_lockedShipIndex = 0;
	}
	if (m_ringDropPlanet == body)
		m_ringDropPlanet = nullptr;
	if (m_ringImmersionPlanet == body)
		m_ringImmersionPlanet = nullptr;
	if (m_interdictPeer == body) {
		ClearInterdiction();
	}
}

void SupercruiseController::SetTarget(Body *target)
{
	m_target = target;
	m_targetFrame = FrameId::Invalid;
	m_targetOffset = vector3d(0.0);
	if (target && target->IsType(ObjectType::SHIP)) {
		Ship *tShip = static_cast<Ship *>(target);
		if (m_lockedShip != tShip && !AcquireSupercruiseLock(tShip))
			ClearSupercruiseLock();
	} else {
		ClearSupercruiseLock();
	}
}

void SupercruiseController::SetTargetPosition(FrameId frameId, const vector3d &offset)
{
	m_target = nullptr;
	m_targetFrame = frameId;
	m_targetOffset = offset;
	ClearSupercruiseLock();
}

bool SupercruiseController::AcquireSupercruiseLock(Ship *target)
{
	if (!m_ship || !IsActive() || !target || target->IsDead() || target == m_ship ||
		target->GetFlightState() != Ship::SUPERCRUISE)
		return false;
	if (IsShipFTL(target) || m_lockedShip == target || IsInterdictingPeer(target)) {
		m_lockedShip = target;
		m_lockedShipIndex = 0;
		return true;
	}
	return false;
}

bool SupercruiseController::IsActive() const
{
	return m_ship && m_ship->GetFlightState() == Ship::SUPERCRUISE;
}

bool SupercruiseController::IsShipFTL(const Ship *ship)
{
	if (!ship || ship->IsDead() || ship->GetFlightState() != Ship::SUPERCRUISE)
		return false;
	const SupercruiseController *sc = ship->GetSupercruise();
	return sc && sc->GetSpeed() >= LIGHT_SPEED;
}

bool SupercruiseController::HasTrackedLock(const Ship *observer, const Ship *target)
{
	if (!observer || !target || target->IsDead() || observer == target)
		return false;
	if (observer->GetFlightState() != Ship::SUPERCRUISE || target->GetFlightState() != Ship::SUPERCRUISE)
		return false;
	const SupercruiseController *obsSc = observer->GetSupercruise();
	if (obsSc && obsSc->IsInterdictingPeer(target))
		return true;
	if (observer->IsType(ObjectType::PLAYER)) {
		const Player *p = static_cast<const Player *>(observer);
		return (p->GetCombatTarget() == target || p->GetNavTarget() == target);
	}
	return obsSc && (obsSc->m_lockedShip == target);
}

bool SupercruiseController::IsShipVisibleToSensors(const Ship *observer, const Ship *target)
{
	if (!observer || !target || target->IsDead() || observer == target)
		return false;
	const bool observerInSC = (observer->GetFlightState() == Ship::SUPERCRUISE);
	const bool targetInSC = (target->GetFlightState() == Ship::SUPERCRUISE);
	if (observerInSC) {
		return IsShipFTL(target) || HasTrackedLock(observer, target);
	}
	return !targetInSC;
}

double SupercruiseController::GetExclusionZoneRadius(const Body *body)
{
	if (!body || !body->IsType(ObjectType::TERRAINBODY))
		return 0.0;
	const SystemBody *sbody = body->GetSystemBody();
	if (!sbody)
		return 0.0;

	const double r = sbody->GetRadius();
	switch (sbody->GetSuperType()) {
	case SystemBody::SUPERTYPE_STAR:
		return r * 1.15;
	case SystemBody::SUPERTYPE_GAS_GIANT:
		return r * 1.05;
	case SystemBody::SUPERTYPE_ROCKY_PLANET: {
		const TerrainBody *tb = static_cast<const TerrainBody *>(body);
		return std::max(r, tb->GetMaxFeatureRadius()) + 4500.0; // 4.5 km above max terrain feature radius
	}
	default:
		return 0.0;
	}
}

double SupercruiseController::GetExclusionZoneRadiusAtDir(const Body *body, const vector3d &unitDirInBodyFrame)
{
	if (!body || !body->IsType(ObjectType::TERRAINBODY))
		return 0.0;
	const SystemBody *sbody = body->GetSystemBody();
	if (!sbody)
		return 0.0;

	if (sbody->GetSuperType() == SystemBody::SUPERTYPE_ROCKY_PLANET) {
		const double r = sbody->GetRadius();
		const TerrainBody *tb = static_cast<const TerrainBody *>(body);
		if (unitDirInBodyFrame.LengthSqr() > 0.25) {
			const double terrainR = tb->GetTerrainHeight(unitDirInBodyFrame.Normalized());
			return std::max(r, terrainR) + 4500.0; // 4.5 km above local terrain height (below 5 km mass-lock altitude)
		}
		return std::max(r, tb->GetMaxFeatureRadius()) + 4500.0;
	}

	return GetExclusionZoneRadius(body);
}

bool SupercruiseController::IsMassLocked(std::string *outReason) const
{
	if (!m_ship || !Pi::game || !Pi::game->GetSpace())
		return false;

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		if (b == m_ship)
			continue;

		if (b->IsType(ObjectType::SPACESTATION)) {
			const double dist = m_ship->GetPositionRelTo(b).Length();
			if (dist < STATION_MASS_LOCK_DIST) {
				if (outReason)
					*outReason = "MASS LOCKED BY " + b->GetLabel();
				return true;
			}
		} else if (b->IsType(ObjectType::TERRAINBODY)) {
			const SystemBody *sb = b->GetSystemBody();
			if (!sb)
				continue;

			const vector3d posRel = m_ship->GetPositionRelTo(b);
			const double dist = posRel.Length();
			const double exclR = GetExclusionZoneRadius(b);

			if (sb->GetSuperType() == SystemBody::SUPERTYPE_ROCKY_PLANET) {
				if (dist < b->GetClipRadius() + PLANET_MASS_LOCK_ALT * 2.0) {
					const Planet *planet = static_cast<const Planet *>(b);
					const double terrainR = planet->GetTerrainHeight(posRel.NormalizedSafe());
					const double alt = dist - terrainR;
					if (alt < PLANET_MASS_LOCK_ALT) {
						if (outReason)
							*outReason = "MASS LOCKED: SURFACE PROXIMITY (" + b->GetLabel() + ")";
						return true;
					}
				}
			} else if (exclR > 0.0 && dist < exclR * 1.02) {
				if (outReason)
					*outReason = "MASS LOCKED: GRAVITY WELL (" + b->GetLabel() + ")";
				return true;
			}
		}
	}

	return false;
}

double SupercruiseController::GetShipMassLockFactor() const
{
	if (!m_ship || !Pi::game || !Pi::game->GetSpace())
		return 1.0;

	const double myHull = std::max(1.0, double(m_ship->GetShipType()->hullMass));
	double maxFactor = 1.0;

	Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(m_ship, 3500.0f);
	for (Body *b : nearby) {
		if (!b || b == m_ship || b->IsDead() || !b->IsType(ObjectType::SHIP))
			continue;
		const Ship *other = static_cast<const Ship *>(b);
		if (other->GetFlightState() != Ship::FLYING)
			continue;
		const double dist = m_ship->GetPositionRelTo(other).Length();
		if (dist > 3000.0)
			continue;
		const double otherHull = double(other->GetShipType()->hullMass);
		if (otherHull >= myHull * 0.75) {
			const double ratio = Clamp(otherHull / myHull, 0.75, 4.0);
			const double prox = Clamp(1.0 - dist / 3000.0, 0.0, 1.0);
			const double factor = 1.0 + ratio * (1.2 + 0.8 * prox);
			maxFactor = std::max(maxFactor, factor);
		}
	}
	return Clamp(maxFactor, 1.0, 5.0);
}

void SupercruiseController::SetFsdOffline(bool offline)
{
	if (m_ship && m_ship->IsType(ObjectType::PLAYER))
		return; // Players can always re-engage Supercruise once cooldown completes
	m_fsdOffline = offline;
	if (m_fsdOffline && m_charging)
		AbortCharge("FSD OFFLINE");
}

SupercruiseController::Status SupercruiseController::GetStatus(std::string *outReason) const
{
	if (!m_ship)
		return SC_NOT_FLYING;

	if (IsActive())
		return SC_ACTIVE;

	if (m_fsdOffline) {
		if (outReason)
			*outReason = "FRAMESHIFT DRIVE OFFLINE";
		return SC_FSD_OFFLINE;
	}

	if (m_charging) {
		if (outReason)
			*outReason = "FRAMESHIFT DRIVE CHARGING";
		return SC_CHARGING;
	}

	if (m_ship->GetFlightState() != Ship::FLYING) {
		if (outReason)
			*outReason = "CANNOT ENGAGE SUPERCRUISE WHILE DOCKED OR LANDED";
		return SC_NOT_FLYING;
	}

	if (m_cooldown > 0.0f) {
		if (outReason) {
			char buf[128];
			snprintf(buf, sizeof(buf), "FSD COOLDOWN ACTIVE (%.1fs)", m_cooldown);
			*outReason = buf;
		}
		return SC_COOLDOWN;
	}

	if (m_ship->GetWheelState() > 0.0f || m_ship->GetWheelTransition() != 0) {
		if (outReason)
			*outReason = "CANNOT ENGAGE FSD: LANDING GEAR DEPLOYED";
		return SC_GEAR_DOWN;
	}

	std::string massLockReason;
	if (IsMassLocked(&massLockReason)) {
		if (outReason)
			*outReason = massLockReason;
		return SC_MASS_LOCKED;
	}

	if (m_ship->GetVelocity().Length() < MIN_ENGAGE_SPEED) {
		if (outReason) {
			char buf[128];
			snprintf(buf, sizeof(buf), "TOO SLOW — ACCELERATE TO %.0f m/s", MIN_ENGAGE_SPEED);
			*outReason = buf;
		}
		return SC_TOO_SLOW;
	}

	if (outReason)
		*outReason = "FSD READY";
	return SC_READY;
}

void SupercruiseController::SetThrottle(double throttle)
{
	m_throttle = Clamp(throttle, 0.0, 1.0);
}

void SupercruiseController::ChangeThrottle(double delta)
{
	SetThrottle(m_throttle + delta);
}

void SupercruiseController::SetSpeed(double speed)
{
	m_speed = Clamp(speed, MIN_SPEED, MAX_SPEED);
}

bool SupercruiseController::HasAssistModule() const
{
	if (!m_ship)
		return false;
	int cap = m_ship->Properties().Get("supercruise_assist_cap");
	int apCap = m_ship->Properties().Get("autopilot_cap");
	return (cap >= 1) || (apCap >= 2);
}

void SupercruiseController::SetAssistActive(bool active, bool dockOnArrival)
{
	if (active && !HasAssistModule()) {
		ShowStatusMessage("SUPERCRUISE ASSIST REQUIRES AUTOPILOT MK 2", 4.0f);
		m_assistActive = false;
		m_dockOnArrival = false;
		return;
	}

	bool hasHyperspaceAlignTarget = false;
	if (m_ship) {
		if (m_ship->IsHyperspaceActive()) {
			hasHyperspaceAlignTarget = true;
		} else if (m_ship->IsType(ObjectType::PLAYER) && Pi::game && Pi::game->GetSectorView() && Pi::game->GetSpace() && Pi::game->GetSpace()->GetStarSystem()) {
			const SystemPath hTarget = Pi::game->GetSectorView()->GetHyperspaceTarget();
			if (hTarget.HasValidSystem() && !hTarget.IsSameSystem(Pi::game->GetSpace()->GetStarSystem()->GetPath())) {
				hasHyperspaceAlignTarget = true;
			}
		}
	}

	if (active && !GetActiveTarget() && !hasHyperspaceAlignTarget) {
		ShowStatusMessage("SUPERCRUISE ASSIST: NO NAVIGATION TARGET SELECTED", 4.0f);
		m_assistActive = false;
		m_dockOnArrival = false;
		return;
	}

	m_assistActive = active;
	m_dockOnArrival = active ? dockOnArrival : false;

	if (m_assistActive) {
		m_throttle = 0.75; // Lock to 75% blue zone
		ShowStatusMessage("SUPERCRUISE ASSIST ENGAGED — THROTTLE LOCKED TO 75%", 4.0f);
		if (!IsActive() && !m_charging) {
			if (!StartCharge()) {
				m_assistActive = false;
				m_dockOnArrival = false;
			}
		}
	} else {
		ShowStatusMessage("SUPERCRUISE ASSIST DISENGAGED", 3.0f);
	}
}

void SupercruiseController::ToggleAssist()
{
	SetAssistActive(!m_assistActive, false);
}

bool SupercruiseController::Toggle()
{
	if (IsActive()) {
		if (m_safeDisengageReady) {
			SafeDisengage();
		} else if (m_speed >= SAFE_DISENGAGE_SPEED) {
			EmergencyDrop("EMERGENCY DROP — EXCESSIVE FSD VELOCITY");
		} else {
			NormalDrop("DROPPED FROM SUPERCRUISE");
		}
		return true;
	}

	if (m_charging) {
		AbortCharge("FSD CHARGE ABORTED");
		return false;
	}

	return StartCharge();
}

bool SupercruiseController::StartCharge()
{
	const bool isPlayer = m_ship && m_ship->IsType(ObjectType::PLAYER);

	if (m_ship && m_ship->IsHyperspaceActive()) {
		if (isPlayer) {
			ShowStatusMessage("FSD BUSY: HYPERJUMP IN PROGRESS", 4.0f);
			Sound::BodyMakeNoise(m_ship, "notify_beep", 0.7f);
		}
		return false;
	}

	std::string reason;
	Status st = GetStatus(&reason);
	if (st != SC_READY) {
		if (isPlayer) {
			ShowStatusMessage(reason, 4.0f);
			Sound::BodyMakeNoise(m_ship, "notify_beep", 0.7f);
		}
		return false;
	}

	m_charging = true;
	m_chargeCountdown = CHARGE_DURATION;
	if (isPlayer && m_ship->AIIsActive())
		m_ship->AIClearInstructions();
	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Charge", 1.0f);
	ShowStatusMessage("FRAMESHIFT DRIVE CHARGING", CHARGE_DURATION);
	return true;
}

void SupercruiseController::AbortCharge(const std::string &reason)
{
	if (!m_charging)
		return;
	m_charging = false;
	m_chargeCountdown = 0.0f;
	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);
	ShowStatusMessage(reason.empty() ? "FSD CHARGE ABORTED" : reason, 3.5f);
}

void SupercruiseController::EnterSupercruise()
{
	m_charging = false;
	m_chargeCountdown = 0.0f;

	// Ensure we are in an orbital parent frame, never a rotating surface frame or station frame
	while (Frame *f = Frame::GetFrame(m_ship->GetFrame())) {
		const bool isStationFrame = f->GetBody() && f->GetBody()->IsType(ObjectType::SPACESTATION);
		if ((f->IsRotFrame() || isStationFrame) && f->GetParent().valid()) {
			m_ship->SwitchToFrame(f->GetParent());
		} else {
			break;
		}
	}

	m_ship->SetFlightState(Ship::SUPERCRUISE);
	ClearSupercruiseLock();
	m_speed = std::max(MIN_SPEED, m_ship->GetVelocity().Length());
	if (m_throttle < 0.25)
		m_throttle = 0.50;
	if (m_assistActive)
		m_throttle = 0.75;

	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->SetVelocity(-m_ship->GetOrient().VectorZ() * m_speed);

	m_trailPositions.clear();
	m_trailSampleTimer = 0.0f;
	if (Pi::game && Pi::game->GetSpace()) {
		const vector3d rootPos = m_ship->GetPositionRelTo(Pi::game->GetSpace()->GetRootFrame());
		m_entryFlashRootPos = rootPos;
		m_entryFlashTimer = ENTRY_FLASH_DURATION;
		if (m_speed >= LIGHT_SPEED)
			m_trailPositions.push_front(rootPos);
	}
	ClearStaleSupercruiseTarget();

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Jump", 1.0f);
	ShowStatusMessage("SUPERCRUISE ENGAGED", 3.5f);
}

void SupercruiseController::EnterSupercruiseImmediate(double initialSpeed)
{
	if (!m_ship)
		return;

	m_charging = false;
	m_chargeCountdown = 0.0f;
	m_cooldown = 0.0f;
	m_entryFlashTimer = 0.0f;

	while (Frame *f = Frame::GetFrame(m_ship->GetFrame())) {
		const bool isStationFrame = f->GetBody() && f->GetBody()->IsType(ObjectType::SPACESTATION);
		if ((f->IsRotFrame() || isStationFrame) && f->GetParent().valid()) {
			m_ship->SwitchToFrame(f->GetParent());
		} else {
			break;
		}
	}

	m_ship->SetFlightState(Ship::SUPERCRUISE);
	ClearSupercruiseLock();
	m_speed = Clamp(initialSpeed, MIN_SPEED, MAX_SPEED);
	m_throttle = 0.75;
	m_desiredSpeed = m_speed;

	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->SetVelocity(-m_ship->GetOrient().VectorZ() * m_speed);

	m_trailPositions.clear();
	m_trailSampleTimer = 0.0f;
	if (Pi::game && Pi::game->GetSpace() && m_speed >= LIGHT_SPEED) {
		m_trailPositions.push_front(m_ship->GetPositionRelTo(Pi::game->GetSpace()->GetRootFrame()));
	}
	ClearStaleSupercruiseTarget();
}

void SupercruiseController::EnterSupercruiseOnHyperspaceExit()
{
	if (!m_ship)
		return;

	ClearInterdiction();
	ResetFuelScoopState();
	m_charging = false;
	m_chargeCountdown = 0.0f;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_cooldown = HYPERJUMP_COOLDOWN;
	m_entryFlashTimer = 0.0f;

	m_ship->SetFlightState(Ship::SUPERCRUISE);
	ClearSupercruiseLock();
	m_speed = MIN_SPEED;
	m_throttle = 0.0;
	m_desiredSpeed = MIN_SPEED;

	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->SetVelocity(-m_ship->GetOrient().VectorZ() * m_speed);

	m_trailPositions.clear();
	m_trailSampleTimer = 0.0f;
	ClearStaleSupercruiseTarget();

	ShowStatusMessage("HYPERSPACE EXIT — FSD COOLDOWN ACTIVE", 5.0f);
}

void SupercruiseController::DropIntoRing(Planet *planet, const std::string &reason)
{
	ClearInterdiction();
	ClearSupercruiseLock();
	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = NORMAL_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;

	if (planet && planet->GetSystemBody()) {
		const SystemBody *sb = planet->GetSystemBody();
		Frame *pf = Frame::GetFrame(planet->GetFrame());
		FrameId orbFrameId = pf ? pf->GetNonRotFrame() : planet->GetFrame();
		if (orbFrameId.valid() && Frame::GetFrame(orbFrameId)) {
			m_ship->SwitchToFrame(orbFrameId);
			const vector3d planetPosOrb = planet->GetPositionRelTo(orbFrameId);
			const matrix3x3d axialRot = matrix3x3d::RotateX(sb->GetAxialTilt());
			vector3d relRing = axialRot.Transpose() * (m_ship->GetPosition() - planetPosOrb);

			if (std::abs(relRing.y) > 550.0) {
				relRing.y = (relRing.y >= 0.0) ? 550.0 : -550.0;
			}
			m_ship->SetPosition(planetPosOrb + axialRot * relRing);
		}
	}

	m_ship->SetFlightState(Ship::FLYING);
	EnsureShipAboveTerrainAndSyncFrame();
	m_ship->SetVelocity(vector3d(0.0));
	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->ClearThrusterState();
	m_ship->CalcExternalForce();
	m_trailPositions.clear();
	ResetFuelScoopState();
	ClearStaleSupercruiseTarget();

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);
	ShowStatusMessage(reason.empty() ? "DROPPED INTO PLANETARY RING" : reason, 5.0f);
}

void SupercruiseController::EnsureShipAboveTerrainAndSyncFrame()
{
	if (!m_ship)
		return;

	m_ship->UpdateFrame();

	if (Pi::game && Pi::game->GetSpace()) {
		for (Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (!b || !b->IsType(ObjectType::TERRAINBODY))
				continue;
			const SystemBody *sb = b->GetSystemBody();
			if (!sb)
				continue;

			const vector3d posInBody = m_ship->GetPositionRelTo(b);
			const double dist = posInBody.Length();
			const double maxExclR = GetExclusionZoneRadius(b);
			if (maxExclR <= 0.0 || dist > maxExclR * 2.0 + 50000.0)
				continue;

			const vector3d unitDir = (dist > 1.0) ? (posInBody / dist) : vector3d(0.0, 1.0, 0.0);
			const double minSafeR = GetExclusionZoneRadiusAtDir(b, unitDir);
			if (minSafeR > 0.0 && dist < minSafeR) {
				if (Frame *bf = Frame::GetFrame(b->GetFrame())) {
					const vector3d safePosInBody = b->GetPosition() + unitDir * (minSafeR + 10.0);
					const vector3d safePosInShipFrame = bf->GetOrientRelTo(m_ship->GetFrame()) * safePosInBody + bf->GetPositionRelTo(m_ship->GetFrame());
					m_ship->SetPosition(safePosInShipFrame);
				}
			}
		}
	}

	m_ship->UpdateFrame();
}

void SupercruiseController::SafeDisengage()
{
	Body *target = GetActiveTarget();
	Planet *ringPlanet = m_ringDropPlanet;
	const bool dockAfterDrop = m_dockOnArrival;

	ClearSupercruiseLock();
	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = NORMAL_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;

	bool exitAtCurrentPosition = false;

	if (target && target->IsType(ObjectType::SPACESTATION)) {
		SpaceStation *station = static_cast<SpaceStation *>(target);
		if (!station->IsGroundStation()) {
			// Orbital Station Drop-In: switch to station frame, 12 km out (or current position if already closer)
			m_ship->SwitchToFrame(station->GetFrame());
			const vector3d relToShip = m_ship->GetPosition() - station->GetPosition();
			const double currentDist = relToShip.Length();
			vector3d fromStation = relToShip.NormalizedSafe();
			if (fromStation.LengthSqr() < 0.1)
				fromStation = vector3d(0.0, 0.0, 1.0);

			const double safeDropDist = 12000.0;
			if (currentDist > safeDropDist) {
				m_ship->SetPosition(station->GetPosition() + fromStation * safeDropDist);

				vector3d up = m_ship->GetOrient().VectorY();
				vector3d x = up.Cross(fromStation).NormalizedSafe();
				if (x.LengthSqr() < 0.1)
					x = vector3d(1.0, 0.0, 0.0).Cross(fromStation).NormalizedSafe();
				vector3d y = fromStation.Cross(x).Normalized();
				m_ship->SetOrient(matrix3x3d::FromVectors(x, y, fromStation));
			} else {
				const double minClearDist = station->GetClipRadius() + m_ship->GetClipRadius() + 250.0;
				if (currentDist < minClearDist)
					m_ship->SetPosition(station->GetPosition() + fromStation * minClearDist);
			}

			m_ship->SetVelocity(station->GetVelocity());
			m_ship->SetAngVelocity(vector3d(0.0));
		} else {
			// Surface Starport Glide Drop-In: switch to planet rotating frame, 10 km altitude & 8 km out
			// (or exit at current position if already closer to the starport)
			m_ship->SwitchToFrame(station->GetFrame());
			const vector3d stPos = station->GetPosition();
			const vector3d upDir = stPos.NormalizedSafe();
			const vector3d shipRel = m_ship->GetPosition() - stPos;
			vector3d horiz = (shipRel - upDir * shipRel.Dot(upDir)).NormalizedSafe();
			if (horiz.LengthSqr() < 0.1)
				horiz = station->GetOrient().VectorZ();

			const vector3d safeDropOffset = upDir * 10000.0 + horiz * 8000.0;
			const double safeDropDist = safeDropOffset.Length();
			const bool closerThanSafeExit = (shipRel.Length() <= safeDropDist);
			vector3d dropPos = closerThanSafeExit ? m_ship->GetPosition() : (stPos + safeDropOffset);

			if (Frame *stFrame = Frame::GetFrame(station->GetFrame())) {
				if (Body *astro = stFrame->GetBody()) {
					if (astro->IsType(ObjectType::TERRAINBODY)) {
						const vector3d dropUnit = dropPos.NormalizedSafe();
						const double minR = GetExclusionZoneRadiusAtDir(astro, dropUnit);
						if (dropPos.Length() < minR) {
							dropPos = dropUnit * (minR + 10.0);
						}
					}
				}
			}
			m_ship->SetPosition(dropPos);

			if (!closerThanSafeExit) {
				const vector3d z = (dropPos - stPos).NormalizedSafe();
				if (z.LengthSqr() > 0.1) {
					vector3d x = upDir.Cross(z).NormalizedSafe();
					if (x.LengthSqr() < 0.1)
						x = vector3d(1.0, 0.0, 0.0).Cross(z).NormalizedSafe();
					const vector3d y = z.Cross(x).Normalized();
					m_ship->SetOrient(matrix3x3d::FromVectors(x, y, z));
				}
			}

			m_ship->SetVelocity(vector3d(0.0));
			m_ship->SetAngVelocity(vector3d(0.0));
		}
	} else if (target && (target->IsType(ObjectType::SHIP) || target->IsType(ObjectType::HYPERSPACECLOUD)) && m_targetDistance <= SAFE_DISENGAGE_DIST) {
		m_ship->SwitchToFrame(target->GetFrame());
		const vector3d relToShip = m_ship->GetPosition() - target->GetPosition();
		const double currentDist = relToShip.Length();
		vector3d fromTarget = relToShip.NormalizedSafe();
		if (fromTarget.LengthSqr() < 0.1)
			fromTarget = vector3d(0.0, 0.0, 1.0);
		const double dropOff = target->IsType(ObjectType::HYPERSPACECLOUD) ? 3000.0 : 4000.0;
		if (currentDist > dropOff) {
			m_ship->SetPosition(target->GetPosition() + fromTarget * dropOff);
		} else {
			const double minClearDist = target->GetClipRadius() + m_ship->GetClipRadius() + 100.0;
			if (currentDist < minClearDist)
				m_ship->SetPosition(target->GetPosition() + fromTarget * minClearDist);
		}
		m_ship->SetVelocity(target->GetVelocity());
		m_ship->SetAngVelocity(vector3d(0.0));
	} else if (target && target->IsType(ObjectType::TERRAINBODY)) {
		// Planetary Orbital Drop-In: if farther than the safe orbital insertion altitude (250 km above local exclusion zone),
		// drop into stable orbit at 250 km above exclusion zone; if already closer, exit at current position.
		Frame *pf = Frame::GetFrame(target->GetFrame());
		FrameId orbFrameId = pf ? pf->GetNonRotFrame() : target->GetFrame();
		if (orbFrameId.valid() && Frame::GetFrame(orbFrameId)) {
			m_ship->SwitchToFrame(orbFrameId);
			const vector3d planetPos = target->GetPositionRelTo(orbFrameId);
			const vector3d relOrb = m_ship->GetPosition() - planetPos;
			const double currentDist = relOrb.Length();
			vector3d fromPlanet = relOrb.NormalizedSafe();
			if (fromPlanet.LengthSqr() < 0.1)
				fromPlanet = vector3d(0.0, 0.0, 1.0);

			const vector3d posInBodyFrame = m_ship->GetPositionRelTo(target);
			const double localExclR = GetExclusionZoneRadiusAtDir(target, posInBodyFrame.NormalizedSafe());
			const double dropDist = localExclR + 250000.0; // 250 km above local exclusion zone

			if (currentDist > dropDist) {
				m_ship->SetPosition(planetPos + fromPlanet * dropDist);

				// Face orbital tangent and establish orbital velocity
				const double M = target->GetMass();
				const double orbSpeed = (M > 0.0 && dropDist > 0.0) ? std::sqrt(G * M / dropDist) : 0.0;
				vector3d up = fromPlanet;
				vector3d fwd = -m_ship->GetOrient().VectorZ();
				vector3d tangent = (fwd - up * fwd.Dot(up)).NormalizedSafe();
				if (tangent.LengthSqr() < 0.1)
					tangent = MathUtil::OrthogonalDirection(up).Normalized();
				vector3d right = tangent.Cross(up).Normalized();
				m_ship->SetOrient(matrix3x3d::FromVectors(right, up, -tangent));

				m_ship->SetVelocity(target->GetVelocityRelTo(orbFrameId) + tangent * orbSpeed);
				m_ship->SetAngVelocity(vector3d(0.0));
			} else {
				exitAtCurrentPosition = true;
			}
		}
	} else if (ringPlanet) {
		DropIntoRing(ringPlanet, "DROPPED INTO PLANETARY RING — " + ringPlanet->GetLabel());
		return;
	} else if (!target && m_targetFrame.valid() && Frame::GetFrame(m_targetFrame)) {
		m_ship->SwitchToFrame(m_targetFrame);
		exitAtCurrentPosition = true;
	} else {
		exitAtCurrentPosition = true;
	}

	m_ship->SetFlightState(Ship::FLYING);
	EnsureShipAboveTerrainAndSyncFrame();
	if (exitAtCurrentPosition) {
		m_ship->SetVelocity(vector3d(0.0));
		m_ship->SetAngVelocity(vector3d(0.0));
	}
	m_ship->ClearThrusterState();
	m_ship->CalcExternalForce();
	m_trailPositions.clear();
	ResetFuelScoopState();
	ClearStaleSupercruiseTarget();
	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);

	if (dockAfterDrop && target && target->IsType(ObjectType::SPACESTATION)) {
		m_ship->AIDock(static_cast<SpaceStation *>(target));
		ShowStatusMessage("SAFE DISENGAGE COMPLETE — AUTO-DOCKING ENGAGED", 5.0f);
	} else {
		ShowStatusMessage("SAFE DISENGAGE COMPLETE", 4.0f);
	}
}

void SupercruiseController::ClearStaleSupercruiseTarget()
{
	if (!m_ship || !m_ship->IsType(ObjectType::PLAYER))
		return;
	Player *p = static_cast<Player *>(m_ship);
	if (Body *ct = p->GetCombatTarget()) {
		if (ct->IsType(ObjectType::SHIP) && !IsShipVisibleToSensors(m_ship, static_cast<const Ship *>(ct)))
			p->SetCombatTarget(nullptr);
	}
	if (Body *nt = p->GetNavTarget()) {
		if (nt->IsType(ObjectType::SHIP) && !IsShipVisibleToSensors(m_ship, static_cast<const Ship *>(nt)))
			p->SetNavTarget(nullptr);
	}
	if (Body *ft = p->GetFollowTarget()) {
		if (ft->IsType(ObjectType::SHIP) && !IsShipVisibleToSensors(m_ship, static_cast<const Ship *>(ft)))
			p->SetFollowTarget(nullptr);
	}
}

void SupercruiseController::NormalDrop(const std::string &reason)
{
	ClearInterdiction();
	ClearSupercruiseLock();
	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = NORMAL_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;

	m_ship->SetFlightState(Ship::FLYING);
	EnsureShipAboveTerrainAndSyncFrame();
	m_ship->SetVelocity(vector3d(0.0));
	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->ClearThrusterState();
	m_ship->CalcExternalForce();
	m_trailPositions.clear();
	ResetFuelScoopState();
	ClearStaleSupercruiseTarget();

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);
	ShowStatusMessage(reason.empty() ? "DROPPED FROM SUPERCRUISE" : reason, 4.0f);
}

void SupercruiseController::EmergencyDrop(const std::string &reason)
{
	ClearInterdiction();
	ClearSupercruiseLock();
	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = EMERGENCY_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;

	m_ship->SetFlightState(Ship::FLYING);
	EnsureShipAboveTerrainAndSyncFrame();
	m_ship->SetVelocity(vector3d(0.0));
	m_ship->SetAngVelocity(vector3d(0.18, -0.09, 0.14));
	m_ship->ClearThrusterState();
	m_ship->CalcExternalForce();
	m_trailPositions.clear();
	ResetFuelScoopState();
	ClearStaleSupercruiseTarget();

	// Spike hull temperature & overload shields (hull damage only if shields were down)
	m_heatSpike = 0.92;
	m_ship->DepleteShieldsForEmergencyDrop(EMERGENCY_COOLDOWN);

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);
	ShowStatusMessage(reason.empty() ? "EMERGENCY DROP — SHIELD OVERLOAD & FSD COOLDOWN" : reason, 6.0f);
}

void SupercruiseController::Reset()
{
	ClearInterdiction();
	ClearSupercruiseLock();
	m_charging = false;
	m_chargeCountdown = 0.0f;
	m_cooldown = 0.0f;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_speed = 0.0;
	m_desiredSpeed = 0.0;
	m_throttle = 0.5;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;
	m_target = nullptr;
	m_targetIndex = 0;
	m_targetFrame = FrameId::Invalid;
	m_targetOffset = vector3d(0.0);
	m_interdictPeer = nullptr;
	m_interdictRole = INTERDICT_NONE;
	m_interdictPeerIndex = 0;
	m_trailPositions.clear();
	m_entryFlashTimer = 0.0f;
	ResetFuelScoopState();
	m_fsdOffline = false;
	m_heatSpike = 0.0;
	m_statusMessage.clear();
	m_statusMessageTimer = 0.0f;
}

void SupercruiseController::OnEnterHyperspace()
{
	ClearInterdiction();
	ClearSupercruiseLock();
	ResetFuelScoopState();
	m_trailPositions.clear();
	m_entryFlashTimer = 0.0f;
	m_charging = false;
	m_chargeCountdown = 0.0f;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;
}

void SupercruiseController::ResetFuelScoopState()
{
	m_fuelScoopActive = false;
	m_fuelScoopUnscoopable = false;
	m_fuelScoopRate = 0.0;
	m_fuelScoopProximity = 0.0;
	m_fuelScoopAccum = 0.0;
	m_fuelScoopDispatchTimer = 0.0f;
}

void SupercruiseController::UpdateStellarFuelScoop(float timeStep)
{
	if (!m_ship || !IsActive() || !Pi::game || !Pi::game->GetSpace()) {
		ResetFuelScoopState();
		return;
	}

	const int scoopCap = m_ship->Properties().Get("fuel_scoop_cap");
	if (scoopCap <= 0) {
		ResetFuelScoopState();
		return;
	}

	Body *bestStar = nullptr;
	double bestRate = 0.0;
	double bestProx = 0.0;
	bool sawUnscoopable = false;

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		if (!b || !b->IsType(ObjectType::STAR))
			continue;
		const SystemBody *sb = b->GetSystemBody();
		if (!sb)
			continue;

		const double starR = std::max(sb->GetRadius(), 1000.0);
		const double exclR = GetExclusionZoneRadius(b);
		const double scoopOuterR = std::max(starR * 2.55, exclR * 2.2);
		const double dist = m_ship->GetPositionRelTo(b).Length();

		if (dist > exclR && dist <= scoopOuterR) {
			if (sb->IsScoopable()) {
				const double span = std::max(1.0, scoopOuterR - exclR);
				const double prox = Clamp((scoopOuterR - dist) / span, 0.0, 1.0);
				const double intensity = 0.12 + 0.88 * prox * prox;
				const double rate = 0.06 * double(scoopCap) * intensity;
				if (rate > bestRate) {
					bestRate = rate;
					bestProx = prox;
					bestStar = b;
				}
			} else {
				sawUnscoopable = true;
			}
		}
	}

	if (!bestStar) {
		m_fuelScoopActive = false;
		m_fuelScoopUnscoopable = sawUnscoopable;
		m_fuelScoopRate = 0.0;
		m_fuelScoopProximity = 0.0;
		m_fuelScoopAccum = 0.0;
		m_fuelScoopDispatchTimer = 0.0f;
		return;
	}

	m_fuelScoopActive = true;
	m_fuelScoopUnscoopable = false;
	m_fuelScoopRate = bestRate;
	m_fuelScoopProximity = bestProx;

	// Gentle thermal rise when skimming deep inside a star's corona
	if (bestProx > 0.45) {
		const double coronaHeat = 0.25 + 0.50 * ((bestProx - 0.45) / 0.55);
		m_heatSpike = std::max(m_heatSpike, coronaHeat);
	}

	m_fuelScoopAccum += bestRate * double(timeStep);
	m_fuelScoopDispatchTimer += timeStep;
	if (m_fuelScoopDispatchTimer >= 0.20f && m_fuelScoopAccum > 0.0) {
		LuaEvent::Queue("onShipScoopFuel", m_ship, bestStar, m_fuelScoopAccum);
		m_fuelScoopAccum = 0.0;
		m_fuelScoopDispatchTimer = 0.0f;
	}
}

void SupercruiseController::ShowStatusMessage(const std::string &msg, float duration)
{
	if (m_ship && !m_ship->IsType(ObjectType::PLAYER))
		return;
	m_statusMessage = msg;
	m_statusMessageTimer = duration;
}

Body *SupercruiseController::GetActiveTarget() const
{
	if (!m_ship)
		return nullptr;

	if (m_ship->IsType(ObjectType::PLAYER)) {
		const Player *player = static_cast<const Player *>(m_ship);
		if (Body *nav = player->GetNavTarget())
			return nav;
		if (Body *combat = player->GetCombatTarget())
			return combat;
		return nullptr;
	}

	return m_target;
}

bool SupercruiseController::GetActiveTargetPosRelToShip(vector3d &outPosRelToShip) const
{
	if (!m_ship)
		return false;

	if (Body *target = GetActiveTarget()) {
		outPosRelToShip = target->GetPositionRelTo(m_ship);
		return true;
	}

	if (m_targetFrame.valid()) {
		if (Frame *f = Frame::GetFrame(m_targetFrame)) {
			const vector3d posInShipFrame = f->GetPositionRelTo(m_ship->GetFrame()) + f->GetOrientRelTo(m_ship->GetFrame()) * m_targetOffset;
			outPosRelToShip = posInShipFrame - m_ship->GetPosition();
			return true;
		}
	}

	return false;
}

const Body *SupercruiseController::GetTargetObscuredBy(const vector3d &targetPosRelToShip, const Body *targetBody) const
{
	if (!m_ship || !Pi::game || !Pi::game->GetSpace())
		return nullptr;

	const double dist = targetPosRelToShip.Length();
	if (dist < 1000.0)
		return nullptr;

	const vector3d dir = targetPosRelToShip / dist;
	const Body *closestBlocker = nullptr;
	double closestProj = std::numeric_limits<double>::max();

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		if (!b || b == m_ship || b == targetBody || !b->IsType(ObjectType::TERRAINBODY))
			continue;

		const double exclR = GetExclusionZoneRadius(b);
		if (exclR <= 0.0)
			continue;

		const vector3d toBody = b->GetPositionRelTo(m_ship);
		const double proj = toBody.Dot(dir);

		// Body center must be in front of the ship and before the destination
		if (proj <= 0.0 || proj >= dist)
			continue;

		// Check if target is located on or in the immediate vicinity of body b
		const vector3d toTargetFromBody = targetPosRelToShip - toBody;
		const double targetRadiusOnBody = toTargetFromBody.Length();
		const bool targetIsOnBody = targetRadiusOnBody <= (exclR * 1.25);
		// If target is attached to body b (e.g. surface starport), the occlusion boundary is the physical horizon beneath the starport.
		// If b is an intervening body, keep a generous clearance buffer to avoid gravity well lock.
		const double clearR = targetIsOnBody ? (std::min(exclR, targetRadiusOnBody) * 0.998) : std::max(exclR * 1.12, exclR + 50000.0);

		const double perpDistSq = toBody.LengthSqr() - proj * proj;
		if (perpDistSq < clearR * clearR && proj < closestProj) {
			closestProj = proj;
			closestBlocker = b;
		}
	}

	return closestBlocker;
}

bool SupercruiseController::IsTargetOccluded(Body **outBlocker) const
{
	if (outBlocker)
		*outBlocker = nullptr;

	vector3d relToTarget;
	if (!GetActiveTargetPosRelToShip(relToTarget))
		return false;

	const Body *blocker = GetTargetObscuredBy(relToTarget, GetActiveTarget());
	if (blocker) {
		if (outBlocker)
			*outBlocker = const_cast<Body *>(blocker);
		return true;
	}
	return false;
}

void SupercruiseController::ComputeAISteering(const vector3d &targetPosRelToShip, const Body *targetBody, vector3d &outAngInput, double &outThrottle) const
{
	outAngInput = vector3d(0.0);
	outThrottle = 0.75;
	if (!m_ship)
		return;

	const double dist = targetPosRelToShip.Length();
	vector3d desiredDir = targetPosRelToShip.NormalizedSafe();
	if (desiredDir.LengthSqr() < 0.1)
		desiredDir = -m_ship->GetOrient().VectorZ();

	bool isOccluded = false;

	// 1. Planetary occlusion avoidance: when destination is obscured behind a planetary or stellar body,
	// orbit tangentially along the great circle until line-of-sight clears the horizon limb.
	if (const Body *blocker = GetTargetObscuredBy(targetPosRelToShip, targetBody)) {
		isOccluded = true;
		const double exclR = GetExclusionZoneRadius(blocker);
		const double clearR = std::max(exclR * 1.12, exclR + 50000.0);
		const vector3d toBody = blocker->GetPositionRelTo(m_ship);
		const double bodyDist = toBody.Length();

		if (bodyDist > 1.0) {
			// Radial unit vector from body center to ship
			const vector3d uBS = -toBody / bodyDist;
			// Vector from body center to target
			const vector3d toTargetFromBlocker = targetPosRelToShip - toBody;
			const vector3d uBT = toTargetFromBlocker.NormalizedSafe();

			// Project target direction onto the plane perpendicular to ship radius (great circle tangent)
			vector3d tangentRaw = uBT - uBS * uBT.Dot(uBS);
			if (tangentRaw.LengthSqr() < 1e-4) {
				const vector3d fwd = -m_ship->GetOrient().VectorZ();
				tangentRaw = fwd - uBS * fwd.Dot(uBS);
				if (tangentRaw.LengthSqr() < 1e-4)
					tangentRaw = MathUtil::OrthogonalDirection(uBS);
			}
			const vector3d tangentDir = tangentRaw.NormalizedSafe();

			if (bodyDist > clearR * 1.5) {
				// Far from body: aim at the horizon limb tangent point on the side of the target
				const vector3d limbPoint = toBody + tangentDir * clearR;
				desiredDir = limbPoint.NormalizedSafe();
			} else {
				// In orbital cruise around the body: orbit tangentially at safe clearance altitude
				const double altDeficit = clearR - bodyDist;
				double radialBias = 0.0;
				if (altDeficit > 0.0) {
					radialBias = std::min(0.65, altDeficit / 20000.0);
				} else {
					radialBias = Clamp((clearR - bodyDist) / clearR, -0.15, 0.15);
				}
				desiredDir = (tangentDir * (1.0 - std::fabs(radialBias)) + uBS * radialBias).NormalizedSafe();
			}
		}
	} else if (Pi::game && Pi::game->GetSpace()) {
		// 2. Obstacle avoidance: steer tangentially around intervening planetary/stellar exclusion zones
		double bestAvoidDist = dist;
		for (Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (!b || !b->IsType(ObjectType::TERRAINBODY))
				continue;
			const double exclR = GetExclusionZoneRadius(b);
			if (exclR <= 0.0)
				continue;

			bool targetOnOrNearBody = (b == targetBody);
			if (!targetOnOrNearBody && targetBody) {
				const double targetDistFromB = targetBody->GetPositionRelTo(b).Length();
				if (targetDistFromB <= exclR * 1.65 + SAFE_DISENGAGE_DIST) {
					targetOnOrNearBody = true;
				}
			}

			// Keep a tighter buffer when approaching the target body (or a station on/orbiting it) vs an intervening body
			const double margin = (b == targetBody)
				? (exclR * 1.03 + 20000.0)
				: (targetOnOrNearBody ? (exclR + 15000.0) : (exclR * 1.35 + 80000.0));
			const vector3d toBody = b->GetPositionRelTo(m_ship);
			const double bodyDist = toBody.Length();
			if (bodyDist < 1.0)
				continue;

			// If already inside the safety buffer and moving inward, steer radially outward
			if (bodyDist < margin && toBody.Dot(desiredDir) > 0.0) {
				const vector3d radialOut = -toBody / bodyDist;
				const vector3d tangent = (desiredDir - radialOut * desiredDir.Dot(radialOut)).NormalizedSafe();
				desiredDir = (tangent.LengthSqr() > 0.1) ? (radialOut * 0.65 + tangent * 0.75).NormalizedSafe() : radialOut;
				bestAvoidDist = std::min(bestAvoidDist, bodyDist);
				continue;
			}

			// Occlusion behind a host planet is already handled in branch 1 (GetTargetObscuredBy),
			// so do not deflect away from a surface or low-orbit target unless the path actually pierces the exclusion zone.
			if (targetOnOrNearBody && b != targetBody && bodyDist >= margin) {
				const double proj = toBody.Dot(desiredDir);
				if (proj > 0.0 && proj < dist) {
					const vector3d closestOffset = desiredDir * proj - toBody;
					const double perpDist = closestOffset.Length();
					const double innerSafe = exclR + 12000.0;
					if (perpDist < innerSafe) {
						vector3d escapeDir = (perpDist > 1.0) ? (closestOffset / perpDist) : MathUtil::OrthogonalDirection(toBody).Normalized();
						desiredDir = (toBody + escapeDir * innerSafe).NormalizedSafe();
						bestAvoidDist = bodyDist;
					}
				}
				continue;
			}

			if (bodyDist >= bestAvoidDist && b != targetBody)
				continue;

			const double proj = toBody.Dot(desiredDir);
			if (proj <= 0.0 || proj >= dist)
				continue;

			const vector3d closestOffset = desiredDir * proj - toBody;
			const double perpDist = closestOffset.Length();
			if (perpDist < margin) {
				vector3d escapeDir = (perpDist > 1.0) ? (closestOffset / perpDist) : MathUtil::OrthogonalDirection(toBody).Normalized();
				const vector3d tangentPoint = toBody + escapeDir * margin;
				desiredDir = tangentPoint.NormalizedSafe();
				bestAvoidDist = bodyDist;
			}
		}
	}

	// Convert desired world direction to ship-local coordinates (-Z forward, +X right, +Y up)
	const vector3d toLocal = desiredDir * m_ship->GetOrient();
	const double pitchErr = std::atan2(toLocal.y, -toLocal.z);
	const double yawErr = std::atan2(-toLocal.x, -toLocal.z);

	const double pitchCmd = Clamp(pitchErr * 2.5, -1.0, 1.0);
	const double yawCmd = Clamp(yawErr * 2.5, -1.0, 1.0);
	// Roll into large lateral offsets so faster pitch axis handles most of the turn
	const double rollCmd = (std::fabs(yawErr) > 0.18) ? Clamp(-toLocal.x * 1.6, -1.0, 1.0) : 0.0;
	outAngInput = vector3d(pitchCmd, yawCmd, rollCmd);

	if (isOccluded) {
		// When orbiting an occluded body, hold 75% blue zone for maximum steering agility and controlled speed
		outThrottle = 0.75;
		return;
	}

	const bool aligned = (toLocal.z < -0.85);
	if (!aligned) {
		// Blue zone provides 1.25x turn agility
		outThrottle = 0.75;
		return;
	}

	const double exclR = (targetBody && targetBody->IsType(ObjectType::TERRAINBODY))
		? GetExclusionZoneRadius(targetBody)
		: 0.0;
	const double effectiveDist = std::max(0.0, dist - exclR);
	const double speed = std::max(m_speed, MIN_SPEED);
	const double eta = (speed > 1.0) ? (effectiveDist / speed) : 0.0;
	if (m_slowDownWarning) {
		// When entering a heavy gravity well or approaching safe drop threshold, regulate throttle to 0.55
		// to allow smooth, controlled braking without sudden throttle oscillation
		outThrottle = 0.55;
	} else if (effectiveDist <= SAFE_DISENGAGE_DIST * 1.6 && speed > SAFE_DISENGAGE_SPEED * 0.90) {
		outThrottle = 0.50;
	} else if (effectiveDist > 30.0 * LIGHT_SPEED && eta > 10.0) {
		outThrottle = 1.0;
	} else {
		outThrottle = 0.75;
	}
}

void SupercruiseController::UpdateEnvironmentAndTarget(float timeStep, Body **outHitExclusionBody)
{
	if (outHitExclusionBody)
		*outHitExclusionBody = nullptr;

	m_ringDropPlanet = nullptr;
	m_ringImmersionPlanet = nullptr;

	if (!m_ship || !Pi::game || !Pi::game->GetSpace())
		return;

	double envMax = MAX_SPEED;
	double maxStrain = 0.0;
	Planet *ringReadyPlanet = nullptr;
	Planet *ringImmersionPlanet = nullptr;
	Body *activeTarget = GetActiveTarget();
	const vector3d forwardDir = -m_ship->GetOrient().VectorZ();
	const FrameId shipFrameId = m_ship->GetFrame();
	const Frame *shipFrame = Frame::GetFrame(shipFrameId);

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		if (!b->IsType(ObjectType::TERRAINBODY))
			continue;
		const SystemBody *sb = b->GetSystemBody();
		if (!sb)
			continue;

		const double r = std::max(sb->GetRadius(), 1000.0);
		const double maxExclR = GetExclusionZoneRadius(b);
		const vector3d posInBodyFrame = m_ship->GetPositionRelTo(b);
		const double dist = posInBodyFrame.Length();
		double exclR = maxExclR;
		if (maxExclR > 0.0 && dist <= maxExclR * 3.0 + 250000.0 && sb->GetSuperType() == SystemBody::SUPERTYPE_ROCKY_PLANET) {
			const vector3d unitDirInBody = (dist > 1.0) ? (posInBodyFrame / dist) : vector3d(0.0, 1.0, 0.0);
			exclR = GetExclusionZoneRadiusAtDir(b, unitDirInBody);
		}

		const vector3d bodyPos = b->GetPositionRelTo(m_ship->GetFrame());
		const vector3d toBody = bodyPos - m_ship->GetPosition();

		const vector3d toBodyNorm = (toBody.Length() > 1.0) ? toBody.Normalized() : vector3d(0.0);
		const double toBodyDot = forwardDir.Dot(toBodyNorm); // > 0: heading towards body
		const double outboundDot = -toBodyDot;               // > 0: heading away from body

		// Check exclusion zone impact: a ship in Supercruise can never remain inside a body's exclusion zone
		if (exclR > 0.0 && dist <= exclR) {
			if (outHitExclusionBody && !*outHitExclusionBody) {
				*outHitExclusionBody = b;
			}
		}

		const double h = std::max(dist - exclR, 1000.0);
		const bool isStar = (sb->GetSuperType() == SystemBody::SUPERTYPE_STAR);

		double vBody;
		double strain;

		if (isStar) {
			// In Elite Dangerous, stellar gravity wells are governed by gravitational potential (mass / distance),
			// not bloated by physical hypergiant radii.
			const double hLs = h / LIGHT_SPEED;
			const double starMassInSols = Clamp(sb->GetMassInSols().ToDouble(), 0.1, 100.0);
			const double massScale = std::pow(starMassInSols, 0.35);
			const double effectiveH_ls = hLs / massScale;

			// Near exclusion boundary (effectiveH_ls <= 1.0 ls): 100 km/s - 1.0 Mm/s
			// 1.0 ls to 8.0 ls: 1.0 Mm/s ramping up to 1.0 c
			// 8.0 ls to 50.0 ls: 1.0 c ramping up to 25.0 c
			// > 50.0 ls: accelerating freely into hundreds of c
			if (effectiveH_ls <= 1.0) {
				vBody = 100000.0 + 900000.0 * effectiveH_ls;
			} else if (effectiveH_ls <= 8.0) {
				vBody = 1000000.0 + (LIGHT_SPEED - 1000000.0) * (effectiveH_ls - 1.0) / 7.0;
			} else if (effectiveH_ls <= 50.0) {
				const double frac = (effectiveH_ls - 8.0) / 42.0;
				vBody = LIGHT_SPEED + 24.0 * LIGHT_SPEED * frac;
			} else {
				const double outerLs = effectiveH_ls - 50.0;
				vBody = 25.0 * LIGHT_SPEED + LIGHT_SPEED * (0.6 * outerLs + 0.008 * outerLs * outerLs);
			}

			const double strainDist = effectiveH_ls / 20.0;
			strain = 1.0 / (1.0 + std::pow(std::max(0.01, strainDist), 1.35));
		} else {
			// Planetary/lunar gravity well: parameterized by planetary radii (hRadii = h / r)
			// Scale envelope speed with body radius relative to Earth so approaching huge gas giants
			// (r = 50,000-80,000 km) takes ~15-20s instead of crawling for minutes, while Earth-sized
			// worlds keep the exact 100 km/s - 800 km/s safe drop envelope.
			const double hRadii = h / r;
			const double rScale = Clamp(std::pow(r / 6371000.0, 0.88), 0.75, 16.0);
			if (hRadii <= 1.0) {
				vBody = (100000.0 + 700000.0 * hRadii) * rScale;
			} else if (hRadii <= 5.0) {
				vBody = (800000.0 + 4000000.0 * (hRadii - 1.0) / 4.0) * rScale;
			} else {
				const double outerH = hRadii - 5.0;
				vBody = 4800000.0 * rScale + LIGHT_SPEED * (0.05 * std::pow(outerH, 1.35) + 0.01 * outerH * outerH) * std::min(rScale, 4.0);
			}

			strain = 1.0 / (1.0 + std::pow(h / (r * 2.0), 1.25));
		}

		// Directional Escape Vector Relief (Elite Dangerous mechanic):
		// When flying radially away from a body (outboundDot > 0), gravity well drag is drastically reduced,
		// allowing the FSD to accelerate smoothly away into FTL.
		if (outboundDot > 0.0) {
			const double boostFactor = 1.0 + 3.0 * outboundDot;
			vBody = std::min(MAX_SPEED, vBody * boostFactor);
			strain *= (1.0 - 0.65 * outboundDot);
		}

		// Planetary Ring Proximity: planar speed regulation & safe/emergency drop-in
		if (sb->HasRings() && b->IsType(ObjectType::PLANET)) {
			Planet *planet = static_cast<Planet *>(b);
			Frame *pf = Frame::GetFrame(planet->GetFrame());
			FrameId orbFrameId = pf ? pf->GetNonRotFrame() : planet->GetFrame();
			if (orbFrameId.valid() && Frame::GetFrame(orbFrameId)) {
				const vector3d relOrb = m_ship->GetPositionRelTo(orbFrameId) - planet->GetPositionRelTo(orbFrameId);
				const matrix3x3d axialRot = matrix3x3d::RotateX(sb->GetAxialTilt());
				const vector3d relRing = axialRot.Transpose() * relOrb;
				const double rXZ = std::hypot(relRing.x, relRing.z);
				const double absY = std::abs(relRing.y);

				const RingStyle &rings = sb->GetRings();
				const double innerR = rings.minRadius.ToDouble() * r;
				const double outerR = rings.maxRadius.ToDouble() * r;
				const double halfThick = rings.thickness.ToDouble();

				if (rXZ >= innerR * 0.96 && rXZ <= outerR * 1.04) {
					const vector3d fwdOrb = (shipFrame && shipFrameId != orbFrameId)
						? (shipFrame->GetOrientRelTo(orbFrameId) * forwardDir)
						: forwardDir;
					const vector3d fwdRing = axialRot.Transpose() * fwdOrb;
					const double vertSign = relRing.y * fwdRing.y; // < 0: approaching midplane; > 0: escaping plane

					if (absY < 200000000.0) {
						const double yAlt = std::max(absY - 85000.0, 0.0);
						double ringVMax = (yAlt <= 250000.0)
							? (SAFE_DISENGAGE_SPEED * 0.85)
							: (SAFE_DISENGAGE_SPEED * 0.85 + 0.08 * yAlt);
						double ringStrain = 1.0 / (1.0 + std::pow(yAlt / 1200000.0, 1.25));
						if (vertSign > 0.0 && std::abs(fwdRing.y) > 0.05) {
							ringVMax = std::min(MAX_SPEED, ringVMax * (1.0 + 3.0 * std::abs(fwdRing.y)));
							ringStrain *= (1.0 - 0.65 * std::abs(fwdRing.y));
						}
						vBody = std::min(vBody, ringVMax);
						strain = std::max(strain, ringStrain);
					}

					if (rXZ >= innerR && rXZ <= outerR) {
						if (absY <= 1000000.0 && m_speed <= SAFE_DISENGAGE_SPEED) {
							ringReadyPlanet = planet;
						}
						const double dropSlabY = std::max(halfThick * 2.0, 85000.0);
						if (absY <= dropSlabY && vertSign < -0.05) {
							if (m_speed <= SAFE_DISENGAGE_SPEED) {
								ringImmersionPlanet = planet;
							} else if (outHitExclusionBody && !*outHitExclusionBody) {
								*outHitExclusionBody = b;
							}
						}
					}
				}
			}
		}

		vBody = Clamp(vBody, 100000.0, MAX_SPEED);
		envMax = std::min(envMax, vBody);
		maxStrain = std::max(maxStrain, strain);
	}

	m_maxEnvSpeed = envMax;
	m_gravityStrain = Clamp(maxStrain, 0.0, 1.0);
	m_ringDropPlanet = ringReadyPlanet;
	m_ringImmersionPlanet = ringImmersionPlanet;

	// Target telemetry
	vector3d relToTarget;
	const bool targetIsSCShip = activeTarget && activeTarget->IsType(ObjectType::SHIP) &&
		static_cast<const Ship *>(activeTarget)->GetFlightState() == Ship::SUPERCRUISE;

	if (GetActiveTargetPosRelToShip(relToTarget)) {
		m_targetDistance = relToTarget.Length();
		double targetExclR = 0.0;
		if (activeTarget && activeTarget->IsType(ObjectType::TERRAINBODY)) {
			const double maxTargetExclR = GetExclusionZoneRadius(activeTarget);
			targetExclR = (m_targetDistance <= maxTargetExclR * 3.0 + 250000.0)
				? GetExclusionZoneRadiusAtDir(activeTarget, m_ship->GetPositionRelTo(activeTarget).NormalizedSafe())
				: maxTargetExclR;
		}
		const double effectiveDist = std::max(0.0, m_targetDistance - targetExclR);
		m_targetETA = (m_speed > 1.0) ? (effectiveDist / m_speed) : 0.0;

		const bool isOccluded = (GetTargetObscuredBy(relToTarget, activeTarget) != nullptr);
		m_safeDisengageReady = !targetIsSCShip && !isOccluded && (effectiveDist <= SAFE_DISENGAGE_DIST) && (m_speed <= SAFE_DISENGAGE_SPEED);

		// Overshoot ("Loop of Shame") warning when ETA drops below 5.2s outside safe drop range,
		// or when entering a heavy gravity well at excessive speed (Elite Dangerous SLOW DOWN indicator)
		const double closingDot = forwardDir.Dot(relToTarget.NormalizedSafe());
		const bool targetOvershoot = !targetIsSCShip && (closingDot > 0.5) &&
			(effectiveDist > SAFE_DISENGAGE_DIST) &&
			(m_speed > SAFE_DISENGAGE_SPEED) &&
			(m_targetETA > 0.0 && m_targetETA < 5.3);
		const bool gravityWellSlowDown = (m_gravityStrain > 0.25) && (m_speed > m_maxEnvSpeed * 1.08);
		m_slowDownWarning = targetOvershoot || gravityWellSlowDown;
	} else {
		m_targetDistance = 0.0;
		m_targetETA = 0.0;
		m_safeDisengageReady = false;
		m_slowDownWarning = (m_gravityStrain > 0.25) && (m_speed > m_maxEnvSpeed * 1.08);
		bool keepAssistForHyperspace = m_ship && m_ship->IsHyperspaceActive();
		if (!keepAssistForHyperspace && m_ship && m_ship->IsType(ObjectType::PLAYER) && Pi::game && Pi::game->GetSectorView() && Pi::game->GetSpace() && Pi::game->GetSpace()->GetStarSystem()) {
			const SystemPath hTarget = Pi::game->GetSectorView()->GetHyperspaceTarget();
			keepAssistForHyperspace = hTarget.HasValidSystem() && !hTarget.IsSameSystem(Pi::game->GetSpace()->GetStarSystem()->GetPath());
		}
		if (m_assistActive && !keepAssistForHyperspace) {
			SetAssistActive(false, false);
		}
	}
	if (m_ringDropPlanet) {
		m_safeDisengageReady = true;
	}
}

void SupercruiseController::StaticUpdate(float timeStep)
{
	if (m_statusMessageTimer > 0.0f) {
		m_statusMessageTimer = std::max(0.0f, m_statusMessageTimer - timeStep);
		if (m_statusMessageTimer == 0.0f)
			m_statusMessage.clear();
	}

	if (m_cooldown > 0.0f) {
		m_cooldown = std::max(0.0f, m_cooldown - timeStep);
	}

	if (m_nullifierCooldown > 0.0f) {
		m_nullifierCooldown = std::max(0.0f, m_nullifierCooldown - timeStep);
	}

	if (m_heatSpike > 0.0) {
		m_heatSpike = std::max(0.0, m_heatSpike - double(timeStep) * 0.045);
	}

	if (m_entryFlashTimer > 0.0f) {
		m_entryFlashTimer = std::max(0.0f, m_entryFlashTimer - timeStep);
	}

	if (m_lockedShip && (!IsActive() || m_lockedShip->IsDead() || m_lockedShip->GetFlightState() != Ship::SUPERCRUISE)) {
		ClearSupercruiseLock();
	}

	if (m_ship && m_ship->IsType(ObjectType::PLAYER)) {
		ClearStaleSupercruiseTarget();
	}

	if (m_charging) {
		std::string reason;
		if (m_ship->GetFlightState() != Ship::FLYING) {
			AbortCharge("FSD CHARGE ABORTED");
			return;
		}
		if (m_ship->GetWheelState() > 0.0f || m_ship->GetWheelTransition() != 0) {
			AbortCharge("FSD ABORTED: LANDING GEAR DEPLOYED");
			return;
		}
		if (IsMassLocked(&reason)) {
			AbortCharge("FSD ABORTED: " + reason);
			return;
		}
		if (m_ship->GetVelocity().Length() < MIN_ENGAGE_SPEED) {
			char buf[128];
			snprintf(buf, sizeof(buf), "FSD ABORTED: TOO SLOW — ACCELERATE TO %.0f m/s", MIN_ENGAGE_SPEED);
			AbortCharge(buf);
			return;
		}

		const double massLock = GetShipMassLockFactor();
		m_chargeCountdown -= timeStep / float(massLock);
		if (m_chargeCountdown <= 0.0f) {
			EnterSupercruise();
		}
		return;
	}

	if (!IsActive()) {
		if (m_fuelScoopActive || m_fuelScoopUnscoopable)
			ResetFuelScoopState();
		return;
	}

	Body *hitExclBody = nullptr;
	UpdateEnvironmentAndTarget(timeStep, &hitExclBody);

	if (hitExclBody) {
		EmergencyDrop("EMERGENCY DROP — TOO CLOSE TO " + hitExclBody->GetLabel());
		return;
	}

	if (m_ringImmersionPlanet) {
		Planet *immPlanet = m_ringImmersionPlanet;
		DropIntoRing(immPlanet, "RING IMMERSION — DROPPED INTO " + immPlanet->GetLabel() + " RINGS");
		return;
	}

	UpdateStellarFuelScoop(timeStep);

	if (m_interdictRole != INTERDICT_NONE) {
		m_assistActive = false;
		m_dockOnArrival = false;
	}

	// Supercruise Assist (Autopilot Mk 2) management
	if (m_assistActive) {
		if (!HasAssistModule()) {
			SetAssistActive(false, false);
		} else {
			m_throttle = 0.75;
			if (m_safeDisengageReady) {
				SafeDisengage();
				return;
			}
		}
	}

	// Compute desired speed from throttle and environment cap
	double targetCapSpeed = m_maxEnvSpeed;
	vector3d targetRel;
	const bool hasTarget = GetActiveTargetPosRelToShip(targetRel);
	Body *activeTarget = GetActiveTarget();
	const bool targetIsSCShip = activeTarget && activeTarget->IsType(ObjectType::SHIP) &&
		static_cast<const Ship *>(activeTarget)->GetFlightState() == Ship::SUPERCRUISE;
	const bool inBlueZone = (m_throttle >= 0.65 && m_throttle <= 0.80);

	// The 6-Second Rule: when approaching a stationary/sublight target, regulate the speed envelope
	// along v = d / 6.0 so ETA holds steady at 0:06 all the way down to Safe Disengage.
	if (hasTarget && !targetIsSCShip && m_targetDistance < 500.0 * LIGHT_SPEED) {
		double targetExclR = 0.0;
		if (activeTarget && activeTarget->IsType(ObjectType::TERRAINBODY)) {
			const double maxTargetExclR = GetExclusionZoneRadius(activeTarget);
			targetExclR = (m_targetDistance <= maxTargetExclR * 3.0 + 250000.0)
				? GetExclusionZoneRadiusAtDir(activeTarget, m_ship->GetPositionRelTo(activeTarget).NormalizedSafe())
				: maxTargetExclR;
		}
		const double effectiveDist = std::max(0.0, m_targetDistance - targetExclR);

		const Body *blocker = GetTargetObscuredBy(targetRel, activeTarget);
		const bool isOccluded = (blocker != nullptr);
		double sixSecondDist = effectiveDist;
		if (isOccluded && blocker) {
			// When orbiting an intervening or host planet to reach a surface starport or occluded station,
			// maintain controlled orbital cruise speed proportional to remaining arc distance so the ship
			// never overshoots at high speed upon cresting the horizon.
			const double exclR = GetExclusionZoneRadius(blocker);
			sixSecondDist = std::max(effectiveDist, exclR * 0.45);
		}

		if (inBlueZone || m_assistActive) {
			const double sixSecondSpeed = std::max(MIN_SPEED, sixSecondDist / 6.0);
			targetCapSpeed = std::min(targetCapSpeed, sixSecondSpeed / 0.75);
		} else if (m_throttle < 0.65 && m_throttle > 0.001) {
			const double subBlueSpeed = std::max(MIN_SPEED, (sixSecondDist / 6.0) * (m_throttle / 0.75));
			targetCapSpeed = std::min(targetCapSpeed, subBlueSpeed / m_throttle);
		}

		// Anti-Loop-of-Shame misalignment speed regulation for AI / Assist:
		// ensure turn radius (v / omega) stays strictly inside 0.3 * effectiveDist when misaligned with a close target
		if ((!m_ship->IsType(ObjectType::PLAYER) || m_assistActive) && !isOccluded && effectiveDist < 25.0 * LIGHT_SPEED) {
			const vector3d forwardDir = -m_ship->GetOrient().VectorZ();
			const double closingDot = forwardDir.Dot(targetRel.NormalizedSafe());
			if (closingDot < 0.82) {
				const double turnSpeedCap = std::max(MIN_SPEED, effectiveDist * (closingDot > 0.25 ? 0.14 : 0.08));
				targetCapSpeed = std::min(targetCapSpeed, turnSpeedCap / std::max(0.25, m_throttle));
			}
		}
	} else if (hasTarget && targetIsSCShip && !m_ship->IsType(ObjectType::PLAYER)) {
		// AI pursuing another Supercruise ship: match speed, follow distance, and approach path
		// so pursuers smoothly settle behind both FTL and sub-1c locked targets for interdiction
		const Ship *targetShip = static_cast<const Ship *>(activeTarget);
		const double targetSpeed = (targetShip && targetShip->GetSupercruise()) ? targetShip->GetSupercruise()->GetSpeed() : MIN_SPEED;
		const vector3d forwardDir = -m_ship->GetOrient().VectorZ();
		const vector3d toTargetDir = targetRel.NormalizedSafe();
		const double closingDot = forwardDir.Dot(toTargetDir);
		const double behindDot = (-targetShip->GetOrient().VectorZ()).Dot(toTargetDir);
		const double followGap = std::max(SAFE_DISENGAGE_DIST * 0.5, targetSpeed * 3.0);
		double desiredPursuitSpeed;
		if (closingDot > 0.55) {
			if (m_targetDistance <= followGap * 2.5 && behindDot > 0.45) {
				const double closure = std::max(0.0, (m_targetDistance - followGap) / 6.0);
				desiredPursuitSpeed = std::max(MIN_SPEED, std::min(targetSpeed * 1.45 + MIN_SPEED, targetSpeed + closure));
			} else {
				desiredPursuitSpeed = std::max(MIN_SPEED, targetSpeed + m_targetDistance / 6.0);
			}
		} else {
			desiredPursuitSpeed = std::max(MIN_SPEED, std::min(targetSpeed * 0.90, m_targetDistance / 8.0));
		}
		targetCapSpeed = std::min(targetCapSpeed, desiredPursuitSpeed / std::max(0.25, m_throttle));
	}

	if (m_throttle <= 0.001) {
		m_desiredSpeed = MIN_SPEED;
	} else {
		m_desiredSpeed = std::max(MIN_SPEED, m_throttle * targetCapSpeed);
	}

	// Exponential acceleration & braking physics:
	// Responsive deceleration allows 6-second rule approaches and prompt speed reduction
	// when throttling down or entering gravity wells, while overthrottling past 0:05 ETA
	// causes an overshoot ("Loop of Shame").
	if (m_speed < m_desiredSpeed) {
		const double accel = std::max(45000.0, m_speed * 0.38) * (0.35 + 0.65 * m_throttle);
		m_speed = std::min(m_desiredSpeed, m_speed + accel * timeStep);
	} else if (m_speed > m_desiredSpeed) {
		const double speedDelta = m_speed - m_desiredSpeed;
		double decelFactor = 0.45 + 1.25 * m_gravityStrain;
		if (inBlueZone || m_assistActive) {
			decelFactor = 0.85 + 2.0 * m_gravityStrain;
		}
		const double decel = std::max(150000.0, m_speed * decelFactor + speedDelta * (1.5 + 2.5 * m_gravityStrain));
		m_speed = std::max(m_desiredSpeed, m_speed - decel * timeStep);
	}

	m_speed = Clamp(m_speed, MIN_SPEED, MAX_SPEED);

	// Sample recent root-frame positions for curved FTL burn-in trails (only at FTL >= 1c)
	if (m_speed >= LIGHT_SPEED) {
		if (Pi::game && Pi::game->GetSpace()) {
			m_trailSampleTimer += timeStep;
			if (m_trailSampleTimer >= 0.04f || m_trailPositions.empty()) {
				m_trailSampleTimer = 0.0f;
				const vector3d rootPos = m_ship->GetPositionRelTo(Pi::game->GetSpace()->GetRootFrame());
				m_trailPositions.push_front(rootPos);
				while (m_trailPositions.size() > MAX_TRAIL_SAMPLES)
					m_trailPositions.pop_back();
			}
		}
	} else if (!m_trailPositions.empty()) {
		m_trailPositions.clear();
		m_trailSampleTimer = 0.0f;
	}

	if (m_interdictRole == INTERDICT_ATTACKER) {
		UpdateInterdiction(timeStep);
	}
}

void SupercruiseController::TimeStepUpdate(float timeStep, const vector3d &desiredAngInput)
{
	if (!IsActive() || !m_ship)
		return;

	// Rotational agility (Pitch/Roll/Yaw):
	// Pitch (x) and Roll (z) are responsive; Yaw (y) is sluggish like Elite Dangerous.
	const double basePitchRate = 0.85; // rad/s
	const double baseYawRate = 0.28;   // rad/s
	const double baseRollRate = 1.65;  // rad/s

	const double speedNorm = Clamp(
		std::log10(std::max(m_speed, MIN_SPEED) / MIN_SPEED) / std::log10(MAX_SPEED / MIN_SPEED),
		0.0, 1.0);
	const double speedFactor = 1.0 - 0.55 * speedNorm;
	const bool inBlueZone = (m_throttle >= 0.65 && m_throttle <= 0.80);
	const double blueZoneMult = inBlueZone ? 1.25 : 1.0;

	vector3d angCmd(
		Clamp(desiredAngInput.x, -1.0, 1.0) * basePitchRate * speedFactor * blueZoneMult,
		Clamp(desiredAngInput.y, -1.0, 1.0) * baseYawRate * speedFactor * blueZoneMult,
		Clamp(desiredAngInput.z, -1.0, 1.0) * baseRollRate * speedFactor * blueZoneMult);

	// If Supercruise Assist is active and player is not overriding pitch/yaw, steer toward target
	// (Prioritize the active hyperjump target vector whenever a hyperjump is charging/waiting for alignment,
	// or when no in-system nav target is selected and a cross-system hyperspace target is set).
	if (m_assistActive && std::fabs(desiredAngInput.x) < 0.05 && std::fabs(desiredAngInput.y) < 0.05) {
		vector3d targetRel;
		Body *steerTargetBody = GetActiveTarget();
		bool hasSteerVector = false;

		if (m_ship->IsHyperspaceActive()) {
			vector3d hyperDirInFrame;
			if (m_ship->GetHyperspaceTargetDirection(m_ship->GetHyperspaceDest(), hyperDirInFrame) && hyperDirInFrame.LengthSqr() > 0.5) {
				targetRel = hyperDirInFrame * (100.0 * LIGHT_SPEED);
				steerTargetBody = nullptr;
				hasSteerVector = true;
			}
		}

		if (!hasSteerVector && GetActiveTargetPosRelToShip(targetRel)) {
			hasSteerVector = true;
		}

		if (!hasSteerVector && m_ship->IsType(ObjectType::PLAYER) && Pi::game && Pi::game->GetSectorView() && Pi::game->GetSpace() && Pi::game->GetSpace()->GetStarSystem()) {
			const SystemPath hTarget = Pi::game->GetSectorView()->GetHyperspaceTarget();
			if (hTarget.HasValidSystem() && !hTarget.IsSameSystem(Pi::game->GetSpace()->GetStarSystem()->GetPath())) {
				vector3d hyperDirInFrame;
				if (m_ship->GetHyperspaceTargetDirection(hTarget, hyperDirInFrame) && hyperDirInFrame.LengthSqr() > 0.5) {
					targetRel = hyperDirInFrame * (100.0 * LIGHT_SPEED);
					steerTargetBody = nullptr;
					hasSteerVector = true;
				}
			}
		}

		if (hasSteerVector) {
			vector3d aiAng;
			double aiThrottle;
			ComputeAISteering(targetRel, steerTargetBody, aiAng, aiThrottle);

			angCmd.x = aiAng.x * basePitchRate * blueZoneMult;
			angCmd.y = aiAng.y * baseYawRate * blueZoneMult;
			if (std::fabs(aiAng.z) > 0.05 && std::fabs(desiredAngInput.z) < 0.05) {
				angCmd.z = aiAng.z * baseRollRate * blueZoneMult;
			}
		}
	}

	const double rotLen = angCmd.Length();
	vector3d forwardDir = -m_ship->GetOrient().VectorZ();
	if (rotLen > 1e-6) {
		const double angle = rotLen * timeStep;
		const vector3d worldAxis = m_ship->GetOrient() * (angCmd * (1.0 / rotLen));
		const matrix3x3d rotMat = matrix3x3d::Rotate(angle, worldAxis);
		forwardDir = -(rotMat * m_ship->GetOrient()).VectorZ();
	}
	m_ship->SetAngVelocity(m_ship->GetOrient() * angCmd);

	// Swept ray-sphere / ray-terrain exclusion zone check along forward vector (-Z)
	const vector3d startPos = m_ship->GetPosition();
	const double stepDist = m_speed * double(timeStep);
	const Frame *shipFrame = Frame::GetFrame(m_ship->GetFrame());

	if (Pi::game && Pi::game->GetSpace() && stepDist > 0.0 && shipFrame) {
		Body *hitBody = nullptr;
		double earliestHitDist = stepDist + 1.0;

		for (Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (!b || !b->IsType(ObjectType::TERRAINBODY))
				continue;
			const SystemBody *sb = b->GetSystemBody();
			if (!sb)
				continue;

			const double maxExclR = GetExclusionZoneRadius(b);
			if (maxExclR <= 0.0)
				continue;

			const vector3d startRel = m_ship->GetPositionRelTo(b);
			const matrix3x3d orientToBody = shipFrame->GetOrientRelTo(b->GetFrame());
			const vector3d fwdRel = (orientToBody * forwardDir).NormalizedSafe();

			const vector3d toBody = -startRel;
			const double distSq0 = startRel.LengthSqr();
			const double proj = toBody.Dot(fwdRel);

			// Fast broadphase: closest point on segment [0, stepDist] to body center
			const double tClosest = Clamp(proj, 0.0, stepDist);
			const double minDistSq = (startRel + fwdRel * tClosest).LengthSqr();
			if (minDistSq > maxExclR * maxExclR)
				continue;

			const double perpDistSq = std::max(0.0, distSq0 - proj * proj);
			if (perpDistSq > maxExclR * maxExclR)
				continue;

			const double halfChordMax = std::sqrt(std::max(0.0, maxExclR * maxExclR - perpDistSq));
			const double segStart = std::max(0.0, proj - halfChordMax);
			const double segEnd = std::min(stepDist, proj + halfChordMax);
			if (segStart > segEnd)
				continue;

			const bool isRocky = (sb->GetSuperType() == SystemBody::SUPERTYPE_ROCKY_PLANET);
			if (!isRocky) {
				if (proj > 0.0 || distSq0 <= maxExclR * maxExclR) {
					if (segStart < earliestHitDist) {
						earliestHitDist = segStart;
						hitBody = b;
					}
				}
			} else {
				const TerrainBody *tb = static_cast<const TerrainBody *>(b);
				const double minExclR = sb->GetRadius() + 4500.0;
				double searchEnd = segEnd;
				bool guaranteedInnerHit = false;
				if (perpDistSq < minExclR * minExclR) {
					const double halfChordMin = std::sqrt(std::max(0.0, minExclR * minExclR - perpDistSq));
					const double tInnerEnter = proj - halfChordMin;
					if (tInnerEnter <= stepDist && (proj > 0.0 || distSq0 <= minExclR * minExclR)) {
						searchEnd = std::min(segEnd, std::max(0.0, tInnerEnter));
						guaranteedInnerHit = true;
					}
				}

				const int NUM_SAMPLES = 32;
				double prevT = segStart;
				bool foundHit = false;
				double hitT = segStart;

				for (int k = 0; k <= NUM_SAMPLES; ++k) {
					const double frac = double(k) / double(NUM_SAMPLES);
					const double t = segStart + (searchEnd - segStart) * frac;
					const vector3d p = startRel + fwdRel * t;
					const double d = p.Length();
					const double localExclR = (d > 1.0)
						? (std::max(sb->GetRadius(), tb->GetTerrainHeight(p / d)) + 4500.0)
						: maxExclR;
					if (d <= localExclR) {
						if (k == 0) {
							hitT = segStart;
						} else {
							double lo = prevT;
							double hi = t;
							for (int iter = 0; iter < 8; ++iter) {
								const double mid = 0.5 * (lo + hi);
								const vector3d pm = startRel + fwdRel * mid;
								const double dm = pm.Length();
								const double exclM = (dm > 1.0)
									? (std::max(sb->GetRadius(), tb->GetTerrainHeight(pm / dm)) + 4500.0)
									: maxExclR;
								if (dm <= exclM)
									hi = mid;
								else
									lo = mid;
							}
							hitT = lo;
						}
						foundHit = true;
						break;
					}
					prevT = t;
				}

				if (!foundHit && guaranteedInnerHit) {
					hitT = searchEnd;
					foundHit = true;
				}

				if (foundHit && hitT < earliestHitDist) {
					earliestHitDist = hitT;
					hitBody = b;
				}
			}
		}

		if (hitBody) {
			m_ship->SetPosition(startPos + forwardDir * std::max(0.0, earliestHitDist));
			EmergencyDrop("EMERGENCY DROP — EXCLUSION ZONE IMPACT (" + hitBody->GetLabel() + ")");
			return;
		}
	}

	m_ship->SetVelocity(forwardDir * m_speed);
}

int SupercruiseController::GetInterdictorLevel() const
{
	if (!m_ship)
		return 0;
	return m_ship->Properties().Get("fsd_interdictor_cap");
}

void SupercruiseController::ClearInterdiction()
{
	if (m_interdictPeer && m_interdictPeer->GetSupercruise()) {
		SupercruiseController *peerSc = m_interdictPeer->GetSupercruise();
		if (peerSc->m_interdictPeer == m_ship) {
			peerSc->m_interdictRole = INTERDICT_NONE;
			peerSc->m_interdictPeer = nullptr;
			peerSc->m_interdictPeerIndex = 0;
			peerSc->m_captureProgress = 0.30;
			peerSc->m_escapeProgress = 0.30;
			peerSc->m_submitTimer = 0.0;
			peerSc->m_submitting = false;
		}
	}
	m_interdictRole = INTERDICT_NONE;
	m_interdictPeer = nullptr;
	m_interdictPeerIndex = 0;
	m_captureProgress = 0.30;
	m_escapeProgress = 0.30;
	m_submitTimer = 0.0;
	m_submitting = false;
}

bool SupercruiseController::CanInterdict(const Ship *target, std::string *outReason) const
{
	const int level = GetInterdictorLevel();
	if (level <= 0) {
		if (outReason)
			*outReason = "NO FSD INTERDICTOR MODULE INSTALLED";
		return false;
	}
	if (!m_ship || !IsActive()) {
		if (outReason)
			*outReason = "MUST BE IN SUPERCRUISE TO INTERDICT";
		return false;
	}
	if (!target || target->IsDead() || target == m_ship) {
		if (outReason)
			*outReason = "NO VALID SUPERCRUISE TARGET";
		return false;
	}
	if (target->GetFlightState() != Ship::SUPERCRUISE) {
		if (outReason)
			*outReason = "TARGET IS NOT IN SUPERCRUISE";
		return false;
	}
	const SupercruiseController *targetSc = target->GetSupercruise();
	if (!targetSc || (!IsShipFTL(target) && !HasTrackedLock(m_ship, target))) {
		if (outReason)
			*outReason = "TARGET IS SUBLIGHT (< 1.0c) — NO FTL SIGNATURE";
		return false;
	}
	if (m_interdictRole != INTERDICT_NONE) {
		if (outReason)
			*outReason = "INTERDICTION TETHER ALREADY ACTIVE";
		return false;
	}
	if (targetSc->m_interdictRole != INTERDICT_NONE) {
		if (outReason)
			*outReason = "TARGET ALREADY TETHERED BY ANOTHER INTERDICTOR";
		return false;
	}

	const vector3d relToTarget = target->GetPositionRelTo(m_ship);
	const double dist = relToTarget.Length();
	const double targetSpeed = targetSc->GetSpeed();
	const double levelMult = 1.0 + 0.35 * double(level - 1);
	const double refSpeed = std::min(m_speed, targetSpeed);
	const double maxRange = std::max(SAFE_DISENGAGE_DIST, refSpeed * 10.0) * levelMult;
	if (dist > maxRange) {
		if (outReason) {
			char buf[128];
			if (maxRange >= 0.1 * LIGHT_SPEED) {
				snprintf(buf, sizeof(buf), "OUT OF INTERDICTION RANGE (%.1f ls / MAX %.1f ls)",
					dist / LIGHT_SPEED, maxRange / LIGHT_SPEED);
			} else if (maxRange >= 1.0e6) {
				snprintf(buf, sizeof(buf), "OUT OF INTERDICTION RANGE (%.1f Mm / MAX %.1f Mm)",
					dist / 1.0e6, maxRange / 1.0e6);
			} else {
				snprintf(buf, sizeof(buf), "OUT OF INTERDICTION RANGE (%.0f km / MAX %.0f km)",
					dist / 1.0e3, maxRange / 1.0e3);
			}
			*outReason = buf;
		}
		return false;
	}

	const double maxMatchSpeed = std::max(targetSpeed * 2.25, MIN_SPEED * 4.0);
	const double minMatchSpeed = (targetSpeed > MIN_SPEED * 2.5) ? (targetSpeed * 0.40) : 0.0;
	if (m_speed > maxMatchSpeed) {
		if (outReason)
			*outReason = "TOO FAST — MATCH TARGET SPEED TO INTERDICT";
		return false;
	}
	if (m_speed < minMatchSpeed) {
		if (outReason)
			*outReason = "TOO SLOW — MATCH TARGET SPEED TO INTERDICT";
		return false;
	}

	const vector3d toTargetDir = relToTarget.NormalizedSafe();
	const vector3d attackerFwd = -m_ship->GetOrient().VectorZ();
	const double aimCos = std::cos((30.0 + 5.0 * double(level - 1)) * (M_PI / 180.0));
	if (attackerFwd.Dot(toTargetDir) < aimCos) {
		if (outReason)
			*outReason = "ALIGN NOSE WITH TARGET TO ENGAGE TETHER";
		return false;
	}

	// Rear-hemisphere check: attacker must be behind target's tail (-(-targetFwd) = targetFwd)
	const vector3d targetBack = target->GetOrient().VectorZ();
	const double rearCos = std::cos((50.0 + 5.0 * double(level - 1)) * (M_PI / 180.0));
	if (targetBack.Dot(-toTargetDir) < rearCos) {
		if (outReason)
			*outReason = "MOVE BEHIND TARGET TO ENGAGE INTERDICTION";
		return false;
	}

	if (outReason)
		*outReason = "INTERDICTION ENVELOPE READY";
	return true;
}

bool SupercruiseController::HasInterdictionNullifier() const
{
	if (!m_ship) return false;
	const int cap = m_ship->Properties().Get("interdiction_nullifier");
	return cap > 0;
}

bool SupercruiseController::StartInterdiction(Ship *target)
{
	std::string reason;
	if (!CanInterdict(target, &reason)) {
		if (m_ship && m_ship->IsType(ObjectType::PLAYER)) {
			ShowStatusMessage(reason, 3.5f);
			Sound::BodyMakeNoise(m_ship, "notify_beep", 0.7f);
		}
		return false;
	}

	SupercruiseController *targetSc = target->GetSupercruise();
	if (!targetSc)
		return false;

	const bool attackerIsPlayer = m_ship->IsType(ObjectType::PLAYER);
	const bool targetIsPlayer = target->IsType(ObjectType::PLAYER);

	// Check if target has an active Interdiction Nullifier countermeasure
	if (targetSc->HasInterdictionNullifier() && targetSc->m_nullifierCooldown <= 0.0f) {
		targetSc->m_nullifierCooldown = 60.0f;
		targetSc->ShowStatusMessage("INTERDICTION NULLIFIED — DEFENSIVE PULSE DISCHARGED", 6.0f);
		if (targetIsPlayer) {
			Sound::BodyMakeNoise(target, "ok", 1.0f);
		}

		// Attacking ship suffers emergency drop, heat spike, and extended 45-second FSD reboot cooldown
		EmergencyDrop("INTERDICTION NULLIFIED — DEFENSIVE COUNTERMEASURE");
		m_heatSpike = 1.0;
		m_cooldown = 45.0f;
		ShowStatusMessage("TARGET ENGAGED INTERDICTION NULLIFIER — FORCED DROPOUT & FSD REBOOT (45s)", 6.0f);
		LuaEvent::Queue("onInterdictionNullified", m_ship, target);
		LuaEvent::Emit();
		if (attackerIsPlayer) {
			Sound::BodyMakeNoise(m_ship, "warning", 0.9f);
		}
		return false;
	}

	// Unlawful interdiction check when player interdicts a clean vessel
	if (attackerIsPlayer && !target->IsWanted()) {
		LuaEvent::Queue("onShipInterdicted", target, m_ship);
	}

	// NPC-vs-NPC interdiction resolves probabilistically and drops both into real space with a Low Wake
	if (!attackerIsPlayer && !targetIsPlayer) {
		const double targetMass = std::max(10.0, double(target->GetShipType()->hullMass));
		const double attackerLevel = double(GetInterdictorLevel());
		const double escapeChance = Clamp(0.38 * (60.0 / targetMass) / (1.0 + 0.25 * (attackerLevel - 1.0)), 0.12, 0.55);
		if (Pi::rng.Double() < escapeChance) {
			EmergencyDrop("INTERDICTION FAILED");
		} else {
			if (Pi::game && Pi::game->GetSpace()) {
				HyperspaceCloud::SpawnLowWake(Pi::game->GetSpace(), target->GetFrame(), target->GetPosition(),
					"LOW WAKE — DISTRESS SIGNAL", 240.0);
			}
			DropPairFromInterdiction(m_ship, target, false);
		}
		return true;
	}

	m_interdictRole = INTERDICT_ATTACKER;
	m_interdictPeer = target;
	m_captureProgress = 0.30;
	m_escapeProgress = 0.30;
	m_submitTimer = 0.0;
	m_submitting = false;

	targetSc->m_interdictRole = INTERDICT_TARGET;
	targetSc->m_interdictPeer = m_ship;
	targetSc->m_captureProgress = 0.30;
	targetSc->m_escapeProgress = 0.30;
	targetSc->m_escapeWanderTime = Pi::rng.Double(0.0, 10.0);
	targetSc->m_submitTimer = 0.0;
	targetSc->m_submitting = false;
	targetSc->m_escapeBaseDir = -target->GetOrient().VectorZ();
	targetSc->m_escapeDirWorld = targetSc->m_escapeBaseDir;

	// NPC haulers sometimes decide to submit rather than fight the tether
	if (!targetIsPlayer && !target->IsWanted() && target->GetShipType()->hullMass >= 80 && Pi::rng.Double() < 0.45) {
		targetSc->m_submitting = true;
	}

	m_assistActive = false;
	targetSc->m_assistActive = false;

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Charge", 0.9f);
	if (attackerIsPlayer)
		ShowStatusMessage("FSD INTERDICTION TETHER ACTIVE — KEEP TARGET CENTERED", 4.5f);
	if (targetIsPlayer) {
		Sound::BodyMakeNoise(target, "warning", 1.0f);
		targetSc->ShowStatusMessage("INTERDICTION DETECTED — ALIGN WITH ESCAPE VECTOR OR THROTTLE TO 0% TO SUBMIT", 6.0f);
	}
	return true;
}

void SupercruiseController::UpdateInterdiction(float timeStep)
{
	if (m_interdictRole != INTERDICT_ATTACKER)
		return;

	Ship *target = m_interdictPeer;
	if (!target || target->IsDead() || !m_ship || m_ship->IsDead() ||
		m_ship->GetFlightState() != Ship::SUPERCRUISE ||
		target->GetFlightState() != Ship::SUPERCRUISE) {
		ClearInterdiction();
		return;
	}

	SupercruiseController *targetSc = target->GetSupercruise();
	if (!targetSc || targetSc->m_interdictPeer != m_ship) {
		ClearInterdiction();
		return;
	}

	// Keep attacker tethered behind/near target at matched FTL speed
	const vector3d relToTarget = target->GetPositionRelTo(m_ship);
	const double dist = relToTarget.Length();
	double desiredTetherSpeed = targetSc->GetSpeed();
	if (dist > 2.5 * LIGHT_SPEED)
		desiredTetherSpeed = std::min(MAX_SPEED, desiredTetherSpeed * 1.12 + 0.05 * LIGHT_SPEED);
	else if (dist < 0.35 * LIGHT_SPEED)
		desiredTetherSpeed = std::max(MIN_SPEED, desiredTetherSpeed * 0.88);
	m_speed = Clamp(m_speed + (desiredTetherSpeed - m_speed) * Clamp(double(timeStep) * 3.0, 0.0, 1.0), MIN_SPEED, MAX_SPEED);

	// Update wandering Escape Vector ahead of target
	targetSc->m_escapeWanderTime += double(timeStep);
	const vector3d targetFwd = -target->GetOrient().VectorZ();
	// Slerp base vector gently toward target forward so Escape Vector stays in front hemisphere
	targetSc->m_escapeBaseDir = (targetSc->m_escapeBaseDir * (1.0 - Clamp(double(timeStep) * 0.65, 0.0, 1.0)) +
		targetFwd * Clamp(double(timeStep) * 0.65, 0.0, 1.0)).NormalizedSafe();
	const vector3d baseFwd = targetSc->m_escapeBaseDir;
	const vector3d refUp = (std::fabs(baseFwd.y) < 0.9) ? vector3d(0.0, 1.0, 0.0) : vector3d(1.0, 0.0, 0.0);
	const vector3d tangentRight = baseFwd.Cross(refUp).Normalized();
	const vector3d tangentUp = tangentRight.Cross(baseFwd).Normalized();

	const double t = targetSc->m_escapeWanderTime;
	const double yawDeflect = 0.34 * std::sin(t * 0.85) + 0.14 * std::sin(t * 2.05);
	const double pitchDeflect = 0.28 * std::cos(t * 0.72) + 0.12 * std::sin(t * 1.65);
	targetSc->m_escapeDirWorld = (baseFwd + tangentRight * yawDeflect + tangentUp * pitchDeflect).NormalizedSafe();

	// Submission check (0% throttle for 0.8s)
	if (targetSc->m_submitting || targetSc->GetThrottle() <= 0.02) {
		targetSc->m_submitTimer += double(timeStep);
		if (targetSc->m_submitTimer >= 0.8) {
			DropPairFromInterdiction(m_ship, target, true);
			return;
		}
	} else {
		targetSc->m_submitTimer = 0.0;
	}

	// Alignment scoring
	const double targetMass = std::max(15.0, double(target->GetShipType()->hullMass));
	const double attackerMass = std::max(15.0, double(m_ship->GetShipType()->hullMass));
	const double targetAgility = Clamp(std::sqrt(60.0 / targetMass), 0.55, 1.55);
	const double attackerAgility = Clamp(std::sqrt(60.0 / attackerMass), 0.65, 1.45);
	const double levelBonus = 1.0 + 0.22 * double(GetInterdictorLevel() - 1);

	const double evaderDot = targetFwd.Dot(targetSc->m_escapeDirWorld);
	const double cosTight = std::cos(14.0 * M_PI / 180.0);
	const double cosLoose = std::cos(26.0 * M_PI / 180.0);

	if (evaderDot >= cosTight)
		m_escapeProgress += 0.14 * targetAgility * double(timeStep);
	else if (evaderDot >= cosLoose)
		m_escapeProgress += 0.03 * targetAgility * double(timeStep);
	else
		m_escapeProgress -= 0.05 * double(timeStep);

	const vector3d attackerFwd = -m_ship->GetOrient().VectorZ();
	const double attackerDot = attackerFwd.Dot(relToTarget.NormalizedSafe());
	if (attackerDot >= cosTight)
		m_captureProgress += 0.15 * levelBonus * attackerAgility * double(timeStep);
	else if (attackerDot >= cosLoose)
		m_captureProgress += 0.04 * levelBonus * double(timeStep);
	else
		m_captureProgress -= 0.06 * double(timeStep);

	m_captureProgress = Clamp(m_captureProgress, 0.0, 1.0);
	m_escapeProgress = Clamp(m_escapeProgress, 0.0, 1.0);
	targetSc->m_captureProgress = m_captureProgress;
	targetSc->m_escapeProgress = m_escapeProgress;

	if (m_captureProgress >= 1.0) {
		DropPairFromInterdiction(m_ship, target, false);
	} else if (m_escapeProgress >= 1.0) {
		ClearInterdiction();
		targetSc->ShowStatusMessage("INTERDICTION EVADED", 4.5f);
		EmergencyDrop("INTERDICTION FAILED — FSD OVERLOAD");
		LuaEvent::Queue("onInterdictionEvaded", m_ship, target);
		LuaEvent::Emit();
	}
}

void SupercruiseController::DropPairFromInterdiction(Ship *attacker, Ship *target, bool submitted)
{
	if (!attacker || !target)
		return;
	SupercruiseController *attSc = attacker->GetSupercruise();
	SupercruiseController *tgtSc = target->GetSupercruise();
	if (!attSc || !tgtSc)
		return;

	attSc->ClearInterdiction();

	// Place both ships in target's current orbital/system frame at dogfight range
	const FrameId dropFrame = target->GetFrame();
	const vector3d targetPos = target->GetPosition();
	const vector3d targetFwd = (-target->GetOrient().VectorZ()).NormalizedSafe();
	const vector3d upDir = target->GetOrient().VectorY().NormalizedSafe();

	attacker->SwitchToFrame(dropFrame);
	attacker->SetPosition(targetPos - targetFwd * 1600.0 + upDir * 120.0);
	const vector3d attZ = (-targetFwd).NormalizedSafe(); // -Z points toward targetFwd
	vector3d attX = upDir.Cross(attZ).NormalizedSafe();
	if (attX.LengthSqr() < 0.1)
		attX = MathUtil::OrthogonalDirection(attZ).Normalized();
	const vector3d attY = attZ.Cross(attX).Normalized();
	attacker->SetOrient(matrix3x3d::FromVectors(attX, attY, attZ));

	target->SetVelocity(targetFwd * 180.0);
	target->SetAngVelocity(vector3d(0.0));
	attacker->SetVelocity(targetFwd * 210.0);
	attacker->SetAngVelocity(vector3d(0.0));

	attSc->m_charging = false;
	attSc->m_assistActive = false;
	attSc->m_speed = 0.0;
	attSc->m_safeDisengageReady = false;
	attSc->m_slowDownWarning = false;

	tgtSc->m_charging = false;
	tgtSc->m_assistActive = false;
	tgtSc->m_speed = 0.0;
	tgtSc->m_safeDisengageReady = false;
	tgtSc->m_slowDownWarning = false;

	if (submitted) {
		attSc->m_cooldown = NORMAL_COOLDOWN;
		tgtSc->m_cooldown = NORMAL_COOLDOWN;
	} else {
		attSc->m_cooldown = 10.0f;
		tgtSc->m_cooldown = EMERGENCY_COOLDOWN;
		tgtSc->m_heatSpike = 0.92;
		target->DepleteShieldsForEmergencyDrop(EMERGENCY_COOLDOWN);
	}

	target->SetFlightState(Ship::FLYING);
	tgtSc->EnsureShipAboveTerrainAndSyncFrame();
	target->ClearThrusterState();
	target->CalcExternalForce();
	attacker->SetFlightState(Ship::FLYING);
	attSc->EnsureShipAboveTerrainAndSyncFrame();
	attacker->ClearThrusterState();
	attacker->CalcExternalForce();

	// Preserve/assign player combat target lock for immediate dogfighting
	if (attacker->IsType(ObjectType::PLAYER)) {
		static_cast<Player *>(attacker)->SetCombatTarget(target);
	} else if (target->IsType(ObjectType::PLAYER)) {
		static_cast<Player *>(target)->SetCombatTarget(attacker);
	}

	// Engage combat AI for NPCs
	if (!attacker->IsType(ObjectType::PLAYER)) {
		attacker->AIKill(target);
	}
	if (!target->IsType(ObjectType::PLAYER)) {
		if (target->GetShipType()->hullMass < 90 || target->IsWanted())
			target->AIKill(attacker);
		else
			target->AIMatchVel(targetFwd * 250.0);
	}

	Sound::BodyMakeNoise(target, "Hyperdrive_Abort", 1.0f);
	Sound::BodyMakeNoise(attacker, "Hyperdrive_Abort", 1.0f);

	if (submitted) {
		attSc->ShowStatusMessage("TARGET SUBMITTED TO INTERDICTION", 4.5f);
		tgtSc->ShowStatusMessage("SUBMITTED TO INTERDICTION — SHORT FSD COOLDOWN (5s)", 5.0f);
	} else {
		attSc->ShowStatusMessage("INTERDICTION SUCCESSFUL — TARGET DROPPED", 4.5f);
		tgtSc->ShowStatusMessage("INTERDICTED — EMERGENCY DROP & FSD COOLDOWN (25s)", 5.5f);
	}

	LuaEvent::Queue("onInterdictionDrop", attacker, target, submitted);
	LuaEvent::Emit();
}
