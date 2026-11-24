// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Player.h"

#include "Frame.h"
#include "Game.h"
#include "GameConfig.h"
#include "GameLog.h"
#include "HyperspaceCloud.h"
#include "Lang.h"
#include "Pi.h"
#include "SectorView.h"
#include "Sfx.h"
#include "Space.h"
#include "SpaceStation.h"
#include "StringF.h"
#include "SystemView.h" // for the transfer planner
#include "TerrainBody.h"
#include "WorldView.h"
#include "lua/LuaEvent.h"
#include "lua/LuaObject.h"
#include "pigui/LuaPiGui.h"
#include "planet/WeatherSystem.h"
#include "ship/PlayerShipController.h"
#include "ship/ShipController.h"
#include "ship/SupercruiseController.h"
#include "sound/Sound.h"

//Some player specific sounds
static Sound::Event s_soundUndercarriage;
static Sound::Event s_soundHyperdrive;

Player::Player(const ShipType::Id &shipId) :
	Ship(shipId),
	m_takeoffTimer(0.0f),
	m_takeoffDuration(4.0f),
	m_takeoffFromStation(false)
{
	SetController(new PlayerShipController());
	InitCockpit();
	m_atmosAccel = vector3d(0.0f, 0.0f, 0.0f);

	static_cast<PlayerShipController *>(m_controller)->onChangeTarget.connect([=](Body *target) {
		LuaEvent::Queue(PiGui::GetEventQueue(), "onPlayerTargetChanged", target);
	});
}

Player::Player(const Json &jsonObj, Space *space) :
	Ship(jsonObj, space),
	m_takeoffTimer(0.0f),
	m_takeoffDuration(4.0f),
	m_takeoffFromStation(false)
{
	InitCockpit();

	static_cast<PlayerShipController *>(m_controller)->onChangeTarget.connect([=](Body *target) {
		LuaEvent::Queue(PiGui::GetEventQueue(), "onPlayerTargetChanged", target);
	});
}

void Player::Revive()
{
	Ship::Revive();
	SetNavTarget(nullptr);
	SetCombatTarget(nullptr);
	SetFollowTarget(nullptr);
	if (m_controller) {
		m_controller->SetFlightControlState(CONTROL_MANUAL);
	}
	if (PlayerShipController *psc = GetPlayerController()) {
		psc->SetSpeedLimiterActive(false);
		psc->ResetMouseCapture();
	}
	if (Pi::input) {
		Pi::input->SetCapturingMouse(false);
	}
}

void Player::SetShipType(const ShipType::Id &shipId)
{
	Ship::SetShipType(shipId);
	InitCockpit();
}

void Player::SaveToJson(Json &jsonObj, Space *space)
{
	Ship::SaveToJson(jsonObj, space);
}

void Player::InitCockpit()
{
	delete m_cockpit.release();
	if (!Pi::config->Int("EnableCockpit"))
		return;

	// XXX select a cockpit model. this is all quite skanky because we want a
	// fallback if the name is not found, which means having to actually try to
	// load the model. but ModelBody (on which ShipCockpit is currently based)
	// requires a model name, not a model object. it won't hurt much because it
	// all stays in the model cache anyway, its just awkward. the fix is to fix
	// ShipCockpit so its not a ModelBody and thus does its model work
	// directly, but we're not there yet
	std::string cockpitModelName;
	if (!GetShipType()->cockpitName.empty()) {
		if (Pi::FindModel(GetShipType()->cockpitName, false))
			cockpitModelName = GetShipType()->cockpitName;
	}
	if (cockpitModelName.empty()) {
		if (Pi::FindModel("default_cockpit", false))
			cockpitModelName = "default_cockpit";
	}
	if (!cockpitModelName.empty())
		m_cockpit.reset(new ShipCockpit(cockpitModelName, this));

	OnCockpitActivated();
}

bool Player::DoDamage(float kgDamage)
{
	bool r = Ship::DoDamage(kgDamage);

	// Don't fire audio on EVERY iteration (aka every 16ms, or 60fps), only when exceeds a value randomly
	const float dam = kgDamage * 0.01f;
	if (Pi::rng.Double() < dam && m_lastDamageSound > k_damageSoundInterval) {
		if (!IsDead() && (GetPercentHull() < 25.0f)) {
			Sound::BodyMakeNoise(this, "warning", .5f);
		}
		if (dam < (0.01 * float(GetShipType()->hullMass)))
			Sound::BodyMakeNoise(this, "Hull_hit_Small", 1.0f);
		else
			Sound::BodyMakeNoise(this, "Hull_Hit_Medium", 1.0f);

		m_lastDamageSound = 0.f;
	}
	return r;
}

//XXX perhaps remove this, the sound is very annoying
bool Player::OnDamage(Body *attacker, float kgDamage, const CollisionContact &contactData)
{
	bool r = Ship::OnDamage(attacker, kgDamage, contactData);
	if (!IsDead() && (GetPercentHull() < 25.0f)) {
		Sound::BodyMakeNoise(this, "warning", .5f);
	}
	return r;
}

void Player::OnDocked(SpaceStation *s, int port)
{
	Ship::OnDocked(s, port);

	if (Body *ct = GetCombatTarget(); ct && ct->IsType(ObjectType::SHIP))
		SetCombatTarget(nullptr);
	if (Body *nt = GetNavTarget(); nt && nt->IsType(ObjectType::SHIP))
		SetNavTarget(nullptr);
	if (Body *ft = GetFollowTarget(); ft && ft->IsType(ObjectType::SHIP))
		SetFollowTarget(nullptr);

	LuaEvent::Queue("onPlayerDocked", this, s, port);
}

void Player::OnUndocked(SpaceStation *s, int port)
{
	Ship::OnUndocked(s, port);

	LuaEvent::Queue("onPlayerUndocked", this, s, port);
}

//XXX all ships should make this sound
bool Player::SetWheelState(bool down)
{
	bool did = Ship::SetWheelState(down);
	if (did) {
		s_soundUndercarriage.Play(down ? "UC_out" : "UC_in", 1.0f, 1.0f, 0);
		GetPlayerController()->SetCruiseDirection(down ? PlayerShipController::CRUISE_UP : PlayerShipController::CRUISE_FWD);
	}
	return did;
}

//XXX all ships should make this sound
Missile *Player::SpawnMissile(const MissileDef &def, Body *target)
{
	Missile *m = Ship::SpawnMissile(def, target);
	if (m)
		Sound::PlaySfx("Missile_launch", 1.0f, 1.0f, 0);
	return m;
}

//XXX do in lua, or use the alert concept for all ships
void Player::SetAlertState(Ship::AlertState as)
{
	Ship::AlertState prev = GetAlertState();

	switch (as) {
	case ALERT_NONE:
		if (prev != ALERT_NONE)
			Pi::game->log->Add(Lang::ALERT_CANCELLED);
		break;

	case ALERT_SHIP_NEARBY:
		if (prev == ALERT_NONE)
			Pi::game->log->Add(Lang::SHIP_DETECTED_NEARBY);
		else
			Pi::game->log->Add(Lang::DOWNGRADING_ALERT_STATUS);
		Sound::PlaySfx("OK");
		break;

	case ALERT_SHIP_FIRING:
		Pi::game->log->Add(Lang::LASER_FIRE_DETECTED);
		Sound::PlaySfx("notify_beep", 0.4f, 0.4f, 0);
		break;

	case ALERT_MISSILE_DETECTED:
		Pi::game->log->Add(Lang::MISSILE_DETECTED);
		Sound::PlaySfx("warning", 0.2f, 0.2f, 0);
		break;
	}

	Ship::SetAlertState(as);
}

void Player::NotifyRemoved(const Body *const removedBody)
{
	if (GetNavTarget() == removedBody)
		SetNavTarget(0);

	if (GetCombatTarget() == removedBody) {
		SetCombatTarget(0);

		if (!GetNavTarget() && removedBody->IsType(ObjectType::SHIP))
			SetNavTarget(static_cast<const Ship *>(removedBody)->GetHyperspaceCloud());
	}

	if (GetFollowTarget() == removedBody) {
		SetFollowTarget(0);
		// turn on manual mode, otherwise the ship will start to drop speed to 0
		// relative to the frame
		if (m_controller->GetFlightControlState() == CONTROL_FIXSPEED) {
			m_controller->SetFlightControlState(CONTROL_MANUAL);
		}
	}

	Ship::NotifyRemoved(removedBody);
}

void Player::OnStartHyperspaceJumpSurge()
{
	if (!m_hyperspace.sounds.jump_sound.empty()) {
		s_soundHyperdrive.Play(m_hyperspace.sounds.jump_sound.c_str());
		m_hyperspaceJumpSoundPlayed = true;
	}
}

void Player::OnBeforeEnterHyperspace()
{
	Ship::OnBeforeEnterHyperspace();

	LuaEvent::Queue("onLeaveSystem", this);
}

//XXX ui stuff
void Player::OnEnterHyperspace()
{
	if (!m_hyperspaceJumpSoundPlayed && !m_hyperspace.sounds.jump_sound.empty()) {
		s_soundHyperdrive.Play(m_hyperspace.sounds.jump_sound.c_str());
	}
	m_hyperspaceJumpSoundPlayed = false;
	SetNavTarget(0);
	SetCombatTarget(0);
	SetFollowTarget(0);

	m_controller->SetFlightControlState(CONTROL_MANUAL); //could set CONTROL_HYPERDRIVE
	ClearThrusterState();
	Pi::game->WantHyperspace();
}

void Player::OnEnterSystem()
{
	m_hyperspaceJumpSoundPlayed = false;
	m_controller->SetFlightControlState(CONTROL_MANUAL);
}

//temporary targeting stuff
PlayerShipController *Player::GetPlayerController() const
{
	return static_cast<PlayerShipController *>(GetController());
}

Body *Player::GetCombatTarget() const
{
	return static_cast<PlayerShipController *>(m_controller)->GetCombatTarget();
}

Body *Player::GetNavTarget() const
{
	return static_cast<PlayerShipController *>(m_controller)->GetNavTarget();
}

Body *Player::GetFollowTarget() const
{
	return static_cast<PlayerShipController *>(m_controller)->GetFollowTarget();
}

void Player::SetCombatTarget(Body *const target, bool setFollowTo)
{
	static_cast<PlayerShipController *>(m_controller)->SetCombatTarget(target, setFollowTo);
}

void Player::SetNavTarget(Body *const target)
{
	static_cast<PlayerShipController *>(m_controller)->SetNavTarget(target);
}

void Player::SetFollowTarget(Body *const target)
{
	static_cast<PlayerShipController *>(m_controller)->SetFollowTarget(target);
}

void Player::ChangeCruiseSpeed(double delta)
{
	static_cast<PlayerShipController *>(m_controller)->ChangeCruiseSpeed(delta);
}

//temporary targeting stuff ends

Ship::HyperjumpStatus Player::InitiateHyperjumpTo(const SystemPath &dest, int warmup_time, double duration, const HyperdriveSoundsTable &sounds, LuaRef checks)
{
	if (!dest.HasValidSystem() || (GetFlightState() != FLYING && GetFlightState() != SUPERCRUISE) || warmup_time < 1)
		return HYPERJUMP_SAFETY_LOCKOUT;

	if (Pi::game && Pi::game->GetSpace()) {
		StarSystem *s = Pi::game->GetSpace()->GetStarSystem().Get();
		if (s && s->GetPath().IsSameSystem(dest))
			return HYPERJUMP_CURRENT_SYSTEM;
	}

	if (SupercruiseController *sc = GetSupercruise()) {
		if (sc->GetCooldown() > 0.0f) {
			char buf[128];
			snprintf(buf, sizeof(buf), "FSD COOLDOWN ACTIVE (%.1fs)", sc->GetCooldown());
			sc->ShowStatusMessage(buf, 4.0f);
			Sound::BodyMakeNoise(this, "notify_beep", 0.7f);
			return HYPERJUMP_SAFETY_LOCKOUT;
		}
	}

	if (const Body *blocker = GetHyperspaceTargetObscuredBy(dest)) {
		if (SupercruiseController *sc = GetSupercruise())
			sc->ShowStatusMessage("HYPERJUMP BLOCKED: TARGET OBSCURED BY " + blocker->GetLabel(), 4.5f);
		Sound::BodyMakeNoise(this, "notify_beep", 0.7f);
		return HYPERJUMP_OBSCURED;
	}

	if (SupercruiseController *sc = GetSupercruise()) {
		if (sc->IsCharging())
			sc->AbortCharge("HYPERJUMP FSD CHARGING");
	}

	m_hyperspaceJumpSoundPlayed = false;
	HyperjumpStatus status = Ship::InitiateHyperjumpTo(dest, warmup_time, duration, sounds, checks);

	if (status == HYPERJUMP_OK)
		s_soundHyperdrive.Play(m_hyperspace.sounds.warmup_sound.c_str());

	return status;
}

void Player::AbortHyperjump()
{
	if (IsHyperspaceJumpSurging())
		return;
	m_hyperspaceJumpSoundPlayed = false;
	s_soundHyperdrive.Play(m_hyperspace.sounds.abort_sound.c_str());
	Ship::AbortHyperjump();
}

void Player::OnCockpitActivated()
{
	if (m_cockpit)
		m_cockpit->OnActivated(this);
}

void Player::StaticUpdate(const float timeStep)
{
	Ship::StaticUpdate(timeStep);

	// now insert the latest value
	vector3d current_atmosAccel = GetAtmosForce() * (1.0 / GetMass());
	m_atmosJerk = (current_atmosAccel - m_atmosAccel) * Pi::game->GetInvTimeAccelRate();
	bool playCreak = false;

	// play creaking sfx if the acceleration along the Y axis (up/down directions) is higher than 1g
	// and the rate of change of acceleration is more than 2.5 m s-3, or during heavy atmospheric turbulence
	if ((abs(m_atmosAccel.Dot(Player::m_interpOrient.VectorY()))) > 10 && abs(m_atmosJerk.Dot(Player::m_interpOrient.VectorY())) > 2.5) {
		playCreak = true;
	}

	float creakVol = fmax(0.f, fmin(float((m_atmosJerk.Length() - 50) * 0.05f), 0.3f));
	WeatherState weather;
	if (GetFlightState() == FLYING && GetCurrentWeatherState(weather) && weather.turbulence > 0.55 && weather.densityKgM3 > 0.15) {
		playCreak = true;
		const float turbCreakVol = float(Clamp((weather.turbulence - 0.55) / 0.45, 0.0, 1.0)) * 0.16f;
		creakVol = std::max(creakVol, turbCreakVol);
	}

	if (playCreak) {
		if (!m_creakSound.IsPlaying()) {
			m_creakSound.Play("metal_creaking", creakVol, creakVol, Sound::OP_REPEAT);
			m_creakSound.VolumeAnimate(creakVol, creakVol, 0.3f, 0.3f);
		}
	} else if (m_creakSound.IsPlaying()) {
		m_creakSound.FadeOut(1.5f);
	}
	m_atmosAccel = current_atmosAccel;

	// XXX even when not on screen. hacky, but really cockpit shouldn't be here
	// anyway so this will do for now
	if (m_cockpit)
		m_cockpit->Update(this, timeStep);

	if (m_takeoffTimer > 0.0f) {
		if (GetFlightState() != Ship::FLYING) {
			m_takeoffTimer = 0.0f;
			m_takeoffFromStation = false;
		} else {
			m_takeoffTimer -= timeStep;
			if (m_takeoffTimer <= 0.0f) {
				m_takeoffTimer = 0.0f;
				m_takeoffFromStation = false;
				ResetLaunchLockTimeout();
				auto con = GetPlayerController();
				if (con && con->GetFlightControlState() == CONTROL_FIXSPEED && con->GetCruiseDirection() == PlayerShipController::CRUISE_UP) {
					// Pad clearance achieved: transition cleanly to forward manual flight mode with full thruster authority
					con->SetCruiseDirection(PlayerShipController::CRUISE_FWD);
					con->SetFlightControlState(CONTROL_MANUAL);
				}
			}
		}
	}
}

bool Player::TakeoverUndocking()
{
	bool handled = false;
	if (m_takeoffTimer > 0.0f) {
		m_takeoffTimer = 0.0f;
		m_takeoffFromStation = false;
		ResetLaunchLockTimeout();
		if (PlayerShipController *con = GetPlayerController()) {
			con->SetCruiseDirection(PlayerShipController::CRUISE_FWD);
			if (con->GetFlightControlState() != CONTROL_FIXSPEED) {
				con->SetFlightControlState(CONTROL_MANUAL);
			}
		}
		handled = true;
	}

	if (GetFlightState() == Ship::UNDOCKING) {
		handled = Ship::TakeoverUndocking() || handled;
		if (PlayerShipController *con = GetPlayerController()) {
			con->SetCruiseDirection(PlayerShipController::CRUISE_FWD);
		}
	}

	return handled;
}

int Player::GetManeuverTime() const
{
	if (Pi::planner->GetOffsetVel().ExactlyEqual(vector3d::Zero)) {
		return 0;
	}
	return Pi::planner->GetStartTime();
}

vector3d Player::GetManeuverVelocity() const
{
	Frame *frame = Frame::GetFrame(GetFrame());
	if (frame->IsRotFrame())
		frame = Frame::GetFrame(frame->GetNonRotFrame());
	const SystemBody *systemBody = frame->GetSystemBody();

	if (Pi::planner->GetOffsetVel().ExactlyEqual(vector3d::Zero)) {
		return vector3d::Zero;
	} else if (systemBody) {
		Orbit playerOrbit = ComputeOrbit();
		if (!is_zero_exact(playerOrbit.GetSemiMajorAxis())) {
			double mass = systemBody->GetMass();
			// XXX The best solution would be to store the mass(es) on Orbit
			const vector3d velocity = (Pi::planner->GetVel() - playerOrbit.OrbitalVelocityAtTime(mass, playerOrbit.OrbitalTimeAtPos(Pi::planner->GetPosition(), mass)));
			return velocity;
		}
	}
	return vector3d::Zero;
}

void Player::DoFixspeedTakeoff(SpaceStation *from)
{
	auto con = GetPlayerController();
	m_takeoffTimer = 0.0f;
	m_takeoffFromStation = (from != nullptr);

	const bool isGround = !from || from->IsGroundStation();
	const double wantSpeed = isGround ? 18.0 : 10.0; // m/s - brisk positive liftoff clear of pad/surface
	if (con->IsSpeedLimiterActive() && con->GetSpeedLimit() < wantSpeed) {
		con->SetSpeedLimiterActive(false);
	}

	// special preparations for launch
	if (from && !from->IsGroundStation()) {
		SetFlightState(Ship::FLYING);
		SetFollowTarget(from);
		con->SetFollowMode(PlayerShipController::FOLLOW_ORI);
		auto pPos = GetPositionRelTo(from);
		SetAngVelocity(from->GetAngVelocity());

		// Clear pad collision mesh margin and set positive radial and tangential velocity
		SetPosition(GetPosition() + GetOrient().VectorY() * 0.2);
		auto tangent = from->GetAngVelocity().Cross(pPos);
		auto radial = GetOrient().VectorY() * 1.5;
		SetVelocity(from->GetVelocity() + tangent + radial);
	} else if (from && from->IsGroundStation()) {
		SetFlightState(Ship::FLYING);
		SetPosition(GetPosition() + GetOrient().VectorY() * 0.5);
		SetVelocity(from->GetVelocity() + GetOrient().VectorY() * 2.5);
		CalcExternalForce();
	} else {
		vector3d up = GetPosition().NormalizedSafe();
		if (up.LengthSqr() < 0.5) {
			up = GetOrient().VectorY().NormalizedSafe();
		}
		Frame *f = Frame::GetFrame(GetFrame());
		if (f && f->GetBody() && f->GetBody()->IsType(ObjectType::TERRAINBODY)) {
			const double terrRadius = static_cast<const TerrainBody *>(f->GetBody())->GetTerrainHeight(up);
			const double minClearRadius = terrRadius - GetAabb().min.y + 2.0;
			if (GetPosition().Length() < minClearRadius) {
				SetPosition(up * minClearRadius);
			} else {
				SetPosition(GetPosition() + up * 2.0);
			}
		} else {
			SetPosition(GetPosition() + up * 2.0);
		}
		SetVelocity(up * 3.0);
		SetAngVelocity(vector3d::Zero);
		SetFlightState(Ship::FLYING);
		CalcExternalForce();
	}

	con->SetCruiseDirection(PlayerShipController::CRUISE_UP);
	con->SetFlightControlState(CONTROL_FIXSPEED);
	const double curSpeed = con->GetCruiseSpeed();
	con->ChangeCruiseSpeed(wantSpeed - curSpeed);
	m_takeoffDuration = 4.0f;
	m_takeoffTimer = m_takeoffDuration;
}
