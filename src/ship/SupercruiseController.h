// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#pragma once

#include "FrameId.h"
#include "JsonFwd.h"
#include "vector3.h"
#include <deque>
#include <string>

class Body;
class Planet;
class Ship;
class Space;

class SupercruiseController {
public:
	static constexpr double LIGHT_SPEED = 299792458.0;        // 1c in m/s
	static constexpr double MIN_SPEED = 30000.0;              // 30 km/s (0.0001c)
	static constexpr double MIN_ENGAGE_SPEED = 500.0;         // 500 m/s minimum sublight engagement speed
	static constexpr double MAX_SPEED = 2001.0 * LIGHT_SPEED; // 2,001c in m/s
	static constexpr double SAFE_DISENGAGE_DIST = 1000000.0;  // 1,000 km
	static constexpr double SAFE_DISENGAGE_SPEED = 1000000.0; // 1,000 km/s
	static constexpr double SUBLIGHT_AUTOPILOT_MAX_DIST = 2500000.0; // 2,500 km (covers safe drop-in envelope + approach buffer)
	static constexpr float CHARGE_DURATION = 5.0f;            // 5s FSD charge-up
	static constexpr float NORMAL_COOLDOWN = 5.0f;            // 5s normal FSD cooldown
	static constexpr float HYPERJUMP_COOLDOWN = 12.0f;        // 12s post-hyperjump FSD cooldown
	static constexpr float EMERGENCY_COOLDOWN = 25.0f;        // 25s emergency FSD cooldown
	static constexpr double STATION_MASS_LOCK_DIST = 5000.0;  // 5 km station mass lock
	static constexpr double PLANET_MASS_LOCK_ALT = 5000.0;    // 5 km surface mass lock

	enum Status {
		SC_READY,
		SC_CHARGING,
		SC_ACTIVE,
		SC_COOLDOWN,
		SC_MASS_LOCKED,
		SC_GEAR_DOWN,
		SC_TOO_SLOW,
		SC_FSD_OFFLINE,
		SC_NOT_FLYING
	};

	enum InterdictionRole {
		INTERDICT_NONE = 0,
		INTERDICT_ATTACKER,
		INTERDICT_TARGET
	};

	SupercruiseController(Ship *ship);
	~SupercruiseController() = default;

	void SaveToJson(Json &jsonObj, Space *space = nullptr) const;
	void LoadFromJson(const Json &jsonObj);
	void PostLoadFixup(Space *space);
	void OnDeleted(const Body *body);

	// AI target assignment (for non-player ships)
	void SetTarget(Body *target);
	void SetTargetPosition(FrameId frameId, const vector3d &offset);
	Body *GetTarget() const { return m_target; }
	void ComputeAISteering(const vector3d &targetPosRelToShip, const Body *targetBody, vector3d &outAngInput, double &outThrottle) const;

	// State queries
	bool IsActive() const;
	bool IsCharging() const { return m_charging; }
	float GetChargeProgress() const { return m_charging ? (1.0f - m_chargeCountdown / CHARGE_DURATION) : 0.0f; }
	float GetChargeCountdown() const { return m_chargeCountdown; }
	float GetCooldown() const { return m_cooldown; }
	bool IsMassLocked(std::string *outReason = nullptr) const;
	double GetShipMassLockFactor() const;
	bool IsFsdOffline() const { return m_fsdOffline; }
	void SetFsdOffline(bool offline);
	Status GetStatus(std::string *outReason = nullptr) const;

	// Speed & Throttle (0.0 to 1.0)
	double GetThrottle() const { return m_throttle; }
	void SetThrottle(double throttle);
	void ChangeThrottle(double delta);
	double GetSpeed() const { return m_speed; }
	void SetSpeed(double speed);
	double GetMaxEnvSpeed() const { return m_maxEnvSpeed; }
	double GetDesiredSpeed() const { return m_desiredSpeed; }
	double GetGravityStrain() const { return m_gravityStrain; }

	// Target telemetry & Safe Disengage
	bool IsSafeDisengageReady() const { return m_safeDisengageReady; }
	bool IsSlowDownWarning() const { return m_slowDownWarning; }
	double GetTargetDistance() const { return m_targetDistance; }
	double GetTargetETA() const { return m_targetETA; }

	// Supercruise Assist (Autopilot Mk 2)
	bool HasAssistModule() const;
	bool IsAssistActive() const { return m_assistActive; }
	void SetAssistActive(bool active, bool dockOnArrival = false);
	void ToggleAssist();

	// Actions
	bool Toggle();
	bool StartCharge();
	void AbortCharge(const std::string &reason = "");
	void EnterSupercruise();
	void EnterSupercruiseImmediate(double initialSpeed = MIN_SPEED);
	void EnterSupercruiseOnHyperspaceExit();
	void SafeDisengage();
	void NormalDrop(const std::string &reason = "");
	void EmergencyDrop(const std::string &reason = "");
	void Reset();
	void OnEnterHyperspace();

	// Per-frame updates
	void StaticUpdate(float timeStep);
	void TimeStepUpdate(float timeStep, const vector3d &desiredAngInput);

	// Heat spike from emergency drop / stellar corona scooping
	double GetHeatSpike() const { return m_heatSpike; }

	// Stellar fuel scooping telemetry (active in Supercruise near scoopable stars)
	bool IsFuelScoopActive() const { return m_fuelScoopActive; }
	bool IsFuelScoopUnscoopable() const { return m_fuelScoopUnscoopable; }
	double GetFuelScoopRate() const { return m_fuelScoopRate; }
	double GetFuelScoopProximity() const { return m_fuelScoopProximity; }

	// Recent root-frame trajectory samples for curved FTL motion-blur trails
	static constexpr size_t MAX_TRAIL_SAMPLES = 12;
	const std::deque<vector3d> &GetTrailPositions() const { return m_trailPositions; }

	// FSD Interdiction
	int GetInterdictorLevel() const;
	bool HasFSDInterdictor() const { return GetInterdictorLevel() > 0; }
	bool HasInterdictionNullifier() const;
	float GetNullifierCooldown() const { return m_nullifierCooldown; }
	bool CanInterdict(const Ship *target, std::string *outReason = nullptr) const;
	bool StartInterdiction(Ship *target);
	bool IsInterdicting() const { return m_interdictRole == INTERDICT_ATTACKER; }
	bool IsBeingInterdicted() const { return m_interdictRole == INTERDICT_TARGET; }
	Ship *GetInterdictionPeer() const { return m_interdictPeer; }
	double GetInterdictionCaptureProgress() const { return m_captureProgress; }
	double GetInterdictionEscapeProgress() const { return m_escapeProgress; }
	const vector3d &GetEscapeVectorWorld() const { return m_escapeDirWorld; }
	bool IsSubmittingToInterdiction() const { return m_submitting || (IsBeingInterdicted() && m_throttle <= 0.02); }
	void ClearInterdiction();

	// Status message for HUD
	const std::string &GetStatusMessage() const { return m_statusMessage; }
	float GetStatusMessageTimer() const { return m_statusMessageTimer; }
	void ShowStatusMessage(const std::string &msg, float duration = 4.0f);

	// Compute exclusion zone radius (in meters) from body center
	static double GetExclusionZoneRadius(const Body *body);
	static double GetExclusionZoneRadiusAtDir(const Body *body, const vector3d &unitDirInBodyFrame);

	// Planetary occlusion queries & great-circle bypass routing
	const Body *GetTargetObscuredBy(const vector3d &targetPosRelToShip, const Body *targetBody) const;
	bool IsTargetOccluded(Body **outBlocker = nullptr) const;

private:
	void UpdateEnvironmentAndTarget(float timeStep, Body **outHitExclusionBody);
	void UpdateStellarFuelScoop(float timeStep);
	void ResetFuelScoopState();
	void UpdateInterdiction(float timeStep);
	static void DropPairFromInterdiction(Ship *attacker, Ship *target, bool submitted);
	void ClearStaleSupercruiseTarget();
	void EnsureShipAboveTerrainAndSyncFrame();
	void DropIntoRing(Planet *planet, const std::string &reason);
	Body *GetActiveTarget() const;
	bool GetActiveTargetPosRelToShip(vector3d &outPosRelToShip) const;

	Ship *m_ship;
	Body *m_target = nullptr;
	int m_targetIndex = 0;
	FrameId m_targetFrame;
	vector3d m_targetOffset = vector3d(0.0);
	bool m_charging = false;
	float m_chargeCountdown = 0.0f;
	float m_cooldown = 0.0f;
	double m_throttle = 0.5;
	double m_speed = 0.0;
	double m_maxEnvSpeed = MAX_SPEED;
	double m_desiredSpeed = MIN_SPEED;
	double m_gravityStrain = 0.0;

	bool m_safeDisengageReady = false;
	bool m_slowDownWarning = false;
	double m_targetDistance = 0.0;
	double m_targetETA = 0.0;

	bool m_assistActive = false;
	bool m_dockOnArrival = false;
	Planet *m_ringDropPlanet = nullptr;
	Planet *m_ringImmersionPlanet = nullptr;

	double m_heatSpike = 0.0;
	bool m_fsdOffline = false;
	std::deque<vector3d> m_trailPositions;
	float m_trailSampleTimer = 0.0f;

	InterdictionRole m_interdictRole = INTERDICT_NONE;
	Ship *m_interdictPeer = nullptr;
	int m_interdictPeerIndex = 0;
	double m_captureProgress = 0.30;
	double m_escapeProgress = 0.30;
	double m_escapeWanderTime = 0.0;
	double m_submitTimer = 0.0;
	bool m_submitting = false;
	vector3d m_escapeBaseDir = vector3d(0.0, 0.0, -1.0);
	vector3d m_escapeDirWorld = vector3d(0.0, 0.0, -1.0);

	std::string m_statusMessage;
	float m_statusMessageTimer = 0.0f;
	float m_nullifierCooldown = 0.0f;

	bool m_fuelScoopActive = false;
	bool m_fuelScoopUnscoopable = false;
	double m_fuelScoopRate = 0.0;
	double m_fuelScoopProximity = 0.0;
	double m_fuelScoopAccum = 0.0;
	float m_fuelScoopDispatchTimer = 0.0f;
};

