// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SupercruiseController.h"
#include "Frame.h"
#include "Game.h"
#include "JsonUtils.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "Ship.h"
#include "Space.h"
#include "SpaceStation.h"
#include "galaxy/SystemBody.h"
#include "sound/Sound.h"

#include <algorithm>
#include <cmath>

SupercruiseController::SupercruiseController(Ship *ship) :
	m_ship(ship)
{
}

void SupercruiseController::SaveToJson(Json &jsonObj) const
{
	Json scObj = Json::object();
	scObj["charging"] = m_charging;
	scObj["charge_countdown"] = m_chargeCountdown;
	scObj["cooldown"] = m_cooldown;
	scObj["throttle"] = m_throttle;
	scObj["speed"] = m_speed;
	scObj["assist_active"] = m_assistActive;
	scObj["dock_on_arrival"] = m_dockOnArrival;
	scObj["heat_spike"] = m_heatSpike;
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
	m_heatSpike = scObj.value("heat_spike", 0.0);
}

bool SupercruiseController::IsActive() const
{
	return m_ship && m_ship->GetFlightState() == Ship::SUPERCRUISE;
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
	case SystemBody::SUPERTYPE_ROCKY_PLANET:
		return r + 4500.0; // 4.5 km above mean radius (below 5 km mass-lock altitude)
	default:
		return 0.0;
	}
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

SupercruiseController::Status SupercruiseController::GetStatus(std::string *outReason) const
{
	if (!m_ship)
		return SC_NOT_FLYING;

	if (IsActive())
		return SC_ACTIVE;

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

	if (active && !GetActiveTarget()) {
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
	if (m_ship && m_ship->IsHyperspaceActive()) {
		ShowStatusMessage("FSD BUSY: HYPERJUMP IN PROGRESS", 4.0f);
		Sound::BodyMakeNoise(m_ship, "warning", 0.5f);
		return false;
	}

	std::string reason;
	Status st = GetStatus(&reason);
	if (st != SC_READY) {
		ShowStatusMessage(reason, 4.0f);
		Sound::BodyMakeNoise(m_ship, "warning", 0.5f);
		return false;
	}

	m_charging = true;
	m_chargeCountdown = CHARGE_DURATION;
	if (m_ship->AIIsActive())
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
	m_speed = std::max(MIN_SPEED, m_ship->GetVelocity().Length());
	if (m_throttle < 0.25)
		m_throttle = 0.50;
	if (m_assistActive)
		m_throttle = 0.75;

	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->SetVelocity(-m_ship->GetOrient().VectorZ() * m_speed);

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Jump", 1.0f);
	ShowStatusMessage("SUPERCRUISE ENGAGED", 3.5f);
}

void SupercruiseController::SafeDisengage()
{
	Body *target = GetActiveTarget();
	const bool dockAfterDrop = m_dockOnArrival;

	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = NORMAL_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;

	if (target && target->IsType(ObjectType::SPACESTATION)) {
		SpaceStation *station = static_cast<SpaceStation *>(target);
		if (!station->IsGroundStation()) {
			// Orbital Station Drop-In: switch to station frame, 12 km out, facing station, zero relative velocity
			m_ship->SwitchToFrame(station->GetFrame());
			vector3d fromStation = (m_ship->GetPosition() - station->GetPosition()).NormalizedSafe();
			if (fromStation.LengthSqr() < 0.1)
				fromStation = vector3d(0.0, 0.0, 1.0);

			m_ship->SetPosition(station->GetPosition() + fromStation * 12000.0);

			vector3d up = m_ship->GetOrient().VectorY();
			vector3d x = up.Cross(fromStation).NormalizedSafe();
			if (x.LengthSqr() < 0.1)
				x = vector3d(1.0, 0.0, 0.0).Cross(fromStation).NormalizedSafe();
			vector3d y = fromStation.Cross(x).Normalized();
			m_ship->SetOrient(matrix3x3d::FromVectors(x, y, fromStation));

			m_ship->SetVelocity(station->GetVelocity());
			m_ship->SetAngVelocity(vector3d(0.0));
		} else {
			// Surface Starport Glide Drop-In: switch to planet rotating frame, 10 km altitude & 8 km out, facing base
			m_ship->SwitchToFrame(station->GetFrame());
			const vector3d stPos = station->GetPosition();
			const vector3d upDir = stPos.NormalizedSafe();
			const vector3d shipRel = m_ship->GetPosition() - stPos;
			vector3d horiz = (shipRel - upDir * shipRel.Dot(upDir)).NormalizedSafe();
			if (horiz.LengthSqr() < 0.1)
				horiz = station->GetOrient().VectorZ();

			const vector3d dropPos = stPos + upDir * 10000.0 + horiz * 8000.0;
			m_ship->SetPosition(dropPos);

			const vector3d z = (dropPos - stPos).Normalized();
			vector3d x = upDir.Cross(z).NormalizedSafe();
			if (x.LengthSqr() < 0.1)
				x = vector3d(1.0, 0.0, 0.0).Cross(z).NormalizedSafe();
			const vector3d y = z.Cross(x).Normalized();
			m_ship->SetOrient(matrix3x3d::FromVectors(x, y, z));

			m_ship->SetVelocity(vector3d(0.0));
			m_ship->SetAngVelocity(vector3d(0.0));
		}
	} else if (target && target->IsType(ObjectType::SHIP) && m_targetDistance <= SAFE_DISENGAGE_DIST) {
		m_ship->SwitchToFrame(target->GetFrame());
		vector3d fromTarget = (m_ship->GetPosition() - target->GetPosition()).NormalizedSafe();
		if (fromTarget.LengthSqr() < 0.1)
			fromTarget = vector3d(0.0, 0.0, 1.0);
		m_ship->SetPosition(target->GetPosition() + fromTarget * 4000.0);
		m_ship->SetVelocity(target->GetVelocity());
		m_ship->SetAngVelocity(vector3d(0.0));
	} else {
		m_ship->SetVelocity(vector3d(0.0));
		m_ship->SetAngVelocity(vector3d(0.0));
	}

	m_ship->SetFlightState(Ship::FLYING);
	m_ship->ClearThrusterState();
	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);

	if (dockAfterDrop && target && target->IsType(ObjectType::SPACESTATION)) {
		m_ship->AIDock(static_cast<SpaceStation *>(target));
		ShowStatusMessage("SAFE DISENGAGE COMPLETE — AUTO-DOCKING ENGAGED", 5.0f);
	} else {
		ShowStatusMessage("SAFE DISENGAGE COMPLETE", 4.0f);
	}
}

void SupercruiseController::NormalDrop(const std::string &reason)
{
	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = NORMAL_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;

	m_ship->SetVelocity(vector3d(0.0));
	m_ship->SetAngVelocity(vector3d(0.0));
	m_ship->SetFlightState(Ship::FLYING);
	m_ship->ClearThrusterState();

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);
	ShowStatusMessage(reason.empty() ? "DROPPED FROM SUPERCRUISE" : reason, 4.0f);
}

void SupercruiseController::EmergencyDrop(const std::string &reason)
{
	m_charging = false;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_cooldown = EMERGENCY_COOLDOWN;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;

	m_ship->SetVelocity(vector3d(0.0));
	m_ship->SetAngVelocity(vector3d(0.18, -0.09, 0.14));
	m_ship->SetFlightState(Ship::FLYING);
	m_ship->ClearThrusterState();

	// Spike hull temperature & overload shields (hull damage only if shields were down)
	m_heatSpike = 0.92;
	m_ship->DepleteShieldsForEmergencyDrop(EMERGENCY_COOLDOWN);

	Sound::BodyMakeNoise(m_ship, "Hyperdrive_Abort", 1.0f);
	ShowStatusMessage(reason.empty() ? "EMERGENCY DROP — SHIELD OVERLOAD & FSD COOLDOWN" : reason, 6.0f);
}

void SupercruiseController::OnEnterHyperspace()
{
	m_charging = false;
	m_chargeCountdown = 0.0f;
	m_assistActive = false;
	m_dockOnArrival = false;
	m_speed = 0.0;
	m_safeDisengageReady = false;
	m_slowDownWarning = false;
}

void SupercruiseController::ShowStatusMessage(const std::string &msg, float duration)
{
	m_statusMessage = msg;
	m_statusMessageTimer = duration;
}

Body *SupercruiseController::GetActiveTarget() const
{
	if (!m_ship || !m_ship->IsType(ObjectType::PLAYER))
		return nullptr;

	const Player *player = static_cast<const Player *>(m_ship);
	if (Body *nav = player->GetNavTarget())
		return nav;
	if (Body *combat = player->GetCombatTarget())
		return combat;
	return nullptr;
}

void SupercruiseController::UpdateEnvironmentAndTarget(float timeStep, Body **outHitExclusionBody)
{
	if (outHitExclusionBody)
		*outHitExclusionBody = nullptr;

	if (!m_ship || !Pi::game || !Pi::game->GetSpace())
		return;

	double envMax = MAX_SPEED;
	double maxStrain = 0.0;
	const vector3d forwardDir = -m_ship->GetOrient().VectorZ();

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		if (!b->IsType(ObjectType::TERRAINBODY))
			continue;
		const SystemBody *sb = b->GetSystemBody();
		if (!sb)
			continue;

		const double r = std::max(sb->GetRadius(), 1000.0);
		const double exclR = GetExclusionZoneRadius(b);
		const vector3d bodyPos = b->GetPositionRelTo(m_ship->GetFrame());
		const vector3d toBody = bodyPos - m_ship->GetPosition();
		const double dist = toBody.Length();

		const vector3d toBodyNorm = (dist > 1.0) ? (toBody / dist) : vector3d(0.0);
		const double toBodyDot = forwardDir.Dot(toBodyNorm); // > 0: heading towards body
		const double outboundDot = -toBodyDot;               // > 0: heading away from body

		// Check exclusion zone impact when moving toward the body
		if (exclR > 0.0 && dist <= exclR && toBodyDot > 0.0) {
			if (outHitExclusionBody && !*outHitExclusionBody)
				*outHitExclusionBody = b;
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
			// Near celestial bodies and orbital/surface stations (hRadii <= 1.0):
			// dragged down to 100 km/s - 800 km/s (safe drop envelope)
			const double hRadii = h / r;
			if (hRadii <= 1.0) {
				vBody = 100000.0 + 700000.0 * hRadii; // 100 km/s to 800 km/s
			} else if (hRadii <= 5.0) {
				vBody = 800000.0 + 4000000.0 * (hRadii - 1.0) / 4.0; // 800 km/s to 4.8 Mm/s
			} else {
				const double outerH = hRadii - 5.0;
				vBody = 4800000.0 + LIGHT_SPEED * (0.05 * std::pow(outerH, 1.35) + 0.01 * outerH * outerH);
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

		vBody = Clamp(vBody, 100000.0, MAX_SPEED);
		envMax = std::min(envMax, vBody);
		maxStrain = std::max(maxStrain, strain);
	}

	m_maxEnvSpeed = envMax;
	m_gravityStrain = Clamp(maxStrain, 0.0, 1.0);

	// Target telemetry
	Body *target = GetActiveTarget();
	if (target) {
		const vector3d relToTarget = target->GetPositionRelTo(m_ship);
		m_targetDistance = relToTarget.Length();
		m_targetETA = (m_speed > 1.0) ? (m_targetDistance / m_speed) : 0.0;

		m_safeDisengageReady = (m_targetDistance <= SAFE_DISENGAGE_DIST) && (m_speed <= SAFE_DISENGAGE_SPEED);

		// Overshoot ("Loop of Shame") warning when ETA drops below 5.2s outside safe drop range,
		// or when entering a heavy gravity well at excessive speed (Elite Dangerous SLOW DOWN indicator)
		const double closingDot = forwardDir.Dot(relToTarget.NormalizedSafe());
		const bool targetOvershoot = (closingDot > 0.5) &&
			(m_targetDistance > SAFE_DISENGAGE_DIST) &&
			(m_speed > SAFE_DISENGAGE_SPEED) &&
			(m_targetETA > 0.0 && m_targetETA < 5.3);
		const bool gravityWellSlowDown = (m_gravityStrain > 0.25) && (m_speed > m_maxEnvSpeed * 1.08);
		m_slowDownWarning = targetOvershoot || gravityWellSlowDown;
	} else {
		m_targetDistance = 0.0;
		m_targetETA = 0.0;
		m_safeDisengageReady = false;
		m_slowDownWarning = (m_gravityStrain > 0.25) && (m_speed > m_maxEnvSpeed * 1.08);
		if (m_assistActive) {
			SetAssistActive(false, false);
		}
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

	if (m_heatSpike > 0.0) {
		m_heatSpike = std::max(0.0, m_heatSpike - double(timeStep) * 0.045);
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

		m_chargeCountdown -= timeStep;
		if (m_chargeCountdown <= 0.0f) {
			EnterSupercruise();
		}
		return;
	}

	if (!IsActive())
		return;

	Body *hitExclBody = nullptr;
	UpdateEnvironmentAndTarget(timeStep, &hitExclBody);

	if (hitExclBody) {
		EmergencyDrop("EMERGENCY DROP — TOO CLOSE TO " + hitExclBody->GetLabel());
		return;
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
	Body *target = GetActiveTarget();
	const bool inBlueZone = (m_throttle >= 0.65 && m_throttle <= 0.80);

	// The 6-Second Rule: when approaching a target, regulate the speed envelope
	// along v = d / 6.0 so ETA holds steady at 0:06 all the way down to
	// Safe Disengage (< 1,000 km & < 1,000 km/s).
	// If the player reduces throttle below 65%, decelerate even faster.
	if (target && m_targetDistance < 500.0 * LIGHT_SPEED) {
		if (inBlueZone) {
			const double sixSecondSpeed = std::max(100000.0, m_targetDistance / 6.0);
			targetCapSpeed = std::min(targetCapSpeed, sixSecondSpeed / 0.75);
		} else if (m_throttle < 0.65 && m_throttle > 0.001) {
			const double subBlueSpeed = std::max(MIN_SPEED, (m_targetDistance / 6.0) * (m_throttle / 0.75));
			targetCapSpeed = std::min(targetCapSpeed, subBlueSpeed / m_throttle);
		}
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
		const double decel = std::max(120000.0, m_speed * (0.35 + 0.65 * m_gravityStrain));
		m_speed = std::max(m_desiredSpeed, m_speed - decel * timeStep);
	}

	m_speed = Clamp(m_speed, MIN_SPEED, MAX_SPEED);
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
	if (m_assistActive && std::fabs(desiredAngInput.x) < 0.05 && std::fabs(desiredAngInput.y) < 0.05) {
		if (Body *target = GetActiveTarget()) {
			const vector3d toTargetWorld = target->GetPositionRelTo(m_ship).NormalizedSafe();
			// Convert to ship-local coordinates (where -Z is forward, +X is right, +Y is up)
			const vector3d toTargetLocal = toTargetWorld * m_ship->GetOrient();
			const double pitchErr = std::atan2(toTargetLocal.y, -toTargetLocal.z);
			const double yawErr = std::atan2(-toTargetLocal.x, -toTargetLocal.z);

			angCmd.x = Clamp(pitchErr * 2.0, -basePitchRate * blueZoneMult, basePitchRate * blueZoneMult);
			angCmd.y = Clamp(yawErr * 2.0, -baseYawRate * blueZoneMult, baseYawRate * blueZoneMult);
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

	// Swept ray-sphere exclusion zone check along forward vector (-Z)
	const vector3d startPos = m_ship->GetPosition();
	const double stepDist = m_speed * double(timeStep);

	if (Pi::game && Pi::game->GetSpace() && stepDist > 0.0) {
		for (Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (!b->IsType(ObjectType::TERRAINBODY))
				continue;
			const double exclR = GetExclusionZoneRadius(b);
			if (exclR <= 0.0)
				continue;

			const vector3d bodyPos = b->GetPositionRelTo(m_ship->GetFrame());
			const vector3d toBody = bodyPos - startPos;
			const double proj = toBody.Dot(forwardDir);
			if (proj > 0.0 && proj < stepDist + exclR) {
				const double perpDistSq = toBody.LengthSqr() - proj * proj;
				if (perpDistSq < exclR * exclR) {
					const double halfChord = std::sqrt(std::max(0.0, exclR * exclR - perpDistSq));
					const double hitDist = proj - halfChord;
					if (hitDist >= 0.0 && hitDist <= stepDist) {
						// Move to just outside the exclusion zone boundary and trigger Emergency Drop
						m_ship->SetPosition(startPos + forwardDir * std::max(0.0, hitDist));
						EmergencyDrop("EMERGENCY DROP — EXCLUSION ZONE IMPACT (" + b->GetLabel() + ")");
						return;
					}
				}
			}
		}
	}

	m_ship->SetVelocity(forwardDir * m_speed);
}
