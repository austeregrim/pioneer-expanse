// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "EnumStrings.h"
#include "Frame.h"
#include "Game.h"
#include "Pi.h"
#include "Player.h"
#include "Ship.h"
#include "ShipAICmd.h"
#include "ship/Propulsion.h"
#include "ship/SupercruiseController.h"
#include "Space.h"
#include "SpaceStation.h"
#include "lua/LuaEvent.h"
#include "ship/GunManager.h"
#include "sound/Sound.h"

#include "profiler/Profiler.h"

static SpaceStation *FindContainingOrbitalStation(const Ship *ship)
{
	if (!ship || ship->IsType(ObjectType::PLAYER) || ship->GetFlightState() != Ship::FLYING)
		return nullptr;
	if (!Pi::game || !Pi::game->GetSpace())
		return nullptr;
	const Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(ship, 1200.0);
	for (Body *b : nearby) {
		if (!b || !b->IsType(ObjectType::SPACESTATION))
			continue;
		SpaceStation *st = static_cast<SpaceStation *>(b);
		if (st->IsInsideStation(ship))
			return st;
	}
	return nullptr;
}

// returns true if command is complete
bool Ship::AITimeStep(float timeStep)
{
	PROFILE_SCOPED()
	// allow the launch thruster thing to happen
	if (m_launchLockTimeout > 0.0) return false;

	m_decelerating = false;

	// Any NPC ship that finds itself inside an orbital space station without docking orders
	// should immediately exit by recentering on the station axis and exiting through the airlock.
	if (SpaceStation *st = FindContainingOrbitalStation(this)) {
		int bay = st->GetMyDockingPort(this);
		bool hasDockingClearance = (bay != -1 && m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DOCK);
		bool isDeparting = (m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART);

		if (!hasDockingClearance && !isDeparting) {
			AIDepart(st);
			return false;
		}
	}

	if (!m_curAICmd) {
		if (this->IsType(ObjectType::PLAYER)) return true;

		if (m_flightState == SUPERCRUISE && m_supercruise &&
			(m_supercruise->IsBeingInterdicted() || m_supercruise->IsInterdicting())) {
			if (m_supercruise->IsBeingInterdicted()) {
				if (m_supercruise->IsSubmittingToInterdiction()) {
					m_supercruise->SetThrottle(0.0);
					m_supercruise->TimeStepUpdate(timeStep, vector3d(0.0));
				} else {
					vector3d angInput;
					double throttle = 0.75;
					m_supercruise->ComputeAISteering(m_supercruise->GetEscapeVectorWorld() * 1e9, nullptr, angInput, throttle);
					m_supercruise->SetThrottle(0.75);
					m_supercruise->TimeStepUpdate(timeStep, angInput);
				}
			} else if (Ship *peer = m_supercruise->GetInterdictionPeer()) {
				vector3d angInput;
				double throttle = 0.75;
				m_supercruise->ComputeAISteering(peer->GetPositionRelTo(this), peer, angInput, throttle);
				m_supercruise->SetThrottle(0.75);
				m_supercruise->TimeStepUpdate(timeStep, angInput);
			}
			return false;
		}

		// If NPC ship is in active flight with no active command, engage flight assist braking
		// rather than dead-stick coasting into planetary surfaces or station hulls
		if (m_flightState == FLYING && m_propulsion && GetVelocity().Length() > 2.0) {
			m_propulsion->AIMatchVel(vector3d(0.0));
			return false;
		} else {
			ClearThrusterState();
		}
		m_gunManager->SetAllGroupsFiring(false);
		return true;
	}

	if (!IsType(ObjectType::PLAYER) && m_flightState == SUPERCRUISE && m_supercruise &&
		(m_supercruise->IsBeingInterdicted() || m_supercruise->IsInterdicting())) {
		if (m_supercruise->IsBeingInterdicted()) {
			if (m_supercruise->IsSubmittingToInterdiction()) {
				m_supercruise->SetThrottle(0.0);
				m_supercruise->TimeStepUpdate(timeStep, vector3d(0.0));
			} else {
				vector3d angInput;
				double throttle = 0.75;
				m_supercruise->ComputeAISteering(m_supercruise->GetEscapeVectorWorld() * 1e9, nullptr, angInput, throttle);
				m_supercruise->SetThrottle(0.75);
				m_supercruise->TimeStepUpdate(timeStep, angInput);
			}
		} else if (Ship *peer = m_supercruise->GetInterdictionPeer()) {
			vector3d angInput;
			double throttle = 0.75;
			m_supercruise->ComputeAISteering(peer->GetPositionRelTo(this), peer, angInput, throttle);
			m_supercruise->SetThrottle(0.75);
			m_supercruise->TimeStepUpdate(timeStep, angInput);
		}
		return false;
	}

	m_propulsion->BeginAISequentialThrusters();
	const bool aiComplete = m_curAICmd->TimeStepUpdate();
	m_propulsion->EndAISequentialThrusters();
	if (aiComplete) {
		AIClearInstructions();
		//		ClearThrusterState();		// otherwise it does one timestep at 10k and gravity is fatal
		LuaEvent::Queue("onAICompleted", this, EnumStrings::GetString("ShipAIError", AIMessage()));
		return true;
	} else
		return false;
}

void Ship::AIClearInstructions()
{
	if (m_supercruise && m_supercruise->IsAssistActive()) {
		m_supercruise->SetAssistActive(false, false);
	}
	if (!m_curAICmd) return;

	delete m_curAICmd; // rely on destructor to kill children
	m_curAICmd = 0;
	m_decelerating = false; // don't adjust unless AI is running
}

void Ship::AIGetStatusText(char *str)
{
	if (!m_curAICmd)
		strcpy(str, "AI inactive");
	else
		m_curAICmd->GetStatusText(str);
}

void Ship::AIKamikaze(Body *target)
{
	if (SpaceStation *st = FindContainingOrbitalStation(this)) {
		if (!(m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART))
			AIDepart(st);
		return;
	}
	AIClearInstructions();
	m_curAICmd = new AICmdKamikaze(this, target);
}

void Ship::AIKill(Ship *target)
{
	if (SpaceStation *st = FindContainingOrbitalStation(this)) {
		if (!(m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART))
			AIDepart(st);
		return;
	}
	AIClearInstructions();
	SetFuelReserve((GetFuel() < 0.5) ? GetFuel() / 2 : 0.25);

	m_curAICmd = new AICmdKill(this, target);
}


bool Ship::IsAIAttacking(const Ship *target) const
{
	return m_curAICmd &&
		((m_curAICmd->GetType() == AICommand::CMD_KILL && (static_cast<AICmdKill *>(m_curAICmd)->GetTarget() == target)) ||
			(m_curAICmd->GetType() == AICommand::CMD_KAMIKAZE && (static_cast<AICmdKamikaze *>(m_curAICmd)->GetTarget() == target)));
}

/*
void Ship::AIJourney(SystemBodyPath &dest)
{
	AIClearInstructions();
//	m_curAICmd = new AICmdJourney(this, dest);
}
*/

void Ship::AIFlyTo(Body *target)
{
	if (SpaceStation *st = FindContainingOrbitalStation(this)) {
		if (!(m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART))
			AIDepart(st);
		return;
	}
	AIClearInstructions();
	if (!target) return;

	if (IsType(ObjectType::PLAYER) && m_supercruise) {
		const double dist = GetPositionRelTo(target).Length() - target->GetPhysRadius();
		if (m_flightState == SUPERCRUISE || dist > SupercruiseController::SUBLIGHT_AUTOPILOT_MAX_DIST) {
			if (m_flightState == SUPERCRUISE && m_supercruise->IsSafeDisengageReady()) {
				m_supercruise->SafeDisengage();
				return;
			}
			if (m_supercruise->HasAssistModule()) {
				static_cast<Player *>(this)->SetNavTarget(target);
				m_supercruise->SetAssistActive(true, false);
			} else {
				if (m_flightState == SUPERCRUISE && dist <= SupercruiseController::SAFE_DISENGAGE_DIST) {
					m_supercruise->ShowStatusMessage("SLOW DOWN TO DISENGAGE VELOCITY (<1,000 KM/S) BEFORE AUTOPILOT", 5.0f);
				} else {
					m_supercruise->ShowStatusMessage("TARGET BEYOND SUB-LIGHT AUTOPILOT RANGE (>2,500 KM) — ENGAGE SUPERCRUISE [J] OR EQUIP AUTOPILOT MK 2", 5.0f);
				}
				Sound::BodyMakeNoise(this, "beep", 0.5f);
			}
			return;
		}
	}

	SetFuelReserve((GetFuel() < 0.5) ? GetFuel() / 2 : 0.25);

	if (target->IsType(ObjectType::SHIP)) {
		Ship *targetShip = static_cast<Ship *>(target);
		if (targetShip->IsOnSurface())
			m_curAICmd = new AICmdFlyTo(this, target);
		else {
			vector3d posoff(-1000.0, 0.0, 1000.0);
			m_curAICmd = new AICmdFormation(this, targetShip, posoff);
		}
	} else
		m_curAICmd = new AICmdFlyTo(this, target);
}

void Ship::AIDock(SpaceStation *target)
{
	if (SpaceStation *st = FindContainingOrbitalStation(this)) {
		const bool hasClearanceHere = (st == target && st->GetMyDockingPort(this) != -1);
		if (!hasClearanceHere) {
			if (!(m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART))
				AIDepart(st);
			return;
		}
	}
	AIClearInstructions();
	if (!target) return;

	if (IsType(ObjectType::PLAYER) && m_supercruise) {
		const double dist = GetPositionRelTo(target).Length() - target->GetPhysRadius();
		if (m_flightState == SUPERCRUISE || dist > SupercruiseController::SUBLIGHT_AUTOPILOT_MAX_DIST) {
			if (m_flightState == SUPERCRUISE && m_supercruise->IsSafeDisengageReady()) {
				m_supercruise->SafeDisengage();
				return;
			}
			if (m_supercruise->HasAssistModule()) {
				static_cast<Player *>(this)->SetNavTarget(target);
				m_supercruise->SetAssistActive(true, true);
			} else {
				if (m_flightState == SUPERCRUISE && dist <= SupercruiseController::SAFE_DISENGAGE_DIST) {
					m_supercruise->ShowStatusMessage("SLOW DOWN TO DISENGAGE VELOCITY (<1,000 KM/S) BEFORE DOCKING", 5.0f);
				} else {
					m_supercruise->ShowStatusMessage("STATION BEYOND DOCKING COMPUTER RANGE (>2,500 KM) — ENGAGE SUPERCRUISE [J] OR EQUIP AUTOPILOT MK 2", 5.0f);
				}
				Sound::BodyMakeNoise(this, "beep", 0.5f);
			}
			return;
		}
	}

	SetFuelReserve((GetFuel() < 0.5) ? GetFuel() / 2 : 0.25);

	m_curAICmd = new AICmdDock(this, target);
}

void Ship::AIDepart(SpaceStation *target)
{
	if (!target) return;
	if (m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART) return;

	AIClearInstructions();
	SetFuelReserve((GetFuel() < 0.5) ? GetFuel() / 2 : 0.25);

	m_curAICmd = new AICmdDepart(this, target);
}

void Ship::AIOrbit(Body *target, double alt)
{
	if (SpaceStation *st = FindContainingOrbitalStation(this)) {
		if (!(m_curAICmd && m_curAICmd->GetType() == AICommand::CMD_DEPART))
			AIDepart(st);
		return;
	}
	AIClearInstructions();
	if (!target) return;

	if (IsType(ObjectType::PLAYER) && m_supercruise) {
		const double dist = GetPositionRelTo(target).Length() - target->GetPhysRadius() * std::max(alt, 1.0);
		if (m_flightState == SUPERCRUISE || dist > SupercruiseController::SUBLIGHT_AUTOPILOT_MAX_DIST) {
			if (m_flightState == SUPERCRUISE && m_supercruise->IsSafeDisengageReady()) {
				m_supercruise->SafeDisengage();
				return;
			}
			if (m_supercruise->HasAssistModule()) {
				static_cast<Player *>(this)->SetNavTarget(target);
				m_supercruise->SetAssistActive(true, false);
			} else {
				if (m_flightState == SUPERCRUISE && dist <= SupercruiseController::SAFE_DISENGAGE_DIST) {
					m_supercruise->ShowStatusMessage("SLOW DOWN TO DISENGAGE VELOCITY (<1,000 KM/S) BEFORE ORBIT", 5.0f);
				} else {
					m_supercruise->ShowStatusMessage("ORBIT TARGET BEYOND SUB-LIGHT AUTOPILOT RANGE (>2,500 KM) — ENGAGE SUPERCRUISE [J] OR EQUIP AUTOPILOT MK 2", 5.0f);
				}
				Sound::BodyMakeNoise(this, "beep", 0.5f);
			}
			return;
		}
	}

	SetFuelReserve((GetFuel() < 0.5) ? GetFuel() / 2 : 0.25);

	m_curAICmd = new AICmdFlyAround(this, target, alt);
}

void Ship::AIHoldPosition()
{
	AIClearInstructions();
	m_curAICmd = new AICmdHoldPosition(this);
}
