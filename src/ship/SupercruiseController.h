// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#pragma once

#include "JsonFwd.h"
#include "vector3.h"
#include <string>

class Ship;
class Body;

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
		SC_NOT_FLYING
	};

	SupercruiseController(Ship *ship);
	~SupercruiseController() = default;

	void SaveToJson(Json &jsonObj) const;
	void LoadFromJson(const Json &jsonObj);

	// State queries
	bool IsActive() const;
	bool IsCharging() const { return m_charging; }
	float GetChargeProgress() const { return m_charging ? (1.0f - m_chargeCountdown / CHARGE_DURATION) : 0.0f; }
	float GetChargeCountdown() const { return m_chargeCountdown; }
	float GetCooldown() const { return m_cooldown; }
	bool IsMassLocked(std::string *outReason = nullptr) const;
	Status GetStatus(std::string *outReason = nullptr) const;

	// Speed & Throttle (0.0 to 1.0)
	double GetThrottle() const { return m_throttle; }
	void SetThrottle(double throttle);
	void ChangeThrottle(double delta);
	double GetSpeed() const { return m_speed; }
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
	void SafeDisengage();
	void NormalDrop(const std::string &reason = "");
	void EmergencyDrop(const std::string &reason = "");
	void OnEnterHyperspace();

	// Per-frame updates
	void StaticUpdate(float timeStep);
	void TimeStepUpdate(float timeStep, const vector3d &desiredAngInput);

	// Heat spike from emergency drop
	double GetHeatSpike() const { return m_heatSpike; }

	// Status message for HUD
	const std::string &GetStatusMessage() const { return m_statusMessage; }
	float GetStatusMessageTimer() const { return m_statusMessageTimer; }
	void ShowStatusMessage(const std::string &msg, float duration = 4.0f);

	// Compute exclusion zone radius (in meters) from body center
	static double GetExclusionZoneRadius(const Body *body);

private:
	void UpdateEnvironmentAndTarget(float timeStep, Body **outHitExclusionBody);
	Body *GetActiveTarget() const;

	Ship *m_ship;
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

	double m_heatSpike = 0.0;

	std::string m_statusMessage;
	float m_statusMessageTimer = 0.0f;
};

